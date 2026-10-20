import Charts
import PureMacKit
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    let navigate: (SidebarItem) -> Void
    @State private var showingGaps = false
    @State private var showingExplanation = false
    @State private var hoveredSegment: RingSegment.ID?
    @State private var fullDiskAccess = FullDiskAccess.Status.unknown
    @State private var askForAccess = false

    #if DEBUG
    private let parts = Set((UserDefaults.standard.string(forKey: "PureMacOverviewParts") ?? "hero,opps,lists,coverage,changes").split(separator: ",").map(String.init))
    #else
    private let parts: Set<String> = ["hero", "opps", "lists", "coverage", "changes"]
    #endif

    var body: some View {
        #if DEBUG
        let _ = PerfTrace.enabled ? Self._printChanges() : ()
        #endif
        let scan = app.scan
        ScreenScaffold(item: .overview) {
            ModuleHeader(item: .overview, subtitle: LocalizedStringKey(headerSubtitle)) {
                if !scan.isBusy { ScanButton() }
            }
            .entrance()

            if let notice = app.recoveryNotice {
                NoticeView(tone: .warning, title: "Local data was reset", message: LocalizedStringKey(notice.markdownEscaped))
            }
            if let error = scan.errorMessage {
                NoticeView(tone: .error, title: "Scan problem", message: LocalizedStringKey(error.markdownEscaped))
            }
            if let finished = scan.justFinished {
                ScanCompleteBanner(session: finished) { scan.acknowledgeFinish() }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if scan.isBusy {
                ScanExperienceView()
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            } else if parts.contains("hero") {
                heroCard.entrance(0.05)
            }

            if parts.contains("opps") {
                // Separate views: background measurements (app sizes, analysis) re-render only these.
                FreeUpSpaceCard(navigate: navigate).entrance(0.1)
                OpportunityRow(navigate: navigate).entrance(0.14)
            }

            if let session = scan.latestSession, !scan.isBusy {
                if session.status == .cancelled {
                    NoticeView(tone: .warning, title: "The last scan was cancelled", message: "Results below are partial. Run a full scan for complete numbers.")
                }
                if parts.contains("lists") {
                    HStack(alignment: .top, spacing: 18) {
                        largestFolders(session)
                        storageMap(session)
                    }
                    .entrance(0.18)
                }
                if parts.contains("coverage") {
                    HStack(alignment: .top, spacing: 18) {
                        largestFiles(session)
                        coverage(session)
                    }
                    .entrance(0.24)
                }
                if parts.contains("changes"), !scan.changes.isEmpty { changesCard.entrance(0.3) }
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: scan.isBusy)
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: scan.justFinished?.id)
        .navigationTitle("Overview")
        // Read-only analysis so the page answers "how much can I free?" without a click.
        // Nothing is selected for removal beyond Smart Clean's own low-risk proposal, and nothing
        // moves until the user reviews and confirms.
        .task {
            guard !app.isHostingTests, !app.isDemo else { return }
            await app.apps.load()
            if app.smartClean.evaluation == nil { await app.smartClean.analyze() }
            if app.apps.orphansFoundAt == nil { await app.apps.findOrphans() }
        }
        .sheet(isPresented: $showingExplanation) { MeasurementExplanationView() }
        .sheet(isPresented: $showingGaps) {
            if let session = app.scan.latestSession { IssuesSheet(session: session).environment(app) }
        }
    }

    private var headerSubtitle: String {
        if let finished = app.scan.latestSession?.finishedAt {
            let files = app.scan.latestSession?.fileCount.formatted() ?? "0"
            return String(localized: "Last scan \(finished.relativeDescription) · \(files) files indexed")
        }
        return Brand.tagline
    }

    // MARK: Hero

    private var heroCard: some View {
        let volume = app.scan.startupVolume
        let segments = diskSegments()
        let total = Double(volume?.totalCapacity ?? 1)
        return GlassCard(padding: 24, tint: SidebarItem.overview.hue) {
            HStack(alignment: .center, spacing: 34) {
                RingChart(segments: segments, total: total, lineWidth: 30, hovered: $hoveredSegment) { hovered in
                    VStack(spacing: 4) {
                        if let hovered {
                            Text(hovered.label).font(.headline).multilineTextAlignment(.center).lineLimit(2)
                            Text(hovered.detail).font(.metric(26)).monospacedDigit()
                            Text((hovered.value / max(total, 1)).formatted(.percent.precision(.fractionLength(1))) + " of disk")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Available").font(.eyebrow).foregroundStyle(.secondary)
                            RollingText(text: ByteFormat.string(volume?.availableCapacity ?? 0, style: byteStyle), font: .hero(38), rolls: true)
                            Text("of \(ByteFormat.string(volume?.totalCapacity ?? 0, style: byteStyle))").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .animation(.easeOut(duration: 0.15), value: hovered?.id)
                }
                .frame(width: 300, height: 300)

                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: "Startup disk")
                        Text(volume?.name ?? "Macintosh HD").font(.system(size: 24, weight: .bold, design: .rounded))
                        if let type = volume?.fileSystemType { Text(type).font(.caption).foregroundStyle(.secondary) }
                    }
                    HStack(spacing: 28) {
                        StatBlock(value: ByteFormat.string(volume?.usedCapacity ?? 0, style: byteStyle), label: "Used")
                        StatBlock(value: ByteFormat.string(volume?.availableCapacity ?? 0, style: byteStyle), label: "Available", tint: Theme.brandTeal)
                        if let purgeable = volume?.purgeableEstimate, purgeable > 0 {
                            StatBlock(value: ByteFormat.string(purgeable, style: byteStyle), label: "Purgeable (macOS)")
                        }
                    }
                    if app.scan.latestSession == nil {
                        Text("Scan to see what’s inside. PureMac reads only names, sizes and dates — never your files’ contents — and never deletes anything without your review.")
                            .font(.callout).foregroundStyle(.secondary).lineLimit(8)
                    } else {
                        legend(segments)
                        if let unscanned = unscannedBytes { entireDiskPrompt(unscanned) }
                    }
                    HStack(spacing: 10) {
                        Button("How is space measured?") { showingExplanation = true }.buttonStyle(.glow(SidebarItem.overview.hue, prominent: false))
                        Button("Storage Settings…") { SystemActions.openStorageSettings() }.buttonStyle(.glow(.secondary, prominent: false))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Used space a home-folder scan left out, when it is a large part of the disk (at least 10 GB
    /// and a fifth of the used space). `nil` after a whole-disk scan or in the App Store edition.
    private var unscannedBytes: Int64? {
        guard !app.access.isRequired, !app.scan.latestScanCoveredEntireDisk, let scanned = scannedOnStartupVolume,
              let used = app.scan.startupVolume?.usedCapacity else { return nil }
        let rest = used - scanned
        return rest >= max(10_000_000_000, used / 5) ? rest : nil
    }

    private func entireDiskPrompt(_ unscanned: Int64) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(ByteFormat.string(unscanned, style: byteStyle)) isn’t in this scan").fontWeight(.semibold)
                    Text("Your last scan covered your home folder. Apps, shared and system data, and other users’ files are outside it.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }
            } icon: {
                Image(systemName: "internaldrive").foregroundStyle(SidebarItem.overview.hue)
            }
            HStack(spacing: 8) {
                Button {
                    if fullDiskAccess == .denied { askForAccess = true } else { app.scan.start(entireDisk: true) }
                } label: {
                    Label("Scan Entire Disk", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(.glow(SidebarItem.overview.hue))
                .disabled(app.store == nil)
                if fullDiskAccess == .denied {
                    Button("Allow Full Disk Access…") { SystemActions.openFullDiskAccessSettings() }
                        .buttonStyle(.glow(.secondary, prominent: false))
                        .help("Without Full Disk Access, protected areas are listed as gaps instead of measured.")
                }
            }
        }
        .padding(12)
        .background(SidebarItem.overview.hue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task { fullDiskAccess = await Task.detached { FullDiskAccess.status() }.value }
        .modifier(EntireDiskAccessCheck(isPresented: $askForAccess) { app.scan.start(entireDisk: true) })
    }

    private func legend(_ segments: [RingSegment]) -> some View {
        // A plain two-column Grid: a LazyVGrid nested in an eager layout re-measures repeatedly.
        let rows = stride(from: 0, to: segments.count, by: 2).map { Array(segments[$0..<min($0 + 2, segments.count)]) }
        return Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            ForEach(rows, id: \.first?.id) { pair in
                GridRow {
                    ForEach(pair) { segment in legendItem(segment) }
                }
            }
        }
    }

    private func legendItem(_ segment: RingSegment) -> some View {
        Group {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 3).fill(segment.color).frame(width: 10, height: 10)
                    Text(segment.label).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(segment.detail).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(hoveredSegment == segment.id ? segment.color.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .onHover { hoveredSegment = $0 ? segment.id : nil }
                .accessibilityElement(children: .combine)
        }
    }

    /// Category slices of the scanned space (only when every root is on the startup volume),
    /// then the rest of the used space as one neutral slice. Free space is the empty track.
    private func diskSegments() -> [RingSegment] {
        guard let volume = app.scan.startupVolume, let used = volume.usedCapacity else { return [] }
        var segments: [RingSegment] = []
        var accounted: Int64 = 0
        if scannedOnStartupVolume != nil {
            let totals = app.scan.categoryTotals.filter { $0.allocatedSize > 0 }
            for total in totals.prefix(8) {
                segments.append(RingSegment(id: "c\(total.category.rawValue)", value: Double(total.allocatedSize), color: total.category.tint,
                                            label: total.category.displayName, detail: ByteFormat.string(total.allocatedSize, style: byteStyle)))
                accounted += total.allocatedSize
            }
            let rest = totals.dropFirst(8).reduce(0) { $0 + $1.allocatedSize }
            if rest > 0 {
                segments.append(RingSegment(id: "rest", value: Double(rest), color: Theme.neutralB, label: String(localized: "Other scanned"), detail: ByteFormat.string(rest, style: byteStyle)))
                accounted += rest
            }
        }
        let outside = max(0, used - accounted)
        segments.append(RingSegment(id: "outside", value: Double(outside), color: accounted > 0 ? Theme.neutralA.opacity(0.45) : Theme.brandBlue,
                                    label: accounted > 0 ? String(localized: "macOS & not scanned") : String(localized: "Used"),
                                    detail: ByteFormat.string(outside, style: byteStyle)))
        return segments
    }

    private var scannedOnStartupVolume: Int64? {
        app.scan.scansOnlyStartupVolume ? app.scan.latestSession?.allocatedSize : nil
    }

    // MARK: Lists & map

    private func largestFolders(_ session: ScanSession) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Largest Folders", systemImage: "folder.fill").font(.headline)
                    Spacer()
                    Button("Explore") { navigate(.explorer) }.buttonStyle(.link)
                }
                let folders = Array(app.scan.largestFolders.prefix(8))
                let maxSize = max(folders.first?.allocatedSize ?? 1, 1)
                if folders.isEmpty { Text("No folders were indexed.").foregroundStyle(.secondary) }
                ForEach(Array(folders.enumerated()), id: \.element.id) { index, record in
                    Button {
                        navigate(.explorer)
                        Task { await app.explorer.open(record) }
                    } label: {
                        BarListRow(title: record.name, subtitle: locationCaption(record), value: ByteFormat.string(record.allocatedSize, style: byteStyle),
                                   fraction: Double(record.allocatedSize) / Double(maxSize), color: record.mapCategory.tint,
                                   iconPath: record.path, delay: Double(index) * 0.04)
                    }
                    .buttonStyle(.plain)
                    .help(record.path)
                    .contextMenu { RecordContextMenu(records: [record]) }
                }
            }
        }
    }

    private func storageMap(_ session: ScanSession) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Storage Map", systemImage: "circle.hexagongrid.fill").font(.headline)
                    Spacer()
                    Text("Double-click to open").font(.caption).foregroundStyle(.secondary)
                }
                if app.scan.mapNodes.isEmpty {
                    Text("No folders to map.").foregroundStyle(.secondary)
                } else {
                    AnimatedSunburst(nodes: app.scan.mapNodes, total: Double(app.scan.mapRoot?.allocatedSize ?? 1),
                                     centerTitle: app.scan.mapRoot.map { abbreviate($0.path) } ?? "",
                                     centerValue: ByteFormat.string(app.scan.mapRoot?.allocatedSize ?? 0, style: byteStyle)) { id in
                        navigate(.explorer)
                        Task { await app.explorer.open(id: id) }
                    }
                    .frame(height: 300)
                }
            }
        }
        .frame(maxWidth: 420)
    }

    private func largestFiles(_ session: ScanSession) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Largest Files", systemImage: "doc.fill").font(.headline)
                    Spacer()
                    Button("Show All") {
                        app.explorer.mode = .largestFiles
                        navigate(.explorer)
                    }
                    .buttonStyle(.link)
                }
                let files = Array(app.scan.largestFiles.prefix(8))
                let maxSize = max(files.first?.allocatedSize ?? 1, 1)
                if files.isEmpty { Text("No large files were found in the scanned locations.").foregroundStyle(.secondary) }
                ForEach(Array(files.enumerated()), id: \.element.id) { index, record in
                    Button {
                        navigate(.explorer)
                        Task { await app.explorer.reveal(record) }
                    } label: {
                        BarListRow(title: record.name, subtitle: locationCaption(record), value: ByteFormat.string(record.allocatedSize, style: byteStyle),
                                   fraction: Double(record.allocatedSize) / Double(maxSize), color: record.mapCategory.tint,
                                   iconPath: record.path, delay: Double(index) * 0.04)
                    }
                    .buttonStyle(.plain)
                    .help("\(record.path) — click to show it in Storage Explorer")
                    .contextMenu { RecordContextMenu(records: [record]) }
                }
                Text("Large personal files are never selected for cleanup automatically.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func coverage(_ session: ScanSession) -> some View {
        let denied = app.scan.issueCounts[.permissionDenied] ?? 0
        let other = app.scan.issueCounts.filter { $0.key != .permissionDenied && $0.key != .excluded }.values.reduce(0, +)
        let excluded = app.scan.issueCounts[.excluded] ?? 0
        let readable = Double(session.directoryCount) / Double(max(session.directoryCount + Int64(denied), 1))
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Scan Coverage", systemImage: "checklist").font(.headline)
                HStack(spacing: 18) {
                    GaugeRing(fraction: readable, color: denied == 0 ? Theme.brandTeal : Theme.warning, lineWidth: 9,
                              label: readable >= 0.9995 ? 1.0.formatted(.percent) : readable.formatted(.percent.precision(.fractionLength(1))), caption: String(localized: "readable"))
                        .frame(width: 104, height: 104)
                    VStack(alignment: .leading, spacing: 6) {
                        coverageRow("folder", "\(session.directoryCount.formatted()) folders · \(session.fileCount.formatted()) files")
                        coverageRow("internaldrive", "\(ByteFormat.string(session.allocatedSize, style: byteStyle)) on disk · \(ByteFormat.string(session.logicalSize, style: byteStyle)) logical")
                        if session.hardLinkDuplicateCount > 0 { coverageRow("link", "\(session.hardLinkDuplicateCount.formatted()) hard links counted once") }
                        if let duration = session.duration { coverageRow("timer", "Finished in \(formattedDuration(duration))") }
                        coverageRow("lock", denied > 0 ? "\(denied) locations not readable" : "No access gaps", tint: denied > 0 ? Theme.warning : nil)
                        if other + excluded > 0 { coverageRow("eye.slash", "\(other + excluded) skipped (excluded, other volumes, changed)") }
                    }
                }
                HStack {
                    if denied + other + excluded > 0 { Button("Show Gaps") { showingGaps = true }.buttonStyle(.glow(SidebarItem.overview.hue, prominent: false)) }
                    if denied > 0 { Button("Full Disk Access…") { SystemActions.openFullDiskAccessSettings() }.buttonStyle(.glow(.secondary, prominent: false)) }
                }
                if scannedOnStartupVolume != nil, let used = app.scan.startupVolume?.usedCapacity {
                    Text("\(ByteFormat.string(max(0, used - session.allocatedSize), style: byteStyle)) of used space is outside the scanned locations (macOS, other users, snapshots, protected data). PureMac does not guess its contents.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(8)
                }
            }
        }
    }

    private func coverageRow(_ symbol: String, _ text: String, tint: Color? = nil) -> some View {
        Label { Text(text).font(.callout) } icon: { Image(systemName: symbol).foregroundStyle(tint ?? .secondary) }
    }

    private var changesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Changes Since Previous Scan", systemImage: "arrow.up.arrow.down").font(.headline)
                let changes = app.scan.changes
                let maxDelta = Double(max(changes.map { abs($0.current - $0.previous) }.max() ?? 1, 1))
                ForEach(changes, id: \.path) { change in
                    let delta = change.current - change.previous
                    HStack(spacing: 10) {
                        Text((change.path as NSString).lastPathComponent).lineLimit(1).frame(width: 180, alignment: .leading)
                        GeometryReader { geo in
                            let half = geo.size.width / 2
                            let width = half * CGFloat(Double(abs(delta)) / maxDelta)
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Theme.track).frame(width: 1).offset(x: half)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(delta >= 0 ? Theme.increase : Theme.decrease)
                                    .frame(width: max(2, width), height: 8)
                                    .offset(x: delta >= 0 ? half + 1 : half - width - 1)
                            }
                            .frame(height: geo.size.height)
                        }
                        .frame(height: 12)
                        Text((delta >= 0 ? "+" : "−") + ByteFormat.string(abs(delta), style: byteStyle))
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                    }
                    .font(.callout)
                }
                HStack(spacing: 14) {
                    LegendChip(color: Theme.increase, label: String(localized: "Grew"))
                    LegendChip(color: Theme.decrease, label: String(localized: "Shrank"))
                    Spacer()
                    Text("Top-level folders, last two completed scans").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}


/// The Overview's main answer: how much can go now, safely, in one review.
struct FreeUpSpaceCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    let navigate: (SidebarItem) -> Void

    // MARK: Free up space

    /// The page's main answer: how much can go now, safely, in one review.
    var body: some View {
        let smart = app.smartClean
        let hue = SidebarItem.smartClean.hue
        let selectedBytes = smart.selectedBytes
        let held = smart.candidates.filter { $0.blockedReason != nil }.count
        return GlassCard(padding: 20, tint: hue) {
            HStack(spacing: 18) {
                IconTile(symbol: "sparkles", gradient: .tile(hue), size: 54)
                    .shadow(color: hue.opacity(0.45), radius: 12, y: 4)
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(text: "Free up space")
                    if smart.isAnalyzing {
                        RoundedRectangle(cornerRadius: 6).fill(Theme.track).frame(width: 220, height: 30).shimmer()
                        Text("Checking \(smart.catalog?.rules.count ?? 0) reviewed cleanup rules…").font(.callout).foregroundStyle(.secondary)
                    } else if smart.evaluation == nil {
                        Text("Find space you can safely reclaim").font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("Caches, logs and leftovers your apps recreate by themselves.").font(.callout).foregroundStyle(.secondary)
                    } else if selectedBytes > 0 {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            RollingText(text: ByteFormat.string(selectedBytes, style: byteStyle), font: .hero(30), rolls: true)
                            Text("ready to clean").font(.title3.weight(.semibold))
                        }
                        Text("\(smart.selectedCandidates.count) caches and logs your apps recreate on their own. Everything goes to the Trash first.")
                            .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        if held > 0 { heldBackLine }
                    } else {
                        Text(smart.candidates.isEmpty ? "Nothing to clean right now" : "Nothing selected")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Text(smart.candidates.isEmpty ? "No reviewed rule matched anything on this Mac." : "Open Smart Clean to choose what to remove.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 8) {
                    if smart.evaluation != nil, selectedBytes > 0 {
                        Button { app.cleanup.present(smart.makePlan()) } label: {
                            Label("Review & Clean", systemImage: "sparkles")
                        }
                        .buttonStyle(.glow(hue))
                        .controlSize(.large)
                        .disabled(app.cleanup.isRunning)
                        .help("Shows every item before anything moves to the Trash")
                    } else if smart.evaluation == nil {
                        Button { Task { await smart.analyze() } } label: { Label("Analyze", systemImage: "sparkles") }
                            .buttonStyle(.glow(hue))
                            .controlSize(.large)
                            .disabled(smart.isAnalyzing || smart.catalog == nil)
                    }
                    Button("See what’s included") { navigate(.smartClean) }.buttonStyle(.link)
                        .disabled(smart.evaluation == nil)
                }
            }
        }
    }

    /// "+ 2 GB more if Chrome and Opera quit" with a one-click way to include it.
    private var heldBackLine: some View {
        let smart = app.smartClean
        let apps = smart.heldBackApps
        let shown = apps.prefix(3).map(\.name)
        let names = apps.count > 3
            ? String(localized: "\(shown.joined(separator: ", ")) and \(apps.count - 3) more")
            : shown.formatted(.list(type: .and))
        return HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill").foregroundStyle(Theme.warning)
            Text(names.isEmpty
                 ? "+\(ByteFormat.string(smart.heldBackBytes, style: byteStyle)) more once some apps quit"
                 : "+\(ByteFormat.string(smart.heldBackBytes, style: byteStyle)) more if \(names) quit")
                .font(.callout).lineLimit(1)
            if !apps.isEmpty, app.apps.canQuitApps {
                Button("Quit & Include") { smart.quitHeldBackApps() }
                    .buttonStyle(.link)
                    .help("Asks these apps to quit normally (they may ask to save), then checks again. PureMac never force-quits.")
            }
        }
    }

}

/// Further ways to free space, each one click from its page.
struct OpportunityRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    let navigate: (SidebarItem) -> Void

    // MARK: Opportunities

    var body: some View {
        let smart = app.smartClean
        let apps = app.apps
        let threeMonthsAgo = Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? .distantPast
        let unused = apps.apps.filter { !$0.isProtected && (apps.lastUsed[$0.path].map { $0 < threeMonthsAgo } ?? false) }
        let unusedBytes = unused.compactMap { apps.totalSize(of: $0) }.reduce(0, +)
        let old = app.scan.oldLargeFiles
        return HStack(spacing: 14) {
            OpportunityTile(
                symbol: "eye", color: Theme.warning, title: "Needs your review",
                value: smart.evaluation.map { _ in ByteFormat.string(smart.reviewRequired.reduce(0) { $0 + $1.allocatedSize }, style: byteStyle) },
                detail: smart.evaluation.map { _ in String(localized: "\(smart.reviewRequired.count) logs, installers, build data") } ?? String(localized: "Logs, installers, build data"),
                isWorking: smart.isAnalyzing, actionTitle: "Review") { navigate(.smartClean) }
            OpportunityTile(
                symbol: "square.stack.3d.up.fill", color: SidebarItem.applications.hue, title: "Apps you don’t use",
                value: apps.loadedAt.map { _ in ByteFormat.string(unusedBytes, style: byteStyle) },
                detail: apps.loadedAt.map { _ in String(localized: "\(unused.count) not opened in 3 months") } ?? String(localized: "Sized with their data"),
                isWorking: apps.isLoading, actionTitle: "Review") {
                apps.filter = .unused
                apps.sortOrder = .size
                navigate(.applications)
            }
            OpportunityTile(
                symbol: "puzzlepiece.extension.fill", color: SidebarItem.orphans.hue, title: "Leftovers of removed apps",
                value: apps.orphansFoundAt.map { _ in ByteFormat.string(apps.orphans.reduce(0) { $0 + ($1.allocatedSize ?? 0) }, style: byteStyle) },
                detail: apps.orphansFoundAt.map { _ in String(localized: "\(apps.orphans.count) items with evidence") } ?? String(localized: "Evidence-based detection"),
                isWorking: apps.isFindingOrphans, actionTitle: "Review") { navigate(.orphans) }
            OpportunityTile(
                symbol: "clock.arrow.circlepath", color: SidebarItem.explorer.hue, title: "Large, untouched files",
                value: app.scan.latestSession.map { _ in ByteFormat.string(old.reduce(0) { $0 + $1.allocatedSize }, style: byteStyle) },
                detail: app.scan.latestSession.map { _ in String(localized: "\(old.count) files ≥ 100 MB, unchanged for a year") } ?? String(localized: "Needs a scan"),
                isWorking: app.scan.isBusy, actionTitle: app.scan.latestSession == nil ? "Scan" : "Review") {
                if app.scan.latestSession == nil {
                    app.scan.start()
                } else {
                    app.explorer.mode = .oldFiles
                    navigate(.explorer)
                }
            }
        }
    }

}

/// A tile summarizing one cleanup opportunity.
struct OpportunityTile: View {
    let symbol: String
    let color: Color
    let title: LocalizedStringKey
    let value: String?
    let detail: String
    let isWorking: Bool
    let actionTitle: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        GlassCard(padding: 16, tint: color) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    IconTile(symbol: symbol, gradient: .tile(color), size: 32)
                        .shadow(color: color.opacity(0.4), radius: 8, y: 3)
                    Spacer()
                    Button(action: action) { Text(actionTitle) }
                        .buttonStyle(.glow(color, prominent: value != nil))
                        .disabled(isWorking)
                }
                Text(title).font(.subheadline.weight(.semibold))
                Group {
                    if isWorking {
                        RoundedRectangle(cornerRadius: 6).fill(Theme.track).frame(width: 120, height: 26).shimmer()
                    } else if let value {
                        RollingText(text: value, font: .metric(26))
                    } else {
                        Text("—").font(.metric(26)).foregroundStyle(.tertiary)
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Celebrates a finished scan with a self-drawing checkmark, then gets out of the way.
struct ScanCompleteBanner: View {
    let session: ScanSession
    let onDismiss: () -> Void
    @State private var drawn = false
    @MotionReduced private var reduceMotion

    var body: some View {
        GlassCard(padding: 14, tint: Theme.good) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Theme.good.opacity(0.18))
                    CheckmarkShape().trim(from: 0, to: drawn || reduceMotion ? 1 : 0)
                        .stroke(Theme.good, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .padding(10)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan complete").font(.headline)
                    Text("\(session.fileCount.formatted()) files in \(session.directoryCount.formatted()) folders · \(formattedDuration(session.duration ?? 0))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { onDismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Dismiss")
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6).delay(0.15)) { drawn = true }
        }
        .task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            onDismiss()
        }
    }
}

struct CheckmarkShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.1))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.1))
        return path
    }
}

/// The folder an item is in, for list rows (`~/Library`, `/System/Library`); `nil` at the top of the disk.
func locationCaption(_ record: FileRecord) -> String? {
    let parent = (record.path as NSString).deletingLastPathComponent
    return parent == "/" || parent.isEmpty ? nil : abbreviate(parent)
}

/// The startup disk's name ("Macintosh HD"), shown for the root of a whole-disk scan.
private let startupDiskName: String =
    (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "Macintosh HD"

func abbreviate(_ path: String) -> String {
    let home = PathTools.userHome
    if path == home { return "~" }
    if path == PathTools.dataVolume { return startupDiskName }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

/// Before a whole-disk scan without Full Disk Access: macOS would ask for access place by place
/// (Music, Photos, Downloads…), and the scan waits for every answer.
struct EntireDiskAccessCheck: ViewModifier {
    @Binding var isPresented: Bool
    let scan: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog("Allow Full Disk Access first?", isPresented: $isPresented) {
            Button("Open Full Disk Access Settings…") { SystemActions.openFullDiskAccessSettings() }
            Button("Scan Anyway") { scan() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Without Full Disk Access, macOS asks separately for places like Music, Photos and Downloads, and the scan waits for each answer. Places you don’t allow are listed as gaps.")
        }
    }
}

struct ScanButton: View {
    @Environment(AppModel.self) private var app
    @State private var askForAccess = false
    var body: some View {
        if app.scan.isBusy {
            Button(role: .cancel) { app.scan.cancel() } label: {
                Label(app.scan.phase == .cancelling ? "Stopping…" : "Stop Scan", systemImage: "stop.fill")
            }
            .buttonStyle(.glow(Theme.critical, prominent: false))
            .disabled(app.scan.phase == .cancelling)
        } else {
            HStack(spacing: 8) {
                // The App Store edition scans the folders it was given; there is no whole-disk choice.
                if !app.access.isRequired { ScanScopeMenu() }
                Button {
                    if entireDisk, FullDiskAccess.status() == .denied { askForAccess = true } else { app.scan.start() }
                } label: {
                    Label(title, systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(.glow(SidebarItem.overview.hue))
                .disabled(app.store == nil)
                .help(entireDisk ? "Scan the entire startup disk (⌘R)" : "Scan your home folder and the folders chosen in Settings (⌘R)")
            }
            .modifier(EntireDiskAccessCheck(isPresented: $askForAccess) { app.scan.start() })
        }
    }

    private var entireDisk: Bool { app.settings.scanEntireDataVolume && !app.access.isRequired }

    /// "Rescan" repeats the last scan; a new or different scope says what will be scanned.
    private var title: LocalizedStringKey {
        if app.scan.latestSession != nil, app.scan.latestScanCoveredEntireDisk == entireDisk { return "Rescan" }
        return entireDisk ? "Scan Entire Disk" : "Scan Home Folder"
    }
}

/// What the next scan covers: the home folder (default) or the entire startup disk. Both choices
/// are visible side by side, so it reads as a choice; it is the same setting as Settings → Scanning.
struct ScanScopeMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        HStack(spacing: 6) {
            Text("Scan").font(.callout).foregroundStyle(.secondary)
            Picker("What to scan", selection: $settings.scanEntireDataVolume) {
                Label("Home Folder", systemImage: "house").tag(false)
                Label("Entire Disk", systemImage: "internaldrive").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .help("Choose what PureMac scans: your home folder, or everything on the startup disk — apps, shared data and other system-managed files too.")
    }
}
