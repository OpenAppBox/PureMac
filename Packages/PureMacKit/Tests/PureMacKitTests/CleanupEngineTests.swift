import Darwin
import Foundation
import Testing
@testable import PureMacKit

@Suite("Cleanup engine — safety regressions")
struct CleanupEngineTests {
    struct Env {
        let home: Fixture
        let trash: String
        let store: LocalStore
        let policy: SafetyPolicy
        func executor(running: FakeRunningApps = FakeRunningApps(), remover: (any FileRemover)? = nil) -> CleanupExecutor {
            CleanupExecutor(store: store, remover: remover ?? FolderTrashRemover(trashDirectory: trash), policy: policy, running: running)
        }
    }

    func env() throws -> Env {
        let home = try Fixture("home")
        let trash = home.root.deletingLastPathComponent().appendingPathComponent("FixtureTrash").path
        let store = try LocalStore(url: home.databaseURL())
        return Env(home: home, trash: trash, store: store, policy: SafetyPolicy(homeDirectory: home.path))
    }

    func ruleCandidate(_ env: Env, _ relative: String, root: String = "Library/Caches", bundleID: String? = nil) throws -> CleanupCandidate {
        let path = env.home.path(relative)
        let st = try FileStat.lstat(path).get()
        let size = DirectorySizer.measure(path)
        return CleanupCandidate(path: path, title: "t", reason: "r", category: .appCache, risk: .low, source: .rule(id: "test"),
                                logicalSize: size.logicalSize, allocatedSize: size.allocatedSize, itemCount: size.fileCount,
                                modified: st.modified, identity: st.identity, relatedBundleIdentifier: bundleID,
                                requiresAppClosed: bundleID != nil, isPreselected: true, scopeRoot: env.home.path(root))
    }

    @Test func dryRunPlanningMakesNoFilesystemChanges() async throws {
        let e = try env()
        try e.home.file("Library/Caches/com.example.a/blob", size: 10_000)
        try e.home.file("Library/Caches/pip/x", size: 10_000)
        let before = e.home.snapshot()
        let candidates = [try ruleCandidate(e, "Library/Caches/com.example.a"), try ruleCandidate(e, "Library/Caches/pip")]
        let plan = CleanupPlanner.plan(mode: .smartClean, title: "Test", selected: candidates)
        let report = plan.dryRunReport { "\($0) B" }
        #expect(report.contains("Library/Caches/pip"))
        #expect(report.contains("Nothing is permanently deleted"))
        #expect(e.home.snapshot() == before)
    }

    @Test func executesMovesToTrashAndJournals() async throws {
        let e = try env()
        try e.home.file("Library/Caches/com.example.a/blob", size: 10_000)
        let plan = CleanupPlanner.plan(mode: .smartClean, title: "Test", selected: [try ruleCandidate(e, "Library/Caches/com.example.a")])
        let result = try await e.executor().execute(plan)
        #expect(result.movedCount == 1)
        #expect(!e.home.exists("Library/Caches/com.example.a"))
        let trashPath = try #require(result.outcomes.first?.trashPath)
        #expect(FileManager.default.fileExists(atPath: trashPath + "/blob"))   // recoverable, not deleted
        #expect(result.bytesMovedToTrash == plan.identifiedAllocatedBytes)
        #expect(result.bytesPermanentlyDeleted == 0)
        let ops = try await e.store.operations()
        #expect(ops.first?.movedCount == 1)
        let items = try await e.store.items(operationID: try #require(ops.first?.id))
        #expect(items.first?.status == .movedToTrash)
        #expect(items.first?.trashPath == trashPath)
    }

    @Test func identityChangeBetweenReviewAndExecutionIsSkipped() async throws {
        let e = try env()
        try e.home.file("Library/Caches/com.example.a/blob", size: 10_000)
        let candidate = try ruleCandidate(e, "Library/Caches/com.example.a")
        // Replace the folder with a different one at the same path.
        try FileManager.default.removeItem(atPath: candidate.path)
        try e.home.file("Library/Caches/com.example.a/other", size: 10)
        let result = try await e.executor().execute(CleanupPlanner.plan(mode: .smartClean, title: "t", selected: [candidate]))
        #expect(result.skippedCount == 1)
        #expect(result.outcomes.first?.message?.contains("changed") == true)
        #expect(e.home.exists("Library/Caches/com.example.a/other"))
    }

    @Test func symlinkSwapAttackCannotRedirectRemoval() async throws {
        let e = try env()
        try e.home.file("Documents/thesis.pdf", size: 10_000)
        try e.home.file("Library/Caches/com.example.a/blob", size: 10_000)
        let candidate = try ruleCandidate(e, "Library/Caches/com.example.a")
        // Attacker swaps the reviewed folder for a symlink to Documents.
        try FileManager.default.removeItem(atPath: candidate.path)
        try e.home.symlink("Library/Caches/com.example.a", to: e.home.path("Documents"))
        let result = try await e.executor().execute(CleanupPlanner.plan(mode: .smartClean, title: "t", selected: [candidate]))
        #expect(result.movedCount == 0)
        #expect(e.home.exists("Documents/thesis.pdf"))
    }

    @Test func parentSymlinkSubstitutionIsRejected() async throws {
        let e = try env()
        try e.home.file("Library/Caches/vendor/com.example.a/blob", size: 10_000)
        try e.home.file("Library/Keychains/vendor/com.example.a/login.keychain-db", size: 10)
        let candidate = try ruleCandidate(e, "Library/Caches/vendor/com.example.a")
        // Replace the parent folder with a symlink into Keychains: same final name, different place.
        try FileManager.default.removeItem(atPath: e.home.path("Library/Caches/vendor"))
        try e.home.symlink("Library/Caches/vendor", to: e.home.path("Library/Keychains/vendor"))
        let result = try await e.executor().execute(CleanupPlanner.plan(mode: .smartClean, title: "t", selected: [candidate]))
        #expect(result.movedCount == 0)
        #expect(e.home.exists("Library/Keychains/vendor/com.example.a/login.keychain-db"))
    }

    @Test func protectedPathsAreRejectedEvenIfPlanned() async throws {
        let e = try env()
        try e.home.file("Library/Keychains/login.keychain-db", size: 100)
        try e.home.file("Documents/a.txt", size: 100)
        var keychain = try ruleCandidate(e, "Library/Keychains/login.keychain-db", root: "Library")
        keychain.scopeRoot = e.home.path("Library")
        var document = try ruleCandidate(e, "Documents/a.txt", root: "Documents")
        document.source = .orphan(bundleIdentifier: "x.y.z")
        let result = try await e.executor().execute(CleanupPlan(mode: .smartClean, title: "t", items: [keychain, document]))
        #expect(result.movedCount == 0)
        #expect(e.home.exists("Library/Keychains/login.keychain-db"))
        #expect(e.home.exists("Documents/a.txt"))
    }

    @Test func runningAppIsRecheckedAtExecution() async throws {
        let e = try env()
        try e.home.file("Library/Caches/com.example.a/blob", size: 10_000)
        let candidate = try ruleCandidate(e, "Library/Caches/com.example.a", bundleID: "com.example.a")
        let result = try await e.executor(running: FakeRunningApps(ids: ["com.example.a"]))
            .execute(CleanupPlanner.plan(mode: .smartClean, title: "t", selected: [candidate]))
        #expect(result.skippedCount == 1)
        #expect(e.home.exists("Library/Caches/com.example.a"))
    }

    @Test func partialFailureIsReportedPerItem() async throws {
        let e = try env()
        try e.home.file("Library/Caches/com.example.a/blob", size: 10_000)
        try e.home.file("Library/Caches/com.example.b/blob", size: 10_000)
        let a = try ruleCandidate(e, "Library/Caches/com.example.a")
        let b = try ruleCandidate(e, "Library/Caches/com.example.b")
        let remover = FailingRemover(base: FolderTrashRemover(trashDirectory: e.trash), failingPaths: [a.path])
        let result = try await e.executor(remover: remover).execute(CleanupPlanner.plan(mode: .smartClean, title: "t", selected: [a, b]))
        #expect(result.failedCount == 1)
        #expect(result.movedCount == 1)
        #expect(e.home.exists("Library/Caches/com.example.a"))
        #expect(!e.home.exists("Library/Caches/com.example.b"))
        #expect(result.outcomes.first { $0.path == a.path }?.message?.contains("Permission") == true)
    }

    @Test func cancellationStopsBetweenItems() async throws {
        let e = try env()
        var candidates: [CleanupCandidate] = []
        for i in 0..<5 {
            try e.home.file("Library/Caches/com.example.c\(i)/blob", size: 100)
            candidates.append(try ruleCandidate(e, "Library/Caches/com.example.c\(i)"))
        }
        let flag = CancellationFlag()
        let result = try await e.executor().execute(CleanupPlanner.plan(mode: .smartClean, title: "t", selected: candidates),
                                                     isCancelled: { flag.isCancelled }, progress: { index, _ in if index == 2 { flag.cancel() } })
        #expect(result.wasCancelled)
        #expect(result.movedCount == 2)
        #expect(result.skippedCount == 3)
    }

    @Test func concurrentOperationsAreRejected() async throws {
        let e = try env()
        for i in 0..<3 { try e.home.file("Library/Caches/com.example.d\(i)/blob", size: 100) }
        let plan = CleanupPlanner.plan(mode: .smartClean, title: "t", selected: try (0..<3).map { try ruleCandidate(e, "Library/Caches/com.example.d\($0)") })
        let gate = GatedRunningApps()
        let executor = CleanupExecutor(store: e.store, remover: FolderTrashRemover(trashDirectory: e.trash), policy: e.policy, running: gate)
        async let first = executor.execute(plan)
        await gate.waitUntilEntered()          // the first operation is now suspended mid-plan
        #expect(await executor.isBusy)
        await #expect(throws: CleanupError.operationInProgress) { _ = try await executor.execute(plan) }
        await gate.open()
        let result = try await first
        #expect(result.movedCount == 3)
        #expect(await !executor.isBusy)
    }

    @Test func blockedItemsAreNeverPlanned() throws {
        let e = try env()
        try e.home.file("Library/Caches/com.example.a/blob", size: 100)
        var candidate = try ruleCandidate(e, "Library/Caches/com.example.a")
        candidate.blockedReason = "running"
        #expect(CleanupPlanner.plan(mode: .smartClean, title: "t", selected: [candidate]).items.isEmpty)
    }

    @Test func restorePutsItemBackOnlyWhenSafe() async throws {
        let e = try env()
        try e.home.file("Library/Caches/com.example.a/blob", size: 100)
        let executor = e.executor()
        let result = try await executor.execute(CleanupPlanner.plan(mode: .smartClean, title: "t", selected: [try ruleCandidate(e, "Library/Caches/com.example.a")]))
        let items = try await e.store.items(operationID: try #require(result.operationID))
        let record = try #require(items.first)
        // Occupied original location → refused.
        try e.home.dir("Library/Caches/com.example.a")
        #expect(await executor.restore(record) != .restored)
        try FileManager.default.removeItem(atPath: e.home.path("Library/Caches/com.example.a"))
        #expect(await executor.restore(record) == .restored)
        #expect(e.home.exists("Library/Caches/com.example.a/blob"))
        #expect(try await e.store.items(operationID: record.operationID).first?.status == .restored)
    }

    @Test func historyWithoutDetailsStoresNoPaths() async throws {
        let e = try env()
        try e.home.file("Library/Caches/com.example.a/blob", size: 100)
        let result = try await e.executor().execute(CleanupPlanner.plan(mode: .smartClean, title: "t", selected: [try ruleCandidate(e, "Library/Caches/com.example.a")]), detailedHistory: false)
        let items = try await e.store.items(operationID: try #require(result.operationID))
        #expect(items.first?.originalPath == nil)
        #expect(items.first?.trashPath == nil)
        #expect(await e.executor().restore(try #require(items.first)) != .restored)
    }

    @Test func uninstallModesPreselectDifferently() throws {
        let e = try env()
        let bundle = try e.home.makeApp("Applications/Alpha.app", id: "com.example.alpha", name: "Alpha")
        try e.home.dir("Library/Caches/com.example.alpha")
        try e.home.file("Library/Preferences/com.example.alpha.plist", size: 10)
        try e.home.dir("Library/Application Support/Alpha")
        let app = e.home.app(bundle)
        func association(_ relative: String, _ kind: AssociationKind, _ confidence: AssociationConfidence, admin: Bool = false) throws -> AppAssociation {
            AppAssociation(path: e.home.path(relative), kind: kind, confidence: confidence, evidence: [Evidence(.exactBundleIdentifier, "x")],
                           identity: try e.home.identity(relative), requiresAdministrator: admin)
        }
        let associations = [
            try association("Applications/Alpha.app", .appBundle, .confirmed),
            try association("Library/Caches/com.example.alpha", .cache, .confirmed),
            try association("Library/Preferences/com.example.alpha.plist", .preferences, .confirmed),
            try association("Library/Application Support/Alpha", .applicationSupport, .ambiguous),
        ]
        let keep = CleanupPlanner.uninstallCandidates(app: app, associations: associations, mode: .keepPersonalData)
        #expect(Set(keep.filter(\.isPreselected).map(\.title)) == ["Application", "Caches"])
        let complete = CleanupPlanner.uninstallCandidates(app: app, associations: associations, mode: .complete)
        #expect(Set(complete.filter(\.isPreselected).map(\.title)) == ["Application", "Caches", "Preferences"])
        // Ambiguous items are offered but never preselected.
        #expect(complete.first { $0.title == "Application Support" }?.isPreselected == false)
        #expect(complete.first { $0.title == "Application Support" }?.blockedReason == nil)
    }

    @Test func uninstallMovesAppBundleAndDataFromFixture() async throws {
        let e = try env()
        let bundle = try e.home.makeApp("Applications/Alpha.app", id: "com.example.alpha", name: "Alpha")
        try e.home.file("Library/Caches/com.example.alpha/c", size: 100)
        let app = e.home.app(bundle)
        let finder = AssociationFinder(home: e.home.path, systemLibraryPath: e.home.path("NoSystemLibrary"), catalog: .bundled())
        let associations = await finder.associations(for: app, allApps: [app])
        let candidates = CleanupPlanner.uninstallCandidates(app: app, associations: associations, mode: .keepPersonalData)
        let policy = SafetyPolicy(homeDirectory: e.home.path, applicationRoots: [e.home.path("Applications")])
        let executor = CleanupExecutor(store: e.store, remover: FolderTrashRemover(trashDirectory: e.trash), policy: policy, running: FakeRunningApps())
        let result = try await executor.execute(CleanupPlanner.plan(mode: .uninstallKeepData, title: "Uninstall Alpha", selected: candidates.filter(\.isPreselected)))
        #expect(result.movedCount == 2)
        #expect(!e.home.exists("Applications/Alpha.app"))
        #expect(!e.home.exists("Library/Caches/com.example.alpha"))
    }

    @Test func runningAppCannotBeUninstalled() async throws {
        let e = try env()
        let bundle = try e.home.makeApp("Applications/Alpha.app", id: "com.example.alpha", name: "Alpha")
        let app = e.home.app(bundle)
        let association = AppAssociation(path: bundle, kind: .appBundle, confidence: .confirmed, evidence: [], identity: try e.home.identity("Applications/Alpha.app"))
        let candidates = CleanupPlanner.uninstallCandidates(app: app, associations: [association], mode: .complete)
        let policy = SafetyPolicy(homeDirectory: e.home.path, applicationRoots: [e.home.path("Applications")])
        let executor = CleanupExecutor(store: e.store, remover: FolderTrashRemover(trashDirectory: e.trash), policy: policy,
                                       running: FakeRunningApps(paths: [bundle]))
        let result = try await executor.execute(CleanupPlanner.plan(mode: .uninstallComplete, title: "t", selected: candidates))
        #expect(result.skippedCount == 1)
        #expect(e.home.exists("Applications/Alpha.app"))
    }

    @Test func realTrashIntegrationIsOptIn() async throws {
        // Moves one throwaway temp file to the user's real Trash only when explicitly enabled.
        guard ProcessInfo.processInfo.environment["PUREMAC_TEST_REAL_TRASH"] == "1" else { return }
        let f = try Fixture()
        let file = try f.file("PureMac-trash-test.txt", size: 10)
        let destination = try SystemTrashRemover().moveToTrash(file.path)
        #expect(FileManager.default.fileExists(atPath: destination))
    }
}
