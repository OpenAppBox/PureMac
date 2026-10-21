import PureMacKit
import SwiftUI

/// One app and the associations found for it.
struct UninstallTarget: Identifiable {
    let app: InstalledApp
    let associations: [AppAssociation]
    var id: String { app.id }
}

/// Item-by-item uninstall review for one or several apps, with the two removal modes.
struct UninstallSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.byteStyle) private var byteStyle
    let targets: [UninstallTarget]

    @State private var mode: CleanupPlanner.UninstallMode = .keepPersonalData
    @State private var candidates: [String: [CleanupCandidate]] = [:]
    @State private var selection: Set<CleanupCandidate.ID> = []
    @State private var showsFiles = false

    private var title: String {
        targets.count == 1 ? String(localized: "Uninstall \(targets[0].app.name)") : String(localized: "Uninstall \(targets.count) Apps")
    }

    var body: some View {
        let all = targets.flatMap { candidates[$0.id] ?? [] }
        let chosen = all.filter { selection.contains($0.id) }
        let running = targets.map(\.app).filter { app.apps.isRunning($0) }
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                HStack(spacing: -10) {
                    ForEach(targets.prefix(5)) { FileIcon(path: $0.app.path, size: 40) }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.title2.weight(.semibold))
                    if targets.count > 1 {
                        Text(targets.map(\.app.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    RollingText(text: ByteFormat.string(chosen.reduce(0) { $0 + $1.allocatedSize }, style: byteStyle), font: .metric(24))
                    Text("\(chosen.count) of \(all.count) items").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Picker("Mode", selection: $mode) {
                Text("Remove app, keep personal data").tag(CleanupPlanner.UninstallMode.keepPersonalData)
                Text("Complete removal (including app settings and data)").tag(CleanupPlanner.UninstallMode.complete)
            }
            .pickerStyle(.radioGroup)
            Text(mode == .keepPersonalData
                 ? "Removes the app plus caches, logs and saved window state. Settings, documents and app data stay, so a reinstall picks up where you left off."
                 : "Also removes the app’s settings, sandbox container and support data that PureMac could confirm. Anything stored only there — settings, local libraries, offline content — is lost once you empty the Trash.")
                .font(.callout).foregroundStyle(.secondary).lineLimit(8)
            if !running.isEmpty {
                HStack {
                    NoticeView(tone: .warning, title: running.count == 1 ? "\(running[0].name) is running" : "\(running.map(\.name).formatted(.list(type: .and))) are running",
                               message: "Quit them first; running apps are skipped.")
                    Button(running.count == 1 ? "Show \(running[0].name)" : "Show \(running.count) Apps") {
                        app.apps.bringToFront(running)
                    }
                    .help("Brings these apps to the front so you can quit them (⌘Q).")
                }
            }
            // Casual view: one line per app. Every file stays one click away.
            List {
                ForEach(targets) { target in
                    let items = candidates[target.id] ?? []
                    Section {
                        if showsFiles || targets.count == 1 {
                            ForEach(items) { candidate in row(candidate, associations: target.associations) }
                        }
                    } header: {
                        appHeader(target, items: items)
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack {
                if targets.count > 1 {
                    Toggle("Show every file", isOn: $showsFiles).toggleStyle(.switch).controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Review Plan…") {
                    let plan = CleanupPlanner.plan(mode: mode == .complete ? .uninstallComplete : .uninstallKeepData,
                                                   title: title, selected: chosen)
                    dismiss()
                    app.cleanup.present(plan)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || app.cleanup.isRunning)
            }
        }
        .padding(20)
        .frame(width: 760, height: 620)
        .onAppear(perform: rebuild)
        .onChange(of: mode) { _, _ in rebuild() }
    }

    private func appHeader(_ target: UninstallTarget, items: [CleanupCandidate]) -> some View {
        let selectable = items.filter { $0.blockedReason == nil }
        let picked = selectable.filter { selection.contains($0.id) }
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { !picked.isEmpty && picked.count == selectable.count },
                                 set: { on in for c in selectable { if on { selection.insert(c.id) } else { selection.remove(c.id) } } })) { EmptyView() }
                .toggleStyle(.checkbox)
                .disabled(selectable.isEmpty)
                .accessibilityLabel("Include all items of \(target.app.name)")
            FileIcon(path: target.app.path, size: 18)
            Text(target.app.name).fontWeight(.semibold)
            if app.apps.isRunning(target.app) { Text("running").font(.caption2).foregroundStyle(Theme.warning) }
            Spacer()
            Text("\(picked.count) of \(items.count) · \(ByteFormat.string(picked.reduce(0) { $0 + $1.allocatedSize }, style: byteStyle))")
                .monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func row(_ candidate: CleanupCandidate, associations: [AppAssociation]) -> some View {
        HStack(alignment: .top) {
            SetCheckbox(id: candidate.id, selection: $selection, label: String(localized: "Include \(candidate.name)"), isDisabled: candidate.blockedReason != nil)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(candidate.title).fontWeight(.medium)
                    if case .uninstall(_, let kind) = candidate.source, let association = associations.first(where: { $0.path == candidate.path }) {
                        ConfidenceBadge(confidence: association.confidence)
                        if kind.holdsPersonalData { Text("personal data").font(.caption2).foregroundStyle(.orange) }
                    }
                }
                Text(abbreviate(candidate.path)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(candidate.reason).font(.caption).foregroundStyle(.secondary)
                if let warning = candidate.warning, candidate.blockedReason == nil {
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                if let blocked = candidate.blockedReason {
                    Label(blocked, systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            SizeText(candidate.allocatedSize).foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Reveal in Finder") { SystemActions.revealInFinder([candidate.path]) }
            Button("Copy Path") { SystemActions.copyToPasteboard(candidate.path) }
        }
    }

    private func rebuild() {
        var built: [String: [CleanupCandidate]] = [:]
        for target in targets {
            built[target.id] = CleanupPlanner.uninstallCandidates(app: target.app, associations: target.associations, mode: mode)
        }
        candidates = built
        selection = Set(built.values.flatMap { $0 }.filter(\.isPreselected).map(\.id))
    }
}
