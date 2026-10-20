import AppKit
import Foundation
import Observation
import PureMacKit

/// Performance diagnostics: evidence-based, no "boosters". While the page is open and Live is on,
/// it samples every ~2 seconds and keeps a short history for trend lines.
@Observable
final class PerformanceModel {
    struct Sample: Identifiable {
        var id: Int
        var takenAt: Date
        /// Wired + active + compressed memory, as a share of installed memory.
        var memoryUsed: Double
        /// CPU time used by all inspectable processes, as a share of every core (nil when not sampled).
        var cpuBusy: Double?
        /// 1-minute load average per core.
        var loadPerCore: Double
        var swapUsed: UInt64
        var diskFree: Double
    }

    /// A running app's identity for process rows (icon, location).
    struct AppInfo {
        var icon: NSImage
        var bundleURL: URL?
    }

    private(set) var snapshot: SystemSnapshot?
    private(set) var topCPU: [ProcessUsage] = []
    private(set) var topMemory: [ProcessUsage] = []
    private(set) var appInfo: [Int32: AppInfo] = [:]
    private(set) var launchItems: [LaunchItem] = []
    private(set) var findings: [DiagnosticFinding] = []
    private(set) var history: [Sample] = []
    private(set) var isSampling = false
    private(set) var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    /// Re-sample continuously while the page is visible.
    var isLive = true
    let processSamplingAvailable = !PathTools.isSandboxed

    static let historyCapacity = 60
    static let liveInterval: TimeInterval = 2

    @ObservationIgnored private var nextSampleID = 0
    @ObservationIgnored private var isDemo = false

    #if DEBUG
    func _demoSet(snapshot: SystemSnapshot, processes: [ProcessUsage], launchItems: [LaunchItem], history: [Sample]) {
        isDemo = true
        self.snapshot = snapshot
        topCPU = processes.sorted { $0.cpuPercent > $1.cpuPercent }
        topMemory = processes.sorted { $0.residentBytes > $1.residentBytes }
        self.launchItems = launchItems
        self.history = history
        uptime = 6 * 86_400 + 4 * 3_600
        findings = SystemDiagnostics.findings(for: snapshot, topProcesses: processes, brokenLaunchItems: launchItems.filter { !$0.programExists }.count)
    }
    #endif

    /// Runs for as long as the page is visible (call from `.task(id: isLive)`).
    func run() async {
        guard !isDemo else { return }
        if snapshot == nil { await refresh() }
        while isLive, !Task.isCancelled {
            // Another sample may still be finishing ("Sample Again", or the run this one replaced):
            // wait for it. `sample` returns at once while one runs, so looping straight back would
            // spin on the main actor and that sample could never resume to finish.
            if isSampling {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            await sample(interval: Self.liveInterval, includeLaunchItems: false)
        }
    }

    /// A complete sample, including launch items (the "Sample Again" button).
    func refresh() async {
        guard !isDemo else { return }
        await sample(interval: 1.0, includeLaunchItems: true)
    }

    private func sample(interval: TimeInterval, includeLaunchItems: Bool) async {
        guard !isSampling else { return }
        isSampling = true
        defer { isSampling = false }
        let snap = await Task.detached(priority: .utility) { SystemDiagnostics.snapshot() }.value
        // The sandbox hides other processes, so the App Store edition does not sample them.
        let all: [ProcessUsage]
        if processSamplingAvailable {
            all = await SystemDiagnostics.processUsage(interval: interval)
        } else {
            try? await Task.sleep(for: .seconds(interval))
            all = []
        }
        guard !Task.isCancelled else { return }
        let launch = includeLaunchItems || launchItems.isEmpty
            ? await Task.detached(priority: .utility) { LaunchItem.inventory() }.value
            : launchItems
        let me = ProcessInfo.processInfo.processIdentifier
        let busiest = all.filter { $0.cpuPercent > 0.5 }.sorted { $0.cpuPercent > $1.cpuPercent }
        let cpu = Array(busiest.prefix(8))
        let memory = Array(all.sorted { $0.residentBytes > $1.residentBytes }.prefix(8))
        var info: [Int32: AppInfo] = [:]
        let shown = Set((cpu + memory).map(\.pid))
        for running in NSWorkspace.shared.runningApplications where shown.contains(running.processIdentifier) {
            if let icon = running.icon { info[running.processIdentifier] = AppInfo(icon: icon, bundleURL: running.bundleURL) }
        }
        nextSampleID += 1
        let point = Sample(id: nextSampleID, takenAt: snap.takenAt, memoryUsed: Self.memoryUsed(snap),
                           cpuBusy: processSamplingAvailable ? min(1, all.reduce(0) { $0 + $1.cpuPercent } / Double(max(snap.logicalCPUs, 1) * 100)) : nil,
                           loadPerCore: snap.loadAverage.0 / Double(max(snap.logicalCPUs, 1)),
                           swapUsed: snap.swapUsed ?? 0, diskFree: Self.diskFree(snap))
        // Publish once: every property changes in the same main-actor turn.
        snapshot = snap
        topCPU = cpu
        topMemory = memory
        appInfo = info
        launchItems = launch
        uptime = ProcessInfo.processInfo.systemUptime
        history = Array((history + [point]).suffix(Self.historyCapacity))
        // PureMac's own work (sampling, background sizing) is not a finding about the Mac.
        findings = SystemDiagnostics.findings(for: snap, topProcesses: busiest.filter { $0.pid != me },
                                              brokenLaunchItems: launch.filter { !$0.programExists }.count)
    }

    static func memoryUsed(_ snapshot: SystemSnapshot) -> Double {
        snapshot.memory.map { Double($0.wired + $0.active + $0.compressed) / Double(max($0.physical, 1)) } ?? 0
    }

    static func diskFree(_ snapshot: SystemSnapshot) -> Double {
        guard let v = snapshot.startupVolume, let total = v.totalCapacity, total > 0 else { return 0 }
        return Double(v.availableForImportantUsage ?? v.availableCapacity ?? 0) / Double(total)
    }
}
