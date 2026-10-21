import Foundation
import Observation
import PureMacKit

/// Developer storage locations and simulators (inspect).
@Observable
final class DeveloperModel {
    /// Every location on the page, including project node_modules folders from the last scan.
    private(set) var items: [DeveloperItem] = [] { didSet { rebuildSizes() } }
    private(set) var simulators: SimulatorSummary?
    private(set) var isLoading = false
    private(set) var loadedAt: Date?
    var selection: Set<String> = []
    var selectedItemID: DeveloperItem.ID?

    /// Sizes of every selectable path on the page (rebuilt once per load).
    private(set) var selectableSizes: [String: Int64] = [:]

    static let nodeModulesID = "projects.node_modules"
    /// Locations whose contents are already counted by another location (~/.cache holds the Hugging Face cache).
    static let overlappingIDs: Set<String> = ["ml.xdg"]

    @ObservationIgnored private weak var app: AppModel?

    func attach(app: AppModel) { self.app = app }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        var found = await DeveloperStorageInspector().inspect()
        // The App Sandbox can't run `simctl`, so simulators are counted from CoreSimulator's files.
        simulators = await Task.detached(priority: .utility) { DeveloperStorageInspector.simulatorSummaryFromFiles() }.value
        var nodeModules: [FileRecord] = []
        if let store = app?.store, let session = try? await store.latestBrowsableSession() {
            // Only top-level node_modules folders of projects (never nested ones), from the latest scan.
            nodeModules = ((try? await store.search(sessionID: session.id, text: "node_modules", limit: 300)) ?? [])
                .filter { $0.name == "node_modules" && $0.isContainer && !Self.hasNodeModulesAncestor($0.path) }
        }
        found += Self.syntheticItems(nodeModules: nodeModules)
        items = found
        if selectedItemID == nil || !items.contains(where: { $0.id == selectedItemID }) {
            selectedItemID = largestItem?.id
        }
        loadedAt = Date()
        isLoading = false
    }

    #if DEBUG
    func _demoSet(items: [DeveloperItem], simulators: SimulatorSummary?, nodeModules: [FileRecord]) {
        guard app?.isDemo == true else { return }
        self.simulators = simulators
        self.items = items + Self.syntheticItems(nodeModules: nodeModules)
        selectedItemID = largestItem?.id
        loadedAt = Date()
    }

    /// Tests only: locations without inspecting the disk.
    func _testSet(items: [DeveloperItem]) {
        self.items = items
    }
    #endif

    /// node_modules folders become one "Project Dependencies" location.
    private static func syntheticItems(nodeModules: [FileRecord]) -> [DeveloperItem] {
        var extra: [DeveloperItem] = []
        if !nodeModules.isEmpty {
            let children = nodeModules.map { record in
                var size = SizeSummary()
                size.allocatedSize = record.allocatedSize
                size.logicalSize = record.logicalSize
                size.fileCount = record.fileCount
                size.newestModification = record.modified
                return DeveloperItem.Child(path: record.path, name: ((record.path as NSString).deletingLastPathComponent as NSString).lastPathComponent,
                                           size: size, modified: record.modified)
            }.sorted { $0.size.allocatedSize > $1.size.allocatedSize }
            var total = SizeSummary()
            total.allocatedSize = children.reduce(0) { $0 + $1.size.allocatedSize }
            total.logicalSize = children.reduce(0) { $0 + $1.size.logicalSize }
            extra.append(DeveloperItem(
                id: nodeModulesID, group: .projects, title: String(localized: "node_modules folders"),
                detail: String(localized: "Packages installed into each JavaScript project, found by your last scan. A project needs them to run or build."),
                path: nil, size: total, risk: .review,
                warning: String(localized: "Remove a project’s node_modules only if you can reinstall its dependencies (npm install) — for example, for projects you no longer work on."),
                handling: .selectChildren, children: children, toolCommandHint: "npm install"))
        }
        return extra
    }

    static func hasNodeModulesAncestor(_ path: String) -> Bool {
        (path as NSString).deletingLastPathComponent.split(separator: "/").contains("node_modules")
    }

    // MARK: Derived

    var selectedItem: DeveloperItem? {
        guard let selectedItemID else { return nil }
        return items.first { $0.id == selectedItemID }
    }

    /// The largest location the user can act on (falls back to the largest of all).
    private var largestItem: DeveloperItem? {
        let candidates = items.filter { !Self.overlappingIDs.contains($0.id) }
        let actionable = candidates.filter { if case .inspectOnly = $0.handling { false } else { true } }
        return (actionable.isEmpty ? candidates : actionable).max { ($0.size?.allocatedSize ?? 0) < ($1.size?.allocatedSize ?? 0) }
    }

    /// Total per group, largest first; overlapping locations are not counted twice.
    var groupTotals: [(group: DeveloperItem.Group, bytes: Int64)] {
        var totals: [DeveloperItem.Group: Int64] = [:]
        for item in items where !Self.overlappingIDs.contains(item.id) {
            totals[item.group, default: 0] += item.size?.allocatedSize ?? 0
        }
        return totals.filter { $0.value > 0 }.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }

    private func rebuildSizes() {
        var sizes: [String: Int64] = [:]
        for item in items {
            if case .selectItem = item.handling, let path = item.path { sizes[path] = item.size?.allocatedSize ?? 0 }
            for child in item.children { sizes[child.path] = child.size.allocatedSize }
        }
        selectableSizes = sizes
    }

    /// Bytes of the selection; a path inside another selected path (the Hugging Face cache inside
    /// ~/.cache) is counted once, as the review will plan it.
    var selectedBytes: Int64 {
        let paths = PathTools.removingNested(Array(selection))
        return paths.reduce(0) { $0 + (selectableSizes[$1] ?? 0) }
    }

    /// Low-risk, regenerable locations (build data, package caches) that can be selected as a whole.
    var regenerablePaths: [String] {
        items.compactMap { item in
            guard item.risk == .low, case .selectItem = item.handling, let path = item.path, (item.size?.allocatedSize ?? 0) > 0 else { return nil }
            return path
        }
    }

    // MARK: Selection

    /// How much of `item` is selected: its children, or the whole folder.
    func selectionState(of item: DeveloperItem) -> (selected: Int, total: Int, bytes: Int64) {
        switch item.handling {
        case .selectItem:
            guard let path = item.path else { return (0, 0, 0) }
            let on = selection.contains(path)
            return (on ? 1 : 0, 1, on ? item.size?.allocatedSize ?? 0 : 0)
        case .selectChildren:
            let chosen = item.children.filter { selection.contains($0.path) }
            return (chosen.count, item.children.count, chosen.reduce(0) { $0 + $1.size.allocatedSize })
        case .inspectOnly:
            return (0, 0, 0)
        }
    }

    /// The list checkbox: clears what is selected in `item`, or selects all of it.
    func toggleAll(_ item: DeveloperItem) {
        let paths = selectablePaths(of: item)
        if paths.contains(where: selection.contains) { selection.subtract(paths) } else { selection.formUnion(paths) }
    }

    func selectablePaths(of item: DeveloperItem) -> [String] {
        switch item.handling {
        case .selectItem: item.path.map { [$0] } ?? []
        case .selectChildren: item.children.map(\.path)
        case .inspectOnly: []
        }
    }

    /// Selects exactly the children of `item` not changed for `days` days (unknown dates are left out).
    func selectChildren(of item: DeveloperItem, unchangedFor days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        selection.subtract(item.children.map(\.path))
        selection.formUnion(item.children.filter { ($0.modified ?? .distantFuture) < cutoff }.map(\.path))
    }

    func reviewSelection() {
        guard let app, !selection.isEmpty else { return }
        app.reviewUserSelection(Array(selection))
    }
}
