import SwiftUI

/// Lays children out left to right, wrapping onto new rows (chips, folder tokens).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + rowSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// A capsule that filters a list: color swatch (identity), label, value. Filled while active.
struct FilterChip: View {
    let label: String
    var value: String?
    var color: Color?
    var symbol: String?
    let isOn: Bool
    /// Shows an ✕ while on (a filter that can be removed); off for one-of-many choices.
    var clears = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let color { RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10) }
                if let symbol { Image(systemName: symbol).imageScale(.small) }
                Text(label).lineLimit(1)
                if let value { Text(value).foregroundStyle(.secondary).monospacedDigit().lineLimit(1) }
                if isOn && clears { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary) }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(isOn ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(Theme.track.opacity(hovering ? 1.6 : 1)), in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .fixedSize()
    }
}

/// A state label that always pairs the reserved status color with an icon and text.
struct StatusChip: View {
    enum Level { case good, attention, serious, critical, neutral }
    let level: Level
    let text: String

    var body: some View {
        Label { Text(text).lineLimit(1) } icon: { Image(systemName: symbol) }
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
            .fixedSize()
    }

    var color: Color {
        switch level {
        case .good: Theme.good
        case .attention: Theme.warning
        case .serious: Theme.serious
        case .critical: Theme.critical
        case .neutral: .secondary
        }
    }

    private var symbol: String {
        switch level {
        case .good: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .serious, .critical: "exclamationmark.triangle.fill"
        case .neutral: "circle.dashed"
        }
    }
}

/// A small trend line (2-point stroke, soft fill) drawn in one Canvas pass. `values` are 0…1.
struct Sparkline: View {
    let values: [Double]
    var color: Color
    /// Number of samples the full width represents, so a short history grows from the right.
    var capacity: Int = 60

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(max(capacity - 1, 1))
            let start = size.width - step * CGFloat(values.count - 1)
            func point(_ i: Int) -> CGPoint {
                CGPoint(x: start + step * CGFloat(i), y: size.height - 1 - CGFloat(min(1, max(0, values[i]))) * (size.height - 2))
            }
            var line = Path()
            line.move(to: point(0))
            for i in 1..<values.count { line.addLine(to: point(i)) }
            var area = line
            area.addLine(to: CGPoint(x: point(values.count - 1).x, y: size.height))
            area.addLine(to: CGPoint(x: start, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.28), color.opacity(0)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            let last = point(values.count - 1)
            context.fill(Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)), with: .color(color))
        }
        .accessibilityHidden(true)
    }
}

/// A thin horizontal meter (render-only scale, no per-frame layout).
struct MeterBar: View {
    let fraction: Double
    var color: Color
    var height: CGFloat = 5

    var body: some View {
        Capsule().fill(Theme.track)
            .overlay(alignment: .leading) {
                Capsule().fill(color)
                    .scaleEffect(x: max(0.012, min(1, fraction)), y: 1, anchor: .leading)
            }
            .frame(height: height)
            .accessibilityHidden(true)
    }
}
