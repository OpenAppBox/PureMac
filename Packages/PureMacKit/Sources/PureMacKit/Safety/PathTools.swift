import Darwin
import Foundation

/// Strict path helpers. All safety decisions operate on normalized absolute paths.
public enum PathTools {
    /// The user's real home folder. Inside the App Sandbox, `homeDirectoryForCurrentUser` and
    /// `NSHomeDirectory()` return the app's container, so the account record is read instead.
    public static let userHome: String = {
        #if DEBUG
        // Development only: the app's demo mode (promotional screenshots) runs against a mock home.
        if let demo = ProcessInfo.processInfo.environment["PUREMAC_DEMO_HOME"], !demo.isEmpty { return demo }
        #endif
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            let home = String(cString: dir)
            if !home.isEmpty { return home }
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }()

    public static var userHomeURL: URL { URL(fileURLWithPath: userHome, isDirectory: true) }

    /// `true` when the process runs in the App Sandbox (the Mac App Store edition).
    public static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// Normalizes an absolute path: rejects relative paths, NUL bytes, empty components produced by
    /// `..`, and any `..` component outright (no lexical escape is ever accepted). Removes `.`
    /// components, duplicate and trailing slashes.
    public static func normalize(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { return nil }
            parts.append(component)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// `true` when `path` is strictly inside `root` (component-wise, not string prefix).
    public static func isStrictlyInside(_ path: String, _ root: String) -> Bool {
        guard path != root else { return false }
        if root == "/" { return path.hasPrefix("/") && path.count > 1 }
        return path.hasPrefix(root + "/")
    }

    public static func isSameOrInside(_ path: String, _ root: String) -> Bool {
        path == root || isStrictlyInside(path, root)
    }

    /// Path components relative to `root` (empty if equal; `nil` if not inside).
    public static func relativeComponents(of path: String, under root: String) -> [String]? {
        if path == root { return [] }
        guard isStrictlyInside(path, root) else { return nil }
        let start = root == "/" ? path.index(after: path.startIndex) : path.index(path.startIndex, offsetBy: root.count + 1)
        return path[start...].split(separator: "/").map(String.init)
    }

    /// `realpath(3)` of the path. `nil` if it does not exist.
    public static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Resolves symlinks in the *parent* directory chain while leaving the final component
    /// untouched (so a symlink target itself is never followed).
    public static func resolvingParent(_ path: String) -> String? {
        guard let normalized = normalize(path), normalized != "/" else { return normalize(path) }
        let parent = (normalized as NSString).deletingLastPathComponent
        let name = (normalized as NSString).lastPathComponent
        guard let realParent = realPath(parent) else { return nil }
        return realParent == "/" ? "/" + name : realParent + "/" + name
    }

    /// Maps the firmlinked Data-volume namespace (`/System/Volumes/Data/Users/...`) to the
    /// canonical user-visible path so the same location is never treated as two places. A
    /// whole-disk scan stores these, so its paths match the rest of PureMac (home folder,
    /// exclusions, cleanups).
    public static func canonicalizingDataVolume(_ path: String) -> String {
        guard isStrictlyInside(path, dataVolume) else { return path }
        for link in firmlinks {
            let inData = dataVolume + "/" + link.data
            if path == inData { return link.visible }
            if isStrictlyInside(path, inData) { return link.visible + path.dropFirst(inData.count) }
        }
        return path
    }

    /// Folders that live on the Data volume but appear at the root through firmlinks.
    static let firmlinkedFolders = ["/Users", "/Applications", "/Library", "/opt", "/private", "/usr/local", "/cores"]

    /// The path as seen from the Data volume (`/Users/x` → `/System/Volumes/Data/Users/x`), so the
    /// two names of one location compare as the same place. Other paths are returned unchanged.
    public static func dataVolumeForm(_ path: String) -> String {
        let data = "/System/Volumes/Data"
        if isSameOrInside(path, data) { return path }
        for folder in firmlinkedFolders where isSameOrInside(path, folder) { return data + path }
        return path
    }

    /// The Data volume's mount point.
    public static let dataVolume = "/System/Volumes/Data"

    /// macOS's firmlinks as (visible path, path relative to the Data volume), longest first — from
    /// `/usr/share/firmlinks` (`/Users<TAB>Users`), or the well-known set if it can't be read.
    static let firmlinks: [(visible: String, data: String)] = {
        let text = (try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8)) ?? ""
        var links = text.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: true)
            guard parts.count == 2, parts[0].hasPrefix("/"), !parts[1].hasPrefix("/") else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
        if links.isEmpty { links = (firmlinkedFolders + ["/Volumes"]).map { ($0, String($0.dropFirst())) } }
        return links.sorted { $0.1.count > $1.1.count }
    }()

    /// Drops paths that are the same as or inside another path of the list (after normalizing and
    /// resolving symlinks), so a traversal never visits a location twice. Shorter paths come first.
    public static func removingNested(_ paths: [String]) -> [String] {
        var kept: [String] = []
        let resolved = paths.compactMap { normalize($0) }.map { realPath($0) ?? $0 }
        for path in resolved.sorted(by: { dataVolumeForm($0).count < dataVolumeForm($1).count })
        where !kept.contains(where: { isSameOrInside(dataVolumeForm(path), dataVolumeForm($0)) }) {
            kept.append(path)
        }
        return kept
    }

    /// Escapes `%`, `_` and `\` for use in a SQLite `LIKE ... ESCAPE '\'` pattern.
    public static func likeEscaped(_ text: String) -> String {
        var out = ""
        for ch in text {
            if ch == "%" || ch == "_" || ch == "\\" { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Whether a string is shaped like a reverse-DNS bundle identifier (e.g. `com.example.App`).
    public static func looksLikeBundleIdentifier(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, name.count <= 155 else { return false }
        let first = parts[0].lowercased()
        guard first.count >= 2, first.count <= 12, first.allSatisfy({ $0.isLetter && $0.isASCII }) else { return false }
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") && $0.isASCII })
            else { return false }
        }
        return true
    }
}
