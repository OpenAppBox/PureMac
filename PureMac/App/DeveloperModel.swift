import Foundation
import Observation
import PureMacKit

/// Developer storage locations, simulators and Docker (inspect).
@Observable
final class DeveloperModel {
    /// Every location on the page, including project node_modules folders from the last scan.
    private(set) var items: [DeveloperItem] = [] { didSet { rebuildSizes() } }
    private(set) var simulators: SimulatorSummary?
    private(set) var docker: DockerSummary?
    private(set) var isLoading = false
    private(set) var loadedAt: Date?
    private(set) var toolMessage: String?
    private(set) var isRunningTool = false
    var selection: Set<String> = []
    var selectedItemID: DeveloperItem.ID?
    /// `simctl` and `docker` can't run inside the App Sandbox (App Store edition).
    let toolsAvailable = !PathTools.isSandboxed

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
        if toolsAvailable {
            async let sims = Task.detached(priority: .utility) { DeveloperStorageInspector.simulatorSummary() }.value
            async let dock = Task.detached(priority: .utility) { DeveloperStorageInspector.dockerSummary() }.value
            simulators = await sims
            docker = await dock
        }
        var nodeModules: [FileRecord] = []
        if let store = app?.store, let session = try? await store.latestBrowsableSession() {
            // Only top-level node_modules folders of projects (never nested ones), from the latest scan.
            nodeModules = ((try? await store.search(sessionID: session.id, text: "node_modules", limit: 300)) ?? [])
                .filter { $0.name == "node_modules" && $0.isContainer && !Self.hasNodeModulesAncestor($0.path) }
        }
        found += Self.syntheticItems(nodeModules: nodeModules, docker: docker, existing: found)
        items = found
        if selectedItemID == nil || !items.contains(where: { $0.id == selectedItemID }) {
            selectedItemID = largestItem?.id
        }
        loadedAt = Date()
        isLoading = false
    }

    #if DEBUG
    func _demoSet(items: [DeveloperItem], simulators: SimulatorSummary?, docker: DockerSummary?, nodeModules: [FileRecord]) {
        guard app?.isDemo == true else { return }
        self.simulators = simulators
        self.docker = docker
        self.items = items + Self.syntheticItems(nodeModules: nodeModules, docker: docker, existing: items)
        selectedItemID = largestItem?.id
        loadedAt = Date()
    }

    /// Tests only: locations without inspecting the disk.
    func _testSet(items: [DeveloperItem]) {
        self.items = items
    }
    #endif

    /// node_modules folders become one "Project Dependencies" location; Docker without Docker
    /// Desktop's data folder (Colima, OrbStack…) still gets an inspect-only entry.
    private static func syntheticItems(nodeModules: [FileRecord], docker: DockerSummary?, existing: [DeveloperItem]) -> [DeveloperItem] {
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
        if let docker, docker.installed, !existing.contains(where: { $0.group == .containers }) {
            extra.append(DeveloperItem(
                id: "docker.cli", group: .containers, title: String(localized: "Docker"),
                detail: String(localized: "Images, containers, volumes and build cache, as reported by Docker."),
                path: nil, size: nil, risk: .protected,
                handling: .inspectOnly(reason: String(localized: "Inspect only. Manage images and volumes in Docker or with `docker` commands.")),
                toolCommandHint: "docker system df -v"))
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

    func deleteUnavailableSimulators() {
        guard !isRunningTool else { return }
        isRunningTool = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { DeveloperStorageInspector.deleteUnavailableSimulators() }.value
            toolMessage = outcome.message
            isRunningTool = false
            await load()
        }
    }
}

extension DockerSummary.Row {
    /// Bytes from Docker's human-readable sizes ("41.2GB", "18.6GB (45%)"). Docker uses powers of 1000.
    static func bytes(_ text: String) -> Int64? {
        let token = text.split(separator: " ").first.map(String.init) ?? text
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (unit, factor) in units where token.hasSuffix(unit) {
            guard let value = Double(token.dropLast(unit.count)) else { return nil }
            return Int64(value * factor)
        }
        return nil
    }

    var sizeBytes: Int64? { Self.bytes(size) }
    var reclaimableBytes: Int64? { Self.bytes(reclaimable) }
}
