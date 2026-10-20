import AppKit
import Foundation
import Observation
import PureMacKit
import UniformTypeIdentifiers

/// Exact duplicate search over folders the user chooses.
@Observable
final class DuplicatesModel {
    private(set) var result: DuplicateScanResult? { didSet { rebuildDerived() } }
    private(set) var isSearching = false
    private(set) var phase = ""
    private(set) var progressDone = 0
    private(set) var progressTotal = 0
    var roots: [String] = []
    var minimumSizeMB = 1
    var selection: Set<String> = []
    var errorMessage: String?

    // Browsing the result
    var selectedGroupID: DuplicateGroup.ID?
    var kindFilter: Kind? { didSet { rebuildVisible() } }
    var searchText = "" { didSet { rebuildVisible() } }
    var sortOrder: SortOrder = .savings { didSet { rebuildVisible() } }
    /// The rule last used for automatic selection (also used by a group's checkbox).
    private(set) var lastRule: KeepRule = .newest

    /// Derived once per result (never in a view body).
    private(set) var visibleGroups: [DuplicateGroup] = []
    private(set) var kindTotals: [(kind: Kind, bytes: Int64, groups: Int)] = []
    private(set) var folderTotals: [(folder: String, bytes: Int64)] = []
    /// The folders the current result was searched in.
    private(set) var searchedRoots: [String] = []
    @ObservationIgnored private var kinds: [DuplicateGroup.ID: Kind] = [:]

    @ObservationIgnored private var flag = CancellationFlag()
    @ObservationIgnored private weak var app: AppModel?

    func attach(app: AppModel) {
        self.app = app
        let home = PathTools.userHome
        roots = ["Downloads", "Documents", "Desktop"].map { home + "/" + $0 }
    }

    func search() {
        guard !isSearching, !roots.isEmpty else { return }
        isSearching = true
        selection = []
        errorMessage = nil
        phase = ""
        progressDone = 0
        progressTotal = 0
        flag = CancellationFlag()
        let flag = flag
        let finder = DuplicateFinder(minimumSize: Int64(minimumSizeMB) << 20)
        let roots = roots
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                finder.find(roots: roots, isCancelled: { flag.isCancelled }) { phase, done, total in
                    Task { @MainActor in
                        self.phase = phase
                        self.progressDone = done
                        self.progressTotal = total
                    }
                }
            }.value
            self.searchedRoots = roots
            self.result = result
            self.isSearching = false
        }
    }

    func cancel() { flag.cancel() }

    /// Forgets the result, back to choosing folders.
    func reset() {
        guard !isSearching else { return }
        result = nil
        selection = []
        errorMessage = nil
    }

    #if DEBUG
    func _demoSet(_ result: DuplicateScanResult) {
        guard app?.isDemo == true else { return }
        searchedRoots = roots
        self.result = result
    }

    /// Tests only: a result without searching the disk.
    func _testSet(_ result: DuplicateScanResult, roots: [String]) {
        searchedRoots = roots
        self.result = result
    }
    #endif

    // MARK: Kinds, filtering, sorting

    enum Kind: Int, CaseIterable, Identifiable {
        case video, image, audio, archive, document, other
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .video: String(localized: "Videos")
            case .image: String(localized: "Images")
            case .audio: String(localized: "Audio")
            case .archive: String(localized: "Archives & Disk Images")
            case .document: String(localized: "Documents")
            case .other: String(localized: "Other Files")
            }
        }

        var symbol: String {
            switch self {
            case .video: "film"
            case .image: "photo"
            case .audio: "waveform"
            case .archive: "archivebox"
            case .document: "doc.text"
            case .other: "doc"
            }
        }

        static func of(path: String) -> Kind {
            let ext = (path as NSString).pathExtension.lowercased()
            guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .other }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .archive) || type.conforms(to: .diskImage) || ["dmg", "iso", "pkg", "xip"].contains(ext) { return .archive }
            if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation)
                || type.conforms(to: .spreadsheet) || type.conforms(to: .compositeContent) { return .document }
            return .other
        }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case savings, copies, size, name
        var id: String { rawValue }
        var title: String {
            switch self {
            case .savings: String(localized: "Most Space")
            case .copies: String(localized: "Most Copies")
            case .size: String(localized: "Largest File")
            case .name: String(localized: "Name")
            }
        }
    }

    func kind(of group: DuplicateGroup) -> Kind { kinds[group.id] ?? .other }

    private func rebuildDerived() {
        let groups = result?.groups ?? []
        kinds = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, Kind.of(path: $0.files.first?.path ?? "")) })
        var byKind: [Kind: (bytes: Int64, groups: Int)] = [:]
        for group in groups {
            let kind = kinds[group.id] ?? .other
            byKind[kind, default: (0, 0)].bytes += group.potentialSavings
            byKind[kind, default: (0, 0)].groups += 1
        }
        kindTotals = Kind.allCases.compactMap { kind in byKind[kind].map { (kind, $0.bytes, $0.groups) } }
        // Where the copies are: every copy's bytes, attributed to the search folder that holds it.
        let roots = searchedRoots.sorted { $0.count > $1.count }
        var byFolder: [String: Int64] = [:]
        for group in groups {
            for file in group.files {
                let root = roots.first { file.path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } ?? (file.path as NSString).deletingLastPathComponent
                byFolder[root, default: 0] += file.allocatedSize
            }
        }
        folderTotals = byFolder.map { ($0.key, $0.value) }.sorted { ($0.1, $1.0) > ($1.1, $0.0) }  // ties by name, stable across renders
        if let kindFilter, byKind[kindFilter] == nil { self.kindFilter = nil }
        rebuildVisible()
        if selectedGroupID == nil || !groups.contains(where: { $0.id == selectedGroupID }) {
            selectedGroupID = visibleGroups.first?.id
        }
    }

    private func rebuildVisible() {
        var groups = result?.groups ?? []
        if let kindFilter { groups = groups.filter { kinds[$0.id] == kindFilter } }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            groups = groups.filter { group in group.files.contains { $0.path.localizedCaseInsensitiveContains(query) } }
        }
        switch sortOrder {
        case .savings: groups.sort { ($0.potentialSavings, $0.id) > ($1.potentialSavings, $1.id) }
        case .copies: groups.sort { ($0.files.count, $0.potentialSavings) > ($1.files.count, $1.potentialSavings) }
        case .size: groups.sort { ($0.size, $0.id) > ($1.size, $1.id) }
        case .name: groups.sort { ($0.files.first?.name ?? "").localizedStandardCompare($1.files.first?.name ?? "") == .orderedAscending }
        }
        visibleGroups = groups
    }

    var selectedGroup: DuplicateGroup? {
        guard let selectedGroupID else { return nil }
        return result?.groups.first { $0.id == selectedGroupID }
    }

    // MARK: Choosing copies

    enum KeepRule: Hashable, Identifiable {
        case newest, oldest, shortestPath
        /// Keep a copy inside this folder when the group has one (otherwise the newest copy).
        case inFolder(String)

        static let standard: [KeepRule] = [.newest, .oldest, .shortestPath]
        var id: String {
            switch self {
            case .newest: "newest"
            case .oldest: "oldest"
            case .shortestPath: "shortest"
            case .inFolder(let folder): "folder:" + folder
            }
        }
        var title: String {
            switch self {
            case .newest: String(localized: "Keep the Newest Copy")
            case .oldest: String(localized: "Keep the Oldest Copy")
            case .shortestPath: String(localized: "Keep the Copy With the Shortest Path")
            case .inFolder(let folder): String(localized: "Keep the Copy in \(abbreviate(folder))")
            }
        }

        func keeper(in group: DuplicateGroup) -> DuplicateFile? {
            switch self {
            case .newest: return group.files.max { ($0.modified, $1.path) < ($1.modified, $0.path) }
            case .oldest: return group.files.min { ($0.modified, $0.path) < ($1.modified, $1.path) }
            case .shortestPath: return group.files.min { ($0.path.count, $0.path) < ($1.path.count, $1.path) }
            case .inFolder(let folder):
                let prefix = folder.hasSuffix("/") ? folder : folder + "/"
                let inside = group.files.filter { $0.path.hasPrefix(prefix) }
                return inside.max { ($0.modified, $1.path) < ($1.modified, $0.path) } ?? KeepRule.newest.keeper(in: group)
            }
        }
    }

    /// Selects every copy except one in each shown group, chosen by `rule`. Groups hidden by the
    /// filter keep their current choice. One copy is always kept.
    func selectExtraCopies(keeping rule: KeepRule) {
        lastRule = rule
        var picked = selection
        for group in visibleGroups where group.files.count > 1 {
            let keep = rule.keeper(in: group)
            for file in group.files {
                if file.path == keep?.path { picked.remove(file.path) } else { picked.insert(file.path) }
            }
        }
        errorMessage = nil
        selection = picked
    }

    /// Keeps `file` and selects the other copies of its group.
    func keepOnly(_ file: DuplicateFile, in group: DuplicateGroup) {
        var picked = selection
        for other in group.files {
            if other.path == file.path { picked.remove(other.path) } else { picked.insert(other.path) }
        }
        errorMessage = nil
        selection = picked
    }

    /// Copies of `group` that are selected for removal.
    func selectedCount(in group: DuplicateGroup) -> Int {
        group.files.reduce(0) { $0 + (selection.contains($1.path) ? 1 : 0) }
    }

    /// A group's checkbox: clears its choice, or selects its extra copies with the last rule.
    func toggleGroup(_ group: DuplicateGroup) {
        if selectedCount(in: group) > 0 {
            selection.subtract(group.files.map(\.path))
        } else if let keep = lastRule.keeper(in: group) {
            selection.formUnion(group.files.map(\.path).filter { $0 != keep.path })
        }
        errorMessage = nil
    }

    /// Checks or clears every shown group.
    func setAllVisible(_ on: Bool) {
        if on {
            selectExtraCopies(keeping: lastRule)
        } else {
            selection.subtract(visibleGroups.flatMap { $0.files.map(\.path) })
            errorMessage = nil
        }
    }

    /// Bytes of the selected copies.
    var selectedBytes: Int64 {
        guard !selection.isEmpty else { return 0 }
        return (result?.groups ?? []).reduce(0) { total, group in
            total + group.files.filter { selection.contains($0.path) }.reduce(0) { $0 + $1.allocatedSize }
        }
    }

    func toggle(_ file: DuplicateFile, in group: DuplicateGroup) {
        setRemove(!selection.contains(file.path), file, in: group)
    }

    /// Marks one copy to remove or keep. At least one copy of every group stays unselected.
    func setRemove(_ remove: Bool, _ file: DuplicateFile, in group: DuplicateGroup) {
        if !remove {
            selection.remove(file.path)
            errorMessage = nil
        } else if !selection.contains(file.path) {
            guard selectedCount(in: group) < group.files.count - 1 else {
                errorMessage = String(localized: "At least one copy of each file is always kept.")
                return
            }
            selection.insert(file.path)
            errorMessage = nil
        }
    }

    func reviewSelection() {
        guard let app, let groups = result?.groups else { return }
        Task {
            do {
                let (candidates, rejected) = try CleanupPlanner.duplicateCandidates(groups: groups, selectedPaths: selection, policy: await app.safetyPolicy())
                app.cleanup.present(CleanupPlanner.plan(mode: .duplicates, title: String(localized: "Duplicate copies"), selected: candidates), rejected: rejected) { _ in
                    self.removeMoved()
                }
            } catch {
                errorMessage = String(localized: "At least one copy of each file must be kept.")
            }
        }
    }

    private func removeMoved() {
        guard var result else { return }
        result.groups = result.groups.compactMap { group in
            var g = group
            g.files.removeAll { file in if case .success(let st) = FileStat.lstat(file.path) { return !st.identity.isSameObject(as: file.identity) } else { return true } }
            return g.files.count > 1 ? g : nil
        }
        self.result = result
        selection = []
    }
}
