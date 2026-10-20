import PureMacKit
import SwiftUI

/// Review → confirm → progress → result, for every destructive action in PureMac.
struct CleanupReviewSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    let plan: CleanupPlan
    @State private var confirming = false
    /// Items the user unticked in this review; they stay where they are.
    @State private var excluded: Set<CleanupCandidate.ID> = []

    var body: some View {
        let coordinator = app.cleanup
        VStack(alignment: .leading, spacing: 14) {
            switch coordinator.stage {
            case .review: review
            case .running(let done, let total): running(done: done, total: total)
            case .finished(let result): CleanupResultView(result: result)
            }
        }
        .padding(24)
        .frame(width: 780, height: 600)
        .background(AuroraBackdrop(hue: SidebarItem.smartClean.hue, intensity: 0.6))
        .interactiveDismissDisabled(coordinator.isRunning)
    }

    // MARK: Review

    /// The plan minus anything the user unticked here.
    private var included: CleanupPlan {
        var filtered = plan
        filtered.items = plan.items.filter { !excluded.contains($0.id) }
        return filtered
    }

    /// Plain-language groups for the summary strip: by app for uninstalls, otherwise by category.
    private var summaryGroups: [(label: String, symbol: String, color: Color, bytes: Int64, count: Int)] {
        let byApp = plan.mode == .uninstallKeepData || plan.mode == .uninstallComplete
        let groups = Dictionary(grouping: included.items) { byApp ? ($0.relatedAppName ?? $0.category.displayName) : $0.category.displayName }
        return groups.map { key, items in
            let first = items[0]
            return (key, byApp ? "app.fill" : first.category.symbolName, first.category.tint, items.reduce(0) { $0 + $1.allocatedSize }, items.count)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    private var review: some View {
        let chosen = included
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                IconTile(symbol: "checklist", gradient: .tile(SidebarItem.smartClean.hue), size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review: \(plan.title)").font(.system(size: 22, weight: .bold, design: .rounded)).lineLimit(1)
                    Text(plan.mode.displayName).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    RollingText(text: ByteFormat.string(chosen.identifiedAllocatedBytes, style: byteStyle), font: .metric(26))
                    Text("\(chosen.items.count) of \(plan.items.count) items").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if summaryGroups.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(summaryGroups.prefix(8), id: \.label) { group in
                            HStack(spacing: 6) {
                                Image(systemName: group.symbol).foregroundStyle(group.color)
                                Text(group.label).lineLimit(1)
                                Text(ByteFormat.string(group.bytes, style: byteStyle)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(group.color.opacity(0.12), in: Capsule())
                        }
                    }
                }
            }
            Text("Everything checked moves to the Trash, where you can put it back until you empty it. Nothing is permanently deleted. Untick anything you want to keep.")
                .foregroundStyle(.secondary)
                .lineLimit(8)
            if plan.items.contains(where: { $0.warning != nil }) {
                NoticeView(tone: .warning, title: "Some items hold important data", message: "Read the warnings below before continuing.")
            }
            List(plan.items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Toggle(isOn: Binding(get: { !excluded.contains(item.id) },
                                         set: { on in if on { excluded.remove(item.id) } else { excluded.insert(item.id) } })) { EmptyView() }
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("Include \(item.name)")
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            FileIcon(path: item.path)
                            Text(item.relatedAppName.map { "\($0) — \(item.name)" } ?? item.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                            RiskBadge(risk: item.risk)
                            Spacer()
                            SizeText(item.allocatedSize).foregroundStyle(.secondary)
                        }
                        Text(abbreviate(item.path)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Text(item.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if let impact = item.regenerationImpact { Text("Impact: \(impact)").font(.caption).foregroundStyle(.secondary) }
                        if let warning = item.warning {
                            Label(warning, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .opacity(excluded.contains(item.id) ? 0.45 : 1)
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Reveal in Finder") { SystemActions.revealInFinder([item.path]) }
                    Button("Copy Path") { SystemActions.copyToPasteboard(item.path) }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .scrollContentBackground(.hidden)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            if !app.cleanup.rejected.isEmpty {
                DisclosureGroup("\(app.cleanup.rejected.count) items were not included for safety reasons") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(app.cleanup.rejected, id: \.path) { item in
                                Text("\(abbreviate(item.path)) — \(item.reason)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxHeight: 80)
                }
            }
            Text("Freed space depends on emptying the Trash. APFS clones, hard links and local snapshots can make the actual change smaller than the identified size.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Copy Dry-Run Plan") {
                    SystemActions.copyToPasteboard(chosen.dryRunReport { ByteFormat.string($0, style: byteStyle) })
                }
                .help("Copies the full plan as text. Nothing is changed.")
                if !excluded.isEmpty {
                    Button("Include All") { excluded = [] }
                }
                Spacer()
                Button("Cancel", role: .cancel) { app.cleanup.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move \(chosen.items.count) Items to Trash…") { confirming = true }
                    .buttonStyle(.glow(SidebarItem.smartClean.hue))
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.items.isEmpty || app.cleanup.isRunning)
            }
        }
        .confirmationDialog("Move \(chosen.items.count) items to the Trash?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { app.cleanup.confirm(included) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(ByteFormat.string(chosen.identifiedAllocatedBytes, style: byteStyle)) identified. Each item is checked again right before it is moved; anything that changed is skipped.")
        }
    }

    private func running(done: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            HStack(spacing: 28) {
                ScannerCore(intensity: 0.8, cancelling: false) {
                    RollingText(text: "\(done)/\(total)", font: .hero(26))
                }
                .frame(width: 200, height: 200)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Moving items to the Trash…").font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Each item is checked again right before it moves. Anything that changed is skipped.")
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(done), total: Double(max(total, 1))).tint(SidebarItem.smartClean.hue)
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button("Stop After Current Item") { app.cleanup.cancelRunning() }
            }
        }
    }
}

struct CleanupResultView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    let result: CleanupResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 24) {
                CompletionBadge(fraction: Double(result.movedCount) / Double(max(result.outcomes.count, 1)),
                                success: result.failedCount == 0 && !result.wasCancelled && result.journalProblem == nil)
                    .frame(width: 120, height: 120)
                VStack(alignment: .leading, spacing: 8) {
                    Text(result.wasCancelled ? "Stopped" : (result.failedCount == 0 && result.journalProblem == nil ? "Moved to the Trash" : "Finished with issues"))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    HStack(spacing: 24) {
                        StatBlock(value: ByteFormat.string(result.bytesMovedToTrash, style: byteStyle), label: "Size moved to Trash", tint: Theme.good)
                        StatBlock(value: "\(result.movedCount)", label: "Moved")
                        StatBlock(value: "\(result.skippedCount)", label: "Skipped", tint: result.skippedCount > 0 ? Theme.warning : nil)
                        StatBlock(value: "\(result.failedCount)", label: "Failed", tint: result.failedCount > 0 ? Theme.critical : nil)
                    }
                    if let delta = result.observedFreeSpaceDelta {
                        Text("Observed free-space change: \((delta >= 0 ? "+" : "−") + ByteFormat.string(abs(delta), style: byteStyle))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if let problem = result.journalProblem {
                NoticeView(tone: .warning, title: "History could not be saved completely",
                           message: LocalizedStringKey(problem.markdownEscaped))
            }
            Text("Items in the Trash still use disk space until you empty it. The observed free-space change also reflects other activity on your Mac, APFS snapshots and clones, so it can differ from the size moved.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(8)
            List(result.outcomes) { outcome in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: symbol(outcome.status)).foregroundStyle(color(outcome.status))
                        .accessibilityLabel(outcome.status.displayName)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(abbreviate(outcome.path)).lineLimit(1).truncationMode(.middle)
                        if let message = outcome.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    SizeText(outcome.allocatedSize).foregroundStyle(.secondary)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            if result.outcomes.contains(where: { $0.message?.contains("App Management") == true }) {
                Button("Open App Management Settings") { SystemActions.openAppManagementSettings() }
            }
            HStack {
                Button("Open Trash") { SystemActions.openTrash() }
                Text("PureMac never empties the Trash for you.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { app.cleanup.dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func symbol(_ status: CleanupItemStatus) -> String {
        switch status {
        case .movedToTrash: "trash.circle.fill"
        case .skipped: "arrow.uturn.right.circle"
        case .failed: "xmark.circle.fill"
        case .restored: "arrow.uturn.backward.circle.fill"
        case .pending: "clock"
        }
    }

    private func color(_ status: CleanupItemStatus) -> Color {
        switch status {
        case .movedToTrash: .green
        case .skipped: .orange
        case .failed: .red
        case .restored, .pending: .secondary
        }
    }
}


/// Animated completion ring with a self-drawing checkmark and a one-time spark burst.
struct CompletionBadge: View {
    let fraction: Double
    let success: Bool
    @MotionReduced private var reduceMotion
    @State private var progress = 0.0
    @State private var burst = false

    var body: some View {
        let color = success ? Theme.good : Theme.warning
        ZStack {
            if !reduceMotion {
                ForEach(0..<12, id: \.self) { i in
                    Capsule()
                        .fill(i.isMultiple(of: 2) ? color : Theme.brandTeal)
                        .frame(width: 3, height: 10)
                        .offset(y: burst ? -78 : -40)
                        .opacity(burst ? 0 : 1)
                        .rotationEffect(.degrees(Double(i) * 30))
                }
            }
            Circle().stroke(Theme.track, lineWidth: 10)
            Circle()
                .trim(from: 0, to: progress * max(0.02, fraction))
                .stroke(AngularGradient(colors: [color.mix(with: .white, by: 0.2), color], center: .center),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.5), radius: 8)
            Image(systemName: success ? "checkmark" : "exclamationmark")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(color)
                .scaleEffect(progress > 0.9 ? 1 : 0.4)
                .opacity(progress > 0.5 ? 1 : 0)
        }
        .onAppear {
            if reduceMotion { progress = 1; return }
            withAnimation(.easeOut(duration: 0.9)) { progress = 1 }
            withAnimation(.easeOut(duration: 0.9).delay(0.7)) { burst = true }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: progress)
        .accessibilityLabel(success ? "Completed" : "Completed with issues")
    }
}
