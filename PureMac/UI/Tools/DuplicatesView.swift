import AppKit
import PureMacKit
import QuickLook
import SwiftUI

struct DuplicatesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    @State private var quickLookURL: URL?

    private var hue: Color { SidebarItem.duplicates.hue }

    var body: some View {
        let model = app.duplicates
        ScreenScaffold(item: .duplicates, scrolls: false) {
            ModuleHeader(item: .duplicates, subtitle: LocalizedStringKey(subtitle.markdownEscaped)) {
                if model.result != nil && !model.isSearching {
                    HStack(spacing: 10) {
                        Button { model.reset() } label: { Label("Change Folders", systemImage: "folder.badge.gearshape") }
                            .buttonStyle(.glow(hue, prominent: false))
                        Button { model.search() } label: { Label("Search Again", systemImage: "arrow.clockwise") }
                            .buttonStyle(.glow(hue, prominent: false))
                            .disabled(model.roots.isEmpty)
                    }
                }
            }
            .entrance()
            if model.isSearching {
                HeroState(item: .duplicates, title: "Comparing files…", message: LocalizedStringKey(progressText), busy: true) {
                    if model.progressTotal > 0 {
                        ProgressView(value: Double(model.progressDone) / Double(model.progressTotal)).frame(width: 220).tint(hue)
                    }
                    Button("Cancel") { model.cancel() }.buttonStyle(.glow(.secondary, prominent: false))
                }
                .entrance(0.04)
            } else if let result = model.result {
                if result.groups.isEmpty {
                    HeroState(item: .duplicates, symbol: "checkmark.seal.fill", title: "No duplicates found",
                              message: result.wasCancelled
                                  ? "\(result.filesConsidered.formatted()) files were compared before the search was cancelled."
                                  : "\(result.filesConsidered.formatted()) files were compared. Every file in these folders is unique.") {
                        Button { model.reset() } label: { Label("Search Other Folders", systemImage: "folder.badge.plus") }
                            .buttonStyle(.glow(hue))
                    }
                    .entrance(0.04)
                } else {
                    summary(result).entrance(0.04)
                    HStack(alignment: .top, spacing: 16) {
                        groupList.frame(width: 390).frame(maxHeight: .infinity)
                        Group {
                            if let group = model.selectedGroup {
                                // Updated in place (no .id/transition): rebuilding the pane per click cost ~80 ms.
                                DuplicateGroupDetail(group: group) { quickLookURL = $0 }
                            } else {
                                GlassCard(padding: 40) {
                                    ContentUnavailableView("Pick a file", systemImage: "doc.on.doc",
                                                           description: Text("Choose a file on the left to see its copies and decide which one to keep."))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .entrance(0.08)
                }
            } else {
                DuplicateSearchSetup().entrance(0.04)
            }
        }
        .selectionBar(isPresented: !model.selection.isEmpty) {
            SelectionActionBar(count: model.selection.count, subject: .copies, bytes: model.selectedBytes,
                               tint: hue, isDisabled: app.cleanup.isRunning,
                               onClear: { app.duplicates.selection = [] }) { model.reviewSelection() }
        }
        .navigationTitle("Duplicates")
        .quickLookPreview($quickLookURL)
    }

    private var subtitle: String {
        let model = app.duplicates
        guard let result = model.result, !model.isSearching else {
            return String(localized: "Byte-identical files, compared by size, fingerprint and SHA-256. One copy is always kept.")
        }
        let folders = model.searchedRoots.map(abbreviate).joined(separator: ", ")
        return String(localized: "\(result.filesConsidered.formatted()) files compared in \(folders)")
    }

    private var progressText: String {
        let model = app.duplicates
        if model.phase.isEmpty { return String(localized: "Listing files…") }
        let phase = String(localized: String.LocalizationValue(model.phase))
        return model.progressTotal > 0
            ? String(localized: "\(phase) — \(model.progressDone) of \(model.progressTotal)")
            : String(localized: "\(phase) — \(model.progressDone)")
    }

    // MARK: Summary

    private func summary(_ result: DuplicateScanResult) -> some View {
        let model = app.duplicates
        let total = model.kindTotals.reduce(Int64(0)) { $0 + $1.bytes }
        let copies = result.groups.reduce(0) { $0 + $1.files.count }
        let folders = Array(model.folderTotals.prefix(3))
        let largestFolder = max(folders.first?.bytes ?? 1, 1)
        return GlassCard(padding: 16, tint: hue) {
            HStack(alignment: .top, spacing: 26) {
                VStack(alignment: .leading, spacing: 3) {
                    Eyebrow(text: "Extra copies")
                    RollingText(text: ByteFormat.string(total, style: byteStyle), font: .hero(30))
                    Text("\(copies) copies of \(result.groups.count) files").font(.caption).foregroundStyle(.secondary)
                    if result.skippedCloudOnly > 0 || result.skippedUnreadable > 0 {
                        Text("Skipped: \(result.skippedCloudOnly) iCloud-only, \(result.skippedUnreadable) unreadable.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if result.wasCancelled {
                        Label("Search was cancelled; results are partial.", systemImage: "exclamationmark.triangle")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                .frame(minWidth: 170, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(text: "By kind — click to filter")
                    CapacityBar(segments: model.kindTotals.map { entry in
                        .init(id: "\(entry.kind.rawValue)", value: Double(entry.bytes), color: entry.kind.tint,
                              label: "\(entry.kind.title) \(ByteFormat.string(entry.bytes, style: byteStyle))")
                    }, total: Double(max(total, 1)))
                    FlowLayout(spacing: 6, rowSpacing: 6) {
                        ForEach(model.kindTotals, id: \.kind) { entry in
                            FilterChip(label: entry.kind.title, value: ByteFormat.string(entry.bytes, style: byteStyle), color: entry.kind.tint,
                                       isOn: model.kindFilter == entry.kind) {
                                model.kindFilter = model.kindFilter == entry.kind ? nil : entry.kind
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(text: "Where the copies are")
                    ForEach(Array(folders.enumerated()), id: \.element.folder) { index, entry in
                        BarListRow(title: abbreviate(entry.folder), value: ByteFormat.string(entry.bytes, style: byteStyle),
                                   fraction: Double(entry.bytes) / Double(largestFolder), color: hue, icon: "folder.fill", delay: Double(index) * 0.05)
                            .contextMenu {
                                Button("Keep the Copies in This Folder") { model.selectExtraCopies(keeping: .inFolder(entry.folder)) }
                                Button("Reveal in Finder") { SystemActions.revealInFinder([entry.folder]) }
                            }
                    }
                }
                .frame(width: 260)
            }
        }
    }

    // MARK: Group list

    private var groupList: some View {
        @Bindable var model = app.duplicates
        let visible = model.visibleGroups
        return GlassCard(padding: 0) {
            VStack(spacing: 0) {
                SearchField(text: $model.searchText, prompt: "Search names and folders").padding([.horizontal, .top], 10)
                listHeader(visible: visible)
                List(visible, selection: $model.selectedGroupID) { group in
                    DuplicateGroupRow(group: group, kind: model.kind(of: group), removing: model.selectedCount(in: group)) {
                        model.toggleGroup(group)
                    }
                    .tag(group.id)
                    .contextMenu {
                        if let first = group.files.first {
                            Button("Quick Look") { quickLookURL = first.url }
                        }
                        Button("Reveal Copies in Finder") { SystemActions.revealInFinder(group.files.map(\.path)) }
                        Divider()
                        ForEach(DuplicatesModel.KeepRule.standard) { rule in
                            Button(rule.title) { if let keep = rule.keeper(in: group) { model.keepOnly(keep, in: group) } }
                        }
                        Button("Keep All Copies") { model.selection.subtract(group.files.map(\.path)) }
                    }
                }
                .scrollContentBackground(.hidden)
                .onKeyPress(.space) {
                    guard let group = model.selectedGroup else { return .ignored }
                    model.toggleGroup(group)
                    return .handled
                }
                .overlay {
                    if visible.isEmpty {
                        if model.searchText.isEmpty {
                            ContentUnavailableView("No matching files", systemImage: "line.3.horizontal.decrease.circle", description: Text("Try another kind."))
                        } else {
                            ContentUnavailableView.search(text: model.searchText)
                        }
                    }
                }
            }
        }
    }

    private func listHeader(visible: [DuplicateGroup]) -> some View {
        // One row when it fits; with longer labels (German, Finnish…) the controls move to a second row.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                listCounts(visible: visible)
                Spacer(minLength: 8)
                listControls
            }
            VStack(alignment: .leading, spacing: 6) {
                listCounts(visible: visible)
                HStack(spacing: 12) {
                    listControls
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func listCounts(visible: [DuplicateGroup]) -> some View {
        let model = app.duplicates
        let decided = visible.filter { model.selectedCount(in: $0) > 0 }.count
        let allChecked = !visible.isEmpty && decided == visible.count
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { allChecked }, set: { model.setAllVisible($0) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .disabled(visible.isEmpty)
                .help("Select the extra copies of every listed file, keeping one copy of each by the current rule")
                .accessibilityLabel("Select extra copies of all listed files")
            VStack(alignment: .leading, spacing: 0) {
                Text("\(visible.count) files").font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
                Text(decided == 0 ? String(localized: "Nothing chosen yet") : String(localized: "\(decided) chosen"))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
        }
    }

    private var listControls: some View {
        @Bindable var model = app.duplicates
        return HStack(spacing: 8) {
            Menu {
                Section("Select the extra copies, and…") {
                    ForEach(DuplicatesModel.KeepRule.standard) { rule in
                        Button(rule.title) { model.selectExtraCopies(keeping: rule) }
                    }
                }
                if !model.searchedRoots.isEmpty {
                    Section("Prefer keeping copies in") {
                        ForEach(model.searchedRoots, id: \.self) { root in
                            Button(abbreviate(root)) { model.selectExtraCopies(keeping: .inFolder(root)) }
                        }
                    }
                }
            } label: {
                Label("Auto-Select", systemImage: "wand.and.stars").font(.caption.weight(.medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Chooses one copy to keep in every listed file and selects the rest. Review before anything moves.")
            ListMenuPicker(title: "Sort by", symbol: "arrow.up.arrow.down", value: $model.sortOrder,
                           options: DuplicatesModel.SortOrder.allCases) { $0.title }
        }
    }
}

// MARK: - Setup

private struct DuplicateSearchSetup: View {
    @Environment(AppModel.self) private var app
    private var hue: Color { SidebarItem.duplicates.hue }

    var body: some View {
        @Bindable var model = app.duplicates
        let home = PathTools.userHome
        let suggestions = ["Movies", "Pictures", "Music", "Desktop", "Documents", "Downloads"].map { home + "/" + $0 }
            .filter { !model.roots.contains($0) && FileManager.default.isDirectoryFast($0) }
        GlassCard(padding: 24, tint: hue) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 24) {
                    ScannerCore(intensity: 0.3, cancelling: false, hue: hue) {
                        Image(systemName: "doc.on.doc.fill").font(.system(size: 34, weight: .semibold)).foregroundStyle(hue)
                    }
                    .frame(width: 130, height: 130)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Find exact duplicates").font(.system(size: 24, weight: .bold, design: .rounded))
                        Text("Only byte-identical files are listed. You choose every copy to remove, and one copy of each file is always kept.")
                            // No fixedSize here: on this non-scrolling page a layout pass can offer the text
                            // almost no width, and a vertically fixed size then blanked the whole window.
                            .foregroundStyle(.secondary).lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            step(1, "Same size", "ruler")
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            step(2, "Same fingerprint", "touchid")
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            step(3, "Same SHA-256", "checkmark.seal")
                        }
                        .padding(.top, 2)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: "Search in")
                    FlowLayout(spacing: 8, rowSpacing: 8) {
                        ForEach(model.roots, id: \.self) { root in
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill").foregroundStyle(hue)
                                Text(abbreviate(root)).lineLimit(1)
                                Button { model.roots.removeAll { $0 == root } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove \(abbreviate(root))")
                            }
                            .font(.callout)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(hue.opacity(0.12), in: Capsule())
                        }
                        Button { addFolder() } label: { Label("Add Folder…", systemImage: "plus") }
                            .buttonStyle(.glow(hue, prominent: false))
                        ForEach(suggestions, id: \.self) { path in
                            Button { model.roots.append(path) } label: {
                                Label(abbreviate(path), systemImage: "plus").font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .overlay(Capsule().strokeBorder(Theme.cardStroke, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                            .help("Add this folder to the search")
                        }
                    }
                }
                HStack(alignment: .center, spacing: 14) {
                    Text("Ignore files smaller than").foregroundStyle(.secondary)
                    Picker("Ignore files smaller than", selection: $model.minimumSizeMB) {
                        Text("1 MB").tag(1)
                        Text("10 MB").tag(10)
                        Text("100 MB").tag(100)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)
                    Spacer()
                    Button { model.search() } label: { Label("Find Duplicates", systemImage: "doc.on.doc") }
                        .buttonStyle(.glow(hue))
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.roots.isEmpty)
                }
                Text("Comparing needs to read file contents; that happens only when you start a search, and only in these folders. Files stored only in iCloud are skipped so nothing is downloaded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func step(_ number: Int, _ title: LocalizedStringKey, _ symbol: String) -> some View {
        Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(hue) }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.track, in: Capsule())
            .accessibilityLabel(Text("Step \(number): ") + Text(title))
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.standardizedFileURL.path
            guard !app.duplicates.roots.contains(path) else { continue }
            app.access.remember(url)
            app.duplicates.roots.append(path)
        }
    }
}

// MARK: - Rows

private struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    let kind: DuplicatesModel.Kind
    let removing: Int
    let toggle: () -> Void
    @Environment(\.byteStyle) private var byteStyle

    var body: some View {
        let name = group.files.first?.name ?? ""
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { removing > 0 }, set: { _ in toggle() })) { EmptyView() }
                .toggleStyle(.checkbox)
                .accessibilityLabel("Remove extra copies of \(name)")
            FileThumbnail(path: group.files.first?.path ?? "", size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1).truncationMode(.middle)
                Text("\(group.files.count) copies · \(ByteFormat.string(group.size, style: byteStyle)) each")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                Text(ByteFormat.string(group.potentialSavings, style: byteStyle)).font(.callout.weight(.semibold)).monospacedDigit()
                CopyDots(total: group.files.count, removing: removing, tint: kind.tint)
            }
        }
        .padding(.vertical, 3)
    }
}

/// One dot per copy: hollow = kept, filled = selected for removal.
private struct CopyDots: View {
    let total: Int
    let removing: Int
    var tint: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<min(total, 6), id: \.self) { index in
                let removed = index >= total - removing
                Circle()
                    .strokeBorder(removed ? Color.clear : Color.secondary.opacity(0.7), lineWidth: 1.2)
                    .background(Circle().fill(removed ? tint : Color.clear))
                    .frame(width: 7, height: 7)
            }
            if total > 6 { Text(verbatim: "+\(total - 6)").font(.system(size: 9)).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(removing == 0 ? Text("All \(total) copies kept") : Text("\(removing) of \(total) copies selected"))
    }
}

// MARK: - Detail

private struct DuplicateGroupDetail: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    let group: DuplicateGroup
    let preview: (URL) -> Void

    var body: some View {
        let model = app.duplicates
        let kind = model.kind(of: group)
        let removing = group.files.filter { model.selection.contains($0.path) }
        let freed = removing.reduce(Int64(0)) { $0 + $1.allocatedSize }
        let newest = group.files.max { $0.modified < $1.modified }?.path
        let oldest = group.files.min { $0.modified < $1.modified }?.path
        let name = group.files.first?.name ?? ""
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    Button { if let url = group.files.first?.url { preview(url) } } label: {
                        FileThumbnail(path: group.files.first?.path ?? "", size: 92)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "eye.circle.fill").font(.title3).symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.55))
                            }
                    }
                    .buttonStyle(.plain)
                    .help("Quick Look (Space in Finder)")
                    .accessibilityLabel("Preview \(name)")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(name).font(.title3.weight(.semibold)).lineLimit(2)
                        HStack(spacing: 6) {
                            Label(kind.title, systemImage: kind.symbol)
                            Text(verbatim: "·")
                            Text("\(group.files.count) identical copies of \(ByteFormat.string(group.size, style: byteStyle))")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Text("SHA-256 \(group.sha256.prefix(16))…").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Button { SystemActions.copyToPasteboard(group.sha256) } label: { Image(systemName: "doc.on.clipboard") }
                                .buttonStyle(.borderless).controlSize(.small)
                                .help("Copy the full SHA-256 hash")
                                .accessibilityLabel("Copy hash")
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        RollingText(text: ByteFormat.string(freed, style: byteStyle), font: .metric(24))
                            .foregroundStyle(freed > 0 ? AnyShapeStyle(SidebarItem.duplicates.hue) : AnyShapeStyle(.secondary))
                        Text(removing.isEmpty ? String(localized: "nothing chosen") : String(localized: "freed by removing \(removing.count) of \(group.files.count)"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Eyebrow(text: "Copies — choose which to keep")
                    Spacer()
                    Menu {
                        ForEach(DuplicatesModel.KeepRule.standard) { rule in
                            Button(rule.title) { if let keep = rule.keeper(in: group) { model.keepOnly(keep, in: group) } }
                        }
                        Divider()
                        Button("Keep All Copies") { model.selection.subtract(group.files.map(\.path)) }
                    } label: {
                        Label("Choose For Me", systemImage: "wand.and.stars").font(.caption.weight(.medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                // A plain stack when the copies fit; scrolling only for unusually many copies.
                // A plain stack for the usual few copies; a bounded scroll area for many. (Chosen by
                // count: ViewThatFits measured the rows repeatedly and made opening the page ~0.3 s slower.)
                if group.files.count <= 6 {
                    copies(newest: newest, oldest: oldest)
                } else {
                    ScrollView { copies(newest: newest, oldest: oldest) }.frame(height: 6 * 62)
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                Text(group.files.contains { !$0.hardLinkPaths.isEmpty }
                     ? "Identical by full SHA-256. Copies made with Finder on APFS can be clones that share disk blocks, so removing them may free less. Hard links are one file and are never counted as copies."
                     : "Identical by full SHA-256. Copies made with Finder on APFS can be clones that share disk blocks, so removing them may free less.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func copies(newest: String?, oldest: String?) -> some View {
        VStack(spacing: 8) {
            ForEach(group.files) { file in
                CopyRow(file: file, group: group, isNewest: group.files.count > 1 && file.path == newest,
                        isOldest: group.files.count > 1 && file.path == oldest && newest != oldest,
                        preview: preview)
            }
        }
    }
}

private struct CopyRow: View {
    @Environment(AppModel.self) private var app
    let file: DuplicateFile
    let group: DuplicateGroup
    let isNewest: Bool
    let isOldest: Bool
    let preview: (URL) -> Void

    var body: some View {
        let model = app.duplicates
        let remove = model.selection.contains(file.path)
        let folder = (file.path as NSString).deletingLastPathComponent
        let hue = SidebarItem.duplicates.hue
        HStack(spacing: 12) {
            KeepRemoveToggle(remove: remove, tint: hue, label: abbreviate(file.path)) { model.setRemove($0, file, in: group) }
            Image(systemName: remove ? "trash.fill" : "folder.fill")
                .foregroundStyle(remove ? hue : Color.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text((folder as NSString).lastPathComponent).fontWeight(.medium).lineLimit(1)
                    if isNewest { pill("Newest") }
                    if isOldest { pill("Oldest") }
                }
                Text(abbreviate(folder)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if !file.hardLinkPaths.isEmpty {
                    Text("Also hard-linked at \(file.hardLinkPaths.count) other path(s)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(file.modified.formatted(date: .abbreviated, time: .shortened)).font(.caption).monospacedDigit()
                Text("modified").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 2) {
                Button { preview(file.url) } label: { Image(systemName: "eye") }
                    .help("Quick Look").accessibilityLabel("Preview \(file.name)")
                Button { SystemActions.revealInFinder([file.path]) } label: { Image(systemName: "magnifyingglass") }
                    .help("Reveal in Finder").accessibilityLabel("Reveal \(file.name) in Finder")
            }
            .buttonStyle(.borderless)
            Button { model.keepOnly(file, in: group) } label: { Image(systemName: "checkmark.circle") }
                .buttonStyle(.borderless)
                .help("Keep only this copy and select all the others")
                .accessibilityLabel("Keep only this copy")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(remove ? hue.opacity(0.10) : Theme.track.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(remove ? hue.opacity(0.45) : Color.clear, lineWidth: 1))
        .contextMenu {
            Button("Keep Only This Copy") { model.keepOnly(file, in: group) }
            Divider()
            Button("Open") { SystemActions.open(file.path) }
            Button("Reveal in Finder") { SystemActions.revealInFinder([file.path]) }
            Button("Copy Path") { SystemActions.copyToPasteboard(file.path) }
        }
        .accessibilityElement(children: .contain)
    }

    // Not named `tag`: an unqualified tag("…") would resolve to View.tag(_:) and nest the row in itself.
    private func pill(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Theme.track, in: Capsule())
            .foregroundStyle(.secondary)
    }
}

/// Two-segment "Keep | Remove" switch for one copy.
private struct KeepRemoveToggle: View {
    let remove: Bool
    let tint: Color
    let label: String
    let set: (Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment("Keep", symbol: "checkmark", isOn: !remove, color: .secondary) { set(false) }
            segment("Remove", symbol: "trash", isOn: remove, color: tint) { set(true) }
        }
        .padding(2)
        .background(Theme.track, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(remove ? Text("Remove") : Text("Keep"))
        .accessibilityAdjustableAction { _ in set(!remove) }
        .accessibilityAction { set(!remove) }
    }

    private func segment(_ title: LocalizedStringKey, symbol: String, isOn: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .foregroundStyle(isOn ? AnyShapeStyle(color == .secondary ? Color.primary : Color.white) : AnyShapeStyle(.secondary))
                .background {
                    if isOn {
                        Capsule().fill(color == .secondary ? AnyShapeStyle(Theme.cardHighlight) : AnyShapeStyle(color))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

extension DuplicatesModel.Kind {
    /// Identity color, fixed per kind (never by rank).
    var tint: Color {
        switch self {
        case .video: Theme.series[4]
        case .image: Theme.series[2]
        case .audio: Theme.series[6]
        case .archive: Theme.series[3]
        case .document: Theme.series[0]
        case .other: Theme.neutralA
        }
    }
}

extension DuplicateFile {
    var url: URL { URL(fileURLWithPath: path) }
}
