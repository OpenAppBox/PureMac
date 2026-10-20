import Foundation
import PureMacKit

/// The leftovers of one removed app, as the Orphaned Remnants page shows them.
struct RemovedApp: Identifiable, Hashable {
    /// The lower-cased identifier the items are named after.
    let id: String
    let identifier: String
    let name: String
    /// Developer part of the identifier, readable (`com.parallax.videoconverter` → "Parallax").
    let vendor: String?
    let items: [OrphanCandidate]
    let bytes: Int64
    let likelyCount: Int
    /// The newest modification inside any item: roughly when the app was last used.
    let lastUsed: Date?
    /// The app itself is in the Trash.
    let isInTrash: Bool

    var allLikely: Bool { likelyCount == items.count }
    var likelyItems: [OrphanCandidate] { items.filter { $0.confidence == .likely } }

    init(identifier: String, items: [OrphanCandidate]) {
        id = identifier.lowercased()
        self.identifier = identifier
        self.items = items.sorted { ($0.allocatedSize ?? 0, $1.path) > ($1.allocatedSize ?? 0, $0.path) }
        name = items.compactMap(\.appName).first ?? Self.readableName(of: identifier)
        vendor = Self.vendorName(of: identifier)
        bytes = items.reduce(0) { $0 + ($1.allocatedSize ?? 0) }
        likelyCount = items.filter { $0.confidence == .likely }.count
        lastUsed = items.compactMap(\.modified).max()
        isInTrash = items.contains { $0.evidence.contains { $0.kind == .appInTrash } }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all, likely, review, trashed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .likely: String(localized: "Likely")
            case .review: String(localized: "Needs Review")
            case .trashed: String(localized: "App in Trash")
            }
        }
        func includes(_ app: RemovedApp) -> Bool {
            switch self {
            case .all: true
            case .likely: app.likelyCount > 0
            case .review: !app.allLikely
            case .trashed: app.isInTrash
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case size, lastUsed, name
        var id: String { rawValue }
        var title: String {
            switch self {
            case .size: String(localized: "Most Space")
            case .lastUsed: String(localized: "Least Recently Used")
            case .name: String(localized: "Name")
            }
        }
    }

    // MARK: Names

    /// Identifier parts that say nothing about the app.
    private static let genericParts: Set<String> = ["com", "org", "net", "io", "app", "apps", "us", "de", "co", "uk", "dev", "me",
                                                    "mac", "macos", "osx", "desktop", "client", "inc", "ltd", "llc", "gmbh"]

    /// `com.microsoft.OneDriveStandaloneUpdater` → "One Drive Standalone Updater",
    /// `com.adobe.Acrobat.Pro` → "Acrobat Pro", `com.openai.chat` → "Openai Chat",
    /// `io.tunnelbox.client` → "Tunnelbox".
    static func readableName(of identifier: String) -> String {
        let parts = identifier.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return words(identifier) }
        let vendor = genericParts.contains(parts[1].lowercased()) ? nil : parts[1]
        let tail = parts.dropFirst(2).filter { !$0.allSatisfy(\.isNumber) }
        // Words after the developer, without generic ones ("mac", "client", "-desktop").
        let specific = tail.flatMap { words($0).split(separator: " ").map(String.init) }
            .filter { !genericParts.contains($0.lowercased()) }
        guard !specific.isEmpty else { return words(vendor ?? parts.last ?? identifier) }
        let name = specific.joined(separator: " ")
        // A short single word ("Chat", "Install") is clearer with its developer in front.
        if let vendor, specific.count == 1, name.count <= 7, words(vendor).lowercased() != name.lowercased() {
            return words(vendor) + " " + name
        }
        return name
    }

    static func vendorName(of identifier: String) -> String? {
        let parts = identifier.split(separator: ".").map(String.init)
        guard parts.count >= 3, !genericParts.contains(parts[1].lowercased()) else { return nil }
        return words(parts[1])
    }

    /// Splits camelCase, dashes and underscores into capitalized words.
    static func words(_ text: String) -> String {
        var out = ""
        var previous: Character?
        for character in text {
            if character == "-" || character == "_" {
                out.append(" ")
            } else {
                if let previous, character.isUppercase, previous.isLowercase || previous.isNumber { out.append(" ") }
                out.append(character)
            }
            previous = character
        }
        return out.split(separator: " ").map { word in
            word.first.map { String($0).uppercased() + word.dropFirst() } ?? String(word)
        }.joined(separator: " ")
    }

    /// A stable hue per identifier for its monogram (FNV-1a; `hashValue` changes every launch).
    var hueSeed: Double {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return Double(hash % 360) / 360
    }

    /// Up to two letters for the monogram.
    var initials: String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        let letters = words.count >= 2 ? [words[0].first!, words[1].first!] : Array(name.filter(\.isLetter).prefix(2))
        return String(letters).uppercased()
    }
}

extension AppsModel {
    func rebuildOrphanGroups() {
        orphanGroupsStorage = Dictionary(grouping: orphans) { $0.inferredBundleIdentifier.lowercased() }
            .map { RemovedApp(identifier: $0.value[0].inferredBundleIdentifier, items: $0.value) }
        rebuildVisibleOrphanGroups()
        if selectedOrphanGroupID == nil || !orphanGroups.contains(where: { $0.id == selectedOrphanGroupID }) {
            selectedOrphanGroupID = visibleOrphanGroups.first?.id
        }
    }

    func rebuildVisibleOrphanGroups() {
        var groups = orphanGroups.filter { orphanFilter.includes($0) }
        let query = orphanSearch.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            groups = groups.filter { group in
                group.name.localizedCaseInsensitiveContains(query) || group.identifier.localizedCaseInsensitiveContains(query)
                    || group.items.contains { $0.path.localizedCaseInsensitiveContains(query) }
            }
        }
        switch orphanSort {
        case .size: groups.sort { ($0.bytes, $1.id) > ($1.bytes, $0.id) }
        case .lastUsed: groups.sort { ($0.lastUsed ?? .distantFuture, $0.id) < ($1.lastUsed ?? .distantFuture, $1.id) }
        case .name: groups.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        visibleOrphanGroupsStorage = groups
    }

    var selectedOrphanGroup: RemovedApp? {
        guard let selectedOrphanGroupID else { return nil }
        return orphanGroups.first { $0.id == selectedOrphanGroupID }
    }

    var likelyOrphans: [OrphanCandidate] { orphans.filter { $0.confidence == .likely } }
    var allLikelyOrphansSelected: Bool { !likelyOrphans.isEmpty && likelyOrphans.allSatisfy { orphanSelection.contains($0.id) } }

    /// Selects every likely item, or — when they all are selected already — clears them again.
    func toggleLikelyOrphans() {
        let ids = likelyOrphans.map(\.id)
        if allLikelyOrphansSelected { orphanSelection.subtract(ids) } else { orphanSelection.formUnion(ids) }
    }

    /// Items of `group` that are selected.
    func selectedCount(in group: RemovedApp) -> Int { group.items.reduce(0) { $0 + (orphanSelection.contains($1.id) ? 1 : 0) } }

    /// A group's checkbox: clears its selection, or selects its likely items (all items when none is likely).
    func toggleOrphanGroup(_ group: RemovedApp) {
        if selectedCount(in: group) > 0 {
            orphanSelection.subtract(group.items.map(\.id))
        } else {
            let pick = group.likelyItems.isEmpty ? group.items : group.likelyItems
            orphanSelection.formUnion(pick.map(\.id))
        }
    }

    func setOrphan(_ orphan: OrphanCandidate, selected: Bool) {
        if selected { orphanSelection.insert(orphan.id) } else { orphanSelection.remove(orphan.id) }
    }

    var selectedOrphans: [OrphanCandidate] { orphans.filter { orphanSelection.contains($0.id) } }
    var selectedOrphanBytes: Int64 { selectedOrphans.reduce(0) { $0 + ($1.allocatedSize ?? 0) } }

    /// "Not an Orphan — Ignore" for every item of a removed app.
    func ignoreOrphans(_ items: [OrphanCandidate]) async {
        for item in items { _ = try? await app?.store?.addExclusion(path: item.path, scope: .cleanup) }
        orphanSelection.subtract(items.map(\.id))
        await findOrphans()
    }
}
