import AppKit
import PureMacKit
import SwiftUI

/// Settings: a sidebar of panes (searchable), each a header and grouped cards that show the
/// current state next to the controls that change it.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("settingsPane") private var selection: SettingsPane = .general
    @State private var query = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PaneHeader(pane: selection)
                    switch selection {
                    case .general: GeneralPane()
                    case .appearance: AppearancePane()
                    case .scanning: ScanningPane()
                    case .exclusions: ExclusionsPane()
                    case .privacy: PrivacyPane()
                    case .safety: SafetyPane()
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(selection)   // each pane starts at its top
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 820, height: 600)
        .navigationTitle(selection.title)
        .task { await app.refreshExclusionCount() }
    }

    private var matches: [SettingsPane] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return SettingsPane.allCases }
        return SettingsPane.allCases.filter { $0.matches(q) }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            SearchField(text: $query, prompt: "Search settings").padding(10)
                .onChange(of: query) { _, _ in if let first = matches.first, !matches.contains(selection) { selection = first } }
            List(matches, selection: Binding(get: { selection }, set: { if let pane = $0 { selection = pane } })) { pane in
                HStack(spacing: 9) {
                    SettingsIcon(symbol: pane.symbol, tint: pane.tint, size: 22)
                    Text(pane.title).lineLimit(1)
                    Spacer(minLength: 0)
                    if pane == .exclusions, app.exclusionCount > 0 {
                        Text(app.exclusionCount, format: .number).font(.caption2.weight(.semibold)).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Theme.track, in: Capsule())
                    }
                }
                .tag(pane)
            }
            .listStyle(.sidebar)
            .overlay { if matches.isEmpty { ContentUnavailableView.search(text: query) } }
            Divider()
            HStack(spacing: 8) {
                Image(nsImage: Brand.appIcon).resizable().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text("PureMac").font(.caption.weight(.semibold))
                    Text("Version \(Brand.version)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
        }
        .background(.regularMaterial)
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, scanning, exclusions, privacy, safety
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .appearance: String(localized: "Appearance")
        case .scanning: String(localized: "settings.pane.scanning", defaultValue: "Scanning", comment: "Settings pane name (a noun), not “scan in progress”")
        case .exclusions: String(localized: "Exclusions")
        case .privacy: String(localized: "Privacy & Data")
        case .safety: String(localized: "Safety")
        }
    }

    var subtitle: String {
        switch self {
        case .general: String(localized: "Language and how sizes are written.")
        case .appearance: String(localized: "Light or dark, and how much moves on screen.")
        case .scanning: String(localized: "What PureMac measures, and how detailed the index is.")
        case .exclusions: String(localized: "Places PureMac skips when scanning or never proposes for cleanup.")
        case .privacy: String(localized: "What PureMac keeps on this Mac, and the permissions it uses.")
        case .safety: String(localized: "How PureMac removes things, and what it never touches.")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintpalette.fill"
        case .scanning: "dot.radiowaves.left.and.right"
        case .exclusions: "eye.slash.fill"
        case .privacy: "hand.raised.fill"
        case .safety: "checkmark.shield.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: Theme.neutralA
        case .appearance: .indigo
        case .scanning: SidebarItem.overview.hue
        case .exclusions: .orange
        case .privacy: Theme.brandBlue
        case .safety: Theme.good
        }
    }

    /// Words that find the pane in the sidebar search (besides its title).
    private var keywords: [String] {
        switch self {
        case .general: [String(localized: "Language"), String(localized: "File sizes"), "KB MB GB KiB"]
        case .appearance: [String(localized: "Dark"), String(localized: "Light"), String(localized: "Reduce animations")]
        case .scanning: [String(localized: "Locations"), String(localized: "Folders"), String(localized: "External volumes (opt-in)"), String(localized: "Index detail")]
        case .exclusions: [String(localized: "Exclude"), String(localized: "Folders")]
        case .privacy: [String(localized: "Database"), String(localized: "History"), String(localized: "Full Disk Access…"), String(localized: "Permissions")]
        case .safety: [String(localized: "Trash"), String(localized: "Protected")]
        }
    }

    func matches(_ query: String) -> Bool {
        ([title, subtitle] + keywords).contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

// MARK: - Building blocks

/// A rounded tile with a white symbol, like the icons in System Settings.
private struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.9), tint], startPoint: .top, endPoint: .bottom))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.52, weight: .semibold)).foregroundStyle(.white))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct PaneHeader: View {
    let pane: SettingsPane
    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(symbol: pane.symbol, tint: pane.tint, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(pane.title).font(.title2.weight(.bold))
                Text(pane.subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 2)
    }
}

/// A titled card of rows separated by hairlines.
private struct SettingsGroup<Content: View>: View {
    var title: LocalizedStringKey?
    var footer: LocalizedStringKey?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Text(title).font(.callout.weight(.semibold)).padding(.leading, 4) }
            // Each row draws a hairline above itself; the card clips the first one away.
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.top, -1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke))
            if let footer { Text(footer).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// A row: title (and explanation) on the left, its control on the right.
private struct SettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?
    var symbol: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let symbol { Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            control
        }
        .settingsRow()
    }
}

extension View {
    /// Padding and the hairline above a row inside a `SettingsGroup`.
    fileprivate func settingsRow() -> some View {
        padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Theme.cardStroke).frame(height: 1).padding(.leading, 14) }
    }
}

/// A large selectable card (scan scope, appearance).
private struct ChoiceCard<Preview: View>: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?
    let isOn: Bool
    let action: () -> Void
    @ViewBuilder var preview: Preview
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                preview.frame(maxWidth: .infinity)
                HStack(spacing: 6) {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle").foregroundStyle(isOn ? Color.accentColor : .secondary)
                    Text(title).fontWeight(.medium)
                }
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isOn ? Color.accentColor.opacity(0.10) : Color.primary.opacity(hovering ? 0.05 : 0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isOn ? Color.accentColor : Theme.cardStroke, lineWidth: isOn ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Environment(AppModel.self) private var app
    @State private var language: String? = AppLanguage.selected

    var body: some View {
        @Bindable var settings = app.settings
        SettingsGroup(title: "Language") {
            SettingsRow(title: "Language", symbol: "globe") {
                Picker("Language", selection: $language) {
                    Text("Same as macOS (\(AppLanguage.nativeName(AppLanguage.current)))").tag(String?.none)
                    Divider()
                    ForEach(AppLanguage.available, id: \.self) { code in
                        Text(AppLanguage.nativeName(code)).tag(Optional(code))
                    }
                }
                .labelsHidden().fixedSize()
                .onChange(of: language) { _, code in AppLanguage.select(code) }
            }
            if language != AppLanguage.selectedAtLaunch {
                SettingsRow(title: "PureMac switches language when it restarts.", symbol: "arrow.clockwise") {
                    Button("Restart Now") { AppLanguage.relaunch() }
                        .buttonStyle(.borderedProminent)
                        .disabled(app.cleanup.isRunning || app.scan.isBusy)
                        .help(app.cleanup.isRunning || app.scan.isBusy ? "Wait for the scan or cleanup to finish." : "Quit and reopen PureMac.")
                }
            }
        }
        SettingsGroup(title: "File sizes", footer: "Decimal units match Finder and the storage sizes Apple advertises.") {
            ForEach(ByteStyle.allCases) { style in
                Button { settings.byteStyle = style } label: {
                    HStack(spacing: 12) {
                        Image(systemName: settings.byteStyle == style ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(settings.byteStyle == style ? Color.accentColor : .secondary).frame(width: 18)
                        Text(style.label)
                        Spacer(minLength: 12)
                        Text(ByteFormat.string(1_500_000_000, style: style)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .settingsRow()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(settings.byteStyle == style ? .isSelected : [])
            }
        }
        SettingsGroup {
            SettingsRow(title: "PureMac has no notifications, login items or background activity. It only works while you use it.", symbol: "moon.zzz") { EmptyView() }
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        SettingsGroup(title: "Appearance") {
            HStack(spacing: 12) {
                ForEach(AppearancePreference.allCases) { choice in
                    ChoiceCard(title: choice.label, isOn: settings.appearance == choice, action: { settings.appearance = choice }) {
                        WindowThumbnail(scheme: choice.colorScheme)
                    }
                }
            }
            .settingsRow()
        }
        SettingsGroup(title: "Motion") {
            SettingsRow(title: "Reduce animations",
                        detail: "Stops the drifting backdrop and scanner motion. PureMac also follows Reduce Motion in System Settings → Accessibility.",
                        symbol: "figure.walk.motion") {
                Toggle("Reduce animations", isOn: $settings.reduceAnimations).labelsHidden().toggleStyle(.switch)
            }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                SettingsRow(title: "Reduce Motion is on in System Settings, so animations are already reduced.", symbol: "checkmark.circle") { EmptyView() }
            }
        }
    }
}

/// A tiny window in the given color scheme (or half and half for "Match System").
private struct WindowThumbnail: View {
    let scheme: ColorScheme?

    var body: some View {
        ZStack {
            if let scheme {
                window(scheme)
            } else {
                window(.light).mask(alignment: .leading) { Rectangle().frame(width: 60) }
                window(.dark).mask(alignment: .trailing) { Rectangle().frame(width: 60) }
            }
        }
        .frame(width: 120, height: 74)
    }

    private func window(_ scheme: ColorScheme) -> some View {
        let dark = scheme == .dark
        return RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(dark ? Color(white: 0.16) : Color(white: 0.97))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 0) {
                    Rectangle().fill(dark ? Color(white: 0.22) : Color(white: 0.90)).frame(width: 34)
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule().fill(Theme.brandBlue).frame(width: 40, height: 6)
                        Capsule().fill(dark ? Color(white: 0.35) : Color(white: 0.8)).frame(width: 60, height: 5)
                        Capsule().fill(dark ? Color(white: 0.35) : Color(white: 0.8)).frame(width: 48, height: 5)
                        RoundedRectangle(cornerRadius: 3).fill(Theme.brandTeal.opacity(0.8)).frame(width: 62, height: 18)
                    }
                    .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.black.opacity(0.15)))
    }
}

// MARK: - Scanning

private struct ScanningPane: View {
    @Environment(AppModel.self) private var app
    @State private var volumes: [VolumeInfo] = []

    var body: some View {
        @Bindable var settings = app.settings
        SettingsGroup {
            SettingsRow(title: lastScanTitle, symbol: "clock.arrow.circlepath") {
                Button("Scan Now") { app.scan.start() }.disabled(app.scan.isBusy || app.store == nil)
            }
        }
        SettingsGroup(title: "What PureMac scans",
                      footer: settings.scanEntireDataVolume ? "Scanning the whole Data volume includes Applications, shared and system-managed data. Most of it needs Full Disk Access to be measured; unreadable areas are reported as gaps." : nil) {
            if !app.access.isRequired {
                HStack(spacing: 12) {
                    ChoiceCard(title: "My home folder", detail: "Your home folder by default. It reads names, sizes and dates — never the contents of your files.",
                               isOn: !settings.scanEntireDataVolume, action: { settings.scanEntireDataVolume = false }) {
                        Image(systemName: "house.fill").font(.system(size: 28)).foregroundStyle(Theme.brandBlue).frame(height: 40)
                    }
                    ChoiceCard(title: "Entire startup disk (Data volume)", detail: "Applications, shared and system-managed data too.",
                               isOn: settings.scanEntireDataVolume, action: { settings.scanEntireDataVolume = true }) {
                        Image(systemName: "internaldrive.fill").font(.system(size: 28)).foregroundStyle(Theme.brandTeal).frame(height: 40)
                    }
                }
                .settingsRow()
            } else {
                SettingsRow(title: "My home folder and the folders below", symbol: "house") { EmptyView() }
            }
        }
        SettingsGroup(title: "Also scan these folders") {
            ForEach(settings.extraScanFolders, id: \.self) { folder in
                SettingsRow(title: LocalizedStringKey(abbreviate(folder).markdownEscaped), symbol: "folder.fill") {
                    Button { settings.extraScanFolders.removeAll { $0 == folder } } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Remove").accessibilityLabel("Remove \(abbreviate(folder))")
                }
            }
            SettingsRow(title: settings.extraScanFolders.isEmpty ? "No other folders yet." : "Add another folder.", symbol: "plus.circle") {
                Button("Add Folder…") { addFolder() }
            }
        }
        SettingsGroup(title: "External volumes (opt-in)") {
            let external = volumes.filter { !$0.isRootFileSystem && !$0.url.path.hasPrefix("/System") }
            if external.isEmpty {
                SettingsRow(title: "No other volumes are mounted.", symbol: "externaldrive") { EmptyView() }
            }
            ForEach(external) { volume in
                SettingsRow(title: LocalizedStringKey(volume.name.markdownEscaped),
                            detail: volume.isLocal ? LocalizedStringKey(volume.fileSystemType ?? "") : "Network volume — scanning can be slow",
                            symbol: volume.isLocal ? "externaldrive.fill" : "server.rack") {
                    Toggle(volume.name, isOn: Binding(
                        get: { settings.externalVolumePaths.contains(volume.url.path) },
                        set: { on in
                            if on { settings.externalVolumePaths.append(volume.url.path) } else { settings.externalVolumePaths.removeAll { $0 == volume.url.path } }
                        }))
                    .labelsHidden().toggleStyle(.switch)
                }
            }
        }
        SettingsGroup(title: "Index detail", footer: "Smaller files are still counted in every total; they are summarized per folder to keep the index small and fast.") {
            SettingsRow(title: "List files individually from", symbol: "list.bullet.indent") {
                Picker("List files individually from", selection: $settings.smallFileThresholdKB) {
                    Text("64 KB").tag(64)
                    Text("256 KB (recommended)").tag(256)
                    Text("1 MB").tag(1024)
                }
                .labelsHidden().fixedSize()
            }
        }
        .onAppear { volumes = VolumeInspector.mountedVolumes() }
    }

    private var lastScanTitle: LocalizedStringKey {
        guard let session = app.scan.latestSession else { return "No scans yet" }
        let when = (session.finishedAt ?? session.startedAt).formatted(.relative(presentation: .named))
        return "Last scan \(when) · \(session.fileCount.formatted()) files indexed"
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.access.remember(url)
        let path = url.standardizedFileURL.path
        if !app.settings.extraScanFolders.contains(path) { app.settings.extraScanFolders.append(path) }
    }
}

// MARK: - Exclusions

private struct ExclusionsPane: View {
    @Environment(AppModel.self) private var app
    @State private var exclusions: [Exclusion] = []

    var body: some View {
        SettingsGroup(footer: "Excluded from scans are not traversed. Excluded from cleanup are never proposed or moved, even if a rule matches.") {
            if exclusions.isEmpty {
                SettingsRow(title: "Nothing is excluded.", detail: "Add a folder PureMac should skip, or right-click an item on any page and choose “Exclude”.", symbol: "checkmark.circle") { EmptyView() }
            }
            ForEach(exclusions) { item in
                HStack(spacing: 12) {
                    FileIcon(path: item.path)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(abbreviate(item.path)).lineLimit(1).truncationMode(.middle).help(item.path)
                        Text(item.scope == .scan ? "Excluded from scans" : "Never proposed for cleanup").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(item.scope == .scan ? "Scans" : "Cleanup").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .foregroundStyle(item.scope == .scan ? Theme.brandBlue : .orange)
                        .background((item.scope == .scan ? Theme.brandBlue : Color.orange).opacity(0.14), in: Capsule())
                    Button { remove(item) } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Remove").accessibilityLabel("Remove \(abbreviate(item.path))")
                }
                .settingsRow()
                .contextMenu {
                    Button("Reveal in Finder") { SystemActions.revealInFinder([item.path]) }
                    Button("Remove") { remove(item) }
                }
            }
        }
        HStack {
            Menu {
                Button("Exclude Folder from Scans…") { add(.scan) }
                Button("Exclude Item from Cleanup…") { add(.cleanup) }
            } label: { Label("Add…", systemImage: "plus") }
            .fixedSize()
            Spacer()
        }
        .task { await reload() }
    }

    private func reload() async {
        exclusions = (try? await app.store?.exclusions()) ?? []
        app.exclusionCount = exclusions.count
    }

    private func remove(_ item: Exclusion) {
        Task {
            try? await app.store?.removeExclusion(id: item.id)
            await reload()
        }
    }

    private func add(_ scope: ExclusionScope) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = scope == .cleanup
        panel.prompt = String(localized: "Exclude")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            _ = try? await app.store?.addExclusion(path: url.standardizedFileURL.path, scope: scope)
            await reload()
        }
    }
}

// MARK: - Privacy & Data

private struct PrivacyPane: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    @State private var databaseSize: Int64 = 0
    @State private var confirmScanClear = false
    @State private var confirmHistoryClear = false
    @State private var fullDiskAccess = FullDiskAccess.Status.unknown

    var body: some View {
        @Bindable var settings = app.settings
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "Stored on this Mac", footer: "Contains scan indexes (names, paths, sizes, dates), your exclusions and cleanup history. Nothing is ever transmitted.") {
                SettingsRow(title: "Database", detail: LocalizedStringKey(abbreviate(app.databaseURL.path).markdownEscaped), symbol: "cylinder.split.1x2") {
                    HStack(spacing: 10) {
                        Text(ByteFormat.string(databaseSize, style: byteStyle)).monospacedDigit().foregroundStyle(.secondary)
                        Button("Reveal") { SystemActions.revealInFinder([app.databaseURL.path]) }
                    }
                }
                SettingsRow(title: "Scan history", detail: "Removes every stored scan index, coverage report and trend. Your files are not affected.", symbol: "chart.bar.doc.horizontal") {
                    Button("Delete…", role: .destructive) { confirmScanClear = true }
                }
                SettingsRow(title: "Cleanup history", detail: "Items already in the Trash stay there, but PureMac will no longer be able to put them back for you.", symbol: "clock.arrow.circlepath") {
                    Button("Delete…", role: .destructive) { confirmHistoryClear = true }
                }
            }
            SettingsGroup(title: "Cleanup history") {
                SettingsRow(title: "Keep detailed history (file paths)",
                            detail: "Detailed history lets you put items back from the Trash later. When off, only dates, counts and sizes are recorded.",
                            symbol: "list.bullet.rectangle") {
                    Toggle("Keep detailed history (file paths)", isOn: $settings.keepDetailedHistory).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsGroup(title: "Permissions", footer: "PureMac works with your normal user permissions. Full Disk Access is optional: it lets scans measure protected locations such as Mail, Messages and other apps’ data. PureMac cannot grant it to itself.") {
                SettingsRow(title: "Full Disk Access", symbol: "lock.shield") {
                    HStack(spacing: 10) {
                        switch fullDiskAccess {
                        case .granted: StatusChip(level: .good, text: String(localized: "Allowed"))
                        case .denied: StatusChip(level: .neutral, text: String(localized: "Not allowed"))
                        case .unknown: EmptyView()
                        }
                        Button("Open Full Disk Access Settings…") { SystemActions.openFullDiskAccessSettings() }
                    }
                }
            }
            if app.access.isRequired {
                SettingsGroup(title: "Folder access", footer: "macOS lets PureMac see only the folders you choose. Revoking a folder hides it from PureMac until you choose it again.") {
                    ForEach(app.access.granted, id: \.self) { path in
                        SettingsRow(title: LocalizedStringKey(abbreviate(path).markdownEscaped), symbol: "folder.fill") {
                            Button("Revoke") { app.access.revoke(path) }
                        }
                    }
                    SettingsRow(title: "Add Folder…", symbol: "plus.circle") {
                        HStack {
                            if !app.access.hasAccess(to: "/Applications") {
                                Button("Allow Applications Folder…") {
                                    app.access.request("/Applications", message: String(localized: "Choose “Applications” so PureMac can move apps you uninstall to the Trash."))
                                }
                            }
                            Button("Add…") {
                                let panel = NSOpenPanel()
                                panel.canChooseDirectories = true
                                panel.canChooseFiles = false
                                panel.prompt = String(localized: "Allow Access")
                                if panel.runModal() == .OK, let url = panel.url { app.access.remember(url) }
                            }
                        }
                    }
                }
            }
        }
            .task {
                databaseSize = await app.store?.databaseSize() ?? 0
                fullDiskAccess = await Task.detached { FullDiskAccess.status() }.value
            }
            .confirmationDialog("Delete all scan history?", isPresented: $confirmScanClear) {
                Button("Delete Scan History", role: .destructive) {
                    Task {
                        try? await app.store?.clearScanHistory()
                        await app.scan.reload()
                        await app.explorer.sessionDidChange()
                        databaseSize = await app.store?.databaseSize() ?? 0
                    }
                }
            } message: {
                Text("Removes every stored scan index, coverage report and trend. Your files are not affected.")
            }
            .confirmationDialog("Delete cleanup history?", isPresented: $confirmHistoryClear) {
                Button("Delete Cleanup History", role: .destructive) {
                    Task {
                        try? await app.store?.clearCleanupHistory()
                        await app.history.reload()
                        databaseSize = await app.store?.databaseSize() ?? 0
                    }
                }
            } message: {
                Text("Items already in the Trash stay there, but PureMac will no longer be able to put them back for you.")
            }
    }
}

/// Whether PureMac has Full Disk Access, judged by reading a folder only that permission opens
/// (no prompt is shown; macOS just refuses). Unknown in the App Sandbox or when none exists.
enum FullDiskAccess {
    enum Status { case granted, denied, unknown }

    nonisolated static func status() -> Status {
        guard !PathTools.isSandboxed else { return .unknown }
        let library = PathTools.userHome + "/Library/"
        for folder in ["Safari", "Mail", "Messages", "Containers/com.apple.Safari"] {
            let path = library + folder
            guard case .success = FileStat.lstat(path) else { continue }
            return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil ? .granted : .denied
        }
        return .unknown
    }
}

// MARK: - Safety

private struct SafetyPane: View {
    var body: some View {
        SettingsGroup(title: "How PureMac removes things") {
            SettingsRow(title: "Every cleanup shows a full preview first. Items go to the Trash, so you can put them back until you empty it.", symbol: "eye") { EmptyView() }
            SettingsRow(title: "PureMac never empties the Trash for you.", symbol: "trash") { EmptyView() }
            SettingsRow(title: "Each item is checked again right before it moves. Anything that changed is skipped.", symbol: "checkmark.shield") { EmptyView() }
            SettingsRow(title: "Nothing is deleted automatically", detail: "There is deliberately no “always clean automatically” option.", symbol: "hand.raised") { EmptyView() }
        }
        SettingsGroup(title: "Always protected") {
            SettingsRow(title: "macOS system locations, other users’ files, keychains, Mail, Messages, Photos libraries, iCloud Drive, Apple app data, PureMac’s own database, and the inside of app bundles.",
                        symbol: "lock.fill") { EmptyView() }
            SettingsRow(title: "Personal folders (Documents, Desktop, Pictures, Movies, Music) are never cleaned automatically. You can still move individual files there to the Trash yourself from Storage Explorer.",
                        symbol: "person.crop.square") { EmptyView() }
        }
    }
}
