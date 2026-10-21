import AppKit
import Foundation
import Observation
import PureMacKit

/// Folder access inside the App Sandbox.
///
/// Inside the App Sandbox PureMac can only read and move items in folders the user picked in an
/// Open panel. Each grant is remembered as a security-scoped bookmark and reactivated at launch,
/// so the user grants their home folder, the startup disk (for entire-disk scans) and
/// /Applications (for uninstalling) once each.
/// Outside the sandbox (unsigned test builds) every check passes and nothing is stored.
@Observable
final class FolderAccess {
    /// `false` outside the sandbox: normal user permissions apply.
    let isRequired: Bool
    /// Paths with an active grant.
    private(set) var granted: [String] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var active: [String: URL] = [:]
    private static let key = "folderAccessBookmarks"

    init(defaults: UserDefaults = .standard, isRequired: Bool = PathTools.isSandboxed) {
        self.defaults = defaults
        self.isRequired = isRequired
        if isRequired { restore() }
    }

    var home: String { PathTools.userHome }

    /// Whether `path` lies inside a granted folder (always `true` outside the sandbox).
    func hasAccess(to path: String) -> Bool {
        !isRequired || granted.contains { PathTools.isSameOrInside(path, $0) }
    }

    var hasHomeAccess: Bool { hasAccess(to: home) }

    /// Asks for access to `path` with an Open panel opened at that folder, unless it is already
    /// granted. Returns whether access is available afterwards. User-initiated actions only.
    @discardableResult
    func request(_ path: String, message: String) -> Bool {
        guard isRequired, !hasAccess(to: path) else { return true }
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = String(localized: "Allow Access")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        remember(url)
        return hasAccess(to: path)
    }

    /// Stores a grant for a folder the user picked in any Open panel (scan folders, duplicates…).
    func remember(_ url: URL) {
        guard isRequired else { return }
        let path = url.standardizedFileURL.path
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var stored = storedBookmarks
        stored[path] = data
        defaults.set(stored, forKey: Self.key)
        activate(url, as: path)
    }

    func revoke(_ path: String) {
        active[path]?.stopAccessingSecurityScopedResource()
        active[path] = nil
        var stored = storedBookmarks
        stored[path] = nil
        defaults.set(stored, forKey: Self.key)
        granted.removeAll { $0 == path }
    }

    // MARK: Private

    private var storedBookmarks: [String: Data] {
        defaults.dictionary(forKey: Self.key) as? [String: Data] ?? [:]
    }

    private func restore() {
        var stored = storedBookmarks
        for (path, data) in stored {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
                stored[path] = nil   // the folder is gone or the grant was revoked
                continue
            }
            activate(url, as: path)
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                stored[path] = fresh
            }
        }
        defaults.set(stored, forKey: Self.key)
    }

    private func activate(_ url: URL, as path: String) {
        guard active[path] == nil, url.startAccessingSecurityScopedResource() else { return }
        active[path] = url
        if !granted.contains(path) { granted.append(path) }
        granted.sort()
    }
}
