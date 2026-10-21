import Darwin
import Foundation

/// A point-in-time snapshot of system health from public Mach, sysctl and Foundation APIs.
public struct SystemSnapshot: Sendable, Hashable {
    public struct Memory: Sendable, Hashable {
        public var physical: UInt64
        public var free: UInt64
        public var active: UInt64
        public var inactive: UInt64
        public var wired: UInt64
        public var compressed: UInt64
        /// App memory approximation (active + inactive − purgeable is not exposed; we show components).
        public var used: UInt64 { physical > free ? physical - free : 0 }

        public init(physical: UInt64, free: UInt64, active: UInt64, inactive: UInt64, wired: UInt64, compressed: UInt64) {
            self.physical = physical
            self.free = free
            self.active = active
            self.inactive = inactive
            self.wired = wired
            self.compressed = compressed
        }
    }

    public enum PressureLevel: Int, Sendable, Hashable {
        case normal = 1, warning = 2, critical = 4, unknown = 0
        public var displayName: String {
            switch self {
            case .normal: String(localized: "Normal", bundle: .module)
            case .warning: String(localized: "Elevated", bundle: .module)
            case .critical: String(localized: "Critical", bundle: .module)
            case .unknown: String(localized: "Unknown", bundle: .module)
            }
        }
    }

    public var takenAt: Date
    public var memory: Memory?
    public var pressure: PressureLevel
    public var swapTotal: UInt64?
    public var swapUsed: UInt64?
    public var thermalState: ProcessInfo.ThermalState
    public var loadAverage: (Double, Double, Double)
    public var logicalCPUs: Int
    public var startupVolume: VolumeInfo?
    /// Processor time counters of the whole Mac; compare two snapshots with `CPUTicks.busyFraction`.
    public var cpuTicks: CPUTicks?

    public static func == (lhs: SystemSnapshot, rhs: SystemSnapshot) -> Bool { lhs.takenAt == rhs.takenAt }
    public func hash(into hasher: inout Hasher) { hasher.combine(takenAt) }

    public init(takenAt: Date, memory: Memory?, pressure: PressureLevel, swapTotal: UInt64?, swapUsed: UInt64?,
                thermalState: ProcessInfo.ThermalState, loadAverage: (Double, Double, Double), logicalCPUs: Int, startupVolume: VolumeInfo?,
                cpuTicks: CPUTicks? = nil) {
        self.takenAt = takenAt
        self.memory = memory
        self.pressure = pressure
        self.swapTotal = swapTotal
        self.swapUsed = swapUsed
        self.thermalState = thermalState
        self.loadAverage = loadAverage
        self.logicalCPUs = logicalCPUs
        self.startupVolume = startupVolume
        self.cpuTicks = cpuTicks
    }
}

/// Cumulative processor time of every core, in scheduler ticks, from the host statistics macOS
/// keeps for the whole Mac. Unlike per-process sampling, this works inside the App Sandbox.
public struct CPUTicks: Sendable, Hashable {
    public var busy: UInt64
    public var total: UInt64

    public init(busy: UInt64, total: UInt64) {
        self.busy = busy
        self.total = total
    }

    /// Share of processor time spent busy between `earlier` and `self` (0…1); `nil` when no time passed.
    public func busyFraction(since earlier: CPUTicks) -> Double? {
        guard total > earlier.total, busy >= earlier.busy else { return nil }
        return min(1, Double(busy - earlier.busy) / Double(total - earlier.total))
    }
}

/// A recommendation that always states its evidence and expected effect.
public struct DiagnosticFinding: Identifiable, Sendable, Hashable {
    public enum Severity: Int, Sendable, Comparable {
        case info = 0, attention = 1, important = 2
        public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
    }
    public var id: String
    public var severity: Severity
    public var title: String
    public var evidence: String
    public var suggestion: String
    public var expectedEffect: String

    public init(id: String, severity: Severity, title: String, evidence: String, suggestion: String, expectedEffect: String) {
        self.id = id
        self.severity = severity
        self.title = title
        self.evidence = evidence
        self.suggestion = suggestion
        self.expectedEffect = expectedEffect
    }
}

public enum SystemDiagnostics {
    public static func snapshot() -> SystemSnapshot {
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        let swap = swapUsage()
        return SystemSnapshot(
            takenAt: Date(), memory: memory(), pressure: pressureLevel(), swapTotal: swap?.total, swapUsed: swap?.used,
            thermalState: ProcessInfo.processInfo.thermalState, loadAverage: (load[0], load[1], load[2]),
            logicalCPUs: ProcessInfo.processInfo.activeProcessorCount,
            startupVolume: VolumeInspector.volume(containing: URL(fileURLWithPath: "/")),
            cpuTicks: cpuTicks())
    }

    public static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return CPUTicks(busy: user + system + nice, total: user + system + idle + nice)
    }

    static func memory() -> SystemSnapshot.Memory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(host, &pageSize)
        let page = UInt64(pageSize)
        return SystemSnapshot.Memory(
            physical: ProcessInfo.processInfo.physicalMemory,
            free: UInt64(stats.free_count) * page,
            active: UInt64(stats.active_count) * page,
            inactive: UInt64(stats.inactive_count) * page,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page)
    }

    static func pressureLevel() -> SystemSnapshot.PressureLevel {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .unknown }
        return SystemSnapshot.PressureLevel(rawValue: Int(level)) ?? .unknown
    }

    static func swapUsage() -> (total: UInt64, used: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (usage.xsu_total, usage.xsu_used)
    }

    /// Evidence-based findings. Never suggests "freeing RAM", killing processes or speed-up percentages.
    public static func findings(for snapshot: SystemSnapshot, brokenLaunchItems: Int) -> [DiagnosticFinding] {
        var findings: [DiagnosticFinding] = []
        if let volume = snapshot.startupVolume, let total = volume.totalCapacity, let free = volume.availableForImportantUsage ?? volume.availableCapacity, total > 0 {
            let fraction = Double(free) / Double(total)
            if fraction < 0.10 {
                findings.append(DiagnosticFinding(
                    id: "disk.low", severity: fraction < 0.05 ? .important : .attention, title: String(localized: "Startup disk is almost full", bundle: .module),
                    evidence: String(localized: "Only \(Int(fraction * 100))% of the startup disk is available (including purgeable space).", bundle: .module),
                    suggestion: String(localized: "Review Smart Clean and the Storage Explorer, then empty the Trash.", bundle: .module),
                    expectedEffect: String(localized: "macOS needs free space for virtual memory, updates and caches; low space can slow the system and block updates.", bundle: .module)))
            }
        }
        switch snapshot.pressure {
        case .critical, .warning:
            findings.append(DiagnosticFinding(
                id: "memory.pressure", severity: snapshot.pressure == .critical ? .important : .attention,
                title: String(localized: "Memory pressure is \(snapshot.pressure.displayName.lowercased())", bundle: .module),
                evidence: snapshot.swapUsed.map { swap in
                    String(localized: "macOS reports memory pressure level \(snapshot.pressure.rawValue), with \(ByteCountFormatter.string(fromByteCount: Int64(swap), countStyle: .memory)) of swap in use.", bundle: .module)
                } ?? String(localized: "macOS reports memory pressure level \(snapshot.pressure.rawValue).", bundle: .module),
                suggestion: String(localized: "Quit apps or browser tabs you are not using. Activity Monitor shows which ones use the most memory.", bundle: .module),
                expectedEffect: String(localized: "Lower pressure reduces swapping and compression, which can make apps more responsive. PureMac does not and cannot “free RAM”.", bundle: .module)))
        default: break
        }
        if snapshot.thermalState == .serious || snapshot.thermalState == .critical {
            findings.append(DiagnosticFinding(
                id: "thermal", severity: .important, title: String(localized: "The Mac is thermally constrained", bundle: .module),
                evidence: snapshot.thermalState == .critical
                    ? String(localized: "macOS reports the thermal state as critical.", bundle: .module)
                    : String(localized: "macOS reports the thermal state as serious.", bundle: .module),
                suggestion: String(localized: "Check for processes with sustained high CPU, improve ventilation, and avoid soft surfaces.", bundle: .module),
                expectedEffect: String(localized: "macOS reduces performance while hot; cooling restores it.", bundle: .module)))
        }
        if brokenLaunchItems > 0 {
            findings.append(DiagnosticFinding(
                id: "launch.broken", severity: .info, title: String(localized: "\(brokenLaunchItems) launch item(s) point to missing programs", bundle: .module),
                evidence: String(localized: "Their launchd definitions reference executables that no longer exist.", bundle: .module),
                suggestion: String(localized: "Review them below. Your own (~/Library) items appear under Orphaned Remnants; system-wide ones need an administrator.", bundle: .module),
                expectedEffect: String(localized: "Mostly tidiness: launchd retries them and logs errors, with little performance impact.", bundle: .module)))
        }
        return findings.sorted { $0.severity > $1.severity }
    }
}

/// Launch agents and daemons PureMac can read. A complete list of *all* background items is only
/// available in System Settings → General → Login Items; PureMac does not claim otherwise.
public struct LaunchItem: Identifiable, Sendable, Hashable {
    public enum Scope: String, Sendable { case userAgent, systemAgent, systemDaemon
        public var displayName: String {
            switch self {
            case .userAgent: String(localized: "Your launch agents", bundle: .module)
            case .systemAgent: String(localized: "System-wide launch agents", bundle: .module)
            case .systemDaemon: String(localized: "System-wide launch daemons", bundle: .module)
            }
        }
    }
    public var id: String { plistPath }
    public var plistPath: String
    public var label: String
    public var program: String?
    public var programExists: Bool
    public var isDisabled: Bool
    public var scope: Scope

    public static func inventory(home: String = PathTools.userHome) -> [LaunchItem] {
        let sources: [(String, Scope)] = [(home + "/Library/LaunchAgents", .userAgent), ("/Library/LaunchAgents", .systemAgent), ("/Library/LaunchDaemons", .systemDaemon)]
        return sources.flatMap { dir, scope in
            LaunchJob.readAll(in: dir).map { job in
                LaunchItem(plistPath: job.plistPath, label: job.label ?? (job.plistPath as NSString).lastPathComponent,
                           program: job.program, programExists: job.programExists, isDisabled: job.isDisabled, scope: scope)
            }
        }
    }

    public init(plistPath: String, label: String, program: String?, programExists: Bool, isDisabled: Bool, scope: Scope) {
        self.plistPath = plistPath
        self.label = label
        self.program = program
        self.programExists = programExists
        self.isDisabled = isDisabled
        self.scope = scope
    }
}
