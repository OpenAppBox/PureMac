import AppKit
import Foundation

/// Abstractions over live system state so ownership and cleanup logic can be tested with fakes.
public protocol RunningAppChecking: Sendable {
    /// Bundle identifiers (lowercased) of every running application.
    func runningBundleIdentifiers() async -> Set<String>
    /// Bundle paths of every running application.
    func runningBundlePaths() async -> Set<String>
}

public protocol LaunchServicesQuerying: Sendable {
    /// Paths of applications LaunchServices knows for a bundle identifier, anywhere on disk.
    func applicationPaths(forBundleIdentifier id: String) async -> [String]
}

/// Live implementation using `NSWorkspace` (queried on the main actor).
public struct WorkspaceRunningAppChecker: RunningAppChecking {
    public init() {}

    public func runningBundleIdentifiers() async -> Set<String> {
        await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
        }
    }

    public func runningBundlePaths() async -> Set<String> {
        await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
        }
    }
}

public struct WorkspaceLaunchServices: LaunchServicesQuerying {
    public init() {}

    /// LaunchServices is thread-safe; querying it off the main actor keeps the UI responsive
    /// (orphan detection performs one query per candidate identifier).
    public func applicationPaths(forBundleIdentifier id: String) async -> [String] {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).map { $0.standardizedFileURL.path }
    }
}

/// Running apps PureMac must not touch can still be shown to the user: the App Sandbox doesn't let
/// an app ask others to quit, and PureMac never force-quits.
public enum AppActivation {
    /// Brings the matching running apps to the front so the user can quit them (⌘Q). Returns how
    /// many were brought forward.
    @MainActor
    public static func bringToFront(bundleIdentifiers: Set<String>, bundlePath: String) -> Int {
        var shown = 0
        for app in NSWorkspace.shared.runningApplications {
            let matchesID = app.bundleIdentifier.map { bundleIdentifiers.contains($0.lowercased()) } ?? false
            let matchesPath = app.bundleURL?.standardizedFileURL.path == bundlePath
            guard matchesID || matchesPath, app.activationPolicy == .regular else { continue }
            NSApp.yieldActivation(to: app)
            if app.activate(from: .current, options: []) { shown += 1 }
        }
        return shown
    }
}

/// Reads installer package receipts with the documented `pkgutil` tool (absolute path, argument array).
public enum PackageReceipts {
    public static func packageIdentifiers(forFile path: String) -> [String] {
        guard let output = ToolRunner.run(executable: "/usr/sbin/pkgutil", arguments: ["--file-info-plist", path], timeout: 10),
              output.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: Data(output.stdout.utf8), format: nil) as? [String: Any],
              let packages = plist["path-info"] as? [[String: Any]]
        else { return [] }
        return packages.compactMap { $0["pkgid"] as? String }
    }
}
