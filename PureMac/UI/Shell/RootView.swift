import AppKit
import PureMacKit
import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case overview
    case smartClean
    case explorer
    case applications
    case orphans
    case duplicates
    case developer
    case performance
    case history

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .smartClean: "Smart Clean"
        case .explorer: "Storage Explorer"
        case .applications: "Applications"
        case .orphans: "Orphaned Remnants"
        case .duplicates: "Duplicates"
        case .developer: "Developer Storage"
        case .performance: "Performance"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .smartClean: "sparkles"
        case .explorer: "circle.hexagongrid.fill"
        case .applications: "square.stack.3d.up.fill"
        case .orphans: "puzzlepiece.extension.fill"
        case .duplicates: "doc.on.doc.fill"
        case .developer: "hammer.fill"
        case .performance: "waveform.path.ecg"
        case .history: "clock.arrow.circlepath"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @State private var selection: SidebarItem? = .overview
    @State private var showOnboarding = false
    /// Screens already shown this session (their intro animations don't replay).
    @State private var visited: Set<SidebarItem> = []
    /// The launch work below runs once per window, not again after the subscribe screen.
    @State private var launched = false

    var body: some View {
        // App Store copies: the subscribe screen until StoreKit confirms the subscription.
        // Onboarding, folder access and everything else come after it. A cleanup that is moving
        // files when a subscription lapses finishes on screen first.
        if app.subscription.isLocked && !app.cleanup.isRunning {
            SubscribeView()
        } else {
            mainWindow
        }
    }

    private var mainWindow: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            ZStack {
                // One backdrop for the whole detail column; only its hue changes on navigation
                // (crossfaded in the render server). No content crossfade: rendering two full
                // screens per frame made navigation stutter.
                AuroraBackdrop(hue: (selection ?? .overview).hue)
                // Every state is wrapped in the page scaffold: when the first page is a plain view,
                // the sidebar list never draws.
                if let error = app.startupError {
                    ScreenScaffold(item: .overview) {
                        ContentUnavailableView("PureMac can’t start", systemImage: "externaldrive.badge.xmark", description: Text(error))
                    }
                } else if app.isDemo && !app.demoReady {
                    ScreenScaffold(item: .overview) { ProgressView().frame(maxWidth: .infinity) }
                } else if !app.access.hasHomeAccess {
                    AccessGateView()
                } else {
                    detail(for: selection ?? .overview)
                        .environment(\.playsIntroAnimations, !visited.contains(selection ?? .overview))
                        .id(selection)
                        .task(id: selection) {
                            // Mark the screen as seen once its intro has had time to play.
                            let shown = selection ?? .overview
                            try? await Task.sleep(nanoseconds: 900_000_000)
                            if !Task.isCancelled { visited.insert(shown) }
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            guard !launched else { return }
            launched = true
            #if DEBUG
            // Development aid: `-PureMacInitialSection orphans` opens a section at launch.
            if let item = DevelopmentHooks.initialSection {
                selection = item
                app.settings.hasCompletedOnboarding = true
            }
            #endif
            await app.bootstrap()
            await app.explorer.sessionDidChange()
            #if DEBUG
            if app.isDemo {
                await DemoContent.install(into: app)
                await app.scan.reload()
                app.demoReady = true
                if let scene = UserDefaults.standard.string(forKey: "PureMacDemoScene") {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    DemoContent.apply(scene: scene, to: app)
                }
            }
            #endif
            if !app.settings.hasCompletedOnboarding && !app.isHostingTests { showOnboarding = true }
            #if DEBUG
            if let pane = UserDefaults.standard.string(forKey: "PureMacOpenSettings") {
                UserDefaults.standard.set(pane, forKey: "settingsPane")
                openSettings()
            }
            await DevelopmentHooks.afterLaunch(app: app) { selection = $0 }
            #endif
        }
        .sheet(item: Binding(get: { app.cleanup.activePlan }, set: { if $0 == nil { app.cleanup.dismiss() } })) { plan in
            CleanupReviewSheet(plan: plan)
                .environment(app)
                .environment(\.byteStyle, app.settings.byteStyle)
        }
        .sheet(item: Binding(get: { app.inspectedRecord }, set: { app.inspectedRecord = $0 })) { record in
            FileInfoSheet(record: record)
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView { showOnboarding = false }
                .environment(app)
        }
    }


    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        switch item {
        case .overview: OverviewView(navigate: { selection = $0 })
        case .smartClean: SmartCleanView()
        case .explorer: ExplorerView()
        case .applications: ApplicationsView()
        case .orphans: OrphansView()
        case .duplicates: DuplicatesView()
        case .developer: DeveloperView()
        case .performance: PerformanceView(navigate: { selection = $0 })
        case .history: HistoryView()
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            BrandHeader()
                .listRowSeparator(.hidden)
                .selectionDisabled()
                .padding(.bottom, 6)
            Section("Storage") {
                row(.overview)
                row(.smartClean, badge: smartCleanBadge)
                row(.explorer)
            }
            Section("Applications") {
                row(.applications)
                row(.orphans, badge: app.apps.orphansFoundAt != nil && !app.apps.orphans.isEmpty ? "\(app.apps.orphans.count)" : nil)
            }
            Section("Tools") {
                row(.duplicates)
                row(.developer)
                row(.performance)
            }
            Section("Activity") {
                row(.history)
            }
        }
        .safeAreaInset(edge: .bottom) { ScanStatusFooter().padding(10) }
    }

    private var smartCleanBadge: String? {
        guard app.smartClean.evaluation != nil else { return nil }
        let bytes = app.smartClean.recommended.filter { $0.blockedReason == nil }.reduce(0) { $0 + $1.allocatedSize }
        return bytes > 0 ? ByteFormat.compact(bytes, style: byteStyle) : nil
    }

    private func row(_ item: SidebarItem, badge: String? = nil) -> some View {
        HStack(spacing: 9) {
            IconTile(symbol: item.symbol, gradient: item.gradient, size: 22)
            // Long names (German, Finnish, Russian…) wrap or shrink slightly instead of truncating.
            Text(item.title).lineLimit(2).minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            if let badge {
                Text(badge)
                    .font(.caption2.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(item.hue.opacity(0.28), in: Capsule())
                    .foregroundStyle(.primary)   // stays readable on the selected (accent) row
            }
        }
        .tag(item)
        .accessibilityElement(children: .combine)
    }
}

private struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: Brand.appIcon)
                .resizable().frame(width: 34, height: 34)
                .shadow(color: Theme.glow.opacity(0.35), radius: 6, y: 2)
            VStack(alignment: .leading, spacing: 0) {
                Text("PureMac").font(.system(size: 15, weight: .bold, design: .rounded))
                Text("by OpenAppBox").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Compact scan status under the sidebar, with a live ring while scanning.
struct ScanStatusFooter: View {
    @Environment(AppModel.self) private var app
    @MotionReduced private var reduceMotion

    var body: some View {
        let scan = app.scan
        HStack(spacing: 10) {
            ZStack {
                if !scan.isBusy { Circle().stroke(Theme.track, lineWidth: 3) }
                if scan.isBusy {
                    SpinnerRing().frame(width: 16, height: 16)
                } else {
                    Image(systemName: scan.latestSession == nil ? "circle.dashed" : "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(scan.latestSession == nil ? Color.secondary : Theme.good)
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                switch scan.phase {
                case .scanning, .cancelling:
                    Text(scan.phase == .cancelling ? "Stopping…" : "Scanning").font(.caption.weight(.semibold))
                    RollingText(text: "\(scan.progress.filesVisited.formatted()) files", font: .caption)
                        .foregroundStyle(.secondary)
                case .idle:
                    if let finished = scan.latestSession?.finishedAt {
                        Text("Index ready").font(.caption.weight(.semibold))
                        Text("Scanned \(finished.relativeDescription)").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Not scanned yet").font(.caption.weight(.semibold))
                        Text("Press ⌘R to scan").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
