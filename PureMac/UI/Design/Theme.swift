import AppKit
import PureMacKit
import SwiftUI

// MARK: - Adaptive colors

extension Color {
    /// A color with distinct light and dark steps (resolved by the current appearance).
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil ? dark : light
        })
    }

    init(lightHex: UInt32, darkHex: UInt32) {
        self.init(light: NSColor(hex: lightHex), dark: NSColor(hex: darkHex))
    }

    init(hex: UInt32, opacity: Double = 1) {
        self.init(nsColor: NSColor(hex: hex).withAlphaComponent(opacity))
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The PureMac "Aurora Glass" design tokens.
enum Theme {
    // Brand (OpenAppBox): blue, teal, navy.
    static let brandBlue = Color(lightHex: 0x1A7BFF, darkHex: 0x3D95FF)
    static let brandTeal = Color(lightHex: 0x00B8A3, darkHex: 0x22E0C8)
    static let brandNavy = Color(hex: 0x0B2B5B)

    // Canvas
    static let canvasTop = Color(lightHex: 0xF6F9FF, darkHex: 0x070B17)
    static let canvasBottom = Color(lightHex: 0xE8F0FE, darkHex: 0x0B1530)
    /// Translucent card surface (replaces live blur).
    static let cardSurface = Color(light: NSColor.white.withAlphaComponent(0.62), dark: NSColor(hex: 0x141C2E).withAlphaComponent(0.72))
    static let cardStroke = Color(light: NSColor.black.withAlphaComponent(0.06), dark: NSColor.white.withAlphaComponent(0.10))
    static let cardHighlight = Color(light: NSColor.white.withAlphaComponent(0.9), dark: NSColor.white.withAlphaComponent(0.16))
    static let track = Color(light: NSColor.black.withAlphaComponent(0.07), dark: NSColor.white.withAlphaComponent(0.08))
    static let glow = Color(lightHex: 0x1A7BFF, darkHex: 0x4AA3FF)

    // Status (reserved; always paired with an icon + label)
    static let good = Color(hex: 0x0CA30C)
    static let warning = Color(hex: 0xFAB219)
    static let serious = Color(hex: 0xEC835A)
    static let critical = Color(hex: 0xD03B3B)

    // Validated categorical palette (8 fixed slots, light/dark steps).
    static let series: [Color] = [
        Color(lightHex: 0x2A78D6, darkHex: 0x3987E5), // 1 blue
        Color(lightHex: 0xEB6834, darkHex: 0xD95926), // 2 orange
        Color(lightHex: 0x1BAF7A, darkHex: 0x199E70), // 3 aqua
        Color(lightHex: 0xEDA100, darkHex: 0xC98500), // 4 yellow
        Color(lightHex: 0xE87BA4, darkHex: 0xD55181), // 5 magenta
        Color(lightHex: 0x008300, darkHex: 0x008300), // 6 green
        Color(lightHex: 0x6250D6, darkHex: 0x9085E9), // 7 violet
        Color(lightHex: 0xE34948, darkHex: 0xE66767), // 8 red
    ]
    static let neutralA = Color(lightHex: 0x8E949E, darkHex: 0x6B7280)
    static let neutralB = Color(lightHex: 0xB4B9C2, darkHex: 0x4B5260)

    // Diverging pair (growth vs. shrink).
    static let increase = Color(lightHex: 0xE34948, darkHex: 0xE66767)
    static let decrease = Color(lightHex: 0x2A78D6, darkHex: 0x3987E5)

    static let cornerRadius: CGFloat = 18
}

// MARK: - Category identity (color follows the entity, never its rank)

extension StorageCategory {
    var tint: Color {
        switch self {
        case .applications: Theme.series[0]
        case .documents: Theme.series[1]
        case .caches: Theme.series[2]
        case .archives: Theme.series[3]
        case .media: Theme.series[4]
        case .appData: Theme.series[5]
        case .developer: Theme.series[6]
        case .backups: Theme.series[7]
        case .cloud, .mail: Theme.neutralB
        case .systemOther, .unclassified: Theme.neutralA
        }
    }
}

extension CleanupCategory {
    var tint: Color {
        switch self {
        case .appCache: Theme.series[2]
        case .browserCache: Theme.series[0]
        case .developerCache: Theme.series[6]
        case .packageManagerCache: Theme.series[3]
        case .logs, .crashReports: Theme.series[1]
        case .installers: Theme.series[7]
        case .appRemnant: Theme.series[4]
        case .appUninstall, .userSelection, .duplicate: Theme.series[5]
        }
    }
}

/// Each module has its own hue for headers, icon tiles and backdrop tint.
extension SidebarItem {
    var hue: Color {
        switch self {
        case .overview: Color(lightHex: 0x1A7BFF, darkHex: 0x3D95FF)
        case .smartClean: Color(lightHex: 0x00A896, darkHex: 0x22D6BE)
        case .explorer: Color(lightHex: 0x6250D6, darkHex: 0x9085E9)
        case .applications: Color(lightHex: 0xEB6834, darkHex: 0xF07A45)
        case .orphans: Color(lightHex: 0xD6457F, darkHex: 0xE87BA4)
        case .duplicates: Color(lightHex: 0xD99200, darkHex: 0xEDA100)
        case .developer: Color(lightHex: 0x4E5BD6, darkHex: 0x7C87F0)
        case .performance: Color(lightHex: 0x0E9F4E, darkHex: 0x2BC46A)
        case .history: Color(lightHex: 0x5A6B85, darkHex: 0x8A9BB8)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [hue.opacity(0.95), hue.mix(with: .black, by: 0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    /// Simple sRGB mix (macOS 14-compatible). Memoized: converting SwiftUI colors to NSColor is
    /// expensive and mixes are requested repeatedly for the same few theme colors.
    nonisolated func mix(with other: Color, by amount: Double) -> Color {
        let key = MixKey(a: self, b: other, t: Int((amount * 1000).rounded()))
        if let cached = MixCache.shared.value(for: key) { return cached }
        let result = computeMix(with: other, by: amount)
        MixCache.shared.store(result, for: key)
        return result
    }

    nonisolated private func computeMix(with other: Color, by amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .gray
        let t = CGFloat(max(0, min(1, amount)))
        return Color(.sRGB, red: Double(a.redComponent + (b.redComponent - a.redComponent) * t),
                     green: Double(a.greenComponent + (b.greenComponent - a.greenComponent) * t),
                     blue: Double(a.blueComponent + (b.blueComponent - a.blueComponent) * t),
                     opacity: Double(a.alphaComponent))
    }
}

nonisolated struct MixKey: Hashable, Sendable {
    let a: Color
    let b: Color
    let t: Int
}

/// Thread-safe memo for `Color.mix`. Adaptive (light/dark) colors stay adaptive because the mix of
/// two dynamic colors is computed from their NSColor representations at first use per appearance.
nonisolated final class MixCache: @unchecked Sendable {
    static let shared = MixCache()
    private let lock = NSLock()
    private var storage: [MixKey: Color] = [:]
    func value(for key: MixKey) -> Color? { lock.lock(); defer { lock.unlock() }; return storage[key] }
    func store(_ color: Color, for key: MixKey) {
        lock.lock(); defer { lock.unlock() }
        if storage.count > 512 { storage.removeAll() }
        storage[key] = color
    }
}

// MARK: - Typography

extension Font {
    static func hero(_ size: CGFloat = 46) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static func metric(_ size: CGFloat = 24) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static let eyebrow = Font.system(size: 11, weight: .semibold).smallCaps()
}
