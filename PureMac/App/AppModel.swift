import Foundation
import Observation
import PureMacKit

/// Composition root. Owns the local store and every feature model. All production models are
/// connected to real services; there is no demo data path.
@Observable
final class AppModel {
    let settings: AppSettings
    /// Folder grants (App Store edition); every check passes in the direct-download edition.
    let access: FolderAccess
    let databaseURL: URL
    private(set) var store: LocalStore?
    var startupError: String?
    var recoveryNotice: String?
    /// Record shown in the File Info sheet.
    var inspectedRecord: FileRecord?

    let scan: ScanModel
    let explorer: ExplorerModel
    let apps: AppsModel
    let smartClean: SmartCleanModel
    let cleanup: CleanupCoordinator
    let history: HistoryModel
    let duplicates: DuplicatesModel
    let developer: DeveloperModel
    let performance: PerformanceModel

    /// `true` when the process hosts unit tests: uses a temporary database and never touches the
    /// user's real PureMac data.
    let isHostingTests: Bool
    /// DEBUG-only demo mode (`-PureMacDemo YES`, promotional screenshots): mock data in a throwaway
    /// database and settings domain. Always `false` in Release builds.
    let isDemo: Bool
    /// Demo mode: `true` once the mock content is installed (pages wait for it).
    var demoReady = false

    init() {
        isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #if DEBUG
        isDemo = DemoContent.isRequested
        #else
        isDemo = false
        #endif
        if isDemo {
            #if DEBUG
            let defaults = UserDefaults(suiteName: "com.openappbox.PureMac.demo") ?? .standard
            settings = AppSettings(defaults: defaults)
            settings.hasCompletedOnboarding = true
            settings.scanEntireDataVolume = true   // matches the demo's whole-disk scan
            access = FolderAccess(defaults: defaults, isRequired: false)
            databaseURL = DemoContent.databaseURL
            #else
            fatalError("Demo mode is DEBUG-only")
            #endif
        } else if isHostingTests {
            // One suite, emptied at the start of every run: a clean slate without leaving a new
            // preferences file behind for each run.
            let suite = "com.openappbox.PureMac.tests"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            settings = AppSettings(defaults: defaults)
            access = FolderAccess(defaults: defaults, isRequired: false)
            databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("PureMacHostedTests-\(UUID().uuidString).sqlite")
        } else {
            settings = AppSettings()
            access = FolderAccess()
            #if DEBUG
            // `-PureMacDatabase <path>`: open another scan database (for checking screens against a
            // prepared scan without touching the real one). DEBUG builds only.
            let override = UserDefaults.standard.string(forKey: "PureMacDatabase").map { URL(fileURLWithPath: $0) }
            #else
            let override: URL? = nil
            #endif
            databaseURL = override ?? (try? LocalStore.defaultURL())
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("PureMac.sqlite")
        }
        scan = ScanModel()
        explorer = ExplorerModel()
        apps = AppsModel()
        smartClean = SmartCleanModel()
        cleanup = CleanupCoordinator()
        history = HistoryModel()
        duplicates = DuplicatesModel()
        developer = DeveloperModel()
        performance = PerformanceModel()

        do {
            let store = try LocalStore(url: databaseURL)
            self.store = store
            if let aside = store.recoveredCorruptFile {
                recoveryNotice = String(localized: "PureMac's local database could not be read and was recreated. The old file was kept at \(aside).")
            }
        } catch {
            startupError = String(localized: "PureMac could not open its local database: \(error.localizedDescription)")
        }
        scan.attach(app: self)
        explorer.attach(app: self)
        apps.attach(app: self)
        smartClean.attach(app: self)
        cleanup.attach(app: self)
        history.attach(app: self)
        duplicates.attach(app: self)
        developer.attach(app: self)
    }

    /// Refreshes every view of the filesystem after a cleanup or restore.
    func cleanupDidFinish(_ result: CleanupResult) async {
        await history.reload()
        // Update the scan index in place, so every folder above a removed item shrinks now.
        let moved = result.outcomes.filter { $0.status == .movedToTrash }
            .map { IndexChange(path: $0.path, allocatedSize: $0.allocatedSize, logicalSize: $0.logicalSize) }
        await adjustIndex(moved, restoring: false)
        if smartClean.evaluation != nil { await smartClean.analyze() }
        await apps.refreshAfterCleanup()
        if developer.loadedAt != nil {
            developer.selection = []
            await developer.load()
        }
        await scan.reload()
    }

    /// Applies removals or a Put Back to the latest browsable scan index and refreshes the Explorer.
    /// Number of exclusions (shown in Settings' sidebar).
    var exclusionCount = 0

    func refreshExclusionCount() async {
        exclusionCount = (try? await store?.exclusions().count) ?? 0
    }

    func adjustIndex(_ changes: [IndexChange], restoring: Bool) async {
        guard !changes.isEmpty, let store, let session = try? await store.latestBrowsableSession() else { return }
        _ = try? await (restoring ? store.applyRestore(sessionID: session.id, changes: changes)
                                  : store.applyRemoval(sessionID: session.id, changes: changes))
        await explorer.indexDidChange()
    }

    /// Plans moving user-selected files (Storage Explorer) to the Trash and opens the review.
    func reviewUserSelection(_ paths: [String]) {
        Task {
            let policy = await safetyPolicy()
            let sizes = await DirectorySizer.measureAll(paths)
            let (candidates, rejected) = CleanupPlanner.userSelectionCandidates(paths: paths, policy: policy, sizes: sizes)
            let plan = CleanupPlanner.plan(mode: .userFiles, title: String(localized: "Selected items"), selected: candidates)
            cleanup.present(plan, rejected: rejected)
        }
    }

    /// Ownership-safety policy for the current user, including PureMac's own data folder and the
    /// user's cleanup exclusions.
    func safetyPolicy() async -> SafetyPolicy {
        let exclusions = (try? await store?.exclusions(scope: .cleanup).map(\.path)) ?? []
        return SafetyPolicy.forCurrentUser(ownDataDirectory: databaseURL.deletingLastPathComponent(), userExclusions: exclusions)
    }

    func bootstrap() async {
        guard let store else { return }
        try? await store.markInterruptedSessions()
        try? await store.markInterruptedOperations()
        await scan.reload()
        await history.reload()
    }
}
