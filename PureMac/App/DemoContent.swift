#if DEBUG
import AppKit
import Foundation
import PureMacKit

/// DEBUG-only demo mode for promotional screenshots (`Scripts/Promo/make_screenshots.sh`).
///
/// It is enabled only with both `-PureMacDemo YES` and the `PUREMAC_DEMO_ROOT` environment
/// variable, and never exists in Release builds. The mock Mac is built by
/// `Scripts/Promo/make_demo.py` (a fictional home folder, apps and scan index). Here the **real
/// engine** — Smart Clean rules, ownership evidence, orphan detection, duplicate hashing, the
/// developer inspector — runs against that mock home, so every screen shows genuine PureMac output;
/// only the sizes come from the mock data, because the mock files themselves are tiny.
@MainActor
enum DemoContent {
    static var root: URL? {
        ProcessInfo.processInfo.environment["PUREMAC_DEMO_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "PureMacDemo") && root != nil }

    static var databaseURL: URL { root!.appendingPathComponent("Data/PureMac.sqlite") }

    struct Manifest: Decodable {
        struct Size: Decodable { var bytes: Int64; var days: Double; var files: Int64 }
        struct App: Decodable {
            var name, bundleID, version, symbol: String
            var colors: [String]
            var bundleBytes: Int64
            var lastUsedDays: Double
            var running: Bool
            var signing, source: String
        }
        struct Volume: Decodable { var name: String; var total, available, important: Int64 }
        var home: String
        var applications: String
        var sizes: [String: Size]
        var apps: [App]
        var volume: Volume
        var duplicateRoots: [String]
    }

    private static var manifest: Manifest?

    /// Fills every model with demo content. Called once at launch, before any page is shown.
    static func install(into app: AppModel) async {
        guard let root, let data = try? Data(contentsOf: root.appendingPathComponent("demo.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return }
        self.manifest = manifest
        let home = manifest.home

        let device = (try? FileStat.lstat(home).get())?.identity.device
        let volume = VolumeInfo(url: URL(fileURLWithPath: "/"), name: manifest.volume.name, totalCapacity: manifest.volume.total,
                                availableCapacity: manifest.volume.available, availableForImportantUsage: manifest.volume.important,
                                fileSystemType: "APFS", isInternal: true, isRemovable: false, isEjectable: false, isLocal: true,
                                isReadOnly: false, isRootFileSystem: true, deviceID: device)
        app.scan._demoVolume = volume

        // Apps: fictional bundles with generated icons.
        var bundleSizes: [String: Int64] = [:], lastUsed: [String: Date] = [:], running: Set<String> = []
        let apps: [InstalledApp] = manifest.apps.map { spec in
            let path = manifest.applications + "/" + spec.name + ".app"
            NSWorkspace.shared.setIcon(icon(symbol: spec.symbol, colors: spec.colors), forFile: path, options: [])
            bundleSizes[path] = spec.bundleBytes
            lastUsed[path] = Date().addingTimeInterval(-spec.lastUsedDays * 86_400 - 3_600)
            if spec.running { running.insert(path) }
            return InstalledApp(path: path, name: spec.name, bundleIdentifier: spec.bundleID, version: spec.version, build: nil,
                                teamIdentifier: "Q7DEMO2026", signingKind: SigningKind(rawValue: spec.signing) ?? .developer,
                                source: AppSource(rawValue: spec.source) ?? .unknown, packageIdentifiers: [],
                                helperBundleIdentifiers: [], applicationGroups: [], isProtected: false, protectionReason: nil,
                                executableName: spec.name)
        }

        // Associations from the real evidence engine (system-wide /Library is left out).
        let finder = AssociationFinder(home: home, systemLibraryPath: root.appendingPathComponent("SystemLibrary").path)
        var associations: [String: [AppAssociation]] = [:]
        for installed in apps {
            var list = await finder.associations(for: installed, allApps: apps)
            for i in list.indices {
                if list[i].kind == .appBundle {
                    list[i].allocatedSize = bundleSizes[installed.path]
                    list[i].logicalSize = bundleSizes[installed.path].map { $0 * 102 / 100 }
                } else if let size = size(list[i].path) {
                    list[i].allocatedSize = size.bytes
                    list[i].logicalSize = size.bytes * 102 / 100
                    list[i].modified = size.date
                }
            }
            associations[installed.path] = list
        }
        app.apps._demoSet(apps: apps, bundleSizes: bundleSizes, lastUsed: lastUsed, associations: associations, running: running, orphans: [])

        // Orphans from the real detector, with demo sizes.
        let detector = OrphanDetector(home: home)
        var orphans = await detector.findOrphans(installedApps: apps)
        for i in orphans.indices {
            if let size = size(orphans[i].path) {
                orphans[i].allocatedSize = size.bytes
                orphans[i].logicalSize = size.bytes * 102 / 100
            }
        }
        app.apps._demoSet(apps: apps, bundleSizes: bundleSizes, lastUsed: lastUsed, associations: associations, running: running, orphans: orphans)

        // Smart Clean: the real rule catalog evaluated on the mock home.
        if let catalog = app.smartClean.catalog {
            let evaluator = RuleEvaluator(catalog: catalog, policy: await app.safetyPolicy())
            var evaluation = await evaluator.evaluate(installedApps: apps, runningIdentifiers: app.apps.runningIDs)
            for i in evaluation.candidates.indices {
                if let size = size(evaluation.candidates[i].path) {
                    evaluation.candidates[i].allocatedSize = size.bytes
                    evaluation.candidates[i].logicalSize = size.bytes * 102 / 100
                    evaluation.candidates[i].itemCount = max(1, size.files)
                }
            }
            app.smartClean._demoSet(evaluation, trashBytes: 2_418_000_000)
        }

        // Duplicates: real hashing of the mock files (identical contents), demo sizes.
        let roots = manifest.duplicateRoots.map { home + "/" + $0 }
        var result = DuplicateFinder(minimumSize: 1).find(roots: roots)
        result.groups = result.groups.map { group in
            var group = group
            group.files = group.files.map { file in
                var file = file
                if let size = size(file.path) {
                    file.allocatedSize = size.bytes
                    file.logicalSize = size.bytes
                }
                return file
            }
            group.size = group.files.first?.logicalSize ?? group.size
            return group
        }
        .sorted { $0.potentialSavings > $1.potentialSavings }
        result.filesConsidered = 18_432
        app.duplicates.roots = roots
        app.duplicates._demoSet(result)

        // Developer storage: the real inspector on the mock home, demo sizes; tool summaries mocked.
        var items = await DeveloperStorageInspector(home: home).inspect()
        for i in items.indices {
            if let path = items[i].path, let size = size(path) { items[i].size = summary(size) }
            items[i].children = items[i].children.map { child in
                var child = child
                if let size = size(child.path) { child.size = summary(size) }
                return child
            }
            .sorted { $0.size.allocatedSize > $1.size.allocatedSize }
        }
        let nodeModules = await nodeModuleRecords(app)
        app.developer._demoSet(items: items, simulators: SimulatorSummary(totalDevices: 14, unavailableDevices: 5, runtimes: ["iOS-26-0", "iOS-26-1", "watchOS-26-0"]),
                               docker: DockerSummary(installed: true, daemonRunning: true, rows: [
                                   .init(type: "Images", total: "23", active: "8", size: "41.2GB", reclaimable: "18.6GB (45%)"),
                                   .init(type: "Containers", total: "11", active: "3", size: "2.1GB", reclaimable: "1.7GB (80%)"),
                                   .init(type: "Local Volumes", total: "9", active: "4", size: "13.4GB", reclaimable: "6.2GB (46%)"),
                                   .init(type: "Build Cache", total: "214", active: "0", size: "7.9GB", reclaimable: "7.9GB"),
                               ], message: nil),
                               nodeModules: nodeModules)

        // Performance: a believable, healthy-but-busy MacBook Pro.
        let gib: UInt64 = 1 << 30
        let snapshot = SystemSnapshot(takenAt: Date(), memory: .init(physical: 32 * gib, free: gib + gib / 4, active: 10 * gib, inactive: 8 * gib, wired: 4 * gib, compressed: 3 * gib),
                                      pressure: .normal, swapTotal: 2 * gib, swapUsed: 412 << 20, thermalState: .nominal,
                                      loadAverage: (3.42, 3.11, 2.87), logicalCPUs: 12, startupVolume: volume)
        let processes = [
            ProcessUsage(pid: 812, name: "Frame Studio", cpuPercent: 142, residentBytes: 4_400 << 20),
            ProcessUsage(pid: 1204, name: "Ember Browser Helper (Renderer)", cpuPercent: 38, residentBytes: 1_210 << 20),
            ProcessUsage(pid: 977, name: "Orbit Code", cpuPercent: 21, residentBytes: 1_020 << 20),
            ProcessUsage(pid: 401, name: "WindowServer", cpuPercent: 12, residentBytes: 640 << 20),
            ProcessUsage(pid: 1388, name: "Slate Chat", cpuPercent: 7, residentBytes: 780 << 20),
            ProcessUsage(pid: 233, name: "mds_stores", cpuPercent: 5, residentBytes: 210 << 20),
        ]
        let agents = home + "/Library/LaunchAgents/"
        let launchItems = [
            LaunchItem(plistPath: agents + "com.ember.browser.updater.plist", label: "com.ember.browser.updater",
                       program: manifest.applications + "/Ember Browser.app/Contents/MacOS/EmberUpdater", programExists: true, isDisabled: false, scope: .userAgent),
            LaunchItem(plistPath: agents + "com.harborvpn.client.helper.plist", label: "com.harborvpn.client.helper",
                       program: manifest.applications + "/Harbor VPN.app/Contents/Library/LoginItems/HarborHelper", programExists: true, isDisabled: false, scope: .userAgent),
            LaunchItem(plistPath: agents + "io.tunnelbox.client.plist", label: "io.tunnelbox.client",
                       program: "/Applications/Tunnelbox.app/Contents/MacOS/tunnelboxd", programExists: false, isDisabled: false, scope: .userAgent),
            LaunchItem(plistPath: "/Library/LaunchDaemons/com.harborvpn.daemon.plist", label: "com.harborvpn.daemon",
                       program: "/Library/PrivilegedHelperTools/com.harborvpn.daemon", programExists: true, isDisabled: false, scope: .systemDaemon),
        ]
        // Two minutes of believable history for the trend lines (an export render around sample 40).
        let history = (0..<60).map { i -> PerformanceModel.Sample in
            let t = Double(i)
            let burst = i > 34 && i < 48 ? 0.22 * sin((t - 34) / 14 * .pi) : 0
            return PerformanceModel.Sample(id: i, takenAt: Date().addingTimeInterval(Double(i - 59) * 2),
                                           memoryUsed: 0.5 + 0.02 * sin(t / 9) + burst * 0.12,
                                           cpuBusy: 0.16 + 0.05 * sin(t / 3.1) + 0.03 * sin(t * 1.7) + burst,
                                           loadPerCore: 0.24 + 0.03 * sin(t / 11) + burst * 0.4,
                                           swapUsed: 412 << 20, diskFree: 0.096)
        }
        app.performance._demoSet(snapshot: snapshot, processes: processes, launchItems: launchItems, history: history)
    }

    /// Puts a page into the state a screenshot needs (`-PureMacDemoScene name`).
    static func apply(scene: String, to app: AppModel) {
        switch scene {
        case "scanning":
            var progress = ScanProgress()
            progress.filesVisited = 824_311
            progress.directoriesVisited = 61_204
            progress.allocatedBytes = 412_800_000_000
            progress.logicalBytes = 425_100_000_000
            progress.elapsed = 24.6
            progress.currentRoot = PathTools.userHome
            progress.currentRelativePath = "Movies/Final Cut Libraries/Iceland Trip 2025.fcpbundle"
            progress.currentTopLevel = "Movies"
            let parts: [StorageCategory: Int64] = [.media: 268_000_000_000, .developer: 52_000_000_000, .appData: 41_000_000_000,
                                                   .caches: 19_000_000_000, .archives: 14_000_000_000, .documents: 11_000_000_000, .cloud: 7_800_000_000]
            for (category, bytes) in parts { progress.categoryAllocated[category.rawValue] = bytes }
            let samples = (0..<90).map { i -> ScanModel.ThroughputSample in
                let t = Double(i) * 24.6 / 89
                let rate = 31_000 + 9_000 * sin(t / 2.3) + 4_000 * sin(t * 1.7) + Double(i % 7) * 600
                return ScanModel.ThroughputSample(id: i, elapsed: t, filesPerSecond: rate)
            }
            app.scan._setFixtureScanState(progress: progress, throughput: samples)
        case "review":
            app.cleanup.present(app.smartClean.makePlan())
        case "apps":
            let byName = Dictionary(uniqueKeysWithValues: app.apps.apps.map { ($0.name, $0.id) })
            app.apps.selectedAppID = byName["Cadence DAW"]
            app.apps.uninstallSelection = Set(["Cadence DAW", "Gamebox Launcher", "Atlas Maps Pro"].compactMap { byName[$0] })
        case "apps-list":
            app.apps.uninstallSelection = []
        case "orphans":
            app.apps.orphanSelection = Set(app.apps.orphans.filter { $0.confidence == .likely }.map(\.id))
        case "duplicates":
            app.duplicates.selectExtraCopies(keeping: .newest)
        case "duplicates-setup":
            app.duplicates.reset()
        case "developer":
            app.developer.selection = Set(app.developer.regenerablePaths)
        default:
            break
        }
    }

    // MARK: Helpers

    private struct DemoSize { var bytes: Int64; var files: Int64; var date: Date }

    private static func size(_ path: String) -> DemoSize? {
        guard let manifest, path.hasPrefix(manifest.home + "/") else { return nil }
        let rel = String(path.dropFirst(manifest.home.count + 1))
        guard let s = manifest.sizes[rel] else { return nil }
        return DemoSize(bytes: s.bytes, files: s.files, date: Date().addingTimeInterval(-s.days * 86_400))
    }

    private static func summary(_ size: DemoSize) -> SizeSummary {
        var summary = SizeSummary()
        summary.allocatedSize = size.bytes
        summary.logicalSize = size.bytes * 102 / 100
        summary.fileCount = size.files
        summary.newestModification = size.date
        return summary
    }

    private static func nodeModuleRecords(_ app: AppModel) async -> [FileRecord] {
        guard let store = app.store, let session = try? await store.latestBrowsableSession() else { return [] }
        return ((try? await store.search(sessionID: session.id, text: "node_modules", limit: 50)) ?? [])
            .filter { $0.name == "node_modules" && $0.isContainer }
    }

    /// A macOS-style app icon: a rounded square with a gradient and a white SF Symbol.
    private static func icon(symbol: String, colors: [String]) -> NSImage {
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { rect in
            let tile = rect.insetBy(dx: 50, dy: 50)
            let path = NSBezierPath(roundedRect: tile, xRadius: 92, yRadius: 92)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.shadowBlurRadius = 18
            shadow.shadowOffset = NSSize(width: 0, height: -8)
            shadow.set()
            NSColor.black.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            let gradient = NSGradient(colors: colors.compactMap(color(hex:))) ?? NSGradient(starting: .systemBlue, ending: .systemIndigo)!
            gradient.draw(in: path, angle: -60)
            NSColor.white.withAlphaComponent(0.18).setStroke()
            path.lineWidth = 3
            path.stroke()
            let configuration = NSImage.SymbolConfiguration(pointSize: 190, weight: .semibold).applying(.init(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let g = glyph.size
                glyph.draw(in: NSRect(x: tile.midX - g.width / 2, y: tile.midY - g.height / 2, width: g.width, height: g.height))
            }
            return true
        }
    }

    private static func color(hex: String) -> NSColor? {
        var value: UInt64 = 0
        guard Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
#endif
