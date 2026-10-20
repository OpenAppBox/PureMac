import AppKit
import Foundation
import PureMacKit

/// User-initiated integrations with Finder and System Settings. Nothing here runs automatically.
enum SystemActions {
    static func revealInFinder(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Privacy & Security → Full Disk Access. PureMac cannot grant this itself.
    static func openFullDiskAccessSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    /// Privacy & Security → App Management (needed to move some apps to Trash).
    static func openAppManagementSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")
    }

    static func openLoginItemsSettings() {
        openSettings("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    }

    static func openStorageSettings() {
        openSettings("x-apple.systempreferences:com.apple.settings.Storage")
    }

    static func openTrash() {
        let trash = PathTools.userHomeURL.appendingPathComponent(".Trash")
        NSWorkspace.shared.open(trash)
    }

    /// Opens Activity Monitor (by bundle identifier, wherever macOS keeps it).
    static func openActivityMonitor() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static func openSettings(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    static func icon(forPath path: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }
}
