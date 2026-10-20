import AppKit
import Foundation

/// PureMac's interface language.
///
/// macOS chooses an app's localization when it launches, from the `AppleLanguages` preference in
/// the app's own defaults domain — the same setting System Settings → General → Language & Region →
/// Applications writes. PureMac stores the user's choice there, so a change applies after a
/// relaunch and both places always agree.
///
/// The list of languages comes from the localizations inside the app bundle, so adding a language
/// to the string catalogs (and the project's known regions) adds it to the picker automatically.
enum AppLanguage {
    private static let key = "AppleLanguages"

    /// Language codes the app ships, English (the development language) first.
    static var available: [String] {
        let development = Bundle.main.developmentLocalization ?? "en"
        let shipped = Bundle.main.localizations.filter { $0 != "Base" && $0 != development }.sorted()
        return [development] + shipped
    }

    /// The language chosen in PureMac, or `nil` to follow the macOS language order.
    static var selected: String? {
        guard let id = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: id)?[key] as? [String] else { return nil }
        return languages.first
    }

    /// The choice that was in effect when this process launched.
    static let selectedAtLaunch = selected

    /// The localization the running process actually uses.
    static var current: String { Bundle.main.preferredLocalizations.first ?? "en" }

    private static let directionKeys = ["AppleTextDirection", "NSForceRightToLeftWritingDirection"]

    /// Makes AppKit lay the interface out right to left when the running localization is written
    /// that way (Arabic), and back to left to right otherwise.
    ///
    /// Choosing such a language through `AppleLanguages` alone — PureMac's picker, System Settings'
    /// per-app language or a launch argument — gives the translated text but leaves AppKit's layout
    /// left to right. AppKit mirrors windows, split views and tables once these two preferences are
    /// set (the switch Xcode uses for right-to-left runs). They are kept in PureMac's own defaults
    /// domain only and are removed again when the language is left to right. Call before the first
    /// window is created.
    static func applyWritingDirection() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let rightToLeft = Locale.Language(identifier: current).characterDirection == .rightToLeft
        let stored = UserDefaults.standard.persistentDomain(forName: id) ?? [:]
        for key in directionKeys {
            if rightToLeft, stored[key] == nil {
                UserDefaults.standard.set(true, forKey: key)
            } else if !rightToLeft, stored[key] != nil {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    static func select(_ code: String?) {
        if let code {
            UserDefaults.standard.set([code], forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// The language's own name for itself (“English”, “Türkçe”), so anyone can find theirs.
    static func nativeName(_ code: String) -> String {
        let locale = Locale(identifier: code)
        return locale.localizedString(forLanguageCode: code)?.capitalized(with: locale) ?? code
    }

    /// Opens a fresh instance of PureMac and quits this one, so the new language takes effect.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
