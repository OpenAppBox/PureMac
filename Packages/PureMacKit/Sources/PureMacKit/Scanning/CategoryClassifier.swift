import Foundation

/// Assigns each scanned item to exactly one `StorageCategory`.
///
/// Directory context wins over file type (a `.mov` inside `~/Library/Caches` is a cache), so a
/// byte is attributed once and category totals never double-count.
public struct CategoryClassifier: Sendable {
    public let home: String

    public init(home: String) {
        self.home = home
    }

    static let mediaExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "raw", "cr2", "cr3", "nef", "arw", "dng", "webp", "psd",
        "mov", "mp4", "m4v", "avi", "mkv", "mts", "m2ts", "wmv", "webm", "braw", "r3d",
        "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "alac", "ogg", "caf",
    ]
    static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "rtf", "md", "csv",
        "epub", "odt", "ods", "odp", "sketch", "fig", "ai", "indd",
    ]
    static let archiveExtensions: Set<String> = [
        "dmg", "pkg", "mpkg", "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "xip", "iso", "img", "sparseimage",
        "sparsebundle",
    ]
    static let developerExtensions: Set<String> = ["xcarchive", "ipa", "dsym", "a", "o", "swiftmodule", "jar", "class"]
    public static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "photoslibrary", "musiclibrary", "tvlibrary", "xcarchive",
        "pages", "numbers", "key", "rtfd", "playground", "xcodeproj", "xcworkspace", "sparsebundle", "fcpbundle",
        "logicx", "band", "imovielibrary", "photolibrary", "appex", "xpc", "dsym", "pkg", "mpkg", "saver", "prefpane",
        "qlgenerator", "mdimporter", "component", "vst", "vst3",
    ]

    /// Folders inside `~/.cache` that hold downloaded models rather than regenerable caches.
    /// Re-downloading tens of gigabytes is not what "cache" suggests, so they count as app data.
    static let modelStoreNames: Set<String> = ["lm-studio", "huggingface", "torch", "whisper", "gpt4all", "ollama"]

    /// Category implied by a directory, or `nil` to inherit / classify by file type.
    public func directoryContext(path: String, name: String, parentContext: StorageCategory?) -> StorageCategory? {
        // The root of a whole-disk scan holds everything (Users, Applications, …): it has no context
        // of its own, or `/System/…` below would make the whole disk "System & Other".
        if path == PathTools.dataVolume { return nil }
        if parentContext == .caches, Self.modelStoreNames.contains(name.lowercased()),
           (path as NSString).deletingLastPathComponent == home + "/.cache" {
            return .appData
        }
        if let parentContext, parentContext != .appData { return parentContext }
        let lowerName = name.lowercased()
        let ext = (lowerName as NSString).pathExtension
        if ext == "app" { return .applications }
        if lowerName == "node_modules" || lowerName == "deriveddata" || lowerName == ".gradle" || lowerName == ".build"
            || lowerName == "pods" || lowerName == ".cargo" || lowerName == ".rustup" || lowerName == ".m2"
            || lowerName == ".npm" || lowerName == ".pnpm-store" || ext == "xcarchive" {
            return .developer
        }
        // Cache folders count as caches only where apps keep caches: inside app data, or ~/.cache.
        // A folder that merely *is named* "cache" inside a user project stays with its context.
        if (lowerName == "caches" || lowerName == "cache" || lowerName == "gpucache" || lowerName == "code cache"), parentContext == .appData {
            return .caches
        }
        if lowerName == ".cache", (path as NSString).deletingLastPathComponent == home { return .caches }
        if ext == "photoslibrary" || ext == "musiclibrary" || ext == "tvlibrary" || ext == "imovielibrary" { return .media }

        if let relative = PathTools.relativeComponents(of: path, under: home) {
            switch relative.count {
            case 1:
                switch relative[0] {
                case "Library": return .appData
                case ".Trash": return .systemOther
                case "Applications": return .applications
                default: return parentContext
                }
            case 2 where relative[0] == "Library":
                switch relative[1] {
                case "Caches", "Logs": return .caches
                case "Developer": return .developer
                case "Mail", "Messages": return .mail
                case "Mobile Documents", "CloudStorage": return .cloud
                default: return .appData
                }
            case 3 where relative[0] == "Library" && relative[1] == "Application Support" && relative[2] == "MobileSync":
                return .backups
            default:
                return parentContext
            }
        }
        if path == "/Applications" || path.hasPrefix("/Applications/") { return .applications }
        if path.hasPrefix("/System") || path.hasPrefix("/private") || path.hasPrefix("/usr") || path == "/Library"
            || path.hasPrefix("/Library/") || path.hasPrefix("/opt") {
            return .systemOther
        }
        if lowerName == "backups.backupdb" || ext == "backupbundle" { return .backups }
        return parentContext
    }

    public func fileCategory(name: String, context: StorageCategory?) -> StorageCategory {
        if let context, context != .appData { return context }
        let ext = (name as NSString).pathExtension.lowercased()
        if context == .appData { return .appData }
        if Self.mediaExtensions.contains(ext) { return .media }
        if Self.documentExtensions.contains(ext) { return .documents }
        if Self.archiveExtensions.contains(ext) { return .archives }
        if Self.developerExtensions.contains(ext) { return .developer }
        return .unclassified
    }
}
