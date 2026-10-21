import PureMacKit
import SwiftUI

struct DeveloperView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    @State private var hoveredGroup: RingSegment.ID?

    private var hue: Color { SidebarItem.developer.hue }

    var body: some View {
        let model = app.developer
        ScreenScaffold(item: .developer, scrolls: false) {
            ModuleHeader(item: .developer, subtitle: LocalizedStringKey(devSubtitle)) {
                if model.loadedAt != nil {
                    Button { Task { await model.load() } } label: { Label(model.isLoading ? "Measuring…" : "Refresh", systemImage: "arrow.clockwise") }
                        .buttonStyle(.glow(hue, prominent: false))
                        .disabled(model.isLoading)
                }
            }
            .entrance()
            if model.loadedAt == nil {
                HeroState(item: .developer, title: model.isLoading ? "Measuring developer storage…" : "Developer storage, explained",
                          message: "Xcode build data and archives, simulators, package-manager caches, Docker and project dependencies — with what each one is and what removing it costs. Nothing is selected automatically.",
                          busy: model.isLoading) {
                    Button { Task { await model.load() } } label: { Label("Measure", systemImage: "ruler") }
                        .buttonStyle(.glow(hue))
                        .disabled(model.isLoading)
                }
                .entrance(0.05)
            } else if model.items.isEmpty {
                HeroState(item: .developer, symbol: "checkmark.seal.fill", title: "No developer storage found",
                          message: "None of the Xcode, simulator, package-manager, Docker or model-cache locations PureMac knows exist on this Mac.") { EmptyView() }
                    .entrance(0.05)
            } else {
                hero.entrance(0.04)
                HStack(alignment: .top, spacing: 16) {
                    locationList.frame(width: 380).frame(maxHeight: .infinity)
                    Group {
                        if let item = model.selectedItem {
                            DeveloperItemDetail(item: item).id(item.id)
                                .transition(.opacity.combined(with: .offset(x: 12)))
                        } else {
                            GlassCard(padding: 40) {
                                ContentUnavailableView("Pick a location", systemImage: "hammer",
                                                       description: Text("Choose a location on the left to see what it holds and what removing it costs."))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .animation(.easeOut(duration: 0.2), value: model.selectedItemID)
                }
                .entrance(0.08)
            }
        }
        .selectionBar(isPresented: !model.selection.isEmpty) {
            SelectionActionBar(count: model.selection.count,
                               bytes: model.selectedBytes, tint: hue, isDisabled: app.cleanup.isRunning,
                               onClear: { app.developer.selection = [] }) { model.reviewSelection() }
        }
        .navigationTitle("Developer Storage")
        // Measuring only reads sizes, so do it on the first visit instead of asking for a click.
        .task { if model.loadedAt == nil && !model.isLoading { await model.load() } }
    }

    private var devSubtitle: String {
        guard let loaded = app.developer.loadedAt else { return String(localized: "Xcode, simulators, package managers, Docker and node_modules") }
        return String(localized: "Measured \(loaded.formatted(date: .omitted, time: .shortened)) · inspect first, remove only what you choose")
    }

    // MARK: Hero

    private var hero: some View {
        let model = app.developer
        let totals = model.groupTotals
        let total = totals.reduce(Int64(0)) { $0 + $1.bytes }
        let largest = max(totals.first?.bytes ?? 1, 1)
        let regenerable = model.regenerablePaths
        let regenerableBytes = regenerable.reduce(Int64(0)) { $0 + (model.selectableSizes[$1] ?? 0) }
        let segments = totals.map { entry in
            RingSegment(id: entry.group.rawValue, value: Double(entry.bytes), color: entry.group.tint,
                        label: entry.group.displayName, detail: ByteFormat.string(entry.bytes, style: byteStyle))
        }
        return GlassCard(padding: 16, tint: hue) {
            HStack(alignment: .center, spacing: 24) {
                RingChart(segments: segments, total: Double(total), lineWidth: 14, hovered: $hoveredGroup) { segment in
                    VStack(spacing: 0) {
                        Text(segment.map { ByteFormat.string(Int64($0.value), style: byteStyle) } ?? ByteFormat.string(total, style: byteStyle))
                            .font(.metric(16)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                        Text(segment?.label ?? String(localized: "developer data"))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                    }
                }
                .frame(width: 150, height: 150)

                VStack(alignment: .leading, spacing: 3) {
                    ForEach(totals, id: \.group) { entry in
                        Button { selectLargest(in: entry.group) } label: {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 3).fill(entry.group.tint).frame(width: 10, height: 10)
                                Text(entry.group.displayName).lineLimit(1).frame(width: 220, alignment: .leading)
                                MeterBar(fraction: Double(entry.bytes) / Double(largest), color: entry.group.tint).frame(maxWidth: .infinity)
                                Text(ByteFormat.string(entry.bytes, style: byteStyle)).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 70, alignment: .trailing)
                            }
                            .font(.callout)
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .background(hoveredGroup == entry.group.rawValue ? Theme.track : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in hoveredGroup = inside ? entry.group.rawValue : (hoveredGroup == entry.group.rawValue ? nil : hoveredGroup) }
                        .help("Show the largest location in \(entry.group.displayName)")
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 10) {
                    StatBlock(value: ByteFormat.string(regenerableBytes, style: byteStyle), label: "safe to rebuild", tint: regenerableBytes > 0 ? hue : nil, size: 22)
                    Button { model.selection.formUnion(regenerable) } label: { Label("Select Regenerable", systemImage: "checkmark.circle") }
                        .buttonStyle(.glow(hue, prominent: false))
                        .disabled(regenerable.isEmpty || regenerable.allSatisfy(model.selection.contains))
                        .help("Low-risk package caches that tools download again when needed. Xcode data, archives, simulators and projects are never included.")
                }
                .frame(width: 190, alignment: .leading)
            }
        }
    }

    private func selectLargest(in group: DeveloperItem.Group) {
        let model = app.developer
        if let item = model.items.filter({ $0.group == group }).max(by: { ($0.size?.allocatedSize ?? 0) < ($1.size?.allocatedSize ?? 0) }) {
            model.selectedItemID = item.id
        }
    }

    // MARK: Location list

    private var locationList: some View {
        @Bindable var model = app.developer
        let largest = max(model.items.filter { !DeveloperModel.overlappingIDs.contains($0.id) }.compactMap { $0.size?.allocatedSize }.max() ?? 1, 1)
        let groups = DeveloperItem.Group.allCases.filter { group in model.items.contains { $0.group == group } }
        return GlassCard(padding: 0) {
            List(selection: $model.selectedItemID) {
                ForEach(groups, id: \.self) { group in
                    Section(group.displayName) {
                        ForEach(model.items.filter { $0.group == group }.sorted { ($0.size?.allocatedSize ?? -1) > ($1.size?.allocatedSize ?? -1) }) { item in
                            DeveloperLocationRow(item: item, state: model.selectionState(of: item), largest: largest) { model.toggleAll(item) }
                                .tag(item.id)
                                .contextMenu {
                                    if let path = item.path {
                                        Button("Reveal in Finder") { SystemActions.revealInFinder([path]) }
                                        Button("Copy Path") { SystemActions.copyToPasteboard(path) }
                                    }
                                }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .onKeyPress(.space) {
                guard let item = model.selectedItem, !model.selectablePaths(of: item).isEmpty else { return .ignored }
                model.toggleAll(item)
                return .handled
            }
        }
    }
}

// MARK: - Rows

private struct DeveloperLocationRow: View {
    let item: DeveloperItem
    let state: (selected: Int, total: Int, bytes: Int64)
    let largest: Int64
    let toggle: () -> Void
    @Environment(\.byteStyle) private var byteStyle

    var body: some View {
        HStack(spacing: 10) {
            if case .inspectOnly = item.handling {
                Image(systemName: "eye").foregroundStyle(.secondary).frame(width: 14).help("Inspect only")
            } else {
                Toggle(isOn: Binding(get: { state.selected > 0 }, set: { _ in toggle() })) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .disabled(state.total == 0)
                    .accessibilityLabel("Select \(item.title)")
            }
            IconTile(symbol: item.symbol, gradient: .tile(item.group.tint), size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(state.selected > 0 ? AnyShapeStyle(SidebarItem.developer.hue) : AnyShapeStyle(.secondary)).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.size.map { ByteFormat.string($0.allocatedSize, style: byteStyle) } ?? "—").font(.callout.weight(.semibold)).monospacedDigit()
                MeterBar(fraction: Double(item.size?.allocatedSize ?? 0) / Double(largest), color: item.group.tint, height: 4).frame(width: 64)
            }
        }
        .padding(.vertical, 3)
    }

    private var status: String {
        switch item.handling {
        case .inspectOnly:
            return String(localized: "Inspect only")
        case .selectItem:
            if state.selected > 0 { return String(localized: "Selected") }
            return item.risk == .low ? String(localized: "Rebuilt when needed") : String(localized: "Review before removing")
        case .selectChildren:
            if state.selected > 0 { return String(localized: "\(state.selected) of \(state.total) selected · \(ByteFormat.string(state.bytes, style: byteStyle))") }
            return state.total == 1 ? String(localized: "1 item") : String(localized: "\(state.total) items")
        }
    }
}

// MARK: - Detail

private struct DeveloperItemDetail: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    let item: DeveloperItem
    @State private var sort: ChildSort = .size

    enum ChildSort: String, CaseIterable, Identifiable {
        case size, age, name
        var id: String { rawValue }
        var title: String {
            switch self {
            case .size: String(localized: "Size")
            case .age: String(localized: "Oldest First")
            case .name: String(localized: "Name")
            }
        }
    }

    var body: some View {
        let model = app.developer
        let state = model.selectionState(of: item)
        GlassCard(padding: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(state: state)
                    Text(item.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let warning = item.warning {
                        NoticeView(tone: .warning, title: LocalizedStringKey(warning))
                    }
                    if case .inspectOnly(let reason) = item.handling {
                        NoticeView(tone: .info, title: LocalizedStringKey(reason))
                    }
                    if let hint = item.toolCommandHint { CommandBox(command: hint) }
                    if item.id == "sim.devices" { SimulatorPanel() }
                    switch item.handling {
                    case .selectItem: wholeFolder(state: state)
                    case .selectChildren: children
                    case .inspectOnly: EmptyView()
                    }
                }
                .padding(18)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func header(state: (selected: Int, total: Int, bytes: Int64)) -> some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: item.symbol, gradient: .tile(item.group.tint), size: 46)
                .shadow(color: item.group.tint.opacity(0.4), radius: 8, y: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.title).font(.title3.weight(.semibold))
                    RiskBadge(risk: item.risk)
                }
                Text(item.group.displayName).font(.caption).foregroundStyle(.secondary)
                if let path = item.path {
                    HStack(spacing: 6) {
                        Text(abbreviate(path)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Reveal in Finder") { SystemActions.revealInFinder([path]) }.buttonStyle(.link).font(.caption)
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.size.map { ByteFormat.string($0.allocatedSize, style: byteStyle) } ?? "—").font(.metric(26)).monospacedDigit()
                if state.bytes > 0 {
                    Text("\(ByteFormat.string(state.bytes, style: byteStyle)) selected").font(.caption).foregroundStyle(SidebarItem.developer.hue)
                } else if let files = item.size?.fileCount, files > 0 {
                    Text("\(files.formatted()) files").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func wholeFolder(state: (selected: Int, total: Int, bytes: Int64)) -> some View {
        @Bindable var model = app.developer
        let on = state.selected > 0
        return Button { model.toggleAll(item) } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.title2)
                    .foregroundStyle(on ? AnyShapeStyle(SidebarItem.developer.hue) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(on ? "Selected for the Trash" : "Select this folder").fontWeight(.medium)
                    Text(item.risk == .low ? "The tool downloads or rebuilds it the next time it’s needed." : "Moves the whole folder to the Trash after review. You can put it back from History.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(item.size.map { ByteFormat.string($0.allocatedSize, style: byteStyle) } ?? "").monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(12)
            .background(on ? SidebarItem.developer.hue.opacity(0.12) : Theme.track.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? SidebarItem.developer.hue.opacity(0.45) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var children: some View {
        @Bindable var model = app.developer
        let rows = sortedChildren
        let largest = max(item.children.map(\.size.allocatedSize).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Eyebrow(text: item.children.count == 1 ? "Contents — 1 item" : "Contents — \(item.children.count) items")
                Spacer()
                Menu {
                    Button("All") { model.selection.formUnion(item.children.map(\.path)) }
                    Section("Not changed for") {
                        Button("30 Days") { model.selectChildren(of: item, unchangedFor: 30) }
                        Button("90 Days") { model.selectChildren(of: item, unchangedFor: 90) }
                        Button("1 Year") { model.selectChildren(of: item, unchangedFor: 365) }
                    }
                    Divider()
                    Button("None") { model.selection.subtract(item.children.map(\.path)) }
                } label: {
                    Label("Select", systemImage: "checklist").font(.caption.weight(.medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(item.children.isEmpty)
                .help("Select items by age — for example, build data of projects you haven’t opened in months")
                ListMenuPicker(title: "Sort by", symbol: "arrow.up.arrow.down", value: $sort, options: ChildSort.allCases) { $0.title }
            }
            if item.children.isEmpty {
                Text("This folder is empty.").foregroundStyle(.secondary).font(.callout)
            }
            LazyVStack(spacing: 2) {
                ForEach(rows) { child in
                    ChildRow(child: child, title: displayName(of: child), largest: largest,
                             subtitle: item.group == .projects ? abbreviate((child.path as NSString).deletingLastPathComponent) : nil)
                }
            }
        }
    }

    private var sortedChildren: [DeveloperItem.Child] {
        switch sort {
        case .size: item.children
        case .age: item.children.sorted { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }
        case .name: item.children.sorted { displayName(of: $0).localizedStandardCompare(displayName(of: $1)) == .orderedAscending }
        }
    }

    /// DerivedData folders are "<Project>-<28 letters>"; show the project name.
    private func displayName(of child: DeveloperItem.Child) -> String {
        guard item.id == "xcode.deriveddata", let dash = child.name.lastIndex(of: "-") else { return child.name }
        let suffix = child.name[child.name.index(after: dash)...]
        return suffix.count >= 20 && suffix.allSatisfy(\.isLowercase) ? String(child.name[..<dash]) : child.name
    }
}

private struct ChildRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    let child: DeveloperItem.Child
    let title: String
    let largest: Int64
    var subtitle: String?

    var body: some View {
        @Bindable var model = app.developer
        let on = model.selection.contains(child.path)
        HStack(spacing: 10) {
            SetCheckbox(id: child.path, selection: $model.selection, label: String(localized: "Select \(title)"))
            FileIcon(path: child.path, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    if let modified = child.modified {
                        Text("Changed \(modified.formatted(.relative(presentation: .named)))")
                    }
                    if let subtitle { Text("· " + subtitle).truncationMode(.middle) }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            MeterBar(fraction: Double(child.size.allocatedSize) / Double(largest), color: on ? SidebarItem.developer.hue : Theme.neutralA, height: 4)
                .frame(width: 70)
            Text(ByteFormat.string(child.size.allocatedSize, style: byteStyle)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(on ? SidebarItem.developer.hue.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if on { model.selection.remove(child.path) } else { model.selection.insert(child.path) } }
        .contextMenu {
            Button("Reveal in Finder") { SystemActions.revealInFinder([child.path]) }
            Button("Copy Path") { SystemActions.copyToPasteboard(child.path) }
        }
    }
}

/// A tool's own command, shown as text to copy — PureMac does not run it.
private struct CommandBox: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Prefer the tool’s own cleanup?").font(.caption).foregroundStyle(.secondary)
                Text(command).font(.callout.monospaced()).textSelection(.enabled)
            }
            Spacer()
            Button { SystemActions.copyToPasteboard(command); copied = true } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.clipboard")
            }
            .buttonStyle(.glow(.secondary, prominent: false))
        }
        .padding(10)
        .background(Theme.track.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SimulatorPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.developer
        if let sims = model.simulators {
            HStack(alignment: .center, spacing: 18) {
                if sims.availabilityKnown {
                    GaugeRing(fraction: Double(sims.unavailableDevices) / Double(max(sims.totalDevices, 1)), color: Theme.warning,
                              label: "\(sims.unavailableDevices)", caption: String(localized: "unavailable"))
                        .frame(width: 92, height: 92)
                } else {
                    GaugeRing(fraction: 1, color: SidebarItem.developer.hue,
                              label: "\(sims.totalDevices)", caption: String(localized: "devices"))
                        .frame(width: 92, height: 92)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if sims.availabilityKnown {
                        Text("\(sims.totalDevices) simulator devices, \(sims.unavailableDevices) unavailable").fontWeight(.medium)
                        Text("Unavailable devices belong to runtimes that are no longer installed.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(sims.totalDevices) simulator devices").fontWeight(.medium)
                        Text("PureMac can’t see which simulator runtimes are installed, so it can’t tell which devices are unavailable.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !sims.runtimes.isEmpty {
                        FlowLayout(spacing: 6, rowSpacing: 6) {
                            ForEach(sims.runtimes, id: \.self) { runtime in
                                Text(Self.runtimeName(runtime)).font(.caption2.weight(.medium))
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Theme.track, in: Capsule())
                            }
                        }
                    }
                    Text("To delete simulators, use Xcode → Window → Devices and Simulators, or run `xcrun simctl delete unavailable` in Terminal.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.track.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// "iOS-26-1" → "iOS 26.1"
    static func runtimeName(_ identifier: String) -> String {
        let parts = identifier.split(separator: "-")
        guard parts.count > 1 else { return identifier }
        return parts[0] + " " + parts.dropFirst().joined(separator: ".")
    }
}

// MARK: - Identity

extension DeveloperItem.Group {
    /// Identity color, fixed per group (never by rank).
    var tint: Color {
        switch self {
        case .xcode: Theme.series[0]
        case .simulators: Theme.series[6]
        case .packageManagers: Theme.series[3]
        case .containers: Theme.series[2]
        case .mlModels: Theme.series[1]
        case .projects: Theme.series[5]
        }
    }

    var symbol: String {
        switch self {
        case .xcode: "hammer.fill"
        case .simulators: "iphone"
        case .packageManagers: "shippingbox.fill"
        case .containers: "cube.fill"
        case .mlModels: "brain"
        case .projects: "folder.fill"
        }
    }
}

extension DeveloperItem {
    var symbol: String {
        switch id {
        case "xcode.archives": "archivebox.fill"
        case "xcode.devicesupport.ios": "iphone.gen3"
        case "xcode.devicesupport.watchos": "applewatch"
        case "xcode.previews": "eye.fill"
        case "sim.caches": "internaldrive.fill"
        default: group.symbol
        }
    }
}
