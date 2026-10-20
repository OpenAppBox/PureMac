import PureMacKit
import SwiftUI

struct SmartCleanView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    @State private var focused: GroupKey?
    @State private var hovered: RingSegment.ID?
    @State private var detailSort: DetailSort = .size
    /// Experts open the full list; everyone else cleans from the summary and the extras.
    @AppStorage("smartCleanShowsEveryItem") private var showsEveryItem = false

    enum DetailSort: String, CaseIterable, Identifiable {
        case size, name, oldest
        var id: String { rawValue }
        var title: String {
            switch self {
            case .size: String(localized: "Largest First")
            case .name: String(localized: "Name")
            case .oldest: String(localized: "Oldest Change First")
            }
        }
    }

    private func sorted(_ items: [CleanupCandidate]) -> [CleanupCandidate] {
        switch detailSort {
        case .size: items.sorted { $0.allocatedSize > $1.allocatedSize }
        case .name: items.sorted { ($0.relatedAppName ?? $0.name).localizedStandardCompare($1.relatedAppName ?? $1.name) == .orderedAscending }
        case .oldest: items.sorted { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }
        }
    }

    /// A category within a risk section. Keys are unique across sections.
    struct GroupKey: Hashable, Identifiable {
        var risk: RiskLevel
        var category: CleanupCategory
        var id: String { "\(risk.rawValue)-\(category.rawValue)" }
    }

    var body: some View {
        let model = app.smartClean
        ScreenScaffold(item: .smartClean) {
            ModuleHeader(item: .smartClean, subtitle: subtitle) {
                Button { Task { await model.analyze() } } label: {
                    Label(model.evaluation == nil ? "Analyze" : "Analyze Again", systemImage: "sparkles")
                }
                .buttonStyle(.glow(SidebarItem.smartClean.hue, prominent: model.evaluation == nil))
                .disabled(model.isAnalyzing || app.cleanup.isRunning || model.catalog == nil)
            }
            .entrance()

            if let error = model.catalogError {
                NoticeView(tone: .error, title: "Smart Clean is unavailable", message: LocalizedStringKey(error.markdownEscaped))
            } else if model.isAnalyzing {
                analyzingHero
            } else if model.evaluation == nil {
                introHero.entrance(0.05)
            } else if model.candidates.isEmpty {
                GlassCard(padding: 30, tint: Theme.good) {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(Theme.good)
                        Text("Nothing to clean right now").font(.title2.weight(.semibold))
                        Text("No reviewed rule matched anything on this Mac.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                resultsHero.entrance(0.04)
                extras.entrance(0.07)
                DisclosureGroup(isExpanded: $showsEveryItem) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 18) {
                            groupColumn.frame(width: 340)
                            detailPanel
                        }
                        if let rejected = model.evaluation?.rejections, !rejected.isEmpty {
                            GlassCard {
                                DisclosureGroup("Skipped by safety rules (\(rejected.count))") {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(rejected, id: \.self) { item in
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(abbreviate(item.path)).lineLimit(1).truncationMode(.middle)
                                                Text(item.reason).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .padding(.top, 6)
                                }
                            }
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    HStack(spacing: 8) {
                        Text("Show every item").font(.headline)
                        Text("\(model.candidates.count) items in \(Set(model.candidates.map(\.category)).count) categories — choose one by one")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy) { showsEveryItem.toggle() } }
                }
                .entrance(0.1)
                Spacer(minLength: 70)
            }
        }
        .overlay(alignment: .bottom) {
            if model.evaluation != nil && !model.candidates.isEmpty { actionBar }
        }
        .navigationTitle("Smart Clean")
        // Analyzing only reads metadata, so it starts by itself: one less thing to decide.
        .task { if model.evaluation == nil && !model.isAnalyzing && model.catalog != nil && !app.isDemo { await model.analyze() } }
        .onChange(of: model.evaluation?.evaluatedAt) { _, _ in focused = groups(for: .low).first ?? groups(for: .review).first }
        .onAppear { if focused == nil { focused = groups(for: .low).first ?? groups(for: .review).first } }
    }

    private var subtitle: LocalizedStringKey {
        if let evaluation = app.smartClean.evaluation {
            return "Analyzed \(evaluation.evaluatedAt.formatted(date: .omitted, time: .shortened)) · \(app.smartClean.catalog?.rules.count ?? 0) reviewed rules · read-only until you confirm"
        }
        return "Reviewed, narrowly scoped rules for caches, logs and leftovers. Nothing is removed without your confirmation."
    }

    // MARK: Heroes

    private var introHero: some View {
        GlassCard(padding: 30, tint: SidebarItem.smartClean.hue) {
            HStack(spacing: 34) {
                ScannerCore(intensity: 0.4, cancelling: false, hue: SidebarItem.smartClean.hue) {
                    Image(systemName: "sparkles").font(.system(size: 46, weight: .semibold)).foregroundStyle(SidebarItem.smartClean.hue)
                }
                .frame(width: 220, height: 220)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Find space you can safely reclaim").font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("PureMac checks \(app.smartClean.catalog?.rules.count ?? 0) reviewed rules: app and browser caches, package-manager downloads, Xcode build data, old logs and installers. Checking only reads metadata.")
                        .foregroundStyle(.secondary).lineLimit(8)
                    HStack(spacing: 18) {
                        Label("Caches of running apps are held back", systemImage: "pause.circle")
                        Label("Everything goes to the Trash", systemImage: "trash")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Button { Task { await app.smartClean.analyze() } } label: { Label("Analyze Now", systemImage: "sparkles") }
                        .buttonStyle(.glow(SidebarItem.smartClean.hue))
                        .controlSize(.large)
                }
            }
        }
    }

    private var analyzingHero: some View {
        GlassCard(padding: 30, tint: SidebarItem.smartClean.hue) {
            HStack(spacing: 34) {
                ScannerCore(intensity: 0.9, cancelling: false, hue: SidebarItem.smartClean.hue) {
                    ProgressView().controlSize(.large)
                }
                .frame(width: 220, height: 220)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Checking cleanup rules…").font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Matching locations and measuring each candidate. Nothing is changed.").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(CleanupCategory.allCases.filter { ![.appUninstall, .userSelection, .duplicate, .appRemnant].contains($0) }, id: \.self) { category in
                            Label(category.displayName, systemImage: category.symbolName)
                                .foregroundStyle(category.tint)
                                .font(.callout)
                                .shimmer()
                        }
                    }
                }
            }
        }
    }

    private var resultsHero: some View {
        let model = app.smartClean
        let selected = model.selectedCandidates
        let found = model.candidates.reduce(0) { $0 + $1.allocatedSize }
        let byCategory = Dictionary(grouping: selected, by: \.category)
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.allocatedSize }) }
            .sorted { $0.1 > $1.1 }
        let segments = byCategory.map { RingSegment(id: $0.0.rawValue, value: Double($0.1), color: $0.0.tint, label: $0.0.displayName, detail: ByteFormat.string($0.1, style: byteStyle)) }
        let blocked = model.candidates.filter { $0.blockedReason != nil }
        return GlassCard(padding: 24, tint: SidebarItem.smartClean.hue) {
            HStack(spacing: 34) {
                RingChart(segments: segments, total: Double(max(found, 1)), lineWidth: 24, hovered: $hovered) { hovered in
                    VStack(spacing: 3) {
                        if let hovered {
                            Text(hovered.label).font(.headline).multilineTextAlignment(.center)
                            Text(hovered.detail).font(.metric(24))
                        } else {
                            Text("Selected").font(.eyebrow).foregroundStyle(.secondary)
                            RollingText(text: ByteFormat.string(model.selectedBytes, style: byteStyle), font: .hero(34), rolls: true)
                            Text("of \(ByteFormat.string(found, style: byteStyle)) found").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 240, height: 240)
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: "Ready to clean")
                        Text(ByteFormat.string(model.selectedBytes, style: byteStyle)).font(.hero(40))
                        Text("\(selected.count) items your apps and tools rebuild by themselves. Everything goes to the Trash first, and you see the full list before anything moves.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 12) {
                        Button { app.cleanup.present(model.makePlan()) } label: {
                            Label("Review & Clean", systemImage: "sparkles").padding(.horizontal, 6)
                        }
                        .buttonStyle(.glow(SidebarItem.smartClean.hue))
                        .controlSize(.large)
                        .disabled(selected.isEmpty || app.cleanup.isRunning)
                        .keyboardShortcut(.defaultAction)
                    }
                    if !blocked.isEmpty {
                        let running = model.heldBackApps
                        HStack(spacing: 10) {
                            Label(running.isEmpty
                              ? "\(blocked.count) items (\(ByteFormat.string(model.heldBackBytes, style: byteStyle))) are held back because their apps are running. Quit them and PureMac checks again by itself."
                              : "\(blocked.count) items (\(ByteFormat.string(model.heldBackBytes, style: byteStyle))) are held back while these apps run: \(running.map(\.name).formatted(.list(type: .and))). Quit them and PureMac checks again by itself.",
                              systemImage: "pause.circle.fill")
                                .font(.callout).foregroundStyle(.secondary)
                            if !running.isEmpty, app.apps.canQuitApps {
                                Button(running.count == 1 ? "Quit & Include" : "Quit \(running.count) Apps & Include") { model.quitHeldBackApps() }
                                    .buttonStyle(.glow(Theme.warning, prominent: false))
                                    .controlSize(.small)
                                    .help("Asks these apps to quit normally (they may ask to save), then analyzes again. PureMac never force-quits.")
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Extras

    /// One-tap additions, each explained in a line, plus what the Trash already holds.
    private var extras: some View {
        let model = app.smartClean
        let shown = SmartCleanModel.Extra.allCases.filter { model.bytes(of: $0) > 0 }
        let searchingLeftovers = app.apps.isFindingOrphans && model.leftovers.isEmpty
        return Group {
            if !shown.isEmpty || searchingLeftovers || (model.trashBytes ?? 0) > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle().fill(Theme.warning).frame(width: 8, height: 8)
                        Text("Free up more").font(.headline)
                        Text("Each is your call — one tap adds it to the review").font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], alignment: .leading, spacing: 12) {
                        ForEach(shown) { extra in ExtraCard(extra: extra) }
                        if searchingLeftovers && !shown.contains(.leftovers) { ExtraSearchingCard() }
                        if let trash = model.trashBytes, trash > 0 { TrashCard(bytes: trash) }
                    }
                }
            }
        }
    }

    // MARK: Groups

    private func groups(for risk: RiskLevel) -> [GroupKey] {
        let items = risk == .low ? app.smartClean.recommended : app.smartClean.reviewRequired
        let totals = Dictionary(grouping: items, by: \.category).mapValues { $0.reduce(0) { $0 + $1.allocatedSize } }
        return totals.sorted { $0.value > $1.value }.map { GroupKey(risk: risk, category: $0.key) }
    }

    private func candidates(in key: GroupKey) -> [CleanupCandidate] {
        app.smartClean.candidates.filter { $0.risk == key.risk && $0.category == key.category }
    }

    private var groupColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Recommended", detail: "Regenerable; proposed for you", color: SidebarItem.smartClean.hue)
            ForEach(groups(for: .low)) { key in groupCard(key) }
            if groups(for: .low).isEmpty { Text("None found.").foregroundStyle(.secondary) }
            sectionHeader("Review Required", detail: "Never selected unless you choose", color: Theme.warning).padding(.top, 8)
            ForEach(groups(for: .review)) { key in groupCard(key) }
            if groups(for: .review).isEmpty { Text("None found.").foregroundStyle(.secondary) }
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey, detail: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func groupCard(_ key: GroupKey) -> some View {
        let model = app.smartClean
        let items = candidates(in: key)
        let selectable = items.filter { $0.blockedReason == nil }
        let selectedItems = selectable.filter { model.selection.contains($0.id) }
        let total = items.reduce(0) { $0 + $1.allocatedSize }
        let selectedBytes = selectedItems.reduce(0) { $0 + $1.allocatedSize }
        let isFocused = focused == key
        return Button { withAnimation(.spring(response: 0.3)) { focused = key } } label: {
            HStack(spacing: 12) {
                IconTile(symbol: key.category.symbolName, gradient: .tile(key.category.tint), size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(key.category.displayName).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(ByteFormat.string(total, style: byteStyle)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                    Capsule().fill(Theme.track)
                        .overlay(alignment: .leading) {
                            Capsule().fill(key.category.tint)
                                .scaleEffect(x: selectedBytes > 0 ? max(0.02, CGFloat(Double(selectedBytes) / Double(max(total, 1)))) : 0.0001, y: 1, anchor: .leading)
                        }
                        .frame(height: 5)
                        .animation(.easeOut(duration: 0.25), value: selectedBytes)
                    Text(items.count > selectable.count
                         ? "\(selectedItems.count) of \(items.count) selected · \(items.count - selectable.count) held back"
                         : "\(selectedItems.count) of \(items.count) selected")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(isOn: Binding(
                    get: { !selectable.isEmpty && selectedItems.count == selectable.count },
                    set: { on in for c in selectable { if on { model.selection.insert(c.id) } else { model.selection.remove(c.id) } } })) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .disabled(selectable.isEmpty)
                    .accessibilityLabel("Select all \(key.category.displayName)")
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isFocused ? AnyShapeStyle(key.category.tint.opacity(0.16)) : AnyShapeStyle(Theme.cardSurface))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isFocused ? key.category.tint.opacity(0.7) : Theme.cardStroke, lineWidth: isFocused ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: Detail

    private var detailPanel: some View {
        GlassCard(padding: 0) {
            if let key = focused {
                let items = sorted(candidates(in: key))
                let selectable = items.filter { $0.blockedReason == nil }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        IconTile(symbol: key.category.symbolName, gradient: .tile(key.category.tint), size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.category.displayName).font(.title3.weight(.semibold))
                            HStack(spacing: 6) {
                                RiskBadge(risk: key.risk)
                                Text("\(items.count) items").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Select All") { app.smartClean.selection.formUnion(selectable.map(\.id)) }
                            .buttonStyle(.borderless)
                            .disabled(selectable.isEmpty || selectable.allSatisfy { app.smartClean.selection.contains($0.id) })
                        Button("None") { app.smartClean.selection.subtract(items.map(\.id)) }
                            .buttonStyle(.borderless)
                            .disabled(!items.contains { app.smartClean.selection.contains($0.id) })
                        ListMenuPicker(title: "Sort by", symbol: "arrow.up.arrow.down", value: $detailSort,
                                       options: DetailSort.allCases) { $0.title }
                    }
                    .padding(16)
                    Divider()
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { candidate in
                            CandidateRow(candidate: candidate)
                            Divider().opacity(0.5)
                        }
                    }
                }
                .id(key)
                .transition(.opacity)
            } else {
                Text("Select a category").foregroundStyle(.secondary).padding(40).frame(maxWidth: .infinity)
            }
        }
    }

    private var actionBar: some View {
        let model = app.smartClean
        return SelectionActionBar(count: model.selectedCandidates.count, bytes: model.selectedBytes,
                                  tint: SidebarItem.smartClean.hue, actionTitle: "Review & Clean", actionSymbol: "sparkles",
                                  isDisabled: app.cleanup.isRunning,
                                  onClear: { model.selection = [] }) { app.cleanup.present(model.makePlan()) }
    }
}

private struct CandidateRow: View {
    @Environment(AppModel.self) private var app
    let candidate: CleanupCandidate
    @State private var showDetails = false
    @State private var hovering = false

    var body: some View {
        let model = app.smartClean
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(
                get: { model.selection.contains(candidate.id) },
                set: { on in if on { model.selection.insert(candidate.id) } else { model.selection.remove(candidate.id) } })) { EmptyView() }
                .toggleStyle(.checkbox)
                .disabled(candidate.blockedReason != nil)
                .accessibilityLabel("Select \(candidate.name)")
            FileIcon(path: candidate.path, size: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.relatedAppName.map { "\($0) — \(candidate.name)" } ?? candidate.name).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(abbreviate(candidate.path)).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    if let modified = candidate.modified {
                        Text("· changed \(modified.formatted(.relative(presentation: .named)))").font(.caption).lineLimit(1).layoutPriority(1)
                    }
                }
                .foregroundStyle(.secondary)
                if let blocked = candidate.blockedReason {
                    Label(blocked, systemImage: "pause.circle.fill").font(.caption).foregroundStyle(Theme.warning)
                }
                if showDetails {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(candidate.reason).font(.caption)
                        if let impact = candidate.regenerationImpact { Label(impact, systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary) }
                        ForEach(candidate.evidence, id: \.self) { evidence in
                            Label(evidence.detail, systemImage: evidence.supportsRemoval ? "checkmark.seal" : "exclamationmark.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let modified = candidate.modified {
                            Text("Last changed \(modified.formatted(date: .abbreviated, time: .shortened)) · \(candidate.itemCount.formatted()) files")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            Spacer()
            Button { SystemActions.revealInFinder([candidate.path]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .opacity(hovering ? 1 : 0)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(candidate.name) in Finder")
            SizeText(candidate.allocatedSize).foregroundStyle(.secondary)
            Button { withAnimation(.spring(response: 0.3)) { showDetails.toggle() } } label: {
                Image(systemName: "chevron.down").rotationEffect(.degrees(showDetails ? 180 : 0))
            }
            .buttonStyle(.borderless)
            .help("Why is this proposed?")
            .accessibilityLabel(showDetails ? "Hide details" : "Show why this is proposed")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(hovering ? Theme.track : Color.clear)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Reveal in Finder") { SystemActions.revealInFinder([candidate.path]) }
            Button("Copy Path") { SystemActions.copyToPasteboard(candidate.path) }
            Button("Never Propose This Again") {
                Task {
                    _ = try? await app.store?.addExclusion(path: candidate.path, scope: .cleanup)
                    await app.smartClean.analyze()
                }
            }
        }
    }
}

private struct ExtraCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    let extra: SmartCleanModel.Extra
    @State private var hovering = false

    var body: some View {
        let model = app.smartClean
        let on = model.isIncluded(extra)
        let items = model.items(of: extra)
        Button { withAnimation(.snappy) { model.setIncluded(extra, !on) } } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    IconTile(symbol: extra.symbol, gradient: .tile(extra.tint), size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(extra.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(items.count == 1 ? String(localized: "1 item") : String(localized: "\(items.count) items"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text("+" + ByteFormat.string(model.bytes(of: extra), style: byteStyle)).font(.metric(17)).foregroundStyle(on ? extra.tint : .primary)
                }
                Text(extra.detail).font(.caption).foregroundStyle(.secondary).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Label(on ? String(localized: "Included") : String(localized: "Include"), systemImage: on ? "checkmark.circle.fill" : "plus.circle")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(on ? extra.tint : Color.accentColor)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? AnyShapeStyle(extra.tint.opacity(0.14)) : AnyShapeStyle(Theme.cardSurface), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(on ? extra.tint.opacity(0.7) : (hovering ? Theme.cardHighlight : Theme.cardStroke), lineWidth: on ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
        .help(on ? "Removes these items from the review again." : "Adds these items to the review. You still see every item before anything moves.")
    }
}

private struct ExtraSearchingCard: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Looking for leftovers of removed apps…").font(.callout).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.cardStroke))
    }
}

/// The Trash is where earlier cleanups went: its space only returns when the user empties it.
private struct TrashCard: View {
    @Environment(\.byteStyle) private var byteStyle
    let bytes: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                IconTile(symbol: "trash.fill", gradient: .tile(Theme.neutralA), size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Already in the Trash").font(.subheadline.weight(.semibold))
                    Text("Not freed yet").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(ByteFormat.string(bytes, style: byteStyle)).font(.metric(17))
            }
            Text("This space returns when you empty the Trash in Finder (Finder ▸ Empty Trash). PureMac never empties it for you.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button { SystemActions.openTrash() } label: { Label("Open Trash", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.link).font(.callout.weight(.semibold))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.cardStroke))
    }
}

private extension SmartCleanModel.Extra {
    var title: String {
        switch self {
        case .developer: String(localized: "Unused developer data")
        case .installers: String(localized: "Old installers")
        case .leftovers: String(localized: "Leftovers of removed apps")
        }
    }
    var detail: String {
        switch self {
        case .developer: String(localized: "Xcode build data, simulator caches and package downloads not touched for 2 weeks. They are rebuilt when needed; the next build of those projects takes longer.")
        case .installers: String(localized: "Disk images and packages in Downloads older than a month. Apps you installed from them keep working; you would download an installer again to reinstall.")
        case .leftovers: String(localized: "Only items where every check agrees that the app is gone (“Likely”). Their settings go too, should you ever reinstall.")
        }
    }
    var symbol: String {
        switch self {
        case .developer: "hammer.fill"
        case .installers: "shippingbox.fill"
        case .leftovers: "puzzlepiece.extension.fill"
        }
    }
    var tint: Color {
        switch self {
        case .developer: CleanupCategory.developerCache.tint
        case .installers: CleanupCategory.installers.tint
        case .leftovers: SidebarItem.orphans.hue
        }
    }
}
