import Foundation
@testable import PureMacKit

struct FakeRunningApps: RunningAppChecking {
    var ids: Set<String> = []
    var paths: Set<String> = []
    func runningBundleIdentifiers() async -> Set<String> { Set(ids.map { $0.lowercased() }) }
    func runningBundlePaths() async -> Set<String> { paths }
}

/// Holds the first running-app query until `open()` — a deterministic point where a cleanup is
/// in progress and suspended, for testing that a second operation is refused.
actor GatedRunningApps: RunningAppChecking {
    private var isOpen = false
    private var hasEntered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    func runningBundleIdentifiers() async -> Set<String> {
        if !isOpen {
            hasEntered = true
            enteredWaiters.forEach { $0.resume() }
            enteredWaiters = []
            await withCheckedContinuation { gateWaiters.append($0) }
        }
        return []
    }

    func runningBundlePaths() async -> Set<String> { [] }

    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func open() {
        isOpen = true
        gateWaiters.forEach { $0.resume() }
        gateWaiters = []
    }
}

struct FakeLaunchServices: LaunchServicesQuerying {
    var known: [String: [String]] = [:]
    func applicationPaths(forBundleIdentifier id: String) async -> [String] { known[id] ?? known[id.lowercased()] ?? [] }
}

extension Fixture {
    /// Creates a minimal but real `.app` bundle with an Info.plist.
    @discardableResult
    func makeApp(_ relative: String, id: String?, name: String? = nil, executable: String? = nil,
                 helpers: [(String, String)] = []) throws -> String {
        let bundle = path(relative)
        var plist: [String: Any] = ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "42"]
        if let id { plist["CFBundleIdentifier"] = id }
        if let name { plist["CFBundleName"] = name }
        if let executable { plist["CFBundleExecutable"] = executable }
        try file(relative + "/Contents/Info.plist", data: try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
        try file(relative + "/Contents/MacOS/" + (executable ?? "main"), size: 4_096)
        for (helperName, helperID) in helpers {
            let helperPlist: [String: Any] = ["CFBundleIdentifier": helperID]
            try file(relative + "/Contents/Library/LoginItems/\(helperName).app/Contents/Info.plist",
                     data: try PropertyListSerialization.data(fromPropertyList: helperPlist, format: .xml, options: 0))
        }
        return bundle
    }

    func writePlist(_ relative: String, _ plist: [String: Any]) throws {
        try file(relative, data: try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
    }

    func app(_ bundlePath: String, groups: [String] = [], team: String? = nil) -> InstalledApp {
        var app = AppDiscoverer.inspect(bundlePath: bundlePath, isSystemRoot: false, inspectSigning: false)!
        app.applicationGroups = groups
        app.teamIdentifier = team
        return app
    }
}
