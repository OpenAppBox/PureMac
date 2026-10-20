import CoreGraphics
import Testing
@testable import PureMacKit

@Suite("Treemap layout")
struct TreemapTests {
    @Test func tilesCoverBoundsProportionally() {
        let items = [60.0, 25, 10, 5].enumerated().map { SquarifiedTreemap.Item(id: $0.offset, weight: $0.element) }
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let tiles = SquarifiedTreemap.layout(items, in: bounds)
        #expect(tiles.count == 4)
        let totalArea = tiles.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
        #expect(abs(totalArea - 120_000) < 1)
        for tile in tiles {
            #expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(tile.rect))
            let expected = items[tile.id].weight / 100 * 120_000
            #expect(abs(Double(tile.rect.width * tile.rect.height) - expected) < 1)
        }
        // No overlaps.
        for a in tiles { for b in tiles where a.id < b.id {
            #expect(a.rect.intersection(b.rect).width * a.rect.intersection(b.rect).height < 0.01)
        } }
    }

    @Test func emptyAndZeroWeightsProduceNoTiles() {
        #expect(SquarifiedTreemap.layout([SquarifiedTreemap.Item(id: 1, weight: 0)], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
        #expect(SquarifiedTreemap.layout([SquarifiedTreemap.Item(id: 1, weight: 5)], in: .zero).isEmpty)
    }

    @Test func tailIsGroupedIntoOther() {
        var items = [SquarifiedTreemap.Item(id: 0, weight: 1000)]
        items += (1...500).map { SquarifiedTreemap.Item(id: $0, weight: 1) }
        let grouped = SquarifiedTreemap.groupTail(items, maxItems: 40, minimumFraction: 0.005, otherID: -1)
        #expect(grouped.count == 2)
        #expect(grouped.last?.id == -1)
        #expect(grouped.last?.weight == 500)
        #expect(grouped.reduce(0) { $0 + $1.weight } == 1500)
    }
}
