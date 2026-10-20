import CoreGraphics
import Foundation

/// Squarified treemap layout (Bruls, Huizing & van Wijk). Pure function, deterministic for a given
/// input order. Items are expected sorted by weight descending; zero-weight items are dropped.
public enum SquarifiedTreemap {
    public struct Item<ID: Hashable & Sendable>: Sendable {
        public var id: ID
        public var weight: Double
        public init(id: ID, weight: Double) {
            self.id = id
            self.weight = weight
        }
    }

    public struct Tile<ID: Hashable & Sendable>: Sendable {
        public var id: ID
        public var rect: CGRect
    }

    /// Groups a long tail into a single "other" item so the map never draws thousands of slivers.
    /// Keeps at most `maxItems` items and folds any item below `minimumFraction` of the total.
    public static func groupTail<ID: Hashable & Sendable>(_ items: [Item<ID>], maxItems: Int, minimumFraction: Double,
                                                          otherID: ID) -> [Item<ID>] {
        let sorted = items.filter { $0.weight > 0 }.sorted { $0.weight > $1.weight }
        let total = sorted.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return [] }
        var kept: [Item<ID>] = []
        var other = 0.0
        for item in sorted {
            if kept.count < maxItems, item.weight / total >= minimumFraction {
                kept.append(item)
            } else {
                other += item.weight
            }
        }
        if other > 0 { kept.append(Item(id: otherID, weight: other)) }
        return kept
    }

    public static func layout<ID: Hashable & Sendable>(_ items: [Item<ID>], in bounds: CGRect) -> [Tile<ID>] {
        let positive = items.filter { $0.weight > 0 }
        let total = positive.reduce(0) { $0 + $1.weight }
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return [] }
        let scale = Double(bounds.width * bounds.height) / total
        var remaining = positive.map { (id: $0.id, area: $0.weight * scale) }
        var rect = bounds
        var tiles: [Tile<ID>] = []
        tiles.reserveCapacity(positive.count)

        while !remaining.isEmpty {
            let side = Double(min(rect.width, rect.height))
            var row: [(id: ID, area: Double)] = [remaining.removeFirst()]
            while let next = remaining.first {
                let current = worstRatio(row.map(\.area), side: side)
                let candidate = worstRatio(row.map(\.area) + [next.area], side: side)
                if candidate <= current {
                    row.append(remaining.removeFirst())
                } else {
                    break
                }
            }
            rect = place(row, in: rect, into: &tiles)
        }
        return tiles
    }

    private static func worstRatio(_ areas: [Double], side: Double) -> Double {
        let sum = areas.reduce(0, +)
        guard sum > 0, side > 0, let maxArea = areas.max(), let minArea = areas.min(), minArea > 0 else { return .infinity }
        let s2 = side * side
        let sum2 = sum * sum
        return max(s2 * maxArea / sum2, sum2 / (s2 * minArea))
    }

    private static func place<ID>(_ row: [(id: ID, area: Double)], in rect: CGRect, into tiles: inout [Tile<ID>]) -> CGRect {
        let sum = row.reduce(0) { $0 + $1.area }
        if rect.width >= rect.height {
            // Lay the row out as a vertical strip on the left.
            let stripWidth = rect.height > 0 ? CGFloat(sum) / rect.height : 0
            var y = rect.minY
            for item in row {
                let h = stripWidth > 0 ? CGFloat(item.area) / stripWidth : 0
                tiles.append(Tile(id: item.id, rect: CGRect(x: rect.minX, y: y, width: stripWidth, height: h)))
                y += h
            }
            return CGRect(x: rect.minX + stripWidth, y: rect.minY, width: max(0, rect.width - stripWidth), height: rect.height)
        } else {
            let stripHeight = rect.width > 0 ? CGFloat(sum) / rect.width : 0
            var x = rect.minX
            for item in row {
                let w = stripHeight > 0 ? CGFloat(item.area) / stripHeight : 0
                tiles.append(Tile(id: item.id, rect: CGRect(x: x, y: rect.minY, width: w, height: stripHeight)))
                x += w
            }
            return CGRect(x: rect.minX, y: rect.minY + stripHeight, width: rect.width, height: max(0, rect.height - stripHeight))
        }
    }
}
