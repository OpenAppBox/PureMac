#if DEBUG
import AppKit
import PureMacKit
import SwiftUI

/// Development aids, compiled into DEBUG builds only: launch arguments that open a section, run a
/// scripted performance pass, size the window, capture the real window as a PNG or click through
/// the UI for automated checks (each argument is described where it is read below).
/// Release builds contain none of this.
@MainActor
enum DevelopmentHooks {
    /// `-PureMacInitialSection <item>` opens a section at launch (and skips onboarding).
    static var initialSection: SidebarItem? {
        UserDefaults.standard.string(forKey: "PureMacInitialSection").flatMap(SidebarItem.init(rawValue:))
    }

    /// `-PureMacPerfScript YES`, `-PureMacStartScan YES`, `-PureMacSelfSnapshot <path.png>`.
    static func afterLaunch(app: AppModel, select: @escaping (SidebarItem) -> Void) async {
        // `-PureMacSetLanguage tr|system` stores the language choice exactly like Settings does, then quits.
        if let code = UserDefaults.standard.string(forKey: "PureMacSetLanguage") {
            AppLanguage.select(code == "system" ? nil : code)
            NSApp.terminate(nil)
        }
        if UserDefaults.standard.bool(forKey: "PureMacPerfScript") { await runPerfScript(app: app, select: select) }
        if UserDefaults.standard.bool(forKey: "PureMacStartScan") { app.scan.start() }
        // `-PureMacWindowSize 1440x900`: a fixed window size (screenshots).
        if let size = windowSize(), let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }) {
            window.setFrame(NSRect(origin: NSPoint(x: 80, y: 60), size: size), display: true)
        }
        if UserDefaults.standard.bool(forKey: "PureMacSandboxProbe") { await sandboxProbe() }
        // `-PureMacOpenSettings privacy` opens Settings on a pane (RootView, which has `openSettings`).
        // `-PureMacClickAt 1318,171` (points from the window's top-left, after `-PureMacClickDelay`
        // seconds, default 6): a real click through the window, to test hit-testing without
        // accessibility permissions.
        if let spec = UserDefaults.standard.string(forKey: "PureMacClickAt") {
            let delay = UserDefaults.standard.object(forKey: "PureMacClickDelay") as? Double ?? 6
            try? await Task.sleep(for: .seconds(delay))
            for point in spec.split(separator: ";") { await click(String(point)); try? await Task.sleep(for: .seconds(1)) }
        }
        // `-PureMacScrollTo 700,500,900`: scrolls the scroll view under that point (window points
        // from the top-left) to a vertical offset — to capture the lower part of a page.
        if let spec = UserDefaults.standard.string(forKey: "PureMacScrollTo") {
            try? await Task.sleep(for: .seconds(UserDefaults.standard.object(forKey: "PureMacClickDelay") as? Double ?? 6))
            scroll(spec)
        }
        if let path = UserDefaults.standard.string(forKey: "PureMacSelfSnapshot") { await snapshot(to: path) }
    }

    private static func click(_ spec: String) async {
        let parts = spec.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }) else { return }
        window.makeKeyAndOrderFront(nil)
        let location = NSPoint(x: parts[0], y: window.frame.height - parts[1])
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
        FileHandle.standardError.write(Data("[click] \(spec)\n".utf8))
    }

    private static func scroll(_ spec: String) {
        let parts = spec.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 3, let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }),
              let content = window.contentView else { return }
        let point = content.convert(NSPoint(x: parts[0], y: window.frame.height - parts[1]), from: nil)
        guard let scrollView = content.hitTest(point)?.enclosingScrollView else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: parts[2]))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        FileHandle.standardError.write(Data("[scroll] \(spec)\n".utf8))
    }

    /// `-PureMacSandboxProbe YES`: reports what the current process can reach (run it in the
    /// App Store configuration to see the sandbox's effect), then quits.
    private static func sandboxProbe() async {
        func log(_ s: String) { FileHandle.standardError.write(Data(("[probe] " + s + "\n").utf8)) }
        let fm = FileManager.default
        log("languages: preferred=\(Bundle.main.preferredLocalizations) available=\(AppLanguage.available) selected=\(AppLanguage.selected ?? "nil") AppleLanguages=\(UserDefaults.standard.array(forKey: "AppleLanguages") ?? []) bundle=\(Bundle.main.bundleIdentifier ?? "?")")
        log("sandboxed=\(PathTools.isSandboxed) home=\(PathTools.userHome) nsHome=\(NSHomeDirectory())")
        log("list /Applications: \((try? fm.contentsOfDirectory(atPath: "/Applications").count).map(String.init) ?? "denied")")
        log("list home: \((try? fm.contentsOfDirectory(atPath: PathTools.userHome).count).map(String.init) ?? "denied")")
        log("list ~/Library/Caches: \((try? fm.contentsOfDirectory(atPath: PathTools.userHome + "/Library/Caches").count).map(String.init) ?? "denied")")
        let apps = await AppDiscoverer().discover()
        log("apps discovered: \(apps.count), signed kinds: \(Set(apps.map(\.signingKind.rawValue)))")
        if let sample = apps.first(where: { $0.name == "Google Chrome" }) ?? apps.first(where: { !$0.isProtected }) {
            let size = DirectorySizer.measure(sample.path)
            log("measure \(sample.name): \(size.allocatedSize) bytes partial=\(size.isPartial)")
            log("last used \(sample.name): \(AppFootprint.lastUsedDate(path: sample.path).map { "\($0)" } ?? "nil")")
            log("receipts \(sample.name): \(PackageReceipts.packageIdentifiers(forFile: sample.path))")
        }
        let top = await SystemDiagnostics.topProcesses(interval: 0.5, limit: 5)
        log("top processes: \(top.map(\.name))")
        log("running apps: \(NSWorkspace.shared.runningApplications.count)")
        NSApp.terminate(nil)
    }

    /// Captures the app's own window (no Screen Recording permission needed), then quits.
    /// `-PureMacSnapshotSize 1440x900` sets the window size; the image is rendered at 2× with the
    /// title bar, and an attached sheet is composited on top where macOS shows it.
    private static func snapshot(to path: String) async {
        NSApp.activate(ignoringOtherApps: true)
        let size = windowSize(key: "PureMacSnapshotSize") ?? NSSize(width: 1240, height: 800)
        if let window = NSApp.windows.first(where: { $0.isVisible }) {
            window.setFrame(NSRect(origin: NSPoint(x: 60, y: 60), size: size), display: true)
            window.makeKeyAndOrderFront(nil)
        }
        let delay = UserDefaults.standard.double(forKey: "PureMacSnapshotDelay")
        try? await Task.sleep(nanoseconds: UInt64((delay > 0 ? delay : 3) * 1_000_000_000))
        // The content view renders the sidebar correctly (the window frame view does not); the
        // traffic-light buttons are drawn on top from their own views.
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.sheetParent == nil }),
              let content = window.contentView, var image = render(content) else { NSApp.terminate(nil); return }
        let canvas = content.bounds.size
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind), let superview = button.superview, let rendered = render(button) else { continue }
            let inWindow = superview.convert(button.frame, to: nil)   // window coordinates, origin bottom-left
            image = composite(image, rendered, at: inWindow.origin, base: canvas, decorated: false)
        }
        if let sheet = window.attachedSheet, let sheetView = sheet.contentView, let sheetImage = render(sheetView) {
            image = composite(image, sheetImage, at: NSPoint(x: sheet.frame.minX - window.frame.minX, y: sheet.frame.minY - window.frame.minY), base: canvas)
        }
        try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        NSApp.terminate(nil)
    }

    private static func windowSize(key: String = "PureMacWindowSize") -> NSSize? {
        let parts = (UserDefaults.standard.string(forKey: key) ?? "").split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : nil
    }

    private static func render(_ view: NSView, scale: CGFloat = 2) -> NSBitmapImageRep? {
        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    /// Draws `overlay` onto `base`; `decorated` adds a sheet's rounded corners and shadow.
    private static func composite(_ base: NSBitmapImageRep, _ overlay: NSBitmapImageRep, at origin: NSPoint, base size: NSSize, decorated: Bool = true) -> NSBitmapImageRep {
        let result = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            let frame = NSRect(origin: origin, size: overlay.size)
            if decorated {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
                shadow.shadowBlurRadius = 28
                shadow.shadowOffset = NSSize(width: 0, height: -8)
                shadow.set()
                NSColor.black.setFill()
                NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14).fill()
                NSGraphicsContext.restoreGraphicsState()
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14).addClip()
                overlay.draw(in: frame)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                overlay.draw(in: frame)
            }
            return true
        }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: base.pixelsWide, pixelsHigh: base.pixelsHigh, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return base }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        result.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func runPerfScript(app: AppModel, select: @escaping (SidebarItem) -> Void) async {
        let probe = PerfProbe.shared
        probe.startHeartbeat()
        app.settings.hasCompletedOnboarding = true
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        switch UserDefaults.standard.string(forKey: "PureMacPerfOnly") {
        case "applications":
            select(.applications)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            for i in 0..<8 {
                await probe.measure("applications select #\(i)", window: 2) {
                    let apps = app.apps.visibleApps
                    if apps.indices.contains(i) { app.apps.selectedAppID = apps[i].id }
                }
            }
            probe.finish(); return
        case "performance-live":
            // The hang of 0.13 review: Live turned on while a sample is still finishing.
            select(.performance)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            for i in 0..<3 {
                await probe.measure("sample again, then live #\(i)", window: 3) {
                    app.performance.isLive = false
                    Task { await app.performance.refresh() }
                    Task { try? await Task.sleep(for: .milliseconds(150)); app.performance.isLive = true }
                }
                await probe.measure("live off/on #\(i)", window: 3) {
                    app.performance.isLive = false
                    Task { try? await Task.sleep(for: .milliseconds(30)); app.performance.isLive = true }
                }
                await probe.measure("leave and return #\(i)", window: 3) {
                    select(.overview)
                    Task { try? await Task.sleep(for: .milliseconds(80)); select(.performance) }
                }
            }
            probe.finish(); return
        case "smartclean-report":
            // What Smart Clean proposes on this Mac, without changing anything.
            await app.smartClean.analyze()
            for _ in 0..<240 where app.smartClean.isAnalyzing || app.smartClean.evaluation == nil { try? await Task.sleep(for: .milliseconds(250)) }
            let m = app.smartClean
            func mb(_ b: Int64) -> String { String(format: "%.0f MB", Double(b) / 1_048_576) }
            var lines = ["[smartclean] catalog: \(m.catalog.map { "\($0.rules.count) rules" } ?? "nil") error: \(m.catalogError ?? "none")", "[smartclean] selected \(mb(m.selectedBytes)) of \(mb(m.candidates.reduce(0) { $0 + $1.allocatedSize })) · held back \(mb(m.heldBackBytes)) · trash \(m.trashBytes.map(mb) ?? "n/a")"]
            for extra in SmartCleanModel.Extra.allCases { lines.append("  extra \(extra.rawValue): \(m.items(of: extra).count) items, \(mb(m.bytes(of: extra)))") }
            for summary in m.evaluation?.summaries ?? [] { lines.append("  rule \(summary.ruleID): \(summary.itemCount) items, \(mb(summary.allocatedBytes))") }
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
            probe.finish(); return
        case "orphans-count":
            // Overview starts the search (as at a normal launch); report what it found.
            for _ in 0..<60 where app.apps.orphansFoundAt == nil || app.apps.isFindingOrphans { try? await Task.sleep(for: .milliseconds(500)) }
            FileHandle.standardError.write(Data("[orphans] \(app.apps.orphans.count) items, \(app.apps.orphanGroups.count) apps, \(app.apps.apps.count) installed apps\n".utf8))
            if let dump = UserDefaults.standard.string(forKey: "PureMacOrphanDump") {
                try? app.apps.orphans.map(\.path).sorted().joined(separator: "\n").write(toFile: dump, atomically: true, encoding: .utf8)
                try? app.apps.apps.map { "\($0.bundleIdentifier ?? "-")\t\($0.path)" }.sorted().joined(separator: "\n").write(toFile: dump + ".apps", atomically: true, encoding: .utf8)
            }
            probe.finish(); return
        case "orphans-select":
            select(.orphans)
            for _ in 0..<40 where app.apps.orphansFoundAt == nil || app.apps.isFindingOrphans { try? await Task.sleep(for: .milliseconds(500)) }
            if let dump = UserDefaults.standard.string(forKey: "PureMacOrphanDump") {
                try? app.apps.orphans.map(\.path).sorted().joined(separator: "\n").write(toFile: dump, atomically: true, encoding: .utf8)
            }
            FileHandle.standardError.write(Data("[orphans] \(app.apps.orphans.count) items, \(app.apps.orphanGroups.count) apps, \(app.apps.apps.count) installed apps\n".utf8))
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for i in 0..<3 {
                await probe.measure("select all likely #\(i)", window: 3) {
                    app.apps.orphanSelection.formUnion(app.apps.orphans.filter { $0.confidence == .likely }.map(\.id))
                }
                await probe.measure("clear selection #\(i)", window: 3) { app.apps.orphanSelection = [] }
            }
            probe.finish(); return
        case "orphans":
            select(.orphans)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await probe.measure("orphans find", window: 6) { Task { await app.apps.findOrphans() } }
            probe.finish(); return
        case "explorer":
            select(.explorer)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for i in 0..<4 {
                await probe.measure("explorer open #\(i)") { if let f = app.explorer.rows.first(where: \.isContainer) { Task { await app.explorer.open(f) } } }
                await probe.measure("explorer up #\(i)") { Task { await app.explorer.goUp() } }
            }
            probe.finish(); return
        case "overview-switch":
            for round in 0..<10 {
                if round == 3 { print("=== round 3: switch to overview"); fflush(stdout) }
                await probe.measure("switch → overview") { select(.overview) }
                if round == 3 { print("=== round 3: switch to history"); fflush(stdout) }
                await probe.measure("switch → history") { select(.history) }
            }
            probe.finish(); return
        case "explorer-switch":
            for _ in 0..<8 {
                await probe.measure("switch → explorer") { select(.explorer) }
                await probe.measure("switch → overview") { select(.overview) }
            }
            probe.finish(); return
        case "duplicates-switch":
            for _ in 0..<6 {
                await probe.measure("switch → duplicates") { select(.duplicates) }
                await probe.measure("switch → overview") { select(.overview) }
            }
            select(.duplicates)
            try? await Task.sleep(nanoseconds: 800_000_000)
            for i in 0..<6 {
                await probe.measure("duplicates toggle group #\(i)", window: 0.6) {
                    if let group = app.duplicates.visibleGroups.first { app.duplicates.toggleGroup(group) }
                }
                await probe.measure("duplicates select row #\(i)", window: 0.6) {
                    let groups = app.duplicates.visibleGroups
                    if !groups.isEmpty { app.duplicates.selectedGroupID = groups[(i + 1) % groups.count].id }
                }
            }
            probe.finish(); return
        case "switch":
            for _ in 0..<3 { for item in SidebarItem.allCases { await probe.measure("switch → \(item.rawValue)") { select(item) } } }
            probe.finish(); return
        default: break
        }
        for item in SidebarItem.allCases + [.overview, .explorer, .smartClean] {
            await probe.measure("switch → \(item.rawValue)") { select(item) }
        }
        select(.smartClean)
        try? await Task.sleep(nanoseconds: 800_000_000)
        await probe.measure("smart clean analyze", window: 5) { Task { await app.smartClean.analyze() } }
        for i in 0..<4 {
            await probe.measure("smart clean toggle #\(i)", window: 0.6) {
                if let c = app.smartClean.candidates.first(where: { $0.blockedReason == nil }) {
                    if app.smartClean.selection.contains(c.id) { app.smartClean.selection.remove(c.id) } else { app.smartClean.selection.insert(c.id) }
                }
            }
        }
        select(.explorer)
        try? await Task.sleep(nanoseconds: 800_000_000)
        for i in 0..<2 {
            await probe.measure("explorer open folder #\(i)") {
                if let folder = app.explorer.rows.first(where: \.isContainer) { Task { await app.explorer.open(folder) } }
            }
        }
        await probe.measure("explorer select row", window: 0.6) { if let r = app.explorer.rows.first { app.explorer.selection = [r.id] } }
        await probe.measure("explorer go up") { Task { await app.explorer.goUp() } }
        select(.applications)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        for i in 0..<3 {
            await probe.measure("applications select #\(i)", window: 2) {
                let apps = app.apps.visibleApps
                if apps.indices.contains(i) { app.apps.selectedAppID = apps[i].id }
            }
        }
        select(.orphans)
        try? await Task.sleep(nanoseconds: 800_000_000)
        await probe.measure("orphans find", window: 3) { Task { await app.apps.findOrphans() } }
        probe.finish()
    }
}
#endif
