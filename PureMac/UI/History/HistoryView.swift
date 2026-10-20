import PureMacKit
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    @State private var tab = 0

    var body: some View {
        ScreenScaffold(item: .history, scrolls: false) {
            ModuleHeader(item: .history, subtitle: "Every cleanup and scan, stored only on this Mac. Put items back from the Trash.") {
                Picker("History", selection: $tab) {
                    Text("Cleanups").tag(0)
                    Text("Scans").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
            .entrance()
            if tab == 0, !app.history.operations.isEmpty { summary.entrance(0.03) }
            GlassCard(padding: 0) {
                Group {
                    if tab == 0 { cleanups } else { ScanHistoryView() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .entrance(0.05)
        }
        .navigationTitle("History")
    }

    /// What PureMac has done so far, in one line a casual user can read.
    private var summary: some View {
        let ops = app.history.operations
        let moved = ops.reduce(Int64(0)) { $0 + $1.bytesMovedToTrash }
        let items = ops.reduce(0) { $0 + $1.movedCount }
        return GlassCard(padding: 16, tint: SidebarItem.history.hue) {
            HStack(spacing: 28) {
                StatBlock(value: ByteFormat.string(moved, style: byteStyle), label: "Moved to the Trash in total", tint: Theme.good)
                StatBlock(value: items.formatted(), label: "Items")
                StatBlock(value: ops.count.formatted(), label: ops.count == 1 ? "Cleanup" : "Cleanups")
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Open Trash") { SystemActions.openTrash() }.buttonStyle(.glow(SidebarItem.history.hue, prominent: false))
                    Text("Space returns when you empty the Trash. PureMac never empties it for you.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var cleanups: some View {
        @Bindable var history = app.history
        return Group {
            if let error = history.loadError {
                ContentUnavailableView("History unavailable", systemImage: "exclamationmark.triangle", description: Text(verbatim: error))
            } else if history.operations.isEmpty {
                ContentUnavailableView("No cleanup history", systemImage: "clock.arrow.circlepath",
                                       description: Text("Every cleanup you run is recorded here, on this Mac only, so you can see what was moved and put items back."))
            } else {
                HSplitView {
                    List(history.operations, selection: $history.selectedOperationID) { op in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(op.title).fontWeight(.medium)
                            Text(op.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            Text("\(op.movedCount) moved · \(op.skippedCount + op.failedCount) not moved · \(ByteFormat.string(op.bytesMovedToTrash, style: byteStyle))")
                                .font(.caption).foregroundStyle(.secondary)
                            if op.status == "interrupted" {
                                Text("Interrupted — PureMac quit during this operation").font(.caption).foregroundStyle(.orange)
                            } else if op.status == "incomplete" {
                                Text("Stopped — PureMac could not save its history").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .tag(op.id)
                    }
                    .scrollContentBackground(.hidden)
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                    detail.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task {
            await history.reload()
            if history.selectedOperationID == nil { history.selectedOperationID = history.operations.first?.id }
        }
        .onChange(of: history.selectedOperationID) { _, id in
            if let id { Task { await history.loadItems(id) } }
        }
    }

    @ViewBuilder
    private var detail: some View {
        let history = app.history
        if let id = history.selectedOperationID, let op = history.operations.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 10) {
                Text(op.title).font(.title3.weight(.semibold))
                Text("\(op.mode.displayName) · \(op.startedAt.formatted(date: .long, time: .shortened))").foregroundStyle(.secondary)
                HStack(spacing: 24) {
                    Metric(value: ByteFormat.string(op.bytesIdentified, style: byteStyle), caption: "Identified")
                    Metric(value: ByteFormat.string(op.bytesMovedToTrash, style: byteStyle), caption: "Moved to Trash")
                    if let before = op.freeSpaceBefore, let after = op.freeSpaceAfter {
                        let delta = after - before
                        Metric(value: (delta >= 0 ? "+" : "−") + ByteFormat.string(abs(delta), style: byteStyle), caption: "Observed free-space change")
                    }
                }
                let restorable = (history.items[id] ?? []).filter { $0.status == .movedToTrash && $0.trashPath != nil }
                if restorable.count > 1 {
                    Button { Task { await app.history.restore(restorable) } } label: {
                        Label("Put Back All \(restorable.count) Items", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.glow(SidebarItem.history.hue, prominent: false))
                    .disabled(app.cleanup.isRunning || history.isRestoring)
                    .help("Moves every item of this cleanup that is still in the Trash back to where it was.")
                }
                if let message = history.message {
                    NoticeView(tone: history.messageIsWarning ? .warning : .info, title: LocalizedStringKey(message.markdownEscaped))
                }
                if op.status == "interrupted" || op.status == "incomplete" || (history.items[id] ?? []).contains(where: { $0.status == .pending }) {
                    HStack(alignment: .firstTextBaseline) {
                        NoticeView(tone: .warning, title: "Some items were not recorded",
                                   message: "PureMac stopped before it could record what happened to the items marked “Not recorded”. They may still be where they were, or in the Trash. To put one back, open the Trash in Finder, select it and choose File → Put Back.")
                        Button("Open Trash") { SystemActions.openTrash() }
                    }
                }
                if !op.hasDetails {
                    Text("Detailed history was off for this operation, so file paths were not recorded.").font(.caption).foregroundStyle(.secondary)
                }
                List(history.items[id] ?? []) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.originalPath.map(abbreviate) ?? String(localized: "Item \(item.sequence + 1)")).lineLimit(1).truncationMode(.middle)
                            Text(item.status.displayName + (item.message.map { " — \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                            if item.status == .movedToTrash, item.trashPath == nil {
                                Text("Its Trash location was not recorded. Use Put Back in Finder’s Trash.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        SizeText(item.allocatedSize).foregroundStyle(.secondary)
                        if item.status == .movedToTrash, item.trashPath != nil {
                            Button("Put Back") { Task { await app.history.restore(item) } }
                                .disabled(app.cleanup.isRunning || history.isRestoring)
                        }
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                Text("Put Back moves an item from the Trash to where it was, only if nothing else is there now and the Trash item is the same one PureMac moved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        } else {
            ContentUnavailableView("Select an operation", systemImage: "clock")
        }
    }
}

extension CleanupItemStatus {
    var displayName: String {
        switch self {
        case .pending: String(localized: "Not recorded")
        case .movedToTrash: String(localized: "Moved to Trash")
        case .skipped: String(localized: "Skipped")
        case .failed: String(localized: "Failed")
        case .restored: String(localized: "Put back")
        }
    }
}
