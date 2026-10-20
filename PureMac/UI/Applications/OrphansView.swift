import PureMacKit
import SwiftUI

/// Leftovers of apps that are gone: one row per removed app on the left, its items and the
/// evidence on the right. Nothing is selected for the user; "Likely" items can be picked at once.
struct OrphansView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle

    private var hue: Color { SidebarItem.orphans.hue }

    var body: some View {
        let model = app.apps
        ScreenScaffold(item: .orphans, scrolls: false) {
            ModuleHeader(item: .orphans, subtitle: "Leftovers of apps that are no longer installed — listed only when independent checks agree.") {
                if model.orphansFoundAt != nil {
                    HStack(spacing: 10) {
                        if model.isFindingOrphans { ProgressView().controlSize(.small) }
                        Button { Task { await model.findOrphans() } } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                            .buttonStyle(.glow(hue, prominent: false))
                            .disabled(model.isFindingOrphans)
                    }
                }
            }
            .entrance()
            if model.orphansFoundAt == nil {
                HeroState(item: .orphans, title: model.isFindingOrphans ? "Looking for leftovers…" : "Find leftovers of removed apps",
                          message: "PureMac checks installed apps, running processes, launch agents and macOS’s app registry before listing anything. Nothing is ever selected for you.",
                          busy: model.isFindingOrphans) {
                    Button { Task { await model.findOrphans() } } label: { Label("Find Remnants", systemImage: "magnifyingglass") }
                        .buttonStyle(.glow(hue))
                        .disabled(model.isFindingOrphans)
                }
                .entrance(0.05)
            } else if model.orphans.isEmpty {
                HeroState(item: .orphans, symbol: "checkmark.seal.fill", title: "No remnants found",
                          message: "No leftovers of uninstalled apps met PureMac’s evidence requirements.") {
                    Button("Check Again") { Task { await model.findOrphans() } }.buttonStyle(.glow(hue))
                }
            } else {
                summary.entrance(0.04)
                HStack(alignment: .top, spacing: 16) {
                    appList.frame(width: 380).frame(maxHeight: .infinity)
                    Group {
                        if let group = model.selectedOrphanGroup {
                            RemovedAppDetail(group: group)
                        } else {
                            GlassCard(padding: 40) {
                                ContentUnavailableView("Pick a removed app", systemImage: "puzzlepiece.extension",
                                                       description: Text("Choose an app on the left to see what it left behind and why PureMac thinks it is gone."))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .entrance(0.08)
            }
        }
        .selectionBar(isPresented: !model.orphanSelection.isEmpty) {
            let selected = model.selectedOrphans
            SelectionActionBar(count: selected.count,
                               bytes: model.selectedOrphanBytes, tint: hue, isDisabled: app.cleanup.isRunning,
                               onClear: { model.orphanSelection = [] }) {
                let candidates = CleanupPlanner.orphanCandidates(selected)
                app.cleanup.present(CleanupPlanner.plan(mode: .orphanRemoval, title: String(localized: "Orphaned remnants"), selected: candidates))
            }
        }
        .navigationTitle("Orphaned Remnants")
        .task { if model.orphansFoundAt == nil && !model.isFindingOrphans { await model.findOrphans() } }
    }

    // MARK: Summary

    private var summary: some View {
        @Bindable var model = app.apps
        let groups = model.orphanGroups
        let total = groups.reduce(Int64(0)) { $0 + $1.bytes }
        let likelyBytes = model.likelyOrphans.reduce(Int64(0)) { $0 + ($1.allocatedSize ?? 0) }
        let trashed = groups.filter(\.isInTrash).count
        let biggest = Array(groups.sorted { $0.bytes > $1.bytes }.prefix(3))
        let largest = max(biggest.first?.bytes ?? 1, 1)
        return GlassCard(padding: 16, tint: hue) {
            HStack(alignment: .top, spacing: 26) {
                VStack(alignment: .leading, spacing: 3) {
                    Eyebrow(text: "Left behind")
                    RollingText(text: ByteFormat.string(total, style: byteStyle), font: .hero(30))
                    Text("in \(model.orphans.count) items from \(groups.count) removed apps").font(.caption).foregroundStyle(.secondary)
                    LikelyToggle().padding(.top, 8)
                }
                .frame(minWidth: 190, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(text: "How sure PureMac is")
                    CapacityBar(segments: [
                        .init(id: "likely", value: Double(likelyBytes), color: .teal, label: String(localized: "Likely \(ByteFormat.string(likelyBytes, style: byteStyle))")),
                        .init(id: "review", value: Double(total - likelyBytes), color: .orange,
                              label: String(localized: "Needs Review \(ByteFormat.string(total - likelyBytes, style: byteStyle))")),
                    ], total: Double(max(total, 1)))
                    FlowLayout(spacing: 6, rowSpacing: 6) {
                        ForEach(RemovedApp.Filter.allCases) { filter in
                            if filter != .trashed || trashed > 0 {
                                FilterChip(label: filter.title, value: "\(groups.filter(filter.includes).count)", color: filter.tint, symbol: filter.symbol,
                                           isOn: model.orphanFilter == filter, clears: false) { model.orphanFilter = filter }
                            }
                        }
                    }
                    Text("“Likely” means every check agrees and nothing in it changed for 30 days.")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(text: "Biggest leftovers")
                    ForEach(Array(biggest.enumerated()), id: \.element.id) { index, group in
                        Button { model.selectedOrphanGroupID = group.id } label: {
                            BarListRow(title: group.name, value: ByteFormat.string(group.bytes, style: byteStyle),
                                       fraction: Double(group.bytes) / Double(largest), color: hue, icon: "puzzlepiece.extension.fill", delay: Double(index) * 0.05)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 250)
            }
        }
    }

    // MARK: List

    private var appList: some View {
        @Bindable var model = app.apps
        let visible = model.visibleOrphanGroups
        return GlassCard(padding: 0) {
            VStack(spacing: 0) {
                SearchField(text: $model.orphanSearch, prompt: "Search apps, identifiers and paths").padding([.horizontal, .top], 10)
                HStack(spacing: 8) {
                    Text("\(visible.count) apps").font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
                    Spacer(minLength: 8)
                    Menu {
                        Picker("Sort by", selection: $model.orphanSort) {
                            ForEach(RemovedApp.Sort.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(model.orphanSort.title, systemImage: "arrow.up.arrow.down").font(.caption)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                List(visible, selection: $model.selectedOrphanGroupID) { group in
                    RemovedAppRow(group: group).tag(group.id)
                        .contextMenu {
                            Button("Reveal in Finder") { SystemActions.revealInFinder(group.items.map(\.path)) }
                            Button("Copy Identifier") { SystemActions.copyToPasteboard(group.identifier) }
                            Divider()
                            Button("Not an Orphan — Ignore") { Task { await model.ignoreOrphans(group.items) } }
                        }
                }
                .scrollContentBackground(.hidden)
                .onKeyPress(.space) {
                    guard let group = model.selectedOrphanGroup else { return .ignored }
                    model.toggleOrphanGroup(group)
                    return .handled
                }
                .overlay {
                    if visible.isEmpty {
                        if model.orphanSearch.isEmpty {
                            ContentUnavailableView("No matching apps", systemImage: "line.3.horizontal.decrease.circle", description: Text("Try another filter."))
                        } else {
                            ContentUnavailableView.search(text: model.orphanSearch)
                        }
                    }
                }
            }
        }
    }
}

/// Selects every "Likely" item at once — and shows plainly when they are, so a second press clears them.
private struct LikelyToggle: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.apps
        let count = model.likelyOrphans.count
        let on = model.allLikelyOrphansSelected
        Button { model.toggleLikelyOrphans() } label: {
            Label(on ? String(localized: "All Likely Selected (\(count))") : String(localized: "Select All Likely (\(count))"),
                  systemImage: on ? "checkmark.circle.fill" : "checkmark.circle")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glow(.teal, prominent: !on))
        .disabled(count == 0)
        .help(on ? "Clears the selection of the likely items." : "Selects every item where all checks agree and nothing changed for 30 days. You still review everything before it moves.")
    }
}

private extension RemovedApp.Filter {
    var tint: Color? {
        switch self {
        case .all: nil
        case .likely: .teal
        case .review: .orange
        case .trashed: nil
        }
    }
    var symbol: String? { self == .trashed ? "trash" : nil }
}

// MARK: - Rows

/// A rounded tile with the app's initials in a hue derived from its identifier.
struct Monogram: View {
    let group: RemovedApp
    var size: CGFloat = 34

    var body: some View {
        let base = Color(hue: group.hueSeed, saturation: 0.55, brightness: 0.82)
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [base, Color(hue: group.hueSeed, saturation: 0.7, brightness: 0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Text(group.initials).font(.system(size: size * 0.4, weight: .bold, design: .rounded)).foregroundStyle(.white))
            .overlay(alignment: .bottomTrailing) {
                if group.isInTrash {
                    Image(systemName: "trash.circle.fill").font(.system(size: size * 0.38)).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.secondary).offset(x: size * 0.12, y: size * 0.12)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct RemovedAppRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    let group: RemovedApp

    var body: some View {
        let model = app.apps
        let picked = model.selectedCount(in: group)
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { picked > 0 }, set: { _ in model.toggleOrphanGroup(group) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .accessibilityLabel("Select all items of \(group.name)")
            Monogram(group: group)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).fontWeight(.semibold).lineLimit(1)
                Text(group.identifier).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    if let lastUsed = group.lastUsed {
                        // Icon instead of "Last used", so it fits in every language.
                        Image(systemName: "clock").imageScale(.small)
                        Text(lastUsed, format: .relative(presentation: .named))
                        Text(verbatim: "·")
                    }
                    Text(group.items.count == 1 ? String(localized: "1 item") : String(localized: "\(group.items.count) items"))
                }
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                SizeText(group.bytes).font(.callout.weight(.medium))
                ConfidenceBadge(confidence: group.allLikely ? .likely : .ambiguous)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail

private struct RemovedAppDetail: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    let group: RemovedApp

    private var hue: Color { SidebarItem.orphans.hue }

    var body: some View {
        let model = app.apps
        let picked = model.selectedCount(in: group)
        GlassCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header(picked: picked)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        verdict
                        items
                    }
                    .padding(16)
                }
            }
        }
    }

    private func header(picked: Int) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Monogram(group: group, size: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name).font(.title2.weight(.bold)).lineLimit(1)
                HStack(spacing: 6) {
                    if let vendor = group.vendor, vendor != group.name { Text(vendor).font(.callout.weight(.medium)) }
                    Text(group.identifier).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if group.isInTrash { StatusChip(level: .neutral, text: String(localized: "App in Trash")) }
                    if group.allLikely {
                        StatusChip(level: .good, text: String(localized: "All checks agree"))
                    } else {
                        StatusChip(level: .attention, text: String(localized: "Needs Review"))
                    }
                    if let lastUsed = group.lastUsed {
                        Text("Last used \(lastUsed, format: .relative(presentation: .named))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    Text(ByteFormat.string(group.bytes, style: byteStyle)).font(.metric(24))
                    Menu {
                        Button { SystemActions.revealInFinder(group.items.map(\.path)) } label: { Label("Reveal in Finder", systemImage: "folder") }
                        Button { SystemActions.copyToPasteboard(group.identifier) } label: { Label("Copy Identifier", systemImage: "doc.on.doc") }
                        Divider()
                        Button { Task { await app.apps.ignoreOrphans(group.items) } } label: { Label("Not an Orphan — Ignore", systemImage: "eye.slash") }
                    } label: { Image(systemName: "ellipsis.circle").imageScale(.large) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("More actions").accessibilityLabel("More actions")
                }
                Text(picked == 0 ? String(localized: "Nothing chosen yet") : String(localized: "\(picked) of \(group.items.count) selected"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    /// The checks behind the verdict, once each (per-item details are on the items).
    private var verdict: some View {
        let shared = sharedEvidence
        return VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "Why PureMac thinks it is gone")
            ForEach(shared, id: \.self) { evidence in
                Label {
                    Text(evidence.detail).font(.callout)
                } icon: {
                    Image(systemName: evidence.supportsRemoval ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(evidence.supportsRemoval ? Theme.good : Theme.warning)
                }
            }
        }
    }

    private var sharedEvidence: [Evidence] {
        var seen = Set<String>()
        var out: [Evidence] = []
        let perItem: Set<Evidence.Kind> = [.exactBundleIdentifier, .curatedVendorPath, .recentlyModified, .staleModification, .nameMatchOnly]
        for evidence in group.items.flatMap(\.evidence) where !perItem.contains(evidence.kind) && seen.insert(evidence.detail).inserted {
            out.append(evidence)
        }
        // Against-removal evidence first, so it is read.
        return out.filter { !$0.supportsRemoval } + out.filter(\.supportsRemoval)
    }

    private var items: some View {
        let model = app.apps
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow(text: "What it left behind")
                Spacer()
                if !group.likelyItems.isEmpty, group.likelyItems.count < group.items.count {
                    Button("Select Likely") { model.orphanSelection.formUnion(group.likelyItems.map(\.id)) }
                }
                Button("Select All") { model.orphanSelection.formUnion(group.items.map(\.id)) }
                Button("Select None") { model.orphanSelection.subtract(group.items.map(\.id)) }
            }
            .buttonStyle(.link).font(.caption)
            ForEach(group.items) { item in OrphanItemRow(item: item) }
        }
    }
}

private struct OrphanItemRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    let item: OrphanCandidate
    @State private var hovering = false

    var body: some View {
        let model = app.apps
        let on = model.orphanSelection.contains(item.id)
        let against = item.evidence.filter { !$0.supportsRemoval }
        let location = item.evidence.first { $0.kind == .exactBundleIdentifier || $0.kind == .curatedVendorPath }
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(get: { on }, set: { model.setOrphan(item, selected: $0) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .accessibilityLabel("Select \(item.name)")
            Image(systemName: item.kind.symbolName).foregroundStyle(SidebarItem.orphans.hue).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.kind.displayName).fontWeight(.medium)
                    ConfidenceBadge(confidence: item.confidence)
                }
                Text(abbreviate(item.path)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(item.path)
                if let location { Text(location.detail).font(.caption2).foregroundStyle(.secondary) }
                ForEach(against, id: \.self) { evidence in
                    Label(evidence.detail, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                if let size = item.allocatedSize { SizeText(size).foregroundStyle(.secondary) }
                if let modified = item.modified {
                    Text(modified, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Button { SystemActions.revealInFinder([item.path]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).opacity(hovering ? 1 : 0.45)
                .help("Reveal in Finder").accessibilityLabel("Reveal in Finder")
        }
        .padding(10)
        .background((on ? SidebarItem.orphans.hue.opacity(0.10) : Theme.track.opacity(hovering ? 0.9 : 0.5)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Reveal in Finder") { SystemActions.revealInFinder([item.path]) }
            Button("Copy Path") { SystemActions.copyToPasteboard(item.path) }
            Button("Not an Orphan — Ignore") { Task { await model.ignoreOrphans([item]) } }
        }
    }
}
