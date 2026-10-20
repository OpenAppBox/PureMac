import Foundation
import PureMacKit
import Testing
@testable import PureMac

/// Put Back from History when the history itself cannot be updated: the file is back, the user is
/// told so with a warning, and the scan index grows back. Uses a fixture folder as the "Trash".
@MainActor
@Suite("History Put Back", .serialized)
struct HistoryRestoreTests {
    @Test(arguments: ["RAISE(ABORT, 'injected')", "RAISE(IGNORE)"])
    func putBackWithFailedHistoryWriteRestoresAndWarns(_ raise: String) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("PureMacHistoryRestore-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        let home = base + "/home", trash = base + "/FixtureTrash"
        try FileManager.default.createDirectory(atPath: home + "/models", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 400_000).write(to: URL(fileURLWithPath: home + "/models/big.bin"))
        try Data(repeating: 7, count: 50_000).write(to: URL(fileURLWithPath: home + "/models/small.bin"))

        let app = AppModel()
        await app.bootstrap()
        let store = try #require(app.store)
        _ = try await StorageScanner(databaseURL: app.databaseURL, home: home)
            .scan(ScanConfiguration(roots: [ScanRoot(path: home, kind: .folder)], smallFileThreshold: 8192, progressInterval: 0)) { _ in }
        await app.explorer.sessionDidChange()
        let models = try #require(app.explorer.rows.first { $0.name == "models" })
        await app.explorer.open(models)
        // The index's own (resolved) path, as a cleanup of this row would use it.
        let original = try #require(app.explorer.rows.first { $0.name == "big.bin" }).path

        // A journaled cleanup that moved big.bin into the fixture Trash.
        let st = try FileStat.lstat(original).get()
        let candidate = CleanupCandidate(path: original, title: "big.bin", reason: "test", category: .userSelection, risk: .review,
                                         source: .userSelection, logicalSize: st.logicalSize, allocatedSize: st.allocatedSize,
                                         itemCount: 1, modified: st.modified, identity: st.identity, isPreselected: false, scopeRoot: home)
        let plan = CleanupPlanner.plan(mode: .userFiles, title: "Test", selected: [candidate])
        let journal = try await store.beginOperation(plan: plan, detailed: true)
        let trashed = trash + "/big.bin"
        try FileManager.default.moveItem(atPath: original, toPath: trashed)
        let outcome = CleanupItemOutcome(path: original, status: .movedToTrash, trashPath: trashed,
                                         allocatedSize: st.allocatedSize, logicalSize: st.logicalSize)
        try await store.journalOutcome(itemID: journal.itemIDs[0], outcome: outcome, detailed: true)
        let result = CleanupResult(planID: plan.id, operationID: journal.operationID, mode: .userFiles, startedAt: Date(), finishedAt: Date(),
                                   outcomes: [outcome], wasCancelled: false, freeSpaceBefore: nil, freeSpaceAfter: nil)
        try await store.finishOperation(id: journal.operationID, result: result)
        await app.cleanupDidFinish(result)
        #expect(app.explorer.current?.allocatedSize == models.allocatedSize - st.allocatedSize)

        // History cannot record the Put Back.
        try SQLiteConnection(path: app.databaseURL.path)
            .execute("CREATE TRIGGER fail_restore BEFORE UPDATE ON cleanup_item WHEN NEW.status = 'restored' BEGIN SELECT \(raise); END")
        let record = try #require(try await store.items(operationID: journal.operationID).first)
        await app.history.restore(record)

        #expect(FileManager.default.fileExists(atPath: original))
        #expect(!FileManager.default.fileExists(atPath: trashed))
        #expect(app.history.messageIsWarning)
        // "Put back …" and, on its own line, why History may not show it (any app language).
        #expect(app.history.message?.contains("\n") == true)
        // The index counts the file again.
        #expect(app.explorer.current?.allocatedSize == models.allocatedSize)
        #expect(app.explorer.rows.contains { $0.name == "big.bin" })
    }

    @Test func cleanupWithoutADatabaseMovesNothing() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("PureMacNoJournal-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        let file = base + "/keep.bin"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10_000).write(to: URL(fileURLWithPath: file))
        let st = try FileStat.lstat(file).get()
        let candidate = CleanupCandidate(path: file, title: "keep.bin", reason: "test", category: .userSelection, risk: .review,
                                         source: .userSelection, logicalSize: st.logicalSize, allocatedSize: st.allocatedSize,
                                         itemCount: 1, modified: st.modified, identity: st.identity, isPreselected: false, scopeRoot: base)
        // No store, and a fixture remover: even if the guard failed, nothing would reach the real Trash.
        let executor = CleanupExecutor(store: nil, remover: FolderTrashRemover(trashDirectory: base + "/FixtureTrash"),
                                       policy: SafetyPolicy(homeDirectory: base))
        await #expect(throws: CleanupError.journalUnavailable) {
            _ = try await executor.execute(CleanupPlanner.plan(mode: .userFiles, title: "t", selected: [candidate]))
        }
        #expect(FileManager.default.fileExists(atPath: file))
    }
}
