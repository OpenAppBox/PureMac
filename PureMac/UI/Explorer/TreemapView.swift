import PureMacKit
import SwiftUI

/// Interactive storage map of the current folder's children. Rendered with `Canvas` and capped
/// at a few dozen tiles (the tail is grouped as "Other"), so it never draws thousands of slivers.
/// The table below it is the accessible, list-based equivalent.
struct TreemapView: View {
    let records: [FileRecord]
    /// Bytes not represented by `records` (e.g. small files summarized in the parent).
    let otherBytes: Int64
    let selection: Set<Int64>
    let onSelect: (FileRecord) -> Void
    let onOpen: (FileRecord) -> Void

    @Environment(\.byteStyle) private var byteStyle
    @State private var hoveredID: Int64?

    private static let otherID: Int64 = -1

    var body: some View {
        GeometryReader { geo in
            let tiles = layout(in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for tile in tiles {
                        draw(tile, in: &context)
                    }
                }
                if let hoveredID, let tile = tiles.first(where: { $0.id == hoveredID }) {
                    tooltip(for: tile)
                        .position(x: min(max(tile.rect.midX, 110), geo.size.width - 110),
                                  y: max(tile.rect.minY + 26, 20))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let id = tiles.first(where: { $0.rect.contains(location) })?.id
                    if id != hoveredID { hoveredID = id }
                case .ended:
                    if hoveredID != nil { hoveredID = nil }
                }
            }
            .gesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    if let record = record(at: value.location, tiles: tiles), record.isContainer { onOpen(record) }
                }
                .exclusively(before: SpatialTapGesture(count: 1).onEnded { value in
                    if let record = record(at: value.location, tiles: tiles) { onSelect(record) }
                })
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage map")
        .accessibilityHint("A visual map of the items listed in the table below. Use the table to navigate with the keyboard or VoiceOver.")
        .overlay {
            if records.isEmpty && otherBytes == 0 {
                Text("Nothing to map").foregroundStyle(.secondary)
            }
        }
    }

    private struct PlacedTile {
        var id: Int64
        var rect: CGRect
        var record: FileRecord?
        var bytes: Int64
    }

    private func layout(in rect: CGRect) -> [PlacedTile] {
        var items = records.map { SquarifiedTreemap.Item(id: $0.id, weight: Double($0.allocatedSize)) }
        if otherBytes > 0 { items.append(.init(id: Self.otherID, weight: Double(otherBytes))) }
        let grouped = SquarifiedTreemap.groupTail(items, maxItems: 60, minimumFraction: 0.003, otherID: Self.otherID)
        // Merge any explicit "other" with the grouped tail.
        var merged: [SquarifiedTreemap.Item<Int64>] = []
        var otherWeight = 0.0
        for item in grouped {
            if item.id == Self.otherID { otherWeight += item.weight } else { merged.append(item) }
        }
        if otherWeight > 0 { merged.append(.init(id: Self.otherID, weight: otherWeight)) }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return SquarifiedTreemap.layout(merged, in: rect.insetBy(dx: 1, dy: 1)).map { tile in
            let record = byID[tile.id]
            let bytes = record?.allocatedSize ?? Int64(otherWeight)
            return PlacedTile(id: tile.id, rect: tile.rect, record: record, bytes: bytes)
        }
    }

    private func draw(_ tile: PlacedTile, in context: inout GraphicsContext) {
        let rect = tile.rect.insetBy(dx: 1, dy: 1)
        guard rect.width > 1, rect.height > 1 else { return }
        let path = Path(roundedRect: rect, cornerRadius: min(6, rect.width / 4, rect.height / 4))
        let color: Color = tile.record.map { $0.mapCategory.tint } ?? Theme.neutralA
        let selected = tile.record.map { selection.contains($0.id) } ?? false
        let hovered = tile.id == hoveredID
        let base = tile.record?.isContainer == true ? color : color.mix(with: .white, by: 0.12)
        // Cushion shading: a light top-left falloff gives each tile volume.
        context.fill(path, with: .linearGradient(Gradient(colors: [base.mix(with: .white, by: hovered ? 0.32 : 0.2), base, base.mix(with: .black, by: 0.22)]),
                                                 startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
        context.fill(path, with: .radialGradient(Gradient(colors: [.white.opacity(0.18), .clear]),
                                                 center: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.minY + rect.height * 0.25),
                                                 startRadius: 0, endRadius: max(rect.width, rect.height) * 0.7))
        context.stroke(path, with: .color(selected ? .white : .white.opacity(hovered ? 0.6 : 0.12)), lineWidth: selected ? 2.5 : (hovered ? 1.5 : 0.5))
        if rect.width > 54, rect.height > 30 {
            if tile.record?.isContainer == true, rect.width > 90, rect.height > 56 {
                let symbol = context.resolve(Image(systemName: "folder.fill"))
                context.draw(symbol, in: CGRect(x: rect.maxX - 20, y: rect.minY + 6, width: 13, height: 11))
            }
            let name = tile.record?.name ?? String(localized: "Other")
            let label = Text(name).font(.caption.weight(.semibold)).foregroundStyle(.white)
            let size = Text(ByteFormat.string(tile.bytes, style: byteStyle)).font(.caption2).foregroundStyle(.white.opacity(0.85))
            context.draw(label, in: CGRect(x: rect.minX + 5, y: rect.minY + 4, width: rect.width - 10, height: 15))
            context.draw(size, in: CGRect(x: rect.minX + 5, y: rect.minY + 18, width: rect.width - 10, height: 14))
        }
    }

    private func tooltip(for tile: PlacedTile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tile.record?.name ?? String(localized: "Other (smaller items)")).font(.caption.weight(.semibold)).lineLimit(1)
            Text(ByteFormat.string(tile.bytes, style: byteStyle) + (tile.record.map { " · " + $0.category.displayName } ?? ""))
                .font(.caption2).foregroundStyle(.secondary)
            if tile.record?.isContainer == true {
                Text("Double-click to open").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(6)
        .frame(maxWidth: 220, alignment: .leading)
        .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.cardStroke))
    }

    private func record(at point: CGPoint, tiles: [PlacedTile]) -> FileRecord? {
        tiles.first { $0.rect.contains(point) }?.record
    }
}
