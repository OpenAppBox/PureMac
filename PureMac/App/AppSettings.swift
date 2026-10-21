import Foundation
import Observation
import PureMacKit
import SwiftUI

enum ByteStyle: String, CaseIterable, Identifiable {
    /// 1 KB = 1000 bytes — matches Finder and macOS Storage settings.
    case decimal
    /// 1 KiB = 1024 bytes.
    case binary

    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .decimal: "Decimal (KB, MB, GB — like Finder)"
        case .binary: "Binary (KiB, MiB, GiB)"
        }
    }
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// User preferences, persisted in the app's own `UserDefaults` domain (local only).
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }
    var byteStyle: ByteStyle { didSet { defaults.set(byteStyle.rawValue, forKey: "byteStyle") } }
    var appearance: AppearancePreference { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    /// Store full paths in cleanup history (needed for "Put Back"). Off = counts and sizes only.
    var keepDetailedHistory: Bool { didSet { defaults.set(keepDetailedHistory, forKey: "keepDetailedHistory") } }
    /// Scan the whole Data volume instead of only the home folder (Full Disk Access recommended).
    var scanEntireDataVolume: Bool { didSet { defaults.set(scanEntireDataVolume, forKey: "scanEntireDataVolume") } }
    /// Additional user-chosen folders (outside home) to scan.
    var extraScanFolders: [String] { didSet { defaults.set(extraScanFolders, forKey: "extraScanFolders") } }
    /// External volumes the user opted in to scan.
    var externalVolumePaths: [String] { didSet { defaults.set(externalVolumePaths, forKey: "externalVolumePaths") } }
    var smallFileThresholdKB: Int { didSet { defaults.set(smallFileThresholdKB, forKey: "smallFileThresholdKB") } }
    /// Turns off decorative motion (backdrop drift, scanner rings, sparks) in addition to the system setting.
    var reduceAnimations: Bool { didSet { defaults.set(reduceAnimations, forKey: "reduceAnimations") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        byteStyle = ByteStyle(rawValue: defaults.string(forKey: "byteStyle") ?? "") ?? .decimal
        appearance = AppearancePreference(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        keepDetailedHistory = defaults.object(forKey: "keepDetailedHistory") as? Bool ?? true
        scanEntireDataVolume = defaults.bool(forKey: "scanEntireDataVolume")
        extraScanFolders = defaults.stringArray(forKey: "extraScanFolders") ?? []
        externalVolumePaths = defaults.stringArray(forKey: "externalVolumePaths") ?? []
        let threshold = defaults.integer(forKey: "smallFileThresholdKB")
        smallFileThresholdKB = threshold > 0 ? threshold : 256
        reduceAnimations = defaults.bool(forKey: "reduceAnimations")
    }

    /// The roots a scan will traverse, in order. Home is always included unless the whole Data
    /// volume (which contains it) is chosen.
    var scanRoots: [ScanRoot] {
        var roots: [ScanRoot] = []
        if scanEntireDataVolume {
            roots.append(ScanRoot(path: "/System/Volumes/Data", kind: .dataVolume))
        } else {
            roots.append(.home())
        }
        roots += extraScanFolders.map { ScanRoot(path: $0, kind: .folder) }
        roots += externalVolumePaths.map { ScanRoot(path: $0, kind: .externalVolume) }
        return roots
    }
}
