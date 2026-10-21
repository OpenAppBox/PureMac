import Foundation
import Observation
import PureMacKit

/// Smart Clean: evaluates the bundled rule catalog (read-only) and keeps the user's selection.
@Observable
final class SmartCleanModel {
    private(set) var evaluation: RuleEvaluation?
    private(set) var isAnalyzing = false
    private(set) var catalogError: String?
    var selection: Set<CleanupCandidate.ID> = []

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private(set) var catalog: CleanupRuleCatalog?

    func attach(app: AppModel) {
        self.app = app
        do {
            catalog = try CleanupRuleCatalog.bundled()
        } catch {
            catalogError = String(localized: "The cleanup rule catalog failed validation and is disabled: \(String(describing: error))")
        }
    }

    /// Rule matches plus the "Likely" leftovers of removed apps (offered as one of the extras).
    var candidates: [CleanupCandidate] { (evaluation?.candidates ?? []) + leftovers }
    /// "Likely" orphans as cleanup candidates, rebuilt when the orphan search or the evaluation changes.
    private(set) var leftovers: [CleanupCandidate] = []
    /// What the Trash holds now (space PureMac moved there earlier is only freed when it is emptied).
    private(set) var trashBytes: Int64?

    /// One-tap additions to the proposal. Each is an explicit choice: nothing in them is ever
    /// selected unless the user includes it.
    enum Extra: String, CaseIterable, Identifiable {
        /// Developer build data and downloads not changed for two weeks.
        case developer
        /// Disk images and packages in Downloads older than 30 days.
        case installers
        /// Leftovers of removed apps where every check agrees.
        case leftovers
        var id: String { rawValue }
    }

    /// Developer data changed more recently than this stays out of the extra (it is probably in use).
    static let developerIdleDays = 14

    func items(of extra: Extra) -> [CleanupCandidate] {
        switch extra {
        case .developer:
            let cutoff = Date().addingTimeInterval(-Double(Self.developerIdleDays) * 86_400)
            return candidates.filter {
                $0.risk == .review && $0.blockedReason == nil && ($0.category == .developerCache || $0.category == .packageManagerCache)
                    && ($0.modified ?? .distantFuture) < cutoff
            }
        case .installers:
            return candidates.filter { $0.category == .installers && $0.blockedReason == nil }
        case .leftovers:
            return leftovers.filter { $0.blockedReason == nil }
        }
    }

    func bytes(of extra: Extra) -> Int64 { items(of: extra).reduce(0) { $0 + $1.allocatedSize } }

    func isIncluded(_ extra: Extra) -> Bool {
        let items = items(of: extra)
        return !items.isEmpty && items.allSatisfy { selection.contains($0.id) }
    }

    func setIncluded(_ extra: Extra, _ on: Bool) {
        let ids = items(of: extra).map(\.id)
        if on { selection.formUnion(ids) } else { selection.subtract(ids) }
    }

    /// Rebuilds the leftovers extra from the latest orphan search (called by AppsModel).
    func orphansDidChange() {
        guard let apps = app?.apps else { return }
        let ruleIDs = Set((evaluation?.candidates ?? []).map(\.id))
        let likely = apps.orphans.filter { $0.confidence == .likely }
        let fresh = CleanupPlanner.orphanCandidates(likely).filter { !ruleIDs.contains($0.id) }
        let gone = Set(leftovers.map(\.id)).subtracting(fresh.map(\.id))
        leftovers = fresh
        selection.subtract(gone)
    }
    var recommended: [CleanupCandidate] { candidates.filter { $0.risk == .low } }
    var reviewRequired: [CleanupCandidate] { candidates.filter { $0.risk == .review } }
    var selectedCandidates: [CleanupCandidate] { candidates.filter { selection.contains($0.id) && $0.blockedReason == nil } }
    var selectedBytes: Int64 { selectedCandidates.reduce(0) { $0 + $1.allocatedSize } }

    /// Items skipped because the app that owns them is running.
    var heldBack: [CleanupCandidate] { candidates.filter { $0.blockedReason != nil } }
    var heldBackBytes: Int64 { heldBack.reduce(0) { $0 + $1.allocatedSize } }

    /// The running apps that hold items back.
    var heldBackApps: [InstalledApp] {
        guard let apps = app?.apps else { return [] }
        let ids = Set(heldBack.compactMap { $0.relatedBundleIdentifier?.lowercased() })
        let paths = Set(heldBack.compactMap(\.relatedAppPath))
        return apps.apps.filter { (paths.contains($0.path) || !$0.allBundleIdentifiers.isDisjoint(with: ids)) && apps.isRunning($0) }
    }

    /// The running apps that hold items back; once none of them runs, analysis repeats by itself
    /// (whether PureMac asked them to quit or the user quit them).
    @ObservationIgnored private var reanalyzeWhenQuit: Set<String> = []

    /// Brings the apps holding items back to the front so the user can quit them; analysis
    /// repeats by itself once they have, so their caches join the proposal.
    func showHeldBackApps() {
        app?.apps.bringToFront(heldBackApps)
    }

    /// Called when apps launch or quit.
    func runningAppsChanged() {
        guard !reanalyzeWhenQuit.isEmpty, let apps = app?.apps else { return }
        let stillRunning = apps.apps.filter { reanalyzeWhenQuit.contains($0.path) && apps.isRunning($0) }
        guard stillRunning.isEmpty else { return }
        reanalyzeWhenQuit = []
        Task { await analyze() }
    }

    /// An analysis asked for while one is running (e.g. a cleanup just finished) runs once it ends,
    /// so results never stay stale.
    @ObservationIgnored private var reanalyzeRequested = false

    func analyze() async {
        guard let catalog, let app else { return }
        guard !isAnalyzing else {
            reanalyzeRequested = true
            return
        }
        defer {
            if reanalyzeRequested {
                reanalyzeRequested = false
                Task { await analyze() }
            }
        }
        isAnalyzing = true
        await app.apps.load()
        app.apps.refreshRunning()
        // Leftovers and the Trash are measured alongside the rules (all read-only).
        let orphanSearch = app.apps.orphansFoundAt == nil ? Task { await app.apps.findOrphans() } : nil
        let trash = Task.detached(priority: .utility) { () -> Int64? in
            let path = PathTools.userHome + "/.Trash"
            guard (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil else { return nil }
            return DirectorySizer.measure(path).allocatedSize
        }
        let evaluator = RuleEvaluator(catalog: catalog, policy: await app.safetyPolicy())
        let result = await evaluator.evaluate(installedApps: app.apps.apps, runningIdentifiers: app.apps.runningIDs)
        await orphanSearch?.value
        trashBytes = await trash.value
        // Low-risk, unblocked items are proposed; everything else needs an explicit opt-in. On a
        // repeat analysis the user's own choices stay, and only newly selectable items are proposed.
        let previouslySelectable = Set((evaluation?.candidates ?? []).filter { $0.blockedReason == nil }.map(\.id))
        let kept = evaluation == nil ? [] : selection
        evaluation = result
        orphansDidChange()
        let ids = Set(candidates.map(\.id))
        let proposed = result.candidates.filter { $0.isPreselected && $0.blockedReason == nil && !previouslySelectable.contains($0.id) }.map(\.id)
        selection = kept.intersection(ids).union(proposed)
        reanalyzeWhenQuit = Set(heldBackApps.map(\.path))
        isAnalyzing = false
    }

    #if DEBUG
    func _demoSet(_ evaluation: RuleEvaluation, trashBytes: Int64? = nil) {
        guard app?.isDemo == true else { return }
        self.evaluation = evaluation
        self.trashBytes = trashBytes
        orphansDidChange()
        selection = Set(evaluation.candidates.filter { $0.isPreselected && $0.blockedReason == nil }.map(\.id))
    }

    /// Tests only: an evaluation (and leftovers) without reading the disk.
    func _testSet(_ evaluation: RuleEvaluation, leftovers: [CleanupCandidate] = []) {
        self.evaluation = evaluation
        self.leftovers = leftovers
        selection = Set(evaluation.candidates.filter { $0.isPreselected && $0.blockedReason == nil }.map(\.id))
    }
    #endif

    func makePlan() -> CleanupPlan {
        CleanupPlanner.plan(mode: .smartClean, title: String(localized: "Smart Clean"), selected: selectedCandidates)
    }
}

/// Cleanup history from the local journal.
@Observable
final class HistoryModel {
    private(set) var operations: [CleanupOperationRecord] = []
    private(set) var items: [Int64: [CleanupItemRecord]] = [:]
    var selectedOperationID: Int64?
    var message: String?
    /// The last Put Back message includes a warning (History could not be updated).
    private(set) var messageIsWarning = false
    /// History could not be read from the local database.
    private(set) var loadError: String?
    /// A Put Back (one item or all of an operation) is in progress.
    private(set) var isRestoring = false

    @ObservationIgnored private weak var app: AppModel?

    func attach(app: AppModel) { self.app = app }

    func reload() async {
        do {
            operations = try await app?.store?.operations() ?? []
            loadError = nil
        } catch {
            loadError = String(localized: "PureMac could not read its cleanup history: \(error.localizedDescription)")
        }
        if let id = selectedOperationID { await loadItems(id) }
    }

    func loadItems(_ operationID: Int64) async {
        items[operationID] = (try? await app?.store?.items(operationID: operationID)) ?? []
    }

    func restore(_ record: CleanupItemRecord) async {
        await restore([record])
    }

    /// Puts items back one after another, then updates the scan index and the lists once.
    func restore(_ records: [CleanupItemRecord]) async {
        guard let app, !isRestoring, !records.isEmpty else { return }
        isRestoring = true
        defer { isRestoring = false }
        var changes: [IndexChange] = []
        var restored: [String] = []
        var failures: [String] = []
        var historyWarning: String?
        for record in records {
            let outcome = await app.cleanup.restore(record)
            if case .restoredWithHistoryWarning(let warning) = outcome { historyWarning = historyWarning ?? warning }
            switch outcome {
            case .restored, .restoredWithHistoryWarning:
                guard let original = record.originalPath else { continue }
                restored.append(original)
                // The item is back on disk: its own sizes are exact. (The journal keeps only the
                // allocated size, which is not the logical size.)
                if case .success(let st) = FileStat.lstat(original) {
                    changes.append(IndexChange(path: original, allocatedSize: st.allocatedSize, logicalSize: st.logicalSize))
                } else {
                    changes.append(IndexChange(path: original, allocatedSize: record.allocatedSize, logicalSize: record.allocatedSize))
                }
            case .notPossible(let reason):
                failures.append(reason)
            }
        }
        if !changes.isEmpty {
            // Folders get the items' scan-time sizes back.
            await app.adjustIndex(changes, restoring: true)
            await app.scan.reload()
        }
        if records.count == 1 {
            if let original = restored.first, !original.isEmpty {
                message = String(localized: "Put back \(abbreviate(original)).")
            } else if let reason = failures.first {
                message = reason
            } else {
                message = String(localized: "Put back the item.")
            }
        } else {
            message = failures.isEmpty
                ? String(localized: "Put back \(restored.count) items.")
                : String(localized: "Put back \(restored.count) of \(records.count) items. \(failures[0])")
        }
        // The files are back either way; say so, then why History may not show it.
        if let historyWarning, let current = message { message = current + "\n" + historyWarning }
        messageIsWarning = historyWarning != nil || !failures.isEmpty
        for operationID in Set(records.map(\.operationID)) { await loadItems(operationID) }
    }
}
