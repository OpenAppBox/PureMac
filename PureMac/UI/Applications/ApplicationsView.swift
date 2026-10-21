import AppKit
import PureMacKit
import SwiftUI

struct ApplicationsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    @State private var uninstallRequest: UninstallRequest?
    @State private var preparingUninstall = false

    var body: some View {
        @Bindable var apps = app.apps
        let visible = apps.visibleApps
        let largest = visible.compactMap { apps.totalSize(of: $0) }.max() ?? 1
        ScreenScaffold(item: .applications, scrolls: false) {
            ModuleHeader(item: .applications, subtitle: LocalizedStringKey(subtitle)) {
                HStack(spacing: 10) {
                    Toggle("Show macOS apps", isOn: $apps.showSystemApps).toggleStyle(.switch).controlSize(.small)
                    Button { Task { await apps.load(force: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .buttonStyle(.glow(SidebarItem.applications.hue, prominent: false))
                        .disabled(apps.isLoading)
                }
            }
            .entrance()
            HStack(alignment: .top, spacing: 16) {
                GlassCard(padding: 0) {
                  VStack(spacing: 0) {
                    SearchField(text: $apps.searchText, prompt: "Search apps").padding([.horizontal, .top], 10)
                    listHeader(visible: visible)
                    List(visible, selection: $apps.selectedAppID) { installed in
                        AppListRow(app: installed, isRunning: apps.isRunning(installed), largest: largest,
                                   bundle: apps.bundleSizes[installed.path], data: apps.dataSize(of: installed),
                                   lastUsed: apps.lastUsed[installed.path],
                                   isChecked: apps.uninstallSelection.contains(installed.id),
                                   setChecked: { on in
                                       if on { app.apps.uninstallSelection.insert(installed.id) } else { app.apps.uninstallSelection.remove(installed.id) }
                                   })
                            .tag(installed.id)
                    }
                    .scrollContentBackground(.hidden)
                    .overlay {
                        if apps.isLoading && apps.apps.isEmpty {
                            ProgressView("Finding applications…")
                        } else if !apps.isLoading && visible.isEmpty {
                            if apps.searchText.isEmpty {
                                ContentUnavailableView("No matching apps", systemImage: "line.3.horizontal.decrease.circle",
                                                       description: Text(apps.filter == .unused ? "Spotlight has no app that went unused for 3 months." : "Try another filter."))
                            } else {
                                ContentUnavailableView.search(text: apps.searchText)
                            }
                        }
                    }
                  }
                }
                .frame(width: 360)
                .frame(maxHeight: .infinity)

                Group {
                    if let selected = apps.selectedApp {
                        AppDetailView(installed: selected) { uninstall([selected]) }.id(selected.id)
                            .transition(.opacity.combined(with: .offset(x: 12)))
                    } else {
                        placeholder
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeOut(duration: 0.2), value: apps.selectedAppID)
            }
        }
        .selectionBar(isPresented: !apps.uninstallSelection.isEmpty) {
            let chosen = apps.uninstallSelectionApps
            SelectionActionBar(count: chosen.count, subject: .apps,
                               bytes: chosen.reduce(Int64(0)) { $0 + (apps.totalSize(of: $1) ?? 0) },
                               tint: SidebarItem.applications.hue,
                               actionTitle: preparingUninstall ? "Preparing…" : "Uninstall…", actionSymbol: "trash",
                               isDisabled: preparingUninstall || app.cleanup.isRunning,
                               onClear: { apps.uninstallSelection = [] }) { uninstall(chosen) }
        }
        .navigationTitle("Applications")
        .task { await apps.load() }
        .sheet(item: $uninstallRequest) { request in
            UninstallSheet(targets: request.targets).environment(app).environment(\.byteStyle, byteStyle)
        }
    }

    private func listHeader(visible: [InstalledApp]) -> some View {
        @Bindable var apps = app.apps
        let removable = visible.filter { !$0.isProtected }
        let allChecked = !removable.isEmpty && removable.allSatisfy { apps.uninstallSelection.contains($0.id) }
        let total = visible.compactMap { apps.totalSize(of: $0) }.reduce(0, +)
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { allChecked }, set: { on in
                if on { apps.uninstallSelection.formUnion(removable.map(\.id)) } else { apps.uninstallSelection.subtract(removable.map(\.id)) }
            })) { EmptyView() }
                .toggleStyle(.checkbox)
                .disabled(removable.isEmpty)
                .help("Check every app in this list for uninstalling")
                .accessibilityLabel("Select all listed apps")
            VStack(alignment: .leading, spacing: 0) {
                Text("\(visible.count) apps").font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
                HStack(spacing: 4) {
                    Text(ByteFormat.string(total, style: byteStyle)).monospacedDigit()
                    if apps.isMeasuring { ProgressView().controlSize(.mini).help("Measuring apps and their data…") }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            ListMenuPicker(title: "Show", symbol: "line.3.horizontal.decrease.circle", value: $apps.filter,
                           options: AppsModel.Filter.allCases) { $0.title }
            ListMenuPicker(title: "Sort by", symbol: "arrow.up.arrow.down", value: $apps.sortOrder,
                           options: AppsModel.SortOrder.allCases) { $0.title }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var placeholder: some View {
        GlassCard(padding: 40) {
            VStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 48)).foregroundStyle(SidebarItem.applications.hue)
                Text("Pick apps to remove").font(.title3.weight(.semibold))
                Text("Check the apps you no longer need and choose Uninstall. Sizes include each app’s caches, settings and support files. Click an app’s name to see every file and the evidence connecting it.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    Button("Show Largest") { app.apps.filter = .all; app.apps.sortOrder = .size }
                        .buttonStyle(.glow(SidebarItem.applications.hue, prominent: false))
                    Button("Show Unused") { app.apps.filter = .unused; app.apps.sortOrder = .size }
                        .buttonStyle(.glow(SidebarItem.applications.hue, prominent: false))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Loads any missing associations, then opens one review for all chosen apps.
    private func uninstall(_ chosen: [InstalledApp]) {
        let removable = chosen.filter { !$0.isProtected }
        guard !removable.isEmpty, !preparingUninstall else { return }
        // In the App Sandbox, moving an app needs a grant for the folder that holds it.
        for folder in Set(removable.map { ($0.path as NSString).deletingLastPathComponent }) where !app.access.hasAccess(to: folder) {
            let name = FileManager.default.displayName(atPath: folder)
            guard app.access.request(folder, message: String(localized: "To move apps to the Trash, PureMac needs access to “\(name)”. Choose it and click Allow Access.")) else { return }
        }
        preparingUninstall = true
        Task {
            for installed in removable where app.apps.associations[installed.path] == nil {
                await app.apps.loadAssociations(for: installed)
            }
            let targets = removable.compactMap { installed in
                app.apps.associations[installed.path].map { UninstallTarget(app: installed, associations: $0) }
            }
            preparingUninstall = false
            if !targets.isEmpty { uninstallRequest = UninstallRequest(targets: targets) }
        }
    }

    private var subtitle: String {
        let apps = app.apps
        if apps.isLoading && apps.apps.isEmpty { return String(localized: "Finding installed applications…") }
        let removable = apps.apps.filter { !$0.isProtected }
        let total = removable.compactMap { apps.totalSize(of: $0) }.reduce(0, +)
        let running = apps.apps.filter { apps.isRunning($0) }.count
        return String(localized: "\(removable.count) removable apps using \(ByteFormat.string(total, style: byteStyle)) · \(running) running · evidence-based uninstall")
    }
}

struct UninstallRequest: Identifiable {
    let id = UUID()
    let targets: [UninstallTarget]
}

/// One app in the list. Takes plain values (not the model) so a background size update only
/// re-renders the rows whose numbers changed.
private struct AppListRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.byteStyle) private var byteStyle
    let app: InstalledApp
    let isRunning: Bool
    let largest: Int64
    let bundle: Int64?
    let data: Int64?
    let lastUsed: Date?
    let isChecked: Bool
    let setChecked: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        let total = bundle.map { $0 + (data ?? 0) }
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { isChecked }, set: setChecked)) { EmptyView() }
                .toggleStyle(.checkbox)
                .disabled(app.isProtected)
                .opacity(app.isProtected ? 0.3 : 1)
                .accessibilityLabel("Uninstall \(app.name)")
            FileIcon(path: app.path, size: 32)
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(app.name).lineLimit(1).fontWeight(.medium)
                    if isRunning {
                        Circle().fill(Theme.good).frame(width: 6, height: 6)
                            .help("Running").accessibilityLabel("Running")
                    }
                    if app.isProtected {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary).help(app.protectionReason ?? "Protected")
                            .accessibilityLabel("Protected")
                    }
                }
                usageLine
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                if let total {
                    Text(ByteFormat.string(total, style: byteStyle)).font(.callout.weight(.semibold)).monospacedDigit()
                    Capsule().fill(Theme.track)
                        .overlay(alignment: .leading) {
                            Capsule().fill(SidebarItem.applications.hue)
                                .scaleEffect(x: max(0.03, CGFloat(Double(total) / Double(max(largest, 1)))), y: 1, anchor: .leading)
                        }
                        .frame(width: 56, height: 3)
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.track).frame(width: 52, height: 12).shimmer()
                        .accessibilityLabel("Measuring")
                }
            }
            .help(sizeHelp)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Reveal in Finder") { SystemActions.revealInFinder([app.path]) }
            if isRunning { Button("Show \(app.name)") { model.apps.bringToFront([app]) } }
        }
    }

    @ViewBuilder private var usageLine: some View {
        if let lastUsed {
            let stale = lastUsed < Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? .distantPast
            Text("Opened \(lastUsed.formatted(.relative(presentation: .named)))")
                .font(.caption).foregroundStyle(stale ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.secondary)).lineLimit(1)
        } else {
            Text(app.version.map { String(localized: "Version \($0)") } ?? (app.bundleIdentifier ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var sizeHelp: String {
        guard let bundle else { return String(localized: "Measuring…") }
        let app = String(localized: "App \(ByteFormat.string(bundle, style: byteStyle))")
        guard let data else { return app + " · measuring its data…" }
        return app + " + data \(ByteFormat.string(data, style: byteStyle)) (caches, settings, support files)"
    }
}

struct AppDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    let installed: InstalledApp
    let onUninstall: () -> Void
    @State private var hoveredKind: RingSegment.ID?
    @State private var tint: Color = SidebarItem.applications.hue

    var body: some View {
        let associations = app.apps.associations[installed.path]
        let loading = app.apps.loadingAssociations.contains(installed.path)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero(associations: associations)
                if app.apps.isRunning(installed) {
                    NoticeView(tone: .info, title: "\(installed.name) is running", message: "Quit it before removing it or its data.")
                }
                if let reason = installed.protectionReason {
                    NoticeView(tone: .info, title: "Protected", message: LocalizedStringKey(reason + " " + String(localized: "PureMac shows its data for information only.")))
                }
                if loading && associations == nil {
                    GlassCard { HStack { ProgressView().controlSize(.small); Text("Looking for associated files…").foregroundStyle(.secondary) } }
                } else if let associations {
                    associationGroups(associations)
                }
            }
            .padding(.bottom, 20)
        }
        .scrollContentBackground(.hidden)
        .task(id: installed.id) {
            if let sampled = await IconTintStore.shared.tint(forPath: installed.path) {
                withAnimation(.easeOut(duration: 0.25)) { tint = sampled }
            }
            await app.apps.loadAssociations(for: installed)
        }
    }

    private func hero(associations: [AppAssociation]?) -> some View {
        let bundle = associations?.first(where: { $0.kind == .appBundle })?.allocatedSize ?? 0
        let data = associations?.associatedDataBytes ?? 0
        let total = bundle + data
        return GlassCard(padding: 22, tint: tint) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 18) {
                    FileIcon(path: installed.path, size: 84)
                        .shadow(color: tint.opacity(0.55), radius: 18, y: 6)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(installed.name).font(.system(size: 26, weight: .bold, design: .rounded))
                        Text([installed.version.map { String(localized: "Version \($0)") }, installed.build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            pill(installed.signingKind.displayName, symbol: "checkmark.seal.fill", color: installed.signingKind == .unsigned || installed.signingKind == .adHoc ? Theme.warning : tint)
                            if installed.source != .unknown, installed.source.displayName != installed.signingKind.displayName {
                                pill(installed.source.displayName, symbol: "shippingbox.fill", color: tint)
                            }
                            if app.apps.isRunning(installed) { pill("Running", symbol: "circle.fill", color: Theme.good) }
                            if let receipts = app.apps.packageReceipts[installed.path], !receipts.isEmpty { pill("Package receipt", symbol: "doc.text.fill", color: tint) }
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        if associations != nil {
                            RollingText(text: ByteFormat.string(total, style: byteStyle), font: .hero(30))
                            Text("App \(ByteFormat.string(bundle, style: byteStyle)) · data \(ByteFormat.string(data, style: byteStyle))")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        if let used = app.apps.lastUsed[installed.path] {
                            Text("Last opened \(used.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            if app.apps.isRunning(installed) {
                                Button("Show \(installed.name)") { app.apps.bringToFront([installed]) }
                                    .buttonStyle(.glow(.secondary, prominent: false))
                                    .help("Brings \(installed.name) to the front so you can quit it (⌘Q).")
                            }
                            Button(action: onUninstall) { Label("Uninstall…", systemImage: "trash") }
                                .buttonStyle(.glow(Theme.critical, prominent: false))
                                .disabled(installed.isProtected || associations == nil || app.cleanup.isRunning)
                        }
                    }
                }
                HStack(alignment: .top, spacing: 24) {
                    if let associations, associations.count > 1 { kindRing(associations).frame(width: 150, height: 150) }
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                        info("Bundle ID", installed.bundleIdentifier ?? String(localized: "None"))
                        info("Location", abbreviate(installed.path))
                        info("Signed by", installed.teamIdentifier.map { String(localized: "\(installed.signingKind.displayName) · Team \($0)") } ?? installed.signingKind.displayName)
                        if let receipts = app.apps.packageReceipts[installed.path], !receipts.isEmpty {
                            info("Installer packages", receipts.joined(separator: ", "))
                        }
                        if !installed.helperBundleIdentifiers.isEmpty {
                            info("Embedded helpers", "\(installed.helperBundleIdentifiers.count)")
                        }
                        GridRow {
                            Text("")
                            Button("Reveal in Finder") { SystemActions.revealInFinder([installed.path]) }.buttonStyle(.link)
                        }
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func kindRing(_ associations: [AppAssociation]) -> some View {
        let byKind = Dictionary(grouping: associations, by: \.kind).map { ($0.key, $0.value.reduce(Int64(0)) { $0 + ($1.allocatedSize ?? 0) }) }
            .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        let segments = byKind.enumerated().map { index, item in
            RingSegment(id: item.0.rawValue, value: Double(item.1), color: Theme.series[index % Theme.series.count],
                        label: item.0.displayName, detail: ByteFormat.string(item.1, style: byteStyle))
        }
        return RingChart(segments: segments, total: 0, lineWidth: 16, hovered: $hoveredKind) { hovered in
            VStack(spacing: 1) {
                (hovered.map { Text($0.label) } ?? Text("Where it lives")).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
                if let hovered { Text(hovered.detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func clearable(kind: AssociationKind, _ associations: [AppAssociation]) -> [CleanupCandidate] {
        CleanupPlanner.uninstallCandidates(app: installed, associations: associations, mode: .keepPersonalData)
            .filter { candidate in
                if case .uninstall(_, let k) = candidate.source { return k == kind && candidate.isPreselected }
                return false
            }
    }

    /// Reviews moving one regenerable kind (caches, logs, window state) to the Trash; the app stays.
    private func clearRegenerable(kind: AssociationKind, associations: [AppAssociation]) {
        let chosen = clearable(kind: kind, associations)
        guard !chosen.isEmpty else { return }
        app.cleanup.present(CleanupPlanner.plan(mode: .appData, title: "\(installed.name) — \(kind.displayName)", selected: chosen))
    }

    private func pill(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private func info(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }

    private func associationGroups(_ associations: [AppAssociation]) -> some View {
        let groups = Dictionary(grouping: associations, by: \.kind)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Associated Files").font(.headline)
                Spacer()
                HStack(spacing: 10) {
                    ForEach([AssociationConfidence.confirmed, .likely, .ambiguous, .shared], id: \.self) { ConfidenceBadge(confidence: $0) }
                }
            }
            Text("Each item lists the evidence connecting it to this app. Ambiguous items are never selected for you; shared and system-wide items are never removed with an app.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(AssociationKind.allCases.enumerated()), id: \.element) { index, kind in
                if let items = groups[kind] {
                    GlassCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: kind.symbolName).foregroundStyle(kind.holdsPersonalData ? Theme.warning : Theme.brandBlue)
                                Text(kind.displayName).font(.subheadline.weight(.semibold))
                                if kind.holdsPersonalData { Text("may contain your data").font(.caption).foregroundStyle(Theme.warning) }
                                Spacer()
                                SizeText(items.reduce(0) { $0 + ($1.allocatedSize ?? 0) }).foregroundStyle(.secondary)
                                if kind.isRegenerable, !installed.isProtected {
                                    Button("Clear…") { clearRegenerable(kind: kind, associations: associations) }
                                        .buttonStyle(.glow(SidebarItem.applications.hue, prominent: false))
                                        .controlSize(.small)
                                        .disabled(app.apps.isRunning(installed) || app.cleanup.isRunning || clearable(kind: kind, associations).isEmpty)
                                        .help(app.apps.isRunning(installed) ? "Quit \(installed.name) first." : "Move this app’s \(kind.displayName.lowercased()) to the Trash and keep the app. They are recreated when needed.")
                                }
                            }
                            ForEach(items) { item in AssociationRow(item: item) }
                        }
                    }
                    .entrance(Double(index) * 0.03)
                }
            }
            if associations.count == 1 {
                Text("No associated files were found in your Library beyond the app itself.").foregroundStyle(.secondary)
            }
        }
    }
}

extension AssociationKind {
    /// Kinds an app recreates by itself, safe to clear while keeping the app.
    var isRegenerable: Bool { self == .cache || self == .logs || self == .savedState }

    var symbolName: String {
        switch self {
        case .appBundle: "app.fill"
        case .cache: "shippingbox.fill"
        case .preferences: "slider.horizontal.3"
        case .applicationSupport: "folder.fill"
        case .container: "cube.fill"
        case .groupContainer: "square.on.square.dashed"
        case .logs: "doc.text.fill"
        case .savedState: "macwindow"
        case .httpStorage, .webKitData, .cookies: "globe"
        case .applicationScripts: "applescript.fill"
        case .launchAgent: "power"
        case .systemLevel: "lock.shield.fill"
        case .other: "questionmark.folder.fill"
        }
    }
}

struct AssociationRow: View {
    let item: AppAssociation
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                FileIcon(path: item.path)
                Text(item.name).lineLimit(1).truncationMode(.middle)
                ConfidenceBadge(confidence: item.confidence)
                if item.requiresAdministrator {
                    Text("Administrator").font(.caption2).foregroundStyle(.secondary).help("Removing this needs administrator rights; PureMac does not do that.")
                }
                Spacer()
                if let size = item.allocatedSize { SizeText(size).foregroundStyle(.secondary) }
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(expanded ? "Hide evidence" : "Show evidence")
            }
            if let warning = item.warning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if expanded {
                Text(abbreviate(item.path)).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                ForEach(item.evidence, id: \.self) { evidence in
                    Label(evidence.detail, systemImage: evidence.supportsRemoval ? "checkmark.seal" : "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if item.isPartiallyMeasured { Text("Some contents could not be read; size is a lower bound.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .contextMenu {
            Button("Reveal in Finder") { SystemActions.revealInFinder([item.path]) }
            Button("Copy Path") { SystemActions.copyToPasteboard(item.path) }
        }
    }
}
