import Foundation

public enum SafetyVerdict: Sendable, Hashable {
    case allowed
    case denied(String)

    public var isAllowed: Bool { if case .allowed = self { true } else { false } }
    public var reason: String? { if case .denied(let reason) = self { reason } else { nil } }
}

/// Allow-list based guard rails evaluated before any item may enter a cleanup plan **and again**
/// immediately before it is moved.
///
/// The policy is a pure function of paths (no filesystem access except resolving the parent
/// directory chain), which makes it exhaustively testable. It is one layer of the safety model;
/// identity revalidation, ownership checks and app-activity checks happen in `Preflight`.
public struct SafetyPolicy: Sendable {
    /// Real path of the user's home folder.
    public let home: String
    /// PureMac's own data (database) and bundle — never removable.
    public let ownPaths: [String]
    /// Folders where `.app` bundles may be removed from.
    public let applicationRoots: [String]
    /// User-defined cleanup exclusions (absolute, normalized).
    public let userExclusions: [String]

    public init(homeDirectory: String, ownPaths: [String] = [], applicationRoots: [String]? = nil, userExclusions: [String] = []) {
        let normalizedHome = PathTools.normalize(homeDirectory) ?? homeDirectory
        let realHome = PathTools.realPath(normalizedHome) ?? normalizedHome
        home = realHome
        self.ownPaths = ownPaths.compactMap { PathTools.normalize($0) }.map { PathTools.realPath($0) ?? $0 }
        self.applicationRoots = (applicationRoots ?? ["/Applications", realHome + "/Applications"])
            .compactMap { PathTools.normalize($0) }
        self.userExclusions = userExclusions.compactMap { PathTools.normalize($0) }
    }

    /// Policy for the current user and process.
    public static func forCurrentUser(ownDataDirectory: URL?, userExclusions: [String] = []) -> SafetyPolicy {
        var own: [String] = [Bundle.main.bundlePath]
        if let ownDataDirectory { own.append(ownDataDirectory.path) }
        return SafetyPolicy(homeDirectory: PathTools.userHome, ownPaths: own, userExclusions: userExclusions)
    }

    // MARK: Static lists

    /// Standard folders directly inside the home folder. The folders themselves are never removable.
    static let standardHomeFolders: Set<String> = [
        "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public",
        "Applications", "Sites", ".Trash",
    ]

    /// Personal-content folders: never reached by automatic cleanup (only by explicit user choice).
    static let personalFolders: Set<String> = ["Desktop", "Documents", "Pictures", "Movies", "Music", "Public", "Sites"]

    /// Standard folders inside `~/Library`. The folders themselves are never removable.
    static let standardLibraryFolders: Set<String> = [
        "Accounts", "Application Scripts", "Application Support", "Assistants", "Audio", "Autosave Information",
        "Biome", "Caches", "Calendars", "CallServices", "CloudStorage", "ColorPickers", "ColorSync", "Containers",
        "Cookies", "CoreData", "Daemon Containers", "DataAccess", "Developer", "Dictionaries", "DoNotDisturb",
        "DuetExpertCenter", "Favorites", "FileProvider", "Finance", "Fonts", "Frameworks", "Group Containers",
        "HTTPStorages", "HomeKit", "IdentityServices", "Input Methods", "Internet Plug-Ins", "Intents",
        "KeyboardServices", "Keychains", "LanguageModeling", "LaunchAgents", "Logs", "Mail", "Messages",
        "Metadata", "Mobile Documents", "News", "Passes", "Personas", "Photos", "PreferencePanes", "Preferences",
        "Printers", "QuickLook", "Reminders", "Safari", "SafariSafeBrowsing", "Saved Application State",
        "Screen Savers", "Services", "Sharing", "Shortcuts", "Sounds", "Spelling", "Suggestions", "SyncedPreferences",
        "Translation", "Trial", "UnifiedAssetFramework", "WebKit", "Weather", "com.apple.AppleMediaServices",
        "studentd", "Staging",
    ]

    /// Subtrees under the home folder that are never removable by PureMac, for any intent.
    static let alwaysProtectedSubtrees: [[String]] = [
        ["Library", "Keychains"],
        ["Library", "Mail"],
        ["Library", "Messages"],
        ["Library", "Safari"],
        ["Library", "Accounts"],
        ["Library", "Calendars"],
        ["Library", "Reminders"],
        ["Library", "Photos"],
        ["Library", "Biome"],
        ["Library", "IdentityServices"],
        ["Library", "Sharing"],
        ["Library", "Suggestions"],
        ["Library", "Daemon Containers"],
        ["Library", "Autosave Information"],
        ["Library", "Mobile Documents"],
        ["Library", "CloudStorage"],
        ["Library", "FileProvider"],
        ["Library", "Passes"],
        ["Library", "HomeKit"],
        ["Library", "Personas"],
        ["Library", "Application Support", "AddressBook"],
        ["Library", "Application Support", "com.apple.TCC"],
        ["Library", "Application Support", "Knowledge"],
        ["Library", "Application Support", "CallHistoryDB"],
        ["Library", "Application Support", "com.apple.sharedfilelist"],
        [".ssh"],
        [".gnupg"],
        [".aws"],
        [".kube"],
        [".password-store"],
    ]

    /// Subtrees reachable only by explicit user selection (never by rules, orphans or uninstall).
    static let userOnlySubtrees: [[String]] = [
        ["Library", "Application Support", "MobileSync"], // iOS device backups
        ["Library", "Developer", "Xcode", "Archives"],     // may be the only copy of a release build
    ]

    /// Library container folders whose children are keyed by bundle/group identifiers.
    static let identifierKeyedLibraryFolders: Set<String> = [
        "Caches", "Containers", "Group Containers", "Preferences", "Application Support", "Logs",
        "Saved Application State", "HTTPStorages", "WebKit", "Cookies", "Application Scripts", "LaunchAgents",
    ]

    /// System locations outside the home folder (for clear denial messages).
    static let systemPrefixes: [String] = [
        "/System", "/usr", "/bin", "/sbin", "/private", "/var", "/etc", "/tmp", "/dev", "/cores", "/opt",
        "/Library", "/Network", "/Users",
    ]

    /// Package types that are databases managed by their applications.
    static let managedLibraryExtensions: Set<String> = ["photoslibrary", "musiclibrary", "tvlibrary", "photolibrary", "aplibrary", "migratedphotolibrary"]

    // Lower-cased copies for matching: APFS and HFS+ volumes are case-insensitive by default, so
    // "keychains" names the same folder as "Keychains". Only *denials* use these (stricter, never looser).
    static let standardHomeFoldersLower = Set(standardHomeFolders.map { $0.lowercased() })
    static let personalFoldersLower = Set(personalFolders.map { $0.lowercased() })
    static let standardLibraryFoldersLower = Set(standardLibraryFolders.map { $0.lowercased() })
    static let alwaysProtectedSubtreesLower = alwaysProtectedSubtrees.map { $0.map { $0.lowercased() } }
    static let userOnlySubtreesLower = userOnlySubtrees.map { $0.map { $0.lowercased() } }
    static let identifierKeyedLibraryFoldersLower = Set(identifierKeyedLibraryFolders.map { $0.lowercased() })

    // MARK: Evaluation

    /// Evaluates whether `rawPath` may be moved to Trash for the given intent.
    ///
    /// - Parameter allowedRoots: For `.ruleCleanup`, the rule's approved base folders; the path must be
    ///   strictly inside one of them.
    public func evaluate(_ rawPath: String, intent: SafetyIntent, allowedRoots: [String] = []) -> SafetyVerdict {
        guard let normalized = PathTools.normalize(rawPath) else {
            return .denied(String(localized: "The path is not a valid absolute path.", bundle: .module))
        }
        let canonical = PathTools.canonicalizingDataVolume(normalized)
        guard let path = PathTools.resolvingParent(canonical) else {
            return .denied(String(localized: "The enclosing folder no longer exists.", bundle: .module))
        }
        if path == "/" { return .denied(String(localized: "The startup volume root can never be removed.", bundle: .module)) }

        let lowerPath = path.lowercased()
        if PathTools.isSameOrInside(home.lowercased(), lowerPath) {
            return .denied(String(localized: "This location is, or contains, your home folder.", bundle: .module))
        }
        for own in ownPaths.map({ $0.lowercased() }) where PathTools.isSameOrInside(lowerPath, own) || PathTools.isStrictlyInside(own, lowerPath) {
            return .denied(String(localized: "This location holds PureMac itself or its own data.", bundle: .module))
        }
        for excluded in userExclusions where PathTools.isSameOrInside(lowerPath, excluded.lowercased()) {
            return .denied(String(localized: "You excluded this location from cleanup in Settings.", bundle: .module))
        }

        let components = path.split(separator: "/").map(String.init)
        // Never modify the inside of an application bundle or a managed library package.
        for component in components.dropLast() {
            let ext = (component as NSString).pathExtension.lowercased()
            if ext == "app" { return .denied(String(localized: "Files inside an application bundle are never removed individually.", bundle: .module)) }
            if Self.managedLibraryExtensions.contains(ext) {
                return .denied(String(localized: "This is inside a library managed by another app (for example Photos). Manage it in that app.", bundle: .module))
            }
        }

        if let relative = PathTools.relativeComponents(of: path, under: home)
            ?? PathTools.relativeComponents(of: lowerPath, under: home.lowercased()) {
            return evaluateInsideHome(path: path, relative: relative, intent: intent, allowedRoots: allowedRoots)
        }
        return evaluateOutsideHome(path: path, intent: intent)
    }

    private func evaluateInsideHome(path: String, relative: [String], intent: SafetyIntent, allowedRoots: [String]) -> SafetyVerdict {
        let rel = relative.map { $0.lowercased() }
        guard let first = rel.first else { return .denied(String(localized: "This is your home folder.", bundle: .module)) }
        if first == ".trash" { return .denied(String(localized: "This item is already in the Trash.", bundle: .module)) }
        if rel.count == 1, Self.standardHomeFoldersLower.contains(first) {
            return .denied(String(localized: "“\(relative[0])” is a standard macOS folder and is never removed.", bundle: .module))
        }
        if first == "library", rel.count == 2, Self.standardLibraryFoldersLower.contains(rel[1]) {
            return .denied(String(localized: "“\(relative[1])” is a standard Library folder and is never removed as a whole.", bundle: .module))
        }
        for (index, subtree) in Self.alwaysProtectedSubtreesLower.enumerated() where rel.starts(with: subtree) {
            return .denied(String(localized: "This location holds protected personal or system data (\(Self.alwaysProtectedSubtrees[index].joined(separator: "/"))).", bundle: .module))
        }
        if rel.count >= 3, first == "library", Self.isAppleComponentName(rel[2]),
           Self.identifierKeyedLibraryFoldersLower.contains(rel[1]) {
            return .denied(String(localized: "This belongs to an Apple system component and is managed by macOS.", bundle: .module))
        }
        if rel.count == 2, first == "library", rel[1].hasPrefix(".") {
            return .denied(String(localized: "Hidden Library items are managed by macOS.", bundle: .module))
        }

        switch intent {
        case .userSelected:
            return .allowed

        case .appBundleRemoval:
            guard path.lowercased().hasSuffix(".app") else { return .denied(String(localized: "Only application bundles can be removed as apps.", bundle: .module)) }
            guard applicationRoots.contains(where: { PathTools.isStrictlyInside(path, $0) }) else {
                return .denied(String(localized: "Applications are only removed from an Applications folder.", bundle: .module))
            }
            return .allowed

        case .ruleCleanup, .orphanRemoval, .appDataRemoval:
            for subtree in Self.userOnlySubtreesLower where rel.starts(with: subtree) {
                return .denied(String(localized: "This data may be irreplaceable; PureMac only removes it when you select it yourself.", bundle: .module))
            }
            if Self.personalFoldersLower.contains(first) {
                return .denied(String(localized: "Personal folders are never cleaned automatically.", bundle: .module))
            }
            if first.hasPrefix(".") && intent != .ruleCleanup {
                return .denied(String(localized: "Hidden configuration folders are not removed with apps.", bundle: .module))
            }
            if intent == .ruleCleanup {
                let roots = allowedRoots.compactMap { PathTools.normalize($0) }.map { PathTools.realPath($0) ?? $0 }
                guard !roots.isEmpty else { return .denied(String(localized: "The rule has no approved location.", bundle: .module)) }
                guard roots.contains(where: { PathTools.isStrictlyInside(path, $0) }) else {
                    return .denied(String(localized: "The item is outside the rule's approved location.", bundle: .module))
                }
                for root in roots {
                    guard let rootRelative = PathTools.relativeComponents(of: root, under: home), !rootRelative.isEmpty else {
                        return .denied(String(localized: "The rule location is not inside your home folder.", bundle: .module))
                    }
                }
                return .allowed
            }
            // Standard Library folders themselves were denied above, so depth 2 here is a
            // non-standard vendor folder directly inside ~/Library.
            guard first == "library", rel.count >= 2 else {
                return .denied(String(localized: "Application data is only removed from your Library folder.", bundle: .module))
            }
            return .allowed
        }
    }

    private func evaluateOutsideHome(path: String, intent: SafetyIntent) -> SafetyVerdict {
        switch intent {
        case .appBundleRemoval:
            guard path.lowercased().hasSuffix(".app") else { return .denied(String(localized: "Only application bundles can be removed as apps.", bundle: .module)) }
            if path.hasPrefix("/System/") { return .denied(String(localized: "Apps on the macOS system volume are protected by macOS.", bundle: .module)) }
            guard applicationRoots.contains(where: { PathTools.isStrictlyInside(path, $0) }) else {
                return .denied(String(localized: "Applications are only removed from an Applications folder.", bundle: .module))
            }
            return .allowed

        case .userSelected:
            // Files the user picked on an external (non-startup) volume.
            if let relative = PathTools.relativeComponents(of: path, under: "/Volumes"), relative.count >= 2 {
                return .allowed
            }
            if let relative = PathTools.relativeComponents(of: path, under: "/Volumes"), relative.count == 1 {
                return .denied(String(localized: "A volume's root folder cannot be moved to Trash.", bundle: .module))
            }
            if applicationRoots.contains(where: { PathTools.isSameOrInside(path, $0) }) {
                return .denied(String(localized: "Use Applications → Uninstall to remove apps safely.", bundle: .module))
            }
            return .denied(systemDenial(for: path))

        case .ruleCleanup, .orphanRemoval, .appDataRemoval:
            return .denied(systemDenial(for: path))
        }
    }

    private func systemDenial(for path: String) -> String {
        if let prefix = Self.systemPrefixes.first(where: { PathTools.isSameOrInside(path, $0) }) {
            if prefix == "/Library" {
                return String(localized: "System-wide Library items require administrator rights; PureMac does not remove them in this version.", bundle: .module)
            }
            if prefix == "/Users" { return String(localized: "Other users' files are never touched.", bundle: .module) }
            return String(localized: "\(prefix) is managed by macOS and is protected.", bundle: .module)
        }
        return String(localized: "This location is outside the areas PureMac is allowed to clean.", bundle: .module)
    }

    static func isAppleComponentName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("com.apple.") || lower.hasPrefix("group.com.apple.") || lower.contains(".com.apple.")
            || lower == "com.apple"
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
