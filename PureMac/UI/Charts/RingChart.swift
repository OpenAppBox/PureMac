import SwiftUI

/// One slice of a ring chart.
struct RingSegment: Identifiable, Hashable {
    var id: String
    var value: Double
    var color: Color
    var label: String
    var detail: String
}

/// An interactive, animated donut. Segments draw in with a sweep on appear; hovering a segment
/// lifts it and reports it so the center can describe it. A 2-point surface gap separates fills.
struct RingChart<Center: View>: View {
    let segments: [RingSegment]
    /// Total the ring represents (the remainder is drawn as an empty track).
    let total: Double
    var lineWidth: CGFloat = 26
    var gapDegrees: Double = 1.2
    @Binding var hovered: RingSegment.ID?
    @ViewBuilder var center: (RingSegment?) -> Center

    @MotionReduced private var motionReduced
    @Environment(\.playsIntroAnimations) private var playsIntro
    @State private var reveal: Double = 0
    private var reduceMotion: Bool { motionReduced || !playsIntro }

    var body: some View {
        #if DEBUG
        let _ = PerfTrace.enabled ? Self._printChanges() : ()
        #endif
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let ranges = self.ranges()
            ZStack {
              ZStack {
                Circle()
                    .stroke(Theme.track, lineWidth: lineWidth)
                    .padding(lineWidth / 2 + 6)
                ForEach(Array(ranges.enumerated()), id: \.element.segment.id) { index, item in
                    let isHovered = hovered == item.segment.id
                    let gap = item.end - item.start > gapDegrees * 2 / 360 ? gapDegrees / 360 / 2 : 0
                    Circle()
                        .trim(from: (item.start + gap) * reveal, to: max((item.start + gap) * reveal, (item.end - gap) * reveal))
                        .stroke(item.segment.color, style: StrokeStyle(lineWidth: isHovered ? lineWidth + 8 : lineWidth, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                        .padding(lineWidth / 2 + 6)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
                        .accessibilityHidden(true)
                        .zIndex(isHovered ? 1 : Double(index) * 0.001)
                }
              }
              .drawingGroup() // own GPU layer for the reveal and hover animations
                center(segments.first { $0.id == hovered })
                    .frame(width: max(0, size - lineWidth * 2 - 40))
            }
            .frame(width: size, height: size)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .contentShape(Circle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let id = segment(at: point, in: geo.size, ranges: ranges)?.id
                    if id != hovered { hovered = id }
                case .ended:
                    if hovered != nil { hovered = nil }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            if reduceMotion { reveal = 1 } else {
                withAnimation(.easeOut(duration: 0.55)) { reveal = 1 }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(segments.map { "\($0.label) \($0.detail)" }.joined(separator: ", "))
    }

    private func ranges() -> [(segment: RingSegment, start: Double, end: Double)] {
        let denominator = max(total, segments.reduce(0) { $0 + $1.value }, 1)
        var cursor = 0.0
        return segments.filter { $0.value > 0 }.map { segment in
            let start = cursor
            cursor += segment.value / denominator
            return (segment, start, min(cursor, 1))
        }
    }

    private func segment(at point: CGPoint, in size: CGSize, ranges: [(segment: RingSegment, start: Double, end: Double)]) -> RingSegment? {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = point.x - c.x, dy = point.y - c.y
        let radius = min(size.width, size.height) / 2
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > radius - lineWidth * 2 - 14, distance < radius + 4 else { return nil }
        var angle = atan2(dx, -dy) / (2 * .pi)   // 0 at 12 o'clock, clockwise
        if angle < 0 { angle += 1 }
        return ranges.first { angle >= $0.start && angle < $0.end }?.segment
    }
}

/// Single-value radial gauge (e.g. memory pressure, selection share).
struct GaugeRing: View {
    let fraction: Double
    var color: Color
    var lineWidth: CGFloat = 10
    var label: String
    var caption: String

    @MotionReduced private var reduceMotion
    @State private var shown = 0.0

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)) * shown)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                RollingText(text: label, font: .metric(18))
                Text(caption).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(lineWidth / 2)
        .onAppear {
            if reduceMotion { shown = 1 } else { withAnimation(.easeOut(duration: 0.9)) { shown = 1 } }
        }
        .animation(.easeInOut(duration: 0.5), value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(caption): \(label)")
    }
}

/// Horizontal bars with animated growth, direct labels and a 2-point gap between rows.
struct BarListRow: View {
    let title: String
    /// Where the item is, in quieter text after the title (tells same-named folders apart).
    var subtitle: String?
    let value: String
    let fraction: Double
    let color: Color
    var icon: String?
    var iconPath: String?
    var delay: Double = 0

    @MotionReduced private var motionReduced
    @Environment(\.playsIntroAnimations) private var playsIntro
    @State private var grown = false
    private var reduceMotion: Bool { motionReduced || !playsIntro }
    @State private var hovering = false

    var body: some View {
        #if DEBUG
        let _ = PerfTrace.enabled ? Self._printChanges() : ()
        #endif
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if let iconPath { FileIcon(path: iconPath, size: 18) }
                if let icon { Image(systemName: icon).foregroundStyle(color).frame(width: 18) }
                Text(title).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                if let subtitle {
                    Text(verbatim: subtitle).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 8)
                Text(value).monospacedDigit().foregroundStyle(.secondary).fixedSize().layoutPriority(2)
            }
            .font(.callout)
            // Growth animates scale (render-only), never width (which would re-layout the screen per frame).
            Capsule().fill(Theme.track)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(color.opacity(hovering ? 1 : 0.9))
                        .scaleEffect(x: max(0.015, min(1, fraction)) * (grown || reduceMotion ? 1 : 0.02), y: 1, anchor: .leading)
                }
                .frame(height: 6)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.45).delay(min(delay, 0.2))) { grown = true }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A legend chip.
struct LegendChip: View {
    let color: Color
    let label: String
    var value: String?
    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            Text(label).foregroundStyle(.primary).lineLimit(1)
            if let value { Text(value).foregroundStyle(.secondary).monospacedDigit().lineLimit(1) }
        }
        .font(.caption)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
