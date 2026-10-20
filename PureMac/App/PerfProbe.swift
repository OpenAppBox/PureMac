#if DEBUG
import AppKit
import SwiftUI

enum PerfTrace {
    static let enabled = UserDefaults.standard.bool(forKey: "PureMacTraceChanges")
    static func changes(_ s: String) { if enabled { FileHandle.standardError.write(Data(("[body] " + s + "\n").utf8)) } }
}

import Foundation
import QuartzCore

/// DEBUG-only responsiveness harness. `-PureMacPerfScript YES` tours every screen and a few
/// interactions, measuring main-thread hitches (gaps in an 8 ms heartbeat) after each step, then
/// writes a report to `-PureMacPerfReport <path>` (default /tmp/puremac-perf.txt) and quits.
@MainActor
final class PerfProbe {
    static let shared = PerfProbe()

    private var timer: Timer?
    private var last = CACurrentMediaTime()
    private var hitches: [Double] = []
    private var lines: [String] = []

    private var activity: NSObjectProtocol?

    func startHeartbeat() {
        // Measure like a foreground app: no App Nap timer throttling, window frontmost.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "PureMac perf probe")
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        last = CACurrentMediaTime()
        let timer = Timer(timeInterval: 0.008, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                let gap = (now - PerfProbe.shared.last) * 1000
                if gap > 25 { PerfProbe.shared.hitches.append(gap) }
                PerfProbe.shared.last = now
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Runs `action`, then watches the main thread for `window` seconds.
    func measure(_ name: String, window: Double = 1.2, _ action: () -> Void) async {
        hitches = []
        last = CACurrentMediaTime()
        let start = CACurrentMediaTime()
        action()
        let actionMs = (CACurrentMediaTime() - start) * 1000
        try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
        let worst = hitches.max() ?? 0
        let total = hitches.reduce(0, +)
        lines.append(String(format: "[aurora %2d orbit %2d windows %d] ", LayerViewCounter.aurora, LayerViewCounter.orbit, NSApp.windows.count) + String(format: "%-28@ action %6.1f ms | worst hitch %6.1f ms | blocked %7.1f ms | hitches %3d",
                            name as NSString, actionMs, worst, total, hitches.count))
    }

    func finish() {
        let path = UserDefaults.standard.string(forKey: "PureMacPerfReport") ?? "/tmp/puremac-perf.txt"
        try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        NSApp.terminate(nil)
    }
}
#endif
