import Foundation
import Testing
@testable import PureMacKit

/// The cleanup journal must be written before anything moves, and a history write that fails — or
/// silently changes nothing — must never go unnoticed. Failures are injected with real SQLite
/// triggers (`RAISE(ABORT)` fails a write, `RAISE(IGNORE)` makes it change zero rows) installed
/// through a second connection. Items move only into a fixture folder, never the real Trash.
@Suite("Cleanup journal reliability")
struct JournalReliabilityTests {
    struct Env {
        let home: Fixture
        let trash: String
        let databaseURL: URL
        let store: LocalStore

        func executor(remover: (any FileRemover)? = nil, store: LocalStore?? = nil) -> CleanupExecutor {
            CleanupExecutor(store: store ?? self.store, remover: remover ?? FolderTrashRemover(trashDirectory: trash),
                            policy: SafetyPolicy(homeDirectory: home.path), running: FakeRunningApps())
        }

        /// Installs a trigger (or any SQL) through a separate connection to the same file.
        func inject(_ sql: String) throws {
            try SQLiteConnection(path: databaseURL.path).execute(sql)
        }

        func count(_ sql: String) throws -> Int {
            let s = try SQLiteConnection(path: databaseURL.path).prepare(sql)
            _ = try s.step()
            return s.int(0)
        }
    }

    func env() throws -> Env {
        let home = try Fixture("home")
        let trash = home.root.deletingLastPathComponent().appendingPathComponent("FixtureTrash").path
        let url = home.databaseURL()
        return Env(home: home, trash: trash, databaseURL: url, store: try LocalStore(url: url))
    }

    /// Three cache folders of different sizes, planned in this order.
    func threeItemPlan(_ e: Env) throws -> CleanupPlan {
        var candidates: [CleanupCandidate] = []
        for (index, name) in ["one", "two", "three"].enumerated() {
            try e.home.file("Library/Caches/com.example.\(name)/blob", size: 8_192 * (index + 1))
            let path = e.home.path("Library/Caches/com.example.\(name)")
            let st = try FileStat.lstat(path).get()
            let size = DirectorySizer.measure(path)
            candidates.append(CleanupCandidate(path: path, title: name, reason: "r", category: .appCache, risk: .low, source: .rule(id: "test"),
                                               logicalSize: size.logicalSize, allocatedSize: size.allocatedSize, itemCount: size.fileCount,
                                               modified: st.modified, identity: st.identity, isPreselected: true,
                                               scopeRoot: e.home.path("Library/Caches")))
        }
        return CleanupPlanner.plan(mode: .smartClean, title: "Journal test", selected: candidates)
    }

    func allStillInPlace(_ e: Env) -> Bool {
        ["one", "two", "three"].allSatisfy { e.home.exists("Library/Caches/com.example.\($0)/blob") }
    }

    // MARK: Before the first move

    @Test func missingJournalMovesNothing() async throws {
        let e = try env()
        let plan = try threeItemPlan(e)
        let before = e.home.snapshot()
        await #expect(throws: CleanupError.journalUnavailable) {
            _ = try await e.executor(store: .some(nil)).execute(plan)
        }
        #expect(e.home.snapshot() == before)
    }

    @Test func failedOperationRowMovesNothing() async throws {
        let e = try env()
        let plan = try threeItemPlan(e)
        let before = e.home.snapshot()
        try e.inject("CREATE TRIGGER fail_op BEFORE INSERT ON cleanup_operation BEGIN SELECT RAISE(ABORT, 'injected'); END")
        await #expect(throws: CleanupError.self) { _ = try await e.executor().execute(plan) }
        #expect(e.home.snapshot() == before)
        #expect(try await e.store.operations().isEmpty)
    }

    @Test(arguments: ["RAISE(ABORT, 'injected')", "RAISE(IGNORE)"])
    func failedPendingItemRollsBackEverything(_ raise: String) async throws {
        let e = try env()
        let plan = try threeItemPlan(e)
        let before = e.home.snapshot()
        // The third pending row fails (or is silently dropped) after two were written.
        try e.inject("CREATE TRIGGER fail_item BEFORE INSERT ON cleanup_item WHEN NEW.seq = 2 BEGIN SELECT \(raise); END")
        await #expect(throws: CleanupError.self) { _ = try await e.executor().execute(plan) }
        #expect(e.home.snapshot() == before)
        #expect(try e.count("SELECT COUNT(*) FROM cleanup_operation") == 0)
        #expect(try e.count("SELECT COUNT(*) FROM cleanup_item") == 0)
    }

    @Test func wholeJournalIsCommittedBeforeTheFirstMove() async throws {
        let e = try env()
        let plan = try threeItemPlan(e)
        let probe = JournalProbe(base: FolderTrashRemover(trashDirectory: e.trash), databaseURL: e.databaseURL)
        let result = try await e.executor(remover: probe).execute(plan)
        #expect(result.movedCount == 3)
        // Read through another connection at the moment of the first move: committed, all pending.
        #expect(probe.firstMoveSaw == ProbeCounts(operations: 1, items: 3, pending: 3))
    }

    @Test func journalConnectionIsFullyDurable() async throws {
        let e = try env()
        #expect(try await e.store.synchronousMode() == 2)                  // FULL
        let scanner = try DatabaseSchema.open(at: e.databaseURL, durability: .normal)
        let s = try scanner.prepare("PRAGMA synchronous")
        _ = try s.step()
        #expect(s.int(0) == 1)                                             // NORMAL, batched
    }

    // MARK: After items move

    @Test(arguments: ["RAISE(ABORT, 'injected')", "RAISE(IGNORE)"])
    func failedOutcomeStopsTheRunAndKeepsTheTruth(_ raise: String) async throws {
        let e = try env()
        let plan = try threeItemPlan(e)
        try e.inject("CREATE TRIGGER fail_outcome BEFORE UPDATE ON cleanup_item WHEN NEW.seq = 0 BEGIN SELECT \(raise); END")
        let result = try await e.executor().execute(plan)

        // The first item really moved and is reported as moved, with its Trash location and bytes.
        #expect(result.outcomes.map(\.status) == [.movedToTrash, .skipped, .skipped])
        let trashPath = try #require(result.outcomes[0].trashPath)
        #expect(FileManager.default.fileExists(atPath: trashPath + "/blob"))
        #expect(result.bytesMovedToTrash == plan.items[0].allocatedSize)
        #expect(result.journalProblem != nil)
        // Nothing after it moved.
        #expect(!e.home.exists("Library/Caches/com.example.one"))
        #expect(e.home.exists("Library/Caches/com.example.two/blob"))
        #expect(e.home.exists("Library/Caches/com.example.three/blob"))
        // The summary still records what happened, and marks the history as incomplete.
        let op = try #require(try await e.store.operations().first)
        #expect(op.status == "incomplete")
        #expect(op.movedCount == 1)
        #expect(op.bytesMovedToTrash == plan.items[0].allocatedSize)
    }

    @Test(arguments: ["RAISE(ABORT, 'injected')", "RAISE(IGNORE)"])
    func failedSummaryIsReported(_ raise: String) async throws {
        let e = try env()
        let plan = try threeItemPlan(e)
        try e.inject("CREATE TRIGGER fail_summary BEFORE UPDATE ON cleanup_operation BEGIN SELECT \(raise); END")
        let result = try await e.executor().execute(plan)
        #expect(result.movedCount == 3)
        #expect(result.bytesMovedToTrash == plan.identifiedAllocatedBytes)
        #expect(result.journalProblem != nil)
        // Every item outcome was recorded; the next launch turns the operation into "interrupted"
        // with the counts its items recorded.
        let operationID = try #require(result.operationID)
        let items = try await e.store.items(operationID: operationID)
        #expect(items.allSatisfy { $0.status == .movedToTrash && $0.trashPath != nil })
        try e.inject("DROP TRIGGER fail_summary")
        try await e.store.markInterruptedOperations()
        let op = try #require(try await e.store.operations().first)
        #expect(op.status == "interrupted")
        #expect(op.movedCount == 3)
        #expect(op.bytesMovedToTrash == plan.identifiedAllocatedBytes)
    }

    @Test func interruptedOperationCountsOnlyRecordedItems() async throws {
        let e = try env()
        let plan = try threeItemPlan(e)
        // A crash after the journal was written: no outcome and no summary were recorded.
        _ = try await e.store.beginOperation(plan: plan, detailed: true)
        try await e.store.markInterruptedOperations()
        let op = try #require(try await e.store.operations().first)
        #expect(op.status == "interrupted")
        #expect(op.movedCount == 0 && op.failedCount == 0 && op.skippedCount == 0)
        let items = try await e.store.items(operationID: op.id)
        #expect(items.count == 3 && items.allSatisfy { $0.status == .pending })
    }

    @Test func outcomeForAMissingRowIsAnError() async throws {
        let e = try env()
        let outcome = CleanupItemOutcome(path: "/x", status: .movedToTrash, allocatedSize: 1, logicalSize: 1)
        await #expect(throws: SQLiteChangeCountError.self) {
            try await e.store.journalOutcome(itemID: 4_242, outcome: outcome, detailed: true)
        }
    }

    // MARK: Put Back

    @Test(arguments: ["RAISE(ABORT, 'injected')", "RAISE(IGNORE)"])
    func putBackWithFailedHistoryStillRestores(_ raise: String) async throws {
        let e = try env()
        let plan = try threeItemPlan(e)
        let executor = e.executor()
        let result = try await executor.execute(plan)
        let operationID = try #require(result.operationID)
        let record = try #require(try await e.store.items(operationID: operationID).first)
        try e.inject("CREATE TRIGGER fail_restore BEFORE UPDATE ON cleanup_item WHEN NEW.status = 'restored' BEGIN SELECT \(raise); END")

        let outcome = await executor.restore(record)
        guard case .restoredWithHistoryWarning = outcome else {
            Issue.record("expected a restore with a history warning, got \(outcome)")
            return
        }
        #expect(outcome.isRestored)
        #expect(e.home.exists("Library/Caches/com.example.one/blob"))       // the file is back
        let after = try #require(try await e.store.items(operationID: record.operationID).first)
        #expect(after.status == .movedToTrash)                              // History could not record it
    }

    @Test func putBackRecordsTheRestore() async throws {
        let e = try env()
        let plan = try threeItemPlan(e)
        let executor = e.executor()
        let result = try await executor.execute(plan)
        let operationID = try #require(result.operationID)
        let record = try #require(try await e.store.items(operationID: operationID).first)
        #expect(await executor.restore(record) == .restored)
        #expect(try await e.store.items(operationID: record.operationID).first?.status == .restored)
        // A second Put Back of the same record is refused by the file checks, and recording it
        // again would change no row.
        await #expect(throws: SQLiteChangeCountError.self) { try await e.store.markRestored(itemID: record.id) }
    }
}

// MARK: - SQLite connection lifetime

@Suite("SQLite connection lifetime")
struct SQLiteLifetimeTests {
    @Test func statementKeepsItsConnectionUntilFinalized() throws {
        let f = try Fixture()
        let url = f.databaseURL()
        weak var weakConnection: SQLiteConnection?
        var statement: SQLiteStatement? = try {
            let connection = try SQLiteConnection(path: url.path)
            weakConnection = connection
            return try connection.prepare("SELECT 41 + 1")
        }()
        #expect(weakConnection != nil)                    // only the statement holds it
        #expect(try statement?.step() == true)
        #expect(statement?.int(0) == 42)
        statement = nil
        #expect(weakConnection == nil)                    // released with its last statement
    }

    @Test func statementOfATemporaryConnectionReportsErrors() throws {
        let f = try Fixture()
        let url = f.databaseURL()
        try SQLiteConnection(path: url.path).execute("CREATE TABLE t(x INTEGER CHECK (x > 0))")
        // The connection is a temporary: nothing but the statement keeps it alive.
        let insert = try SQLiteConnection(path: url.path).prepare("INSERT INTO t(x) VALUES (?)")
        do {
            try insert.run(.int(-1))
            Issue.record("the CHECK constraint should have failed")
        } catch let error as SQLiteError {
            #expect(error.message.contains("CHECK constraint failed"))
        }
        try insert.run(.int(1))
        #expect(insert.connection.changes == 1)
    }

    @Test func connectionIsReleasedAfterTheLastOfSeveralStatements() throws {
        let f = try Fixture()
        let url = f.databaseURL()
        weak var weakConnection: SQLiteConnection?
        var first: SQLiteStatement?
        var second: SQLiteStatement?
        do {
            let connection = try SQLiteConnection(path: url.path)
            weakConnection = connection
            first = try connection.prepare("SELECT 1")
            second = try connection.prepare("SELECT 2")
        }
        #expect(try first?.step() == true)
        first = nil
        #expect(weakConnection != nil)
        #expect(try second?.step() == true)
        second = nil
        #expect(weakConnection == nil)
    }

    @Test func writeDetectsZeroChangedRows() throws {
        let f = try Fixture()
        let db = try SQLiteConnection(path: f.databaseURL().path)
        try db.execute("CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT); INSERT INTO t(id, v) VALUES (1, 'a')")
        try db.write("UPDATE t SET v = ? WHERE id = ?", .text("b"), .int(1))
        #expect(throws: SQLiteChangeCountError.self) { try db.write("UPDATE t SET v = ? WHERE id = ?", .text("c"), .int(2)) }
    }
}

// MARK: - Helpers

struct ProbeCounts: Equatable, Sendable {
    var operations: Int
    var items: Int
    var pending: Int
}

/// A fixture remover that, at the first move, reads the journal through its own connection.
final class JournalProbe: FileRemover, @unchecked Sendable {
    let base: FolderTrashRemover
    let databaseURL: URL
    private let lock = NSLock()
    private var counts: ProbeCounts?

    init(base: FolderTrashRemover, databaseURL: URL) {
        self.base = base
        self.databaseURL = databaseURL
    }

    var firstMoveSaw: ProbeCounts? { lock.withLock { counts } }

    func moveToTrash(_ path: String) throws -> String {
        let alreadyProbed = lock.withLock { counts != nil }
        if !alreadyProbed {
            let db = try SQLiteConnection(path: databaseURL.path, readOnly: true)
            func count(_ sql: String) throws -> Int {
                let s = try db.prepare(sql)
                _ = try s.step()
                return s.int(0)
            }
            let seen = ProbeCounts(operations: try count("SELECT COUNT(*) FROM cleanup_operation"),
                                   items: try count("SELECT COUNT(*) FROM cleanup_item"),
                                   pending: try count("SELECT COUNT(*) FROM cleanup_item WHERE status = 'pending'"))
            lock.withLock { counts = seen }
        }
        return try base.moveToTrash(path)
    }
}

extension LocalStore {
    /// `PRAGMA synchronous` of the store's connection (2 = FULL).
    func synchronousMode() throws -> Int {
        let s = try db.prepare("PRAGMA synchronous")
        _ = try s.step()
        return s.int(0)
    }
}
