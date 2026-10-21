import AppKit
import Foundation
import Observation
import PureMacKit

/// Installed applications, their evidence-based associations, and orphaned remnants.
@Observable
final class AppsModel {
    private(set) var apps: [InstalledApp] = []
    private(set) var isLoading = false
    private(set) var loadedAt: Date?
    private(set) var associations: [String: [AppAssociation]] = [:] {
        didSet { dataSizes = associations.mapValues(\.associatedDataBytes) }
    }
    /// `associatedDataBytes` per app, computed once per change (list sorting reads it often).
    private(set) var dataSizes: [String: Int64] = [:]
    private(set) var loadingAssociations: Set<String> = []
    private(set) var packageReceipts: [String: [String]] = [:]
    private(set) var runningIDs: Set<String> = []
    private(set) var runningPaths: Set<String> = []

    private(set) var orphans: [OrphanCandidate] = [] { didSet { rebuildOrphanGroups() } }
    /// Orphans grouped per removed app, and the groups the filter, search and sort leave visible.
    var orphanGroups: [RemovedApp] { orphanGroupsStorage }
    var visibleOrphanGroups: [RemovedApp] { visibleOrphanGroupsStorage }
    /// Set only by `rebuildOrphanGroups` / `rebuildVisibleOrphanGroups` (RemovedApps.swift).
    var orphanGroupsStorage: [RemovedApp] = []
    var visibleOrphanGroupsStorage: [RemovedApp] = []
    var orphanFilter: RemovedApp.Filter = .all { didSet { rebuildVisibleOrphanGroups() } }
    var orphanSort: RemovedApp.Sort = .size { didSet { rebuildVisibleOrphanGroups() } }
    var orphanSearch = "" { didSet { rebuildVisibleOrphanGroups() } }
    var selectedOrphanGroupID: RemovedApp.ID?
    private(set) var isFindingOrphans = false
    private(set) var orphansFoundAt: Date?

    /// Bundle sizes and last-used dates, measured in the background after discovery.
    private(set) var bundleSizes: [String: Int64] = [:]
    private(set) var lastUsed: [String: Date] = [:]
    /// Apps whose Spotlight record was read (a missing `lastUsed` then means "no record").
    private(set) var usageChecked: Set<String> = []
    private(set) var isMeasuring = false

    enum SortOrder: String, CaseIterable, Identifiable {
        case size, name, lastUsed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .size: String(localized: "Size")
            case .name: String(localized: "Name")
            case .lastUsed: String(localized: "Last Used")
            }
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all, unused, large
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: String(localized: "All Apps")
            case .unused: String(localized: "Not Used in 3 Months")
            case .large: String(localized: "Larger Than 1 GB")
            }
        }
    }

    var searchText = ""
    var selectedAppID: InstalledApp.ID?
    /// Apps checked for a batch uninstall (independent of the app shown in the detail pane).
    var uninstallSelection: Set<InstalledApp.ID> = []
    var sortOrder: SortOrder = .size
    var filter: Filter = .all
    var orphanSelection: Set<OrphanCandidate.ID> = []
    var showSystemApps = false

    @ObservationIgnored private(set) weak var app: AppModel?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var measureTask: Task<Void, Never>?

    func attach(app: AppModel) {
        self.app = app
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshRunning()
                    self?.app?.smartClean.runningAppsChanged()
                }
            })
        }
        refreshRunning()
    }

    var visibleApps: [InstalledApp] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let threeMonthsAgo = Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? .distantPast
        let filtered = apps.filter { app in
            guard showSystemApps || !app.isProtected else { return false }
            guard query.isEmpty || app.name.localizedCaseInsensitiveContains(query)
                    || (app.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false) else { return false }
            switch filter {
            case .all: return true
            case .unused:
                // Only apps Spotlight actually knows to be unused; "no record" is not evidence.
                return lastUsed[app.path].map { $0 < threeMonthsAgo } ?? false
            case .large: return (totalSize(of: app) ?? 0) >= 1_000_000_000
            }
        }
        switch sortOrder {
        case .name:
            return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            return filtered.sorted { (totalSize(of: $0) ?? -1, $1.name) > (totalSize(of: $1) ?? -1, $0.name) }
        case .lastUsed:
            // Least recently used first: these are the likeliest to be unneeded.
            return filtered.sorted { (lastUsed[$0.path] ?? .distantFuture) < (lastUsed[$1.path] ?? .distantFuture) }
        }
    }

    /// Bytes of associated files (caches, support data, containers…) other than the bundle, once known.
    func dataSize(of app: InstalledApp) -> Int64? { dataSizes[app.path] }

    /// Bundle plus associated data; just the bundle until associations are measured.
    func totalSize(of app: InstalledApp) -> Int64? {
        guard let bundle = bundleSizes[app.path] else { return nil }
        return bundle + (dataSize(of: app) ?? 0)
    }

    var uninstallSelectionApps: [InstalledApp] { apps.filter { uninstallSelection.contains($0.id) } }

    var selectedApp: InstalledApp? { apps.first { $0.id == selectedAppID } }

    func isRunning(_ app: InstalledApp) -> Bool {
        runningPaths.contains(app.path) || !app.allBundleIdentifiers.isDisjoint(with: runningIDs)
    }

    func refreshRunning() {
        #if DEBUG
        if let demo = _demoRunning {
            runningPaths = demo
            runningIDs = Set(apps.filter { demo.contains($0.path) }.flatMap(\.allBundleIdentifiers))
            return
        }
        #endif
        let running = NSWorkspace.shared.runningApplications
        runningIDs = Set(running.compactMap { $0.bundleIdentifier?.lowercased() })
        runningPaths = Set(running.compactMap { $0.bundleURL?.standardizedFileURL.path })
    }

    /// A forced reload asked for while one is running (e.g. after a cleanup) runs once it ends.
    /// The discovery in progress. Callers wait for it: the orphan search and Smart Clean need the
    /// complete list of installed apps — returning early with an empty list made every extension
    /// and helper of an installed app look orphaned.
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var orphanSearchRequested = false

    func load(force: Bool = false) async {
        guard app?.isDemo != true else { return }
        if let inFlight = loadTask {
            await inFlight.value
            guard force else { return }
            // A reload asked for while one ran: one more pass, shared by everyone who asked.
            if let next = loadTask, next != inFlight { await next.value; return }
        } else if !force, loadedAt != nil {
            return
        }
        let task = Task { await discoverApps() }
        loadTask = task
        await task.value
        if loadTask == task { loadTask = nil }
    }

    private func discoverApps() async {
        isLoading = true
        let discovered = await AppDiscoverer().discover()
        apps = discovered
        loadedAt = Date()
        isLoading = false
        associations = [:]
        uninstallSelection = uninstallSelection.intersection(Set(discovered.map(\.id)))
        refreshRunning()
        startMeasuring()
    }

    /// Sizes every bundle, then finds each removable app's associated data, publishing in small
    /// batches (never once per app) so the list fills in without re-rendering on every result.
    private func startMeasuring() {
        measureTask?.cancel()
        let all = apps
        // Removable apps first; macOS apps last (they are only listed on request).
        let ordered = all.filter { !$0.isProtected } + all.filter(\.isProtected)
        isMeasuring = true
        measureTask = Task {
            var sizes: [String: Int64] = [:], used: [String: Date] = [:], checked: Set<String> = []
            var summaries: [String: SizeSummary] = [:]   // reused by the association pass
            var lastPublish = Date()
            @MainActor func flush() {
                bundleSizes.merge(sizes) { $1 }
                lastUsed.merge(used) { $1 }
                usageChecked.formUnion(checked)
                sizes = [:]; used = [:]; checked = []
                lastPublish = Date()
            }
            for await measured in AppFootprint.measure(paths: ordered.map(\.path), maxConcurrency: 2) {
                sizes[measured.path] = measured.bundle.allocatedSize
                summaries[measured.path] = measured.bundle
                if let date = measured.lastUsed { used[measured.path] = date }
                checked.insert(measured.path)
                if Date().timeIntervalSince(lastPublish) > 0.4 { flush() }
            }
            guard !Task.isCancelled else { return }   // a newer load replaced this one
            flush()

            let removable = all.filter { !$0.isProtected && associations[$0.path] == nil }
            var found: [String: [AppAssociation]] = [:]
            for await (path, list) in AppFootprint.associations(for: removable, allApps: all, knownSizes: summaries) {
                found[path] = list
                if Task.isCancelled { return }
                if Date().timeIntervalSince(lastPublish) > 1.0 {
                    associations.merge(found) { current, _ in current }
                    found = [:]
                    lastPublish = Date()
                }
            }
            // A cancelled pass must not merge results from before a refresh (e.g. an uninstall).
            guard !Task.isCancelled else { return }
            associations.merge(found) { current, _ in current }
            isMeasuring = false
        }
    }

    func loadAssociations(for installed: InstalledApp, force: Bool = false) async {
        guard force || associations[installed.path] == nil, !loadingAssociations.contains(installed.path) else { return }
        loadingAssociations.insert(installed.path)
        let finder = AssociationFinder()
        let all = apps
        let found = await finder.associations(for: installed, allApps: all)
        associations[installed.path] = found
        loadingAssociations.remove(installed.path)
        if packageReceipts[installed.path] == nil, !installed.isProtected {
            let path = installed.path
            let receipts = await Task.detached(priority: .utility) { PackageReceipts.packageIdentifiers(forFile: path) }.value
            packageReceipts[installed.path] = receipts
        }
    }

    #if DEBUG
    @ObservationIgnored private var _demoRunning: Set<String>?

    func _demoSet(apps: [InstalledApp], bundleSizes: [String: Int64], lastUsed: [String: Date],
                  associations: [String: [AppAssociation]], running: Set<String>, orphans: [OrphanCandidate]) {
        guard app?.isDemo == true else { return }
        self.apps = apps
        self.bundleSizes = bundleSizes
        self.lastUsed = lastUsed
        usageChecked = Set(apps.map(\.path))
        self.associations = associations
        loadedAt = Date()
        isMeasuring = false
        _demoRunning = running
        refreshRunning()
        self.orphans = orphans
        orphansFoundAt = Date()
    }

    /// Tests only: orphans without searching the Library.
    func _testSet(orphans: [OrphanCandidate]) {
        self.orphans = orphans
        orphansFoundAt = Date()
    }
    #endif

    /// Brings running apps to the front so the user can quit them. The App Sandbox doesn't let
    /// PureMac ask other apps to quit, and PureMac never force-quits.
    func bringToFront(_ targets: [InstalledApp]) {
        for installed in targets {
            _ = AppActivation.bringToFront(bundleIdentifiers: installed.allBundleIdentifiers, bundlePath: installed.path)
        }
    }

    func findOrphans() async {
        guard !isFindingOrphans else {
            orphanSearchRequested = true   // results may already be stale (e.g. a cleanup finished)
            return
        }
        defer {
            if orphanSearchRequested {
                orphanSearchRequested = false
                Task { await findOrphans() }
            }
        }
        isFindingOrphans = true
        await load()
        // Without the installed apps every extension and helper would look orphaned: never search then.
        guard !apps.isEmpty else {
            isFindingOrphans = false
            return
        }
        let ignored = Set((try? await app?.store?.exclusions(scope: .cleanup).map { ($0.path as NSString).lastPathComponent }) ?? [])
        orphans = await OrphanDetector().findOrphans(installedApps: apps, ignoredIdentifiers: ignored)
        orphanSelection = orphanSelection.intersection(Set(orphans.map(\.id)))
        orphansFoundAt = Date()
        app?.smartClean.orphansDidChange()
        isFindingOrphans = false
    }

    /// Called after any cleanup: removed items disappear, sizes refresh.
    func refreshAfterCleanup() async {
        if loadedAt != nil {
            let selected = selectedAppID
            await load(force: true)
            if let selected, let installed = apps.first(where: { $0.id == selected }) { await loadAssociations(for: installed, force: true) }
        }
        if orphansFoundAt != nil { await findOrphans() }
    }
}
