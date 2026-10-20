import Foundation
import PureMacKit
import SwiftUI

enum ByteFormat {
    /// Whole units for tight spaces such as sidebar badges ("17 GB").
    static func compact(_ bytes: Int64, style: ByteStyle) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = style == .binary ? .binary : .file
        formatter.isAdaptive = false
        return formatter.string(fromByteCount: bytes)
    }

    static func string(_ bytes: Int64, style: ByteStyle) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: style == .binary ? .binary : .file)
    }
}

private struct ByteStyleKey: EnvironmentKey {
    static let defaultValue: ByteStyle = .decimal
}

extension EnvironmentValues {
    var byteStyle: ByteStyle {
        get { self[ByteStyleKey.self] }
        set { self[ByteStyleKey.self] = newValue }
    }
}

/// Renders a byte count honoring the user's unit preference.
struct SizeText: View {
    let bytes: Int64
    @Environment(\.byteStyle) private var style

    init(_ bytes: Int64) { self.bytes = bytes }

    var body: some View {
        Text(ByteFormat.string(bytes, style: style)).monospacedDigit()
    }
}

extension Date {
    var relativeDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}

extension Duration {
    static func seconds(_ interval: TimeInterval) -> Duration { .milliseconds(Int64(interval * 1000)) }
}

func formattedDuration(_ interval: TimeInterval) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = interval >= 3600 ? [.hour, .minute] : [.minute, .second]
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: max(0, interval)) ?? "—"
}

extension StorageCategory {
    /// Category identity color (validated palette; see Theme).
    var color: Color { tint }
    var treemapColor: Color { tint }

    /// Display name for a folder's category: an unclassified folder is a mix of types.
    func label(isContainer: Bool) -> String {
        isContainer && self == .unclassified ? String(localized: "Mixed") : displayName
    }

    var symbolName: String {
        switch self {
        case .applications: "app.dashed"
        case .documents: "doc.richtext"
        case .media: "photo.on.rectangle"
        case .developer: "hammer"
        case .caches: "shippingbox"
        case .backups: "externaldrive.badge.timemachine"
        case .archives: "archivebox"
        case .systemOther: "gearshape"
        case .unclassified: "questionmark.folder"
        case .cloud: "icloud"
        case .appData: "square.stack.3d.up"
        case .mail: "envelope"
        }
    }
}

extension FileRecord {
    /// The logical size is much larger than what is stored (sparse, compressed or iCloud-only data):
    /// at least 1.5× and 100 MB more, or a file the scan flagged as sparse or dataless.
    var logicalExceedsDisk: Bool {
        if !isContainer && flags.contains(.sparseOrDataless) { return true }
        return logicalSize - allocatedSize > 100_000_000 && Double(logicalSize) > Double(allocatedSize) * 1.5
    }
}

extension String {
    /// For dynamic text shown through `LocalizedStringKey`, which reads inline Markdown: escapes it,
    /// so file and folder names (`*draft*`, `[2024]`, back-ticks) appear exactly as they are.
    var markdownEscaped: String {
        var out = ""
        out.reserveCapacity(count)
        for character in self {
            if "\\`*_[]<>~#!".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}
