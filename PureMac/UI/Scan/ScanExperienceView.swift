import Charts
import PureMacKit
import SwiftUI

/// The live scan: an animated "scanner core", rolling counters, a throughput chart and
/// per-category bars that grow from real progress data. Motion stops with Reduce Motion.
struct ScanExperienceView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle

    var body: some View {
        let scan = app.scan
        let p = scan.progress
        GlassCard(padding: 24, tint: SidebarItem.overview.hue) {
            HStack(alignment: .center, spacing: 32) {
                ScannerCore(intensity: min(1, scan.currentFilesPerSecond / max(scan.peakFilesPerSecond, 1)), cancelling: scan.phase == .cancelling) {
                    VStack(spacing: 2) {
                        RollingText(text: p.filesVisited.formatted(), font: .hero(34), rolls: true)
                        Text("files measured").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 290, height: 290)

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scan.phase == .cancelling ? "Stopping scan…" : "Scanning your Mac")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                            Text(p.currentTopLevel.isEmpty ? abbreviate(p.currentRoot) : "In \(p.currentTopLevel)")
                                .font(.callout).foregroundStyle(.secondary)
                                .contentTransition(.opacity)
                                .animation(.easeInOut, value: p.currentTopLevel)
                        }
                        Spacer()
                        Button(role: .cancel) { scan.cancel() } label: { Label("Stop", systemImage: "stop.fill") }
                            .buttonStyle(.glow(Theme.critical, prominent: false))
                            .disabled(scan.phase == .cancelling)
                            .keyboardShortcut(".", modifiers: [.command])
                    }
                    HStack(spacing: 26) {
                        StatBlock(value: p.directoriesVisited.formatted(), label: "Folders")
                        StatBlock(value: ByteFormat.string(p.allocatedBytes, style: byteStyle), label: "Measured")
                        StatBlock(value: Int(scan.currentFilesPerSecond).formatted(), label: "Files / second")
                        StatBlock(value: formattedDuration(p.elapsed), label: "Elapsed")
                        if p.issueCount > 0 { StatBlock(value: p.issueCount.formatted(), label: "Not readable", tint: Theme.serious) }
                    }
                    ThroughputChart(samples: scan.throughput)
                        .frame(height: 74)
                    LiveCategoryBar(allocated: p.categoryAllocated)
                    Text(p.currentRelativePath.isEmpty ? " " : p.currentRelativePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.head)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scan in progress: \(p.filesVisited) files")
    }
}

/// Concentric orbiting arcs, a radar sweep, a breathing glow and sparks around a center label.
/// All continuous motion is Core Animation (see `OrbitCoreView`).
struct ScannerCore<Center: View>: View {
    var intensity: Double
    var cancelling: Bool
    var hue: Color = SidebarItem.overview.hue
    @ViewBuilder var center: Center

    @MotionReduced private var reduceMotion

    var body: some View {
        ZStack {
            OrbitCore(hue: hue, accent: Theme.brandTeal, intensity: intensity, animated: !reduceMotion && !cancelling)
            // A 70-point inset, capped for small cores: below 140 points a fixed inset went negative
            // and the invalid geometry blanked the whole window.
            GeometryReader { geo in
                let inset = min(70, min(geo.size.width, geo.size.height) * 0.35)
                Circle()
                    .fill(Theme.cardSurface)
                    .overlay(Circle().strokeBorder(Theme.cardHighlight, lineWidth: 1))
                    .padding(inset)
                    .shadow(color: hue.opacity(0.4), radius: 16)
            }
            center
        }
        .accessibilityHidden(true)
    }
}

/// 72 tick marks around a circle.
struct TickRing: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        for i in 0..<72 {
            let a = Double(i) / 72 * 2 * .pi
            let inner = r - (i % 6 == 0 ? 9 : 4)
            path.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * inner, y: c.y + CGFloat(sin(a)) * inner))
            path.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r))
        }
        return path
    }
}

/// Live files-per-second area chart.
struct ThroughputChart: View {
    let samples: [ScanModel.ThroughputSample]

    var body: some View {
        Chart(samples) { sample in
            AreaMark(x: .value("Time", sample.elapsed), y: .value("Files per second", sample.filesPerSecond))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(LinearGradient(colors: [Theme.brandTeal.opacity(0.45), Theme.brandTeal.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Time", sample.elapsed), y: .value("Files per second", sample.filesPerSecond))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .foregroundStyle(Theme.brandTeal)
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Theme.track)
                AxisValueLabel { if let v = value.as(Double.self) { Text(Int(v).formatted()).font(.caption2) } }
            }
        }
        .overlay(alignment: .topLeading) { Eyebrow(text: "Throughput (files/s)") }
        .accessibilityLabel("Scan throughput over time")
    }
}

/// A stacked bar of bytes found per category, growing as the scan progresses.
struct LiveCategoryBar: View {
    let allocated: [Int64]
    @Environment(\.byteStyle) private var byteStyle

    var body: some View {
        let items = StorageCategory.allCases
            .map { ($0, allocated.indices.contains($0.rawValue) ? allocated[$0.rawValue] : 0) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        let total = max(items.reduce(0) { $0 + $1.1 }, 1)
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Found so far")
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(items, id: \.0) { category, bytes in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(category.tint)
                            .frame(width: max(3, (geo.size.width - CGFloat(items.count) * 2) * CGFloat(bytes) / CGFloat(total)))
                            .help("\(category.displayName): \(ByteFormat.string(bytes, style: byteStyle))")
                    }
                }
                .animation(.easeOut(duration: 0.4), value: allocated)
            }
            .frame(height: 12)
            FlowLegend(items: items.prefix(5).map { (color: $0.0.tint, label: $0.0.displayName, value: ByteFormat.string($0.1, style: byteStyle)) })
        }
    }
}

/// Wrapping legend.
struct FlowLegend: View {
    let items: [(color: Color, label: String, value: String)]
    var body: some View {
        HStack(spacing: 14) {
            ForEach(items, id: \.label) { item in LegendChip(color: item.color, label: item.label, value: item.value) }
        }
    }
}
