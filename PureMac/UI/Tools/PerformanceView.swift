import PureMacKit
import SwiftUI

struct PerformanceView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    var navigate: (SidebarItem) -> Void = { _ in }

    private var hue: Color { SidebarItem.performance.hue }

    var body: some View {
        @Bindable var model = app.performance
        ScreenScaffold(item: .performance) {
            ModuleHeader(item: .performance, subtitle: "Measurements from macOS with the evidence behind every suggestion. No boosters, no RAM “cleaning”, no force-quits.") {
                HStack(spacing: 12) {
                    Toggle(isOn: $model.isLive) {
                        HStack(spacing: 5) {
                            LiveDot(isLive: model.isLive, color: hue)
                            Text("Live")
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Measure again every \(Int(PerformanceModel.liveInterval)) seconds while this page is open")
                    if !model.isLive {
                        Button { Task { await model.refresh() } } label: { Label(model.isSampling ? "Sampling…" : "Sample Again", systemImage: "waveform.path.ecg") }
                            .buttonStyle(.glow(hue))
                            .disabled(model.isSampling)
                    }
                }
            }
            .entrance()
            if let snapshot = model.snapshot {
                vitals(snapshot).entrance(0.02)
                HealthChecks(snapshot: snapshot, navigate: navigate).entrance(0.06)
                HStack(alignment: .top, spacing: 16) {
                    memoryCard(snapshot)
                    systemCard(snapshot)
                }
                .entrance(0.1)
                if model.processSamplingAvailable { ProcessesCard().entrance(0.14) }
                LaunchItemsCard(navigate: navigate).entrance(0.18)
            } else {
                HeroState(item: .performance, title: "Sampling your Mac…", message: "Reading memory, CPU, thermal and disk measurements from macOS.", busy: true) { EmptyView() }
            }
        }
        .navigationTitle("Performance")
        // Samples only while the page is visible; toggling Live restarts or stops the loop.
        .task(id: model.isLive) { await model.run() }
    }

    // MARK: Vitals

    private func vitals(_ snapshot: SystemSnapshot) -> some View {
        let model = app.performance
        let history = model.history
        let memory = PerformanceModel.memoryUsed(snapshot)
        let disk = PerformanceModel.diskFree(snapshot)
        let loadPerCore = snapshot.loadAverage.0 / Double(max(snapshot.logicalCPUs, 1))
        let cpuBusy = history.last?.cpuBusy
        let cpuLevel: StatusChip.Level = loadPerCore > 1 ? .serious : (loadPerCore > 0.7 ? .attention : .good)
        let memoryLevel: StatusChip.Level = snapshot.pressure == .critical ? .critical : (snapshot.pressure == .warning ? .attention : (snapshot.pressure == .unknown ? .neutral : .good))
        let diskLevel: StatusChip.Level = disk < 0.05 ? .critical : (disk < 0.10 ? .attention : .good)
        let thermalLevel: StatusChip.Level = switch snapshot.thermalState {
        case .nominal: .good
        case .fair: .attention
        case .serious: .serious
        default: .critical
        }
        let freeBytes = snapshot.startupVolume.flatMap { $0.availableForImportantUsage ?? $0.availableCapacity } ?? 0
        return GlassCard(padding: 16, tint: hue) {
            VStack(alignment: .leading, spacing: 14) {
                verdict(snapshot)
                HStack(spacing: 12) {
                    VitalTile(title: "Memory", symbol: "memorychip", value: memory.formatted(.percent.precision(.fractionLength(0))),
                              caption: String(localized: "in use · pressure \(snapshot.pressure.displayName.lowercased())"),
                              level: memoryLevel, levelText: snapshot.pressure.displayName,
                              trend: history.map(\.memoryUsed), color: Theme.series[6])
                    VitalTile(title: "CPU", symbol: "cpu",
                              value: cpuBusy.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? snapshot.loadAverage.0.formatted(.number.precision(.fractionLength(2))),
                              caption: cpuBusy != nil
                                  ? String(localized: "busy · load \(snapshot.loadAverage.0.formatted(.number.precision(.fractionLength(2)))) on \(snapshot.logicalCPUs) cores")
                                  : String(localized: "load (1 min) on \(snapshot.logicalCPUs) cores"),
                              level: cpuLevel, levelText: cpuLevel == .good ? String(localized: "Normal") : (cpuLevel == .attention ? String(localized: "Busy") : String(localized: "Overloaded")),
                              trend: history.map { $0.cpuBusy ?? min(1, $0.loadPerCore) }, color: Theme.brandBlue)
                    VitalTile(title: "Startup Disk", symbol: "internaldrive", value: disk.formatted(.percent.precision(.fractionLength(0)).rounded(rule: .down)),
                              caption: String(localized: "free · \(ByteFormat.string(freeBytes, style: byteStyle))"),
                              level: diskLevel, levelText: diskLevel == .good ? String(localized: "Enough space") : String(localized: "Low"),
                              trend: history.map(\.diskFree), color: Theme.brandTeal)
                    VitalTile(title: "Temperature", symbol: "thermometer.medium", value: thermalName(snapshot.thermalState),
                              caption: String(localized: "swap used \(mem(snapshot.swapUsed ?? 0))"),
                              level: thermalLevel, levelText: thermalLevel == .good ? String(localized: "Cool") : String(localized: "Throttling"),
                              trend: nil, color: Theme.series[1])
                }
            }
        }
    }

    /// One plain-language answer before any numbers.
    private func verdict(_ snapshot: SystemSnapshot) -> some View {
        let model = app.performance
        let findings = model.findings
        let important = findings.filter { $0.severity == .important }.count
        let attention = findings.filter { $0.severity == .attention }.count
        let (symbol, color, title, detail): (String, Color, String, String) = {
            if important > 0 {
                return ("exclamationmark.triangle.fill", Theme.critical,
                        important == 1 ? String(localized: "1 thing needs attention") : String(localized: "\(important) things need attention"),
                        String(localized: "See the checks below — each comes with the measurement behind it."))
            }
            if attention > 0 {
                return ("exclamationmark.circle.fill", Theme.warning,
                        attention == 1 ? String(localized: "Mostly fine, 1 thing worth a look") : String(localized: "Mostly fine, \(attention) things worth a look"),
                        String(localized: "Nothing urgent. Details are in the checks below."))
            }
            return ("checkmark.seal.fill", Theme.good, String(localized: "Your Mac looks healthy"),
                    String(localized: "Memory, CPU, temperature and disk space are all within normal ranges."))
        }()
        return HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.title3.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(model.isLive ? String(localized: "Updated \(snapshot.takenAt.formatted(date: .omitted, time: .standard))")
                                  : String(localized: "Sampled \(snapshot.takenAt.formatted(date: .omitted, time: .standard))"))
                    .font(.caption).monospacedDigit()
                Text(model.isLive ? String(localized: "every \(Int(PerformanceModel.liveInterval)) seconds while open") : String(localized: "Live is off"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Memory & system

    private func memoryCard(_ snapshot: SystemSnapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(title: "Memory", systemImage: "memorychip")
                if let memory = snapshot.memory {
                    let parts: [(String, UInt64, Color, String)] = [
                        ("wired", memory.wired, Theme.series[1], String(localized: "Wired")),
                        ("active", memory.active, Theme.series[0], String(localized: "Active")),
                        ("compressed", memory.compressed, Theme.series[6], String(localized: "Compressed")),
                        ("inactive", memory.inactive, Theme.series[2], String(localized: "Inactive (reusable)")),
                    ]
                    CapacityBar(segments: parts.map { .init(id: $0.0, value: Double($0.1), color: $0.2, label: "\($0.3) \(mem($0.1))") },
                                total: Double(memory.physical))
                    FlowLayout(spacing: 12, rowSpacing: 6) {
                        ForEach(parts, id: \.0) { part in LegendChip(color: part.2, label: part.3, value: mem(part.1)) }
                        LegendChip(color: Theme.track, label: String(localized: "Free"), value: mem(memory.free))
                    }
                    HStack(spacing: 20) {
                        Metric(value: mem(memory.physical), caption: "Installed")
                        Metric(value: snapshot.pressure.displayName, caption: "Memory pressure")
                        if let used = snapshot.swapUsed { Metric(value: mem(used), caption: "Swap used") }
                    }
                    Text("Unused memory is wasted memory: macOS keeps recently used data in RAM on purpose. Pressure, not free memory, shows whether your Mac needs more.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func systemCard(_ snapshot: SystemSnapshot) -> some View {
        let cores = Double(max(snapshot.logicalCPUs, 1))
        let loads: [(LocalizedStringKey, Double)] = [("1 min", snapshot.loadAverage.0), ("5 min", snapshot.loadAverage.1), ("15 min", snapshot.loadAverage.2)]
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(title: "System", systemImage: "cpu")
                Text("Load average — waiting work per core (1.0 = every core busy)").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(loads.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 10) {
                        Text(entry.0).font(.caption).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                        MeterBar(fraction: entry.1 / cores, color: entry.1 / cores > 1 ? Theme.serious : Theme.brandBlue, height: 6)
                        Text(entry.1.formatted(.number.precision(.fractionLength(2)))).font(.callout).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    GridRow { Text("Cores").foregroundStyle(.secondary); Text(verbatim: "\(snapshot.logicalCPUs)") }
                    GridRow { Text("Thermal state").foregroundStyle(.secondary); Text(thermal(snapshot.thermalState)) }
                    GridRow { Text("Up for").foregroundStyle(.secondary); Text(formattedUptime(app.performance.uptime)) }
                }
                .font(.callout)
                .padding(.top, 2)
            }
        }
    }

    private func formattedUptime(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        return formatter.string(from: interval) ?? ""
    }

    private func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: String(localized: "Normal")
        case .fair: String(localized: "Fair")
        case .serious: String(localized: "Serious")
        case .critical: String(localized: "Critical")
        @unknown default: String(localized: "Unknown")
        }
    }

    private func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: String(localized: "Normal")
        case .fair: String(localized: "Fair")
        case .serious: String(localized: "Serious — performance reduced")
        case .critical: String(localized: "Critical — performance reduced")
        @unknown default: String(localized: "Unknown")
        }
    }
}

func mem(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}

// MARK: - Vitals

private struct VitalTile: View {
    let title: LocalizedStringKey
    let symbol: String
    let value: String
    let caption: String
    let level: StatusChip.Level
    let levelText: String
    /// Shares 0…1 over time; nil for values without a meaningful trend.
    let trend: [Double]?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(color).frame(width: 16)
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                StatusChip(level: level, text: levelText)
            }
            Text(value).font(.metric(26)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Group {
                if let trend {
                    Sparkline(values: trend, color: color, capacity: PerformanceModel.historyCapacity)
                        .overlay(alignment: .bottomLeading) {
                            if trend.count < 2 {
                                Text("Trend appears as Live samples").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                } else {
                    Text("As reported by macOS").font(.caption2).foregroundStyle(.tertiary)
                        .frame(maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .frame(height: 30)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.track.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A small "recording" dot (static: a repeating pulse would redraw the window continuously).
private struct LiveDot: View {
    let isLive: Bool
    let color: Color

    var body: some View {
        Circle()
            .fill(isLive ? color : Color.secondary.opacity(0.5))
            .frame(width: 7, height: 7)
            .overlay { if isLive { Circle().stroke(color.opacity(0.35), lineWidth: 3).padding(-2) } }
            .accessibilityHidden(true)
    }
}

// MARK: - Health checks

/// Every check PureMac makes, passing or not, with the evidence and next step for each finding.
private struct HealthChecks: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    let snapshot: SystemSnapshot
    let navigate: (SidebarItem) -> Void

    struct Check: Identifiable {
        var id: String
        var title: String
        var symbol: String
        var measurement: String
        var finding: DiagnosticFinding?
    }

    var body: some View {
        let checks = makeChecks().sorted { ($0.finding?.severity.rawValue ?? -1) > ($1.finding?.severity.rawValue ?? -1) }
        let passing = checks.filter { $0.finding == nil }.count
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CardTitle(title: "Health Checks", systemImage: "stethoscope")
                    Spacer()
                    Text("\(passing) of \(checks.count) passed").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                VStack(spacing: 8) {
                    ForEach(checks) { check in CheckRow(check: check, action: action(for: check.finding?.id)) }
                }
            }
        }
    }

    private func makeChecks() -> [Check] {
        let model = app.performance
        let byID = Dictionary(model.findings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let disk = PerformanceModel.diskFree(snapshot)
        let free = snapshot.startupVolume.flatMap { $0.availableForImportantUsage ?? $0.availableCapacity } ?? 0
        let busy = model.topCPU.filter { $0.cpuPercent >= 80 && $0.pid != ProcessInfo.processInfo.processIdentifier }
        let broken = model.launchItems.filter { !$0.programExists }.count
        return [
            Check(id: "disk", title: String(localized: "Free disk space"), symbol: "internaldrive",
                  measurement: String(localized: "\(disk.formatted(.percent.precision(.fractionLength(0)).rounded(rule: .down))) free (\(ByteFormat.string(free, style: byteStyle)))"),
                  finding: byID["disk.low"]),
            Check(id: "memory", title: String(localized: "Memory pressure"), symbol: "memorychip",
                  measurement: snapshot.pressure.displayName, finding: byID["memory.pressure"]),
            Check(id: "thermal", title: String(localized: "Temperature"), symbol: "thermometer.medium",
                  measurement: snapshot.thermalState == .nominal ? String(localized: "No throttling") : String(localized: "Throttling"),
                  finding: byID["thermal"]),
            Check(id: "cpu", title: String(localized: "Runaway processes"), symbol: "cpu",
                  measurement: model.processSamplingAvailable
                      ? (busy.isEmpty ? String(localized: "None above 80% CPU") : busy.map(\.name).joined(separator: ", "))
                      : String(localized: "Not available in the App Store version"),
                  finding: byID["cpu.hot"]),
            Check(id: "launch", title: String(localized: "Background jobs"), symbol: "power",
                  measurement: broken == 0 ? String(localized: "All \(model.launchItems.count) point to existing programs") : String(localized: "\(broken) of \(model.launchItems.count) point to missing programs"),
                  finding: byID["launch.broken"]),
        ]
    }

    /// A direct next step for findings PureMac can help with.
    private func action(for id: String?) -> AnyView? {
        let hue = SidebarItem.performance.hue
        switch id {
        case "disk.low":
            return AnyView(HStack {
                Button("Free Up Space") { navigate(.smartClean) }.buttonStyle(.glow(hue))
                Button("Find Large Apps") {
                    app.apps.filter = .all
                    app.apps.sortOrder = .size
                    navigate(.applications)
                }
                .buttonStyle(.glow(.secondary, prominent: false))
            })
        case "memory.pressure", "cpu.hot", "thermal":
            return AnyView(Button("Open Activity Monitor") { SystemActions.openActivityMonitor() }
                .buttonStyle(.glow(.secondary, prominent: false)))
        case "launch.broken":
            return AnyView(Button("Review Orphaned Remnants") { navigate(.orphans) }
                .buttonStyle(.glow(.secondary, prominent: false)))
        default:
            return nil
        }
    }
}

private struct CheckRow: View {
    let check: HealthChecks.Check
    let action: AnyView?
    @State private var expanded: Bool?

    var body: some View {
        let finding = check.finding
        let isOpen = expanded ?? ((finding?.severity ?? .info) >= .attention)
        let color: Color = switch finding?.severity {
        case .important: Theme.critical
        case .attention: Theme.warning
        case .info: Theme.brandBlue
        case nil: Theme.good
        }
        VStack(alignment: .leading, spacing: 10) {
            Button { if finding != nil { expanded = !isOpen } } label: {
                HStack(spacing: 10) {
                    Image(systemName: finding == nil ? "checkmark.circle.fill" : (finding?.severity == .info ? "info.circle.fill" : "exclamationmark.triangle.fill"))
                        .foregroundStyle(color).font(.title3)
                    Image(systemName: check.symbol).foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(finding?.title ?? check.title).fontWeight(.medium)
                        Text(check.measurement).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if finding != nil {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    } else {
                        Text("Passed").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(finding == nil)
            .accessibilityLabel(Text(finding?.title ?? check.title))
            .accessibilityValue(Text(finding == nil ? String(localized: "Passed") : check.measurement))
            if let finding, isOpen {
                Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 4) {
                    GridRow {
                        Eyebrow(text: "Evidence")
                        Eyebrow(text: "What you can do")
                        Eyebrow(text: "What to expect")
                    }
                    GridRow {
                        Text(finding.evidence)
                        Text(finding.suggestion)
                        Text(finding.expectedEffect).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 30)
                if let action { action.padding(.leading, 30) }
            }
        }
        .padding(12)
        .background(finding == nil ? Theme.track.opacity(0.45) : color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            if finding != nil {
                UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12).fill(color).frame(width: 3)
            }
        }
        .animation(.easeOut(duration: 0.18), value: isOpen)
    }
}

// MARK: - Processes

private struct ProcessesCard: View {
    @Environment(AppModel.self) private var app
    @State private var ranking: Ranking = .cpu

    enum Ranking: String, CaseIterable, Identifiable {
        case cpu, memory
        var id: String { rawValue }
    }

    var body: some View {
        let model = app.performance
        let rows = ranking == .cpu ? model.topCPU : model.topMemory
        let largest = ranking == .cpu ? max(rows.map(\.cpuPercent).max() ?? 1, 1) : Double(max(rows.map(\.residentBytes).max() ?? 1, 1))
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardTitle(title: "Busiest Processes", systemImage: "chart.bar")
                    Spacer()
                    Picker("Rank by", selection: $ranking) {
                        Text("CPU").tag(Ranking.cpu)
                        Text("Memory").tag(Ranking.memory)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Button("Activity Monitor") { SystemActions.openActivityMonitor() }
                        .buttonStyle(.glow(.secondary, prominent: false))
                }
                if rows.isEmpty {
                    Text("No process used noticeable CPU during the sample.").foregroundStyle(.secondary)
                }
                VStack(spacing: 2) {
                    ForEach(rows) { process in
                        let info = model.appInfo[process.pid]
                        let fraction = ranking == .cpu ? process.cpuPercent / largest : Double(process.residentBytes) / largest
                        HStack(spacing: 10) {
                            Group {
                                if let icon = info?.icon {
                                    Image(nsImage: icon).resizable()
                                } else {
                                    Image(systemName: "gearshape.fill").resizable().scaledToFit().padding(3).foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 20, height: 20)
                            .accessibilityHidden(true)
                            Text(process.name).lineLimit(1).frame(width: 220, alignment: .leading)
                            MeterBar(fraction: fraction, color: ranking == .cpu ? Theme.brandBlue : Theme.series[6], height: 6)
                            Text(process.cpuPercent.formatted(.number.precision(.fractionLength(0))) + "%")
                                .monospacedDigit().frame(width: 52, alignment: .trailing)
                                .foregroundStyle(ranking == .cpu ? .primary : .secondary)
                            Text(mem(process.residentBytes)).monospacedDigit().frame(width: 80, alignment: .trailing)
                                .foregroundStyle(ranking == .memory ? .primary : .secondary)
                        }
                        .font(.callout)
                        .padding(.vertical, 3)
                        .contextMenu {
                            if let url = info?.bundleURL {
                                Button("Reveal in Finder") { SystemActions.revealInFinder([url.path]) }
                            }
                            Button("Open Activity Monitor") { SystemActions.openActivityMonitor() }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Text(ranking == .cpu
                     ? "CPU over the last sample; 100% is one full core. Only processes your account may inspect are shown, and PureMac never quits processes."
                     : "Memory each process holds right now. Only processes your account may inspect are shown, and PureMac never quits processes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Launch items

private struct LaunchItemsCard: View {
    @Environment(AppModel.self) private var app
    let navigate: (SidebarItem) -> Void
    @State private var filter: Filter = .all

    enum Filter: Hashable { case all, yours, system, problems }

    var body: some View {
        let items = app.performance.launchItems
        let yours = items.filter { $0.scope == .userAgent }
        let problems = items.filter { !$0.programExists }
        let shown: [LaunchItem] = switch filter {
        case .all: items
        case .yours: yours
        case .system: items.filter { $0.scope != .userAgent }
        case .problems: problems
        }
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardTitle(title: "Launch Agents & Daemons", systemImage: "power")
                    Spacer()
                    Button("Open Login Items Settings") { SystemActions.openLoginItemsSettings() }
                        .buttonStyle(.glow(.secondary, prominent: false))
                }
                Text("Background jobs PureMac can read. macOS’s complete list of login and background items is in System Settings → General → Login Items.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    FilterChip(label: String(localized: "All"), value: "\(items.count)", isOn: filter == .all, clears: false) { filter = .all }
                    FilterChip(label: String(localized: "Yours"), value: "\(yours.count)", isOn: filter == .yours, clears: false) { filter = .yours }
                    FilterChip(label: String(localized: "System-wide"), value: "\(items.count - yours.count)", isOn: filter == .system, clears: false) { filter = .system }
                    if !problems.isEmpty {
                        FilterChip(label: String(localized: "Missing program"), value: "\(problems.count)", symbol: "exclamationmark.triangle", isOn: filter == .problems, clears: false) { filter = .problems }
                    }
                }
                if shown.isEmpty {
                    Text("Nothing here.").foregroundStyle(.secondary).font(.callout)
                }
                VStack(spacing: 2) {
                    ForEach(shown) { item in row(item) }
                }
            }
        }
    }

    private func row(_ item: LaunchItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.programExists ? "checkmark.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(item.programExists ? Color.secondary : Theme.warning)
                .frame(width: 18)
                .accessibilityLabel(item.programExists ? "Program present" : "Program missing")
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label).lineLimit(1)
                if let program = item.program {
                    Text(abbreviate(program) + (item.programExists ? "" : String(localized: " — missing")))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if item.isDisabled { scopePill(String(localized: "Disabled")) }
            scopePill(item.scope == .userAgent ? String(localized: "Yours") : (item.scope == .systemAgent ? String(localized: "Agent") : String(localized: "Daemon")))
            if !item.programExists && item.scope == .userAgent {
                Button("Review…") { navigate(.orphans) }
                    .buttonStyle(.glow(.secondary, prominent: false)).controlSize(.small)
                    .help("Your launch agents with a missing program are listed under Orphaned Remnants, where you can move them to the Trash after review.")
            }
            Button { SystemActions.revealInFinder([item.plistPath]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Reveal the job’s file in Finder")
                .accessibilityLabel("Reveal \(item.label) in Finder")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Reveal in Finder") { SystemActions.revealInFinder([item.plistPath]) }
            Button("Copy Label") { SystemActions.copyToPasteboard(item.label) }
        }
    }

    private func scopePill(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.track, in: Capsule())
            .foregroundStyle(.secondary)
    }
}

extension LaunchItem.Scope {
    static let allScopes: [LaunchItem.Scope] = [.userAgent, .systemAgent, .systemDaemon]
}
