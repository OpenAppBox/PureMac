import SwiftUI

struct SunburstNode: Identifiable, Hashable {
    var id: Int64
    var name: String
    var value: Double
    var color: Color
    var isContainer: Bool
    var children: [SunburstNode] = []
}

/// Two-ring radial map of a folder: the inner ring is its children, the outer ring their children.
/// Drawn in a single Canvas (no per-arc views); hover and click are resolved with polar math.
/// The reveal animation interpolates through `animatableData`.
struct SunburstView: View, Animatable {
    let nodes: [SunburstNode]
    let total: Double
    var centerTitle: String
    var centerValue: String
    var reveal: Double = 1
    var onOpen: (Int64) -> Void = { _ in }

    var animatableData: Double {
        get { reveal }
        set { reveal = newValue }
    }

    @State private var hovered: Int64?
    @Environment(\.colorScheme) private var scheme

    struct Arc {
        var node: SunburstNode
        var ring: Int
        var start: Double
        var end: Double
    }

    var body: some View {
        #if DEBUG
        let _ = PerfTrace.enabled ? Self._printChanges() : ()
        #endif
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let arcs = layout()
            let radii = ringRadii(size: size)
            ZStack {
                Canvas { context, _ in
                    for arc in arcs {
                        draw(arc, in: &context, center: center, radii: radii)
                    }
                }
                .drawingGroup() // own GPU layer: reveal/hover frames redraw only the chart
                VStack(spacing: 2) {
                    if let node = arcs.first(where: { $0.node.id == hovered })?.node {
                        Text(node.name).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                        Text(formatShare(node.value)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(centerTitle).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                        Text(centerValue).font(.metric(20)).monospacedDigit()
                    }
                }
                .frame(width: radii.inner * 1.6)
                .position(center)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let point) = phase {
                    let id = hit(point, center: center, radii: radii, arcs: arcs)?.node.id
                    if id != hovered { hovered = id }
                } else if hovered != nil {
                    hovered = nil
                }
            }
            .onTapGesture(count: 2, coordinateSpace: .local) { point in
                if let arc = hit(point, center: center, radii: radii, arcs: arcs), arc.node.isContainer { onOpen(arc.node.id) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sunburst map of \(centerTitle)")
        .accessibilityHint("A radial view of the folders listed below.")
    }

    private func ringRadii(size: CGFloat) -> (inner: CGFloat, mid: CGFloat, outer: CGFloat) {
        let outer = size / 2 - 4
        return (outer * 0.36, outer * 0.68, outer)
    }

    private func layout() -> [Arc] {
        let denominator = max(total, nodes.reduce(0) { $0 + $1.value }, 1)
        var arcs: [Arc] = []
        var cursor = 0.0
        for node in nodes where node.value > 0 {
            let span = node.value / denominator
            arcs.append(Arc(node: node, ring: 0, start: cursor, end: cursor + span))
            var inner = cursor
            let childTotal = max(node.value, node.children.reduce(0) { $0 + $1.value })
            for child in node.children where child.value > 0 {
                let childSpan = span * child.value / childTotal
                if childSpan > 0.002 { arcs.append(Arc(node: child, ring: 1, start: inner, end: inner + childSpan)) }
                inner += childSpan
            }
            cursor += span
        }
        return arcs
    }

    private func draw(_ arc: Arc, in context: inout GraphicsContext, center: CGPoint, radii: (inner: CGFloat, mid: CGFloat, outer: CGFloat)) {
        let start = arc.start * reveal, end = arc.end * reveal
        guard end - start > 0.0005 else { return }
        let gap = min(0.0015, (end - start) / 4)
        let (r0, r1) = arc.ring == 0 ? (radii.inner, radii.mid - 3) : (radii.mid, radii.outer)
        let isHovered = hovered == arc.node.id
        let lift: CGFloat = isHovered ? 5 : 0
        var path = Path()
        let a0 = Angle(radians: (start + gap) * 2 * .pi - .pi / 2)
        let a1 = Angle(radians: (end - gap) * 2 * .pi - .pi / 2)
        path.addArc(center: center, radius: r1 + lift, startAngle: a0, endAngle: a1, clockwise: false)
        path.addArc(center: center, radius: r0, startAngle: a1, endAngle: a0, clockwise: true)
        path.closeSubpath()
        context.fill(path, with: .color(arc.ring == 0 ? arc.node.color : arc.node.color.opacity(0.62)))
        if isHovered {
            context.stroke(path, with: .color(.white.opacity(0.85)), lineWidth: 1.5)
        }
        // Direct labels only where there is room.
        let sweep = (end - start) * 2 * .pi * Double(r1)
        if arc.ring == 0, sweep > 70, reveal > 0.95 {
            let mid = (start + end) / 2 * 2 * .pi - .pi / 2
            let r = (r0 + r1) / 2
            let point = CGPoint(x: center.x + CGFloat(cos(mid)) * r, y: center.y + CGFloat(sin(mid)) * r)
            context.draw(Text(arc.node.name).font(.caption2.weight(.semibold)).foregroundStyle(.white), at: point)
        }
    }

    private func hit(_ point: CGPoint, center: CGPoint, radii: (inner: CGFloat, mid: CGFloat, outer: CGFloat), arcs: [Arc]) -> Arc? {
        let dx = point.x - center.x, dy = point.y - center.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let ring: Int
        if distance >= radii.inner && distance < radii.mid { ring = 0 } else if distance >= radii.mid && distance <= radii.outer + 6 { ring = 1 } else { return nil }
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        let t = angle / (2 * .pi)
        return arcs.first { $0.ring == ring && t >= $0.start && t < $0.end }
    }

    private func formatShare(_ value: Double) -> String {
        let share = value / max(total, 1)
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) + " · " + share.formatted(.percent.precision(.fractionLength(share < 0.1 ? 1 : 0)))
    }
}

/// Animates a sunburst in when its data changes.
struct AnimatedSunburst: View {
    let nodes: [SunburstNode]
    let total: Double
    let centerTitle: String
    let centerValue: String
    var onOpen: (Int64) -> Void

    @MotionReduced private var motionReduced
    @Environment(\.playsIntroAnimations) private var playsIntro
    @State private var reveal = 0.0
    private var reduceMotion: Bool { motionReduced || !playsIntro }

    var body: some View {
        SunburstView(nodes: nodes, total: total, centerTitle: centerTitle, centerValue: centerValue, reveal: reveal, onOpen: onOpen)
            .onAppear { animateIn() }
            .onChange(of: nodes.map(\.id)) { _, _ in
                reveal = 0
                animateIn()
            }
    }

    private func animateIn() {
        if reduceMotion { reveal = 1 } else { withAnimation(.easeOut(duration: 0.5)) { reveal = 1 } }
    }
}
