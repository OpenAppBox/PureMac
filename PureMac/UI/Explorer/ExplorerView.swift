import PureMacKit
import QuickLook
import SwiftUI

struct ExplorerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    @State private var sortOrder = [KeyPathComparator(\FileRecord.allocatedSize, order: .reverse)]
    @State private var quickLookURL: URL?
    @State private var showTreemap = true

    enum MapStyle: String, CaseIterable, Identifiable {
        case treemap, sunburst
        var id: String { rawValue }
    }
    #if DEBUG
    @State private var mapStyle: MapStyle = UserDefaults.standard.string(forKey: "PureMacExplorerMap") == "sunburst" ? .sunburst : .treemap
    #else
    @State private var mapStyle: MapStyle = .treemap
    #endif
    /// Experts can hide or reorder columns from the header's context menu.
    @State private var columns = TableColumnCustomization<FileRecord>()

    var body: some View {
        @Bindable var explorer = app.explorer
        ScreenScaffold(item: .explorer, scrolls: false) {
            ModuleHeader(item: .explorer, subtitle: LocalizedStringKey((explorer.current.map { abbreviate($0.path) } ?? String(localized: "Browse the latest scan")).markdownEscaped)) {
                HStack(spacing: 10) {
                    Picker("Map", selection: $mapStyle) {
                        Image(systemName: "square.grid.2x2.fill").help("Treemap").tag(MapStyle.treemap)
                        Image(systemName: "circle.circle.fill").help("Sunburst").tag(MapStyle.sunburst)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 96)
                    .disabled(!showTreemap)
                    Toggle(isOn: $showTreemap) { Image(systemName: "rectangle.split.1x2") }
                        .toggleStyle(.button)
                        .help("Show or hide the storage map")
                    ScanButton()
                }
            }
            .entrance()
            if explorer.session == nil {
                emptyState
            } else {
                controlBar
                content
            }
        }
        .selectionBar(isPresented: !explorer.selection.isEmpty) {
            let records = explorer.selectedRecords
            SelectionActionBar(count: records.count,
                               bytes: records.reduce(0) { $0 + $1.allocatedSize }, tint: SidebarItem.explorer.hue,
                               isDisabled: app.cleanup.isRunning,
                               secondary: AnyView(Button("Reveal") { SystemActions.revealInFinder(records.map(\.path)) }.buttonStyle(.borderless)),
                               onClear: { explorer.selection = [] }) { app.reviewUserSelection(records.map(\.path)) }
        }
        .navigationTitle("Storage Explorer")
        // Controls live in the content, not the window toolbar: rebuilding NSToolbar items on every
        // navigation was the single largest cost of switching to this screen.
        .onChange(of: explorer.searchText) { _, _ in explorer.searchChanged() }
        .quickLookPreview($quickLookURL)
    }

    private var controlBar: some View {
        @Bindable var explorer = app.explorer
        return HStack(spacing: 10) {
            Button { Task { await explorer.goUp() } } label: { Image(systemName: "chevron.up") }
                .disabled(explorer.current == nil || explorer.mode != .folders)
                .keyboardShortcut(.upArrow, modifiers: [.command])
                .help("Enclosing folder (⌘↑)")
                .accessibilityLabel("Enclosing folder")
            // Segments at their natural width when they fit, otherwise a menu. (Squeezed into a smaller
            // frame, the segmented control was drawn wider than its slot and covered the up button.)
            ViewThatFits(in: .horizontal) {
                modePicker.pickerStyle(.segmented).fixedSize()
                modePicker.pickerStyle(.menu).fixedSize()
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            SearchField(text: $explorer.searchText, prompt: "Search names in this scan")
                .frame(minWidth: 150, maxWidth: 240)
        }
    }

    private var modePicker: some View {
        @Bindable var explorer = app.explorer
        return Picker("View", selection: $explorer.mode) {
            ForEach(ExplorerModel.Mode.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
    }

    private var emptyState: some View {
        GlassCard(padding: 40, tint: SidebarItem.explorer.hue) {
            VStack(spacing: 14) {
                Image(systemName: app.scan.isBusy ? "dot.radiowaves.left.and.right" : "circle.hexagongrid.fill")
                    .font(.system(size: 52)).foregroundStyle(SidebarItem.explorer.hue)
                    .symbolEffect(.pulse, isActive: app.scan.isBusy)
                Text(app.scan.isBusy ? "Scanning…" : "No scan results yet").font(.title2.weight(.semibold))
                Text(app.scan.isBusy ? "The explorer fills in when the scan finishes." : "Scan your Mac to browse what uses space. Only sizes and dates are read, never file contents.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                if !app.scan.isBusy { ScanButton() }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var content: some View {
        @Bindable var explorer = app.explorer
        return VStack(spacing: 12) {
            if explorer.searchText.isEmpty, let hint = modeHint {
                Label(hint, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if explorer.mode == .folders && explorer.searchText.isEmpty { breadcrumbBar }
            if explorer.mode == .byType && explorer.searchText.isEmpty { typeBar }
            if let error = explorer.errorMessage {
                NoticeView(tone: .error, title: "Something went wrong", message: LocalizedStringKey(error.markdownEscaped))
            }
            VSplitView {
                if showTreemap {
                    GlassCard(padding: 10) {
                        Group {
                            switch mapStyle {
                            case .treemap:
                                TreemapView(records: explorer.rows,
                                            otherBytes: explorer.mode == .folders ? (explorer.current?.smallFileAllocated ?? 0) : 0,
                                            selection: explorer.selection,
                                            onSelect: { explorer.selection = [$0.id] },
                                            onOpen: { record in Task { await explorer.open(record) } })
                            case .sunburst:
                                AnimatedSunburst(nodes: explorer.mapNodes,
                                                 total: Double(explorer.current?.allocatedSize ?? explorer.rows.reduce(0) { $0 + $1.allocatedSize }),
                                                 centerTitle: explorer.current?.name ?? String(localized: "Results"),
                                                 centerValue: ByteFormat.string(explorer.current?.allocatedSize ?? explorer.rows.reduce(0) { $0 + $1.allocatedSize }, style: byteStyle)) { id in
                                    Task { await explorer.open(id: id) }
                                }
                                .padding(6)
                            }
                        }
                        .id("\(mapStyle.rawValue)-\(explorer.current?.id ?? -1)-\(explorer.mode.rawValue)")
                        .transition(.scale(scale: 0.94).combined(with: .opacity))
                    }
                    .animation(.spring(response: 0.45, dampingFraction: 0.86), value: explorer.current?.id)
                    .frame(minHeight: 180, idealHeight: 300)
                    .padding(.bottom, 6)
                }
                GlassCard(padding: 0) {
                    VStack(spacing: 0) {
                        table
                        footer
                    }
                }
                .frame(minHeight: 220)
                .padding(.top, 6)
            }
        }
    }

    /// One plain sentence per view so casual users know what they are looking at.
    private var modeHint: String? {
        let threshold = ByteFormat.string(app.explorer.session?.smallFileThreshold ?? 0, style: byteStyle)
        switch app.explorer.mode {
        case .folders: return nil
        case .largestFiles: return String(localized: "The biggest files anywhere in the scan. Select any you no longer need and press ⌘⌫ to review moving them to the Trash.")
        case .oldFiles: return String(localized: "Files of at least \(threshold) not changed for over a year, largest first — often forgotten downloads, exports and disk images.")
        case .recentFiles: return String(localized: "Files changed in the last 7 days — useful for finding what suddenly used space.")
        case .byType: return String(localized: "Files grouped by extension. Pick a type to see its largest files.")
        }
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                crumb(title: String(localized: "Scan Roots"), symbol: "externaldrive.fill") { Task { await app.explorer.showRoots() } }
                ForEach(app.explorer.breadcrumbs) { record in
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    crumb(title: record.depth == 0 ? abbreviate(record.path) : record.name, symbol: nil,
                          isCurrent: record.id == app.explorer.current?.id) { Task { await app.explorer.open(record) } }
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folder path")
    }

    private func crumb(title: String, symbol: String?, isCurrent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol) }
                Text(title).lineLimit(1)
            }
            .font(.callout.weight(isCurrent ? .semibold : .regular))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(isCurrent ? AnyShapeStyle(SidebarItem.explorer.hue.opacity(0.22)) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
            .overlay(Capsule().strokeBorder(isCurrent ? SidebarItem.explorer.hue.opacity(0.6) : Theme.cardStroke))
        }
        .buttonStyle(.plain)
    }

    private var typeBar: some View {
        @Bindable var explorer = app.explorer
        return HStack {
            Picker("File type", selection: $explorer.selectedExtension) {
                Text("All types").tag(String?.none)
                ForEach(explorer.extensionTotals) { total in
                    Text(".\(total.ext) — \(ByteFormat.string(total.allocated, style: byteStyle)) in \(total.fileCount) files").tag(Optional(total.ext))
                }
            }
            .frame(maxWidth: 420)
            Spacer()
            Text("Covers files of at least \(ByteFormat.string(app.explorer.session?.smallFileThreshold ?? 0, style: byteStyle)).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var table: some View {
        @Bindable var explorer = app.explorer
        let total = max(explorer.current?.allocatedSize ?? explorer.rows.reduce(0) { $0 + $1.allocatedSize }, 1)
        return Table(explorer.rows.sorted(using: sortOrder), selection: $explorer.selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Name", value: \FileRecord.name) { record in
                HStack(spacing: 6) {
                    FileIcon(path: record.path)
                    Text(record.name).lineLimit(1).truncationMode(.middle)
                    if record.flags.contains(.unreadable) {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Could not be read — size unknown")
                    } else if record.flags.contains(.partial) {
                        Image(systemName: "lock.badge.clock").foregroundStyle(.secondary).help("Some contents could not be read; size is a lower bound")
                    }
                    if record.flags.contains(.excluded) {
                        Image(systemName: "eye.slash").foregroundStyle(.secondary).help("Excluded from scans")
                    }
                    if record.flags.contains(.mountBoundary) {
                        Image(systemName: "externaldrive").foregroundStyle(.secondary).help("Another volume is mounted here")
                    }
                    if record.flags.contains(.hardLinkDuplicate) {
                        Image(systemName: "link").foregroundStyle(.secondary).help("Hard link — its disk space is already counted elsewhere")
                    }
                }
                .help(record.path)
            }
            .width(min: 200, ideal: 340)
            .customizationID("name")
            TableColumn("On Disk", value: \FileRecord.allocatedSize) { record in
                HStack(spacing: 6) {
                    SizeText(record.allocatedSize)
                    Spacer(minLength: 0)
                    Text(percent(record.allocatedSize, of: total)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .width(min: 110, ideal: 130)
            .customizationID("ondisk")
            TableColumn("Logical", value: \FileRecord.logicalSize) { record in
                HStack(spacing: 4) {
                    SizeText(record.logicalSize).foregroundStyle(.secondary)
                    if record.logicalExceedsDisk {
                        Image(systemName: "circle.dashed").font(.caption).foregroundStyle(.secondary)
                            .help(record.isContainer
                                  ? "Larger than on disk: this folder holds sparse files (such as virtual machine disks), compressed or iCloud-only files. They report sizes they don’t occupy — On Disk is the space actually used."
                                  : "Larger than on disk: a sparse, compressed or iCloud-only file reports a size it doesn’t occupy. On Disk is the space actually used.")
                            .accessibilityLabel("Logical size is larger than the space used on disk")
                    }
                }
            }
            .width(min: 80, ideal: 100)
            .customizationID("logical")
            TableColumn("Items", value: \FileRecord.fileCount) { record in
                Text(record.isContainer ? record.fileCount.formatted() : "—").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            .customizationID("items")
            TableColumn("Modified", value: \FileRecord.sortableModified) { record in
                Text(record.modified?.formatted(date: .abbreviated, time: .omitted) ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110)
            .customizationID("modified")
            TableColumn("Category", value: \FileRecord.category.displayName) { record in
                Label(record.category.label(isContainer: record.isContainer), systemImage: record.isContainer && record.category == .unclassified ? "square.stack" : record.category.symbolName)
                    .labelStyle(.titleAndIcon).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 90, ideal: 130)
            .customizationID("category")
        }
        .contextMenu(forSelectionType: FileRecord.ID.self) { ids in
            RecordContextMenu(records: explorer.rows.filter { ids.contains($0.id) }, quickLook: { quickLookURL = $0 })
        } primaryAction: { ids in
            guard let id = ids.first, let record = explorer.rows.first(where: { $0.id == id }) else { return }
            if record.isContainer {
                Task { await explorer.open(record) }
            } else {
                quickLookURL = record.url
            }
        }
        .onChange(of: sortOrder) { _, newValue in
            guard let first = newValue.first else { return }
            if explorer.mode == .folders && explorer.current != nil {
                switch first.keyPath {
                case \FileRecord.name: explorer.sort = .nameAscending
                case \FileRecord.logicalSize: explorer.sort = .logicalDescending
                case \FileRecord.sortableModified: explorer.sort = .modifiedDescending
                default: explorer.sort = .allocatedDescending
                }
            }
        }
        .scrollContentBackground(.hidden)
        .onKeyPress(.space) {
            guard let record = explorer.selectedRecords.first else { return .ignored }
            quickLookURL = record.url
            return .handled
        }
    }

    private var footer: some View {
        let explorer = app.explorer
        return HStack(spacing: 12) {
            if explorer.isLoading { ProgressView().controlSize(.small) }
            if explorer.mode == .folders, explorer.searchText.isEmpty, let current = explorer.current, current.smallFileCount > 0 {
                Text("Plus \(current.smallFileCount.formatted()) smaller files (\(ByteFormat.string(current.smallFileAllocated, style: byteStyle))) directly in this folder, summarized instead of listed.")
            } else if !explorer.searchText.isEmpty {
                Text("Search covers folders and files of at least \(ByteFormat.string(explorer.session?.smallFileThreshold ?? 0, style: byteStyle)).")
            } else {
                Text("\(explorer.rows.count.formatted()) items")
            }
            Spacer()
            if explorer.hasMoreRows {
                Button("Show More") { Task { await app.explorer.loadMore() } }.controlSize(.small)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func percent(_ part: Int64, of total: Int64) -> String {
        let value = Double(part) / Double(max(total, 1))
        return value < 0.001 ? "<0.1%" : value.formatted(.percent.precision(.fractionLength(value < 0.1 ? 1 : 0)))
    }
}

extension FileRecord {
    nonisolated var sortableModified: Date { modified ?? .distantPast }
}

/// Context actions shared by every list that shows index records.
struct RecordContextMenu: View {
    @Environment(AppModel.self) private var app
    let records: [FileRecord]
    var quickLook: ((URL) -> Void)?

    var body: some View {
        if records.count == 1, let record = records.first {
            if record.isContainer {
                Button("Open in Explorer") { Task { await app.explorer.open(record) } }
            } else if let quickLook {
                Button("Quick Look") { quickLook(record.url) }
            }
        }
        Button("Reveal in Finder") { SystemActions.revealInFinder(records.map(\.path)) }
        Button("Copy Path") { SystemActions.copyToPasteboard(records.map(\.path).joined(separator: "\n")) }
        if records.count == 1, let record = records.first {
            Button("Get Info") { app.inspectedRecord = record }
        }
        Divider()
        Button("Exclude from Scans") {
            Task {
                for record in records where record.isContainer { _ = try? await app.store?.addExclusion(path: record.path, scope: .scan) }
            }
        }
        .disabled(!records.contains { $0.isContainer })
        Button("Exclude from Cleanup") {
            Task { for record in records { _ = try? await app.store?.addExclusion(path: record.path, scope: .cleanup) } }
        }
        Divider()
        Button("Move to Trash…") { app.reviewUserSelection(records.map(\.path)) }
            .disabled(app.cleanup.isRunning || records.isEmpty)
    }
}
