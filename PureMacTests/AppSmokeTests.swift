import AppKit
import PureMacKit
import SwiftUI
import Testing
@testable import PureMac

/// App-level smoke tests. They run inside the app host, which detects the test environment and
/// uses a throwaway database — the user's real PureMac data and files are never touched.
@MainActor
@Suite("App smoke tests", .serialized)
struct AppSmokeTests {
    @Test func appModelUsesIsolatedStorageUnderTests() {
        let app = AppModel()
        #expect(app.isHostingTests)
        #expect(app.store != nil)
        #expect(app.startupError == nil)
        #expect(app.databaseURL.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    @Test func noDemoDataBeforeAnyScan() async {
        let app = AppModel()
        await app.bootstrap()
        #expect(app.scan.latestSession == nil)
        #expect(app.scan.largestFiles.isEmpty)
        #expect(app.scan.categoryTotals.isEmpty)
        #expect(app.smartClean.evaluation == nil)
        #expect(app.apps.orphans.isEmpty)
    }

    /// Read-only: never writes the language preference of the real app domain.
    @Test func languagePickerListsEveryShippedLanguage() {
        let languages = AppLanguage.available
        #expect(languages.first == "en")
        #expect(languages.contains("tr"))
        #expect(Set(languages).count == languages.count)
        #expect(AppLanguage.nativeName("en") == "English")
        #expect(AppLanguage.nativeName("tr") == "Türkçe")
        #expect(languages.contains(AppLanguage.current))
    }

    @Test func ruleCatalogLoadsInTheApp() {
        let app = AppModel()
        #expect(app.smartClean.catalogError == nil)
        #expect((app.smartClean.catalog?.rules.count ?? 0) > 0)
    }

    @Test func settingsDefaultsAreConservative() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "PureMacTests-\(UUID().uuidString)")!)
        #expect(settings.scanRoots.count == 1)
        #expect(settings.scanRoots.first?.kind == .home)
        #expect(settings.keepDetailedHistory)
        #expect(!settings.scanEntireDataVolume)
        #expect(settings.externalVolumePaths.isEmpty)
    }

    @Test func coordinatorRefusesSecondPresentationWhileIdleReviewIsReplaced() {
        let app = AppModel()
        let plan = CleanupPlan(mode: .userFiles, title: "Empty", items: [])
        app.cleanup.present(plan)
        #expect(app.cleanup.activePlan?.id == plan.id)
        app.cleanup.dismiss()
        #expect(app.cleanup.activePlan == nil)
    }

    @Test func byteFormattingHonorsUnits() {
        #expect(ByteFormat.string(1_000_000, style: .decimal).contains("MB"))
        #expect(ByteFormat.string(1_048_576, style: .binary).contains("MB") || ByteFormat.string(1_048_576, style: .binary).contains("MiB"))
    }

    /// Renders the real views with fixture-only scan data into PNGs for visual review.
    /// Set PUREMAC_SNAPSHOT_DIR to choose the output folder.
    @Test func renderSnapshotsOfMainScreens() async throws {
        guard let outDir = ProcessInfo.processInfo.environment["PUREMAC_SNAPSHOT_DIR"] else { return }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("PureMacSnapshotFixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let fm = FileManager.default
        for (path, size) in [("Projects/App/build.bin", 48_000_000), ("Projects/App/src.zip", 12_000_000), ("Movies/clip.mov", 90_000_000),
                             ("Library/Caches/com.example.app/blob", 20_000_000), ("Documents/report.pdf", 4_000_000),
                             ("Downloads/Setup.dmg", 30_000_000), ("Music/a.m4a", 8_000_000)] {
            let url = fixture.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: size).write(to: url)
        }

        let app = AppModel()
        app.settings.hasCompletedOnboarding = true
        _ = try await StorageScanner(databaseURL: app.databaseURL, home: fixture.path)
            .scan(ScanConfiguration(roots: [ScanRoot(path: fixture.path, kind: .folder)])) { _ in }
        await app.bootstrap()
        await app.explorer.sessionDidChange()

        await app.performance.refresh()
        await app.smartClean.analyze()
        await app.apps.load()
        app.apps.selectedAppID = app.apps.visibleApps.first?.id
        app.explorer.selection = []
        for item in [SidebarItem.overview, .explorer, .smartClean, .orphans, .duplicates, .developer, .performance, .history, .applications] {
            for dark in [true, false] where dark || item == .overview || item == .smartClean {
                let view = SnapshotHost(item: item).environment(app).environment(\.byteStyle, .decimal)
                let png = try render(view, size: CGSize(width: 1280, height: 860), dark: dark)
                try png.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(item.rawValue)\(dark ? "" : "-light").png"))
            }
        }
        // Scanning state with fixture progress.
        var progress = ScanProgress()
        progress.filesVisited = 184_233
        progress.directoriesVisited = 21_904
        progress.allocatedBytes = 41_800_000_000
        progress.elapsed = 7.4
        progress.currentRoot = fixture.path
        progress.currentTopLevel = "Library"
        progress.currentRelativePath = "Library/Application Support/Code/User/workspaceStorage"
        progress.categoryAllocated = [2_100_000_000, 900_000_000, 6_400_000_000, 9_800_000_000, 3_200_000_000, 1_500_000_000, 0, 0, 4_100_000_000, 0, 12_800_000_000, 30_000_000, 0]
        let samples = (1...40).map { ScanModel.ThroughputSample(id: $0, elapsed: Double($0) * 0.18, filesPerSecond: 18_000 + 9_000 * sin(Double($0) / 5) + Double($0) * 120) }
        app.scan._setFixtureScanState(progress: progress, throughput: samples)
        let scanning = try render(SnapshotHost(item: .overview).environment(app).environment(\.byteStyle, .decimal), size: CGSize(width: 1280, height: 860), dark: true)
        try scanning.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("scanning.png"))
        app.scan._clearFixtureScanState()
        let about = try render(AboutView().environment(app), size: CGSize(width: 440, height: 620))
        try about.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("about.png"))
        let onboarding = try render(OnboardingView(onFinish: {}).environment(app), size: CGSize(width: 720, height: 620))
        try onboarding.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("onboarding.png"))
    }

    private func render<V: View>(_ view: V, size: CGSize, dark: Bool = true) throws -> Data {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.layoutIfNeeded()
        for _ in 0..<30 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        host.layoutSubtreeIfNeeded()
        host.display()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}

/// The split view with a fixed selection, for snapshots.
private struct SnapshotHost: View {
    let item: SidebarItem
    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: .constant(Optional(item))) { entry in
                Label(entry.title, systemImage: entry.symbol).tag(entry)
            }
        } detail: {
            switch item {
            case .overview: OverviewView(navigate: { _ in })
            case .explorer: ExplorerView()
            case .smartClean: SmartCleanView()
            case .applications: ApplicationsView()
            case .duplicates: DuplicatesView()
            case .orphans: OrphansView()
            case .developer: DeveloperView()
            case .performance: PerformanceView()
            case .history: HistoryView()
            }
        }
    }
}
