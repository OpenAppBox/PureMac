import Foundation
import Observation
import PureMacKit

/// Storage Explorer state. Only the rows currently displayed are loaded from SQLite.
@Observable
final class ExplorerModel {
    enum Mode: String, CaseIterable, Identifiable {
        case folders
        case largestFiles
        case oldFiles
        case recentFiles
        case byType

        var id: String { rawValue }
        var title: String {
            switch self {
            case .folders: String(localized: "Folders")
            case .largestFiles: String(localized: "Largest Files")
            case .oldFiles: String(localized: "Old Files")
            case .recentFiles: String(localized: "Recent")
            case .byType: String(localized: "By Type")
            }
        }
    }

    private(set) var session: ScanSession?
    private(set) var current: FileRecord?
    private(set) var breadcrumbs: [FileRecord] = []
    private(set) var rows: [FileRecord] = []
    private(set) var hasMoreRows = false
    private(set) var extensionTotals: [ExtensionTotal] = []
    private(set) var isLoading = false
    /// Two-level sunburst data for the current folder (folders mode only).
    private(set) var mapNodes: [SunburstNode] = []
    var errorMessage: String?

    var mode: Mode = .folders { didSet { if oldValue != mode && !suppressModeReload { Task { await reloadRows() } } } }
    var sort: ChildSort = .allocatedDescending { didSet { if oldValue != sort { Task { await reloadRows() } } } }
    var selectedExtension: String? { didSet { if oldValue != selectedExtension { Task { await reloadRows() } } } }
    var searchText = ""
    var selection: Set<FileRecord.ID> = []

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    static let defaultPageSize = 200
    @ObservationIgnored private var pageSize = ExplorerModel.defaultPageSize
    @ObservationIgnored private var generation = 0

    func attach(app: AppModel) { self.app = app }

    var selectedRecords: [FileRecord] { rows.filter { selection.contains($0.id) } }

    /// Called after a scan finishes or history is cleared.
    func sessionDidChange() async {
        guard let store = app?.store else { return }
        session = try? await store.latestBrowsableSession()
        current = nil
        breadcrumbs = []
        selection = []
        if let session {
            let roots = (try? await store.roots(sessionID: session.id)) ?? []
            if roots.count == 1, let only = roots.first {
                await open(only)
            } else {
                rows = roots
                hasMoreRows = false
            }
            extensionTotals = (try? await store.extensionTotals(sessionID: session.id, limit: 40)) ?? []
        } else {
            rows = []
            extensionTotals = []
        }
    }

    func open(_ record: FileRecord) async {
        guard record.isContainer, let store = app?.store else { return }
        let ancestry = (try? await store.ancestry(of: record.id)) ?? [record]
        if mode != .folders {
            suppressModeReload = true
            mode = .folders
            suppressModeReload = false
        }
        pageSize = Self.defaultPageSize   // "Show More" applies to one folder, not every later one
        // Fetch first, then publish everything in one main-actor turn: one table rebuild, not four.
        guard let loaded = await fetch(current: record, mode: .folders, search: "") else { return }
        current = record
        breadcrumbs = ancestry
        selection = []
        publish(loaded)
    }

    func open(id: Int64) async {
        guard let store = app?.store, let record = try? await store.entry(id: id) else { return }
        await open(record)
    }

    /// Opens the folder containing `record` and selects it.
    func reveal(_ record: FileRecord) async {
        if record.isContainer, record.parentID == nil { await open(record); return }
        guard let parent = record.parentID else { return }
        await open(id: parent)
        if rows.contains(where: { $0.id == record.id }) { selection = [record.id] }
    }

    func goUp() async {
        guard breadcrumbs.count >= 2 else {
            await showRoots()
            return
        }
        await open(breadcrumbs[breadcrumbs.count - 2])
    }

    func showRoots() async {
        if mode != .folders {
            suppressModeReload = true
            mode = .folders
            suppressModeReload = false
        }
        guard let loaded = await fetch(current: nil, mode: .folders, search: "") else { return }
        current = nil
        breadcrumbs = []
        publish(loaded)
    }

    func reloadRows() async {
        guard let loaded = await fetch(current: current, mode: mode, search: searchText) else { return }
        publish(loaded)
    }

    private struct Loaded {
        var rows: [FileRecord]
        var hasMore: Bool
        var mapNodes: [SunburstNode]
        var token: Int
    }

    @ObservationIgnored private var suppressModeReload = false

    /// Loads rows (and the sunburst data) without touching observable state.
    private func fetch(current: FileRecord?, mode: Mode, search: String) async -> Loaded? {
        guard let store = app?.store, let session else { return nil }
        generation += 1
        let token = generation
        isLoading = true
        defer { if token == generation { isLoading = false } }
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [FileRecord] = []
        do {
            if !trimmed.isEmpty {
                result = try await store.search(sessionID: session.id, text: trimmed, limit: 300)
            } else {
                switch mode {
                case .folders:
                    if let current {
                        result = try await store.children(of: current.id, sort: sort, limit: pageSize + 1)
                    } else {
                        result = try await store.roots(sessionID: session.id)
                    }
                case .largestFiles:
                    var q = FileQuery(); q.limit = 300
                    result = try await store.files(sessionID: session.id, query: q)
                case .oldFiles:
                    var q = FileQuery(); q.limit = 300
                    q.modifiedBefore = Calendar.current.date(byAdding: .year, value: -1, to: Date())
                    result = try await store.files(sessionID: session.id, query: q)
                case .recentFiles:
                    var q = FileQuery(); q.limit = 300
                    q.modifiedAfter = Calendar.current.date(byAdding: .day, value: -7, to: Date())
                    result = try await store.files(sessionID: session.id, query: q)
                case .byType:
                    var q = FileQuery(); q.limit = 300
                    if let ext = selectedExtension { q.extensions = [ext] }
                    result = try await store.files(sessionID: session.id, query: q)
                }
            }
        } catch {
            errorMessage = String(localized: "Could not load items: \(error.localizedDescription)")
        }
        guard token == generation else { return nil }
        let hasMore = mode == .folders && trimmed.isEmpty && current != nil && result.count > pageSize
        let rows = hasMore ? Array(result.prefix(pageSize)) : result
        var nodes: [SunburstNode]
        if mode == .folders, trimmed.isEmpty, let current, sort == .allocatedDescending {
            nodes = (try? await ScanModel.mapNodes(for: current, store: store)) ?? []
        } else {
            nodes = rows.prefix(24).map { SunburstNode(id: $0.id, name: $0.name, value: Double($0.allocatedSize), color: $0.mapCategory.tint, isContainer: $0.isContainer) }
        }
        guard token == generation else { return nil }
        return Loaded(rows: rows, hasMore: hasMore, mapNodes: nodes, token: token)
    }

    private func publish(_ loaded: Loaded) {
        guard loaded.token == generation else { return }
        hasMoreRows = loaded.hasMore
        rows = loaded.rows
        mapNodes = loaded.mapNodes
        selection = selection.intersection(Set(loaded.rows.map(\.id)))
    }

    /// The index changed in place (items moved to the Trash or put back): reloads the open folder's
    /// own sizes, the breadcrumbs, its rows and the map. If the open folder itself is gone, opens the
    /// nearest folder above it that still exists.
    func indexDidChange() async {
        guard let store = app?.store, let session else { return }
        extensionTotals = (try? await store.extensionTotals(sessionID: session.id, limit: 40)) ?? extensionTotals
        guard let current else {
            await reloadRows()
            return
        }
        let chain = (try? await store.ancestry(of: current.id)) ?? []
        if let visible = chain.last(where: { $0.flags.isDisjoint(with: EntryFlags(rawValue: EntryFlags.hiddenMask)) }) {
            if visible.id == current.id {
                guard let loaded = await fetch(current: visible, mode: mode, search: searchText) else { return }
                self.current = visible
                breadcrumbs = chain
                publish(loaded)
            } else {
                await open(visible)
            }
        } else {
            await showRoots()
        }
    }

    func loadMore() async {
        pageSize += 200
        await reloadRows()
    }

    func searchChanged() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await reloadRows()
        }
    }
}
