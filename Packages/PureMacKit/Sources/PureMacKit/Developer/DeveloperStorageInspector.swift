import Foundation

/// A developer-related storage location or tool-managed resource.
public struct DeveloperItem: Identifiable, Sendable, Hashable {
    public enum Group: String, Sendable, CaseIterable {
        case xcode, simulators, packageManagers, containers, mlModels
        /// Dependencies installed inside projects (node_modules), found by the storage scan.
        case projects
        public var displayName: String {
            switch self {
            case .xcode: String(localized: "Xcode", bundle: .module)
            case .simulators: String(localized: "Simulators", bundle: .module)
            case .packageManagers: String(localized: "Package Managers & Build Caches", bundle: .module)
            case .containers: String(localized: "Docker", bundle: .module)
            case .mlModels: String(localized: "Model & Tool Caches", bundle: .module)
            case .projects: String(localized: "Project Dependencies", bundle: .module)
            }
        }
    }

    /// What the user may do with the item in PureMac.
    public enum Handling: Sendable, Hashable {
        /// Children can be selected individually and moved to the Trash.
        case selectChildren
        /// The folder itself can be selected and moved to the Trash.
        case selectItem
        /// Information only; managed by a tool or too risky to touch here.
        case inspectOnly(reason: String)
    }

    public var id: String
    public var group: Group
    public var title: String
    public var detail: String
    public var path: String?
    public var size: SizeSummary?
    public var risk: RiskLevel
    public var warning: String?
    public var handling: Handling
    /// For `.selectChildren`: the immediate children with sizes.
    public var children: [Child]
    /// Supported tool command the user can run explicitly (shown as text, executed only on request).
    public var toolCommandHint: String?

    public init(id: String, group: Group, title: String, detail: String, path: String?, size: SizeSummary?, risk: RiskLevel,
                warning: String? = nil, handling: Handling, children: [Child] = [], toolCommandHint: String? = nil) {
        self.id = id
        self.group = group
        self.title = title
        self.detail = detail
        self.path = path
        self.size = size
        self.risk = risk
        self.warning = warning
        self.handling = handling
        self.children = children
        self.toolCommandHint = toolCommandHint
    }

    public struct Child: Identifiable, Sendable, Hashable {
        public var id: String { path }
        public var path: String
        public var name: String
        public var size: SizeSummary
        public var modified: Date?

        public init(path: String, name: String, size: SizeSummary, modified: Date?) {
            self.path = path
            self.name = name
            self.size = size
            self.modified = modified
        }
    }
}

public struct SimulatorSummary: Sendable, Hashable {
    public var totalDevices: Int
    public var unavailableDevices: Int
    public var runtimes: [String]

    public init(totalDevices: Int, unavailableDevices: Int, runtimes: [String]) {
        self.totalDevices = totalDevices
        self.unavailableDevices = unavailableDevices
        self.runtimes = runtimes
    }
}

public struct DockerSummary: Sendable, Hashable {
    public struct Row: Sendable, Hashable, Identifiable {
        public var id: String { type }
        public var type: String
        public var total: String
        public var active: String
        public var size: String
        public var reclaimable: String

        public init(type: String, total: String, active: String, size: String, reclaimable: String) {
            self.type = type
            self.total = total
            self.active = active
            self.size = size
            self.reclaimable = reclaimable
        }
    }
    public var installed: Bool
    public var daemonRunning: Bool
    public var rows: [Row]
    public var message: String?

    public init(installed: Bool, daemonRunning: Bool, rows: [Row], message: String?) {
        self.installed = installed
        self.daemonRunning = daemonRunning
        self.rows = rows
        self.message = message
    }
}

/// Inspects well-known developer storage. Read-only; tool invocations here only *list* resources.
public struct DeveloperStorageInspector: Sendable {
    public var home: String

    public init(home: String = PathTools.userHome) {
        self.home = home
    }

    struct Spec {
        var id: String
        var group: DeveloperItem.Group
        var title: String
        var detail: String
        var relative: String
        var risk: RiskLevel
        var warning: String?
        var handling: DeveloperItem.Handling
        var hint: String?
    }

    var specs: [Spec] {
        [
            Spec(id: "xcode.deriveddata", group: .xcode, title: String(localized: "DerivedData", bundle: .module), detail: String(localized: "Build products and indexes per project. Regenerated by the next build (which is then a full rebuild).", bundle: .module),
                 relative: "Library/Developer/Xcode/DerivedData", risk: .review, handling: .selectChildren),
            Spec(id: "xcode.archives", group: .xcode, title: String(localized: "Archives", bundle: .module), detail: String(localized: "Archived builds from Product → Archive.", bundle: .module),
                 relative: "Library/Developer/Xcode/Archives", risk: .review,
                 warning: String(localized: "An archive may be the only copy of a shipped build and its debug symbols (needed to read crash reports).", bundle: .module),
                 handling: .selectChildren),
            Spec(id: "xcode.devicesupport.ios", group: .xcode, title: String(localized: "iOS Device Support", bundle: .module), detail: String(localized: "Symbols copied from connected devices; copied again on next connection.", bundle: .module),
                 relative: "Library/Developer/Xcode/iOS DeviceSupport", risk: .review, handling: .selectChildren),
            Spec(id: "xcode.devicesupport.watchos", group: .xcode, title: String(localized: "watchOS Device Support", bundle: .module), detail: String(localized: "Symbols copied from connected watches.", bundle: .module),
                 relative: "Library/Developer/Xcode/watchOS DeviceSupport", risk: .review, handling: .selectChildren),
            Spec(id: "xcode.previews", group: .xcode, title: String(localized: "SwiftUI Previews", bundle: .module), detail: String(localized: "Preview build data.", bundle: .module),
                 relative: "Library/Developer/Xcode/UserData/Previews", risk: .review, handling: .selectItem),
            Spec(id: "sim.devices", group: .simulators, title: String(localized: "Simulator Devices", bundle: .module), detail: String(localized: "Each simulator's apps, data and settings.", bundle: .module),
                 relative: "Library/Developer/CoreSimulator/Devices", risk: .review,
                 warning: String(localized: "Simulators can hold test data and app state. Remove devices with Xcode or `xcrun simctl`, not by deleting folders.", bundle: .module),
                 handling: .inspectOnly(reason: String(localized: "Managed by Xcode. Use “Delete Unavailable Simulators” or Xcode’s Devices window.", bundle: .module)),
                 hint: "xcrun simctl delete unavailable"),
            Spec(id: "sim.caches", group: .simulators, title: String(localized: "Simulator Caches", bundle: .module), detail: String(localized: "Caches created by CoreSimulator.", bundle: .module),
                 relative: "Library/Developer/CoreSimulator/Caches", risk: .review, handling: .selectChildren),
            Spec(id: "pm.npm", group: .packageManagers, title: String(localized: "npm cache", bundle: .module), detail: String(localized: "Downloaded packages.", bundle: .module), relative: ".npm/_cacache", risk: .review,
                 handling: .selectItem, hint: "npm cache clean --force"),
            Spec(id: "pm.yarn", group: .packageManagers, title: String(localized: "Yarn cache", bundle: .module), detail: String(localized: "Downloaded packages.", bundle: .module), relative: "Library/Caches/Yarn", risk: .low,
                 handling: .selectItem, hint: "yarn cache clean"),
            Spec(id: "pm.pnpm", group: .packageManagers, title: String(localized: "pnpm store", bundle: .module), detail: String(localized: "Content-addressed package store shared by projects.", bundle: .module),
                 relative: "Library/pnpm/store", risk: .review, warning: String(localized: "Projects hard-link into this store; use `pnpm store prune` instead of deleting it.", bundle: .module),
                 handling: .inspectOnly(reason: String(localized: "Use `pnpm store prune`.", bundle: .module)), hint: "pnpm store prune"),
            Spec(id: "pm.homebrew", group: .packageManagers, title: String(localized: "Homebrew cache", bundle: .module), detail: String(localized: "Downloaded bottles and casks.", bundle: .module), relative: "Library/Caches/Homebrew",
                 risk: .low, handling: .selectChildren, hint: "brew cleanup"),
            Spec(id: "pm.swiftpm", group: .packageManagers, title: String(localized: "Swift Package Manager cache", bundle: .module), detail: String(localized: "Cloned package repositories.", bundle: .module),
                 relative: "Library/Caches/org.swift.swiftpm", risk: .low, handling: .selectItem),
            Spec(id: "pm.cocoapods", group: .packageManagers, title: String(localized: "CocoaPods cache", bundle: .module), detail: String(localized: "Pod sources.", bundle: .module), relative: "Library/Caches/CocoaPods",
                 risk: .low, handling: .selectItem, hint: "pod cache clean --all"),
            Spec(id: "pm.gradle", group: .packageManagers, title: String(localized: "Gradle caches", bundle: .module), detail: String(localized: "Dependencies and build caches.", bundle: .module), relative: ".gradle/caches",
                 risk: .review, handling: .selectItem),
            Spec(id: "pm.cargo", group: .packageManagers, title: String(localized: "Cargo registry", bundle: .module), detail: String(localized: "Downloaded crates.", bundle: .module), relative: ".cargo/registry",
                 risk: .review, handling: .selectItem),
            Spec(id: "pm.pip", group: .packageManagers, title: String(localized: "pip cache", bundle: .module), detail: String(localized: "Downloaded Python packages.", bundle: .module), relative: "Library/Caches/pip",
                 risk: .low, handling: .selectItem, hint: "pip cache purge"),
            Spec(id: "docker.data", group: .containers, title: String(localized: "Docker Desktop data", bundle: .module), detail: String(localized: "The virtual machine disk holding all images, containers and volumes.", bundle: .module),
                 relative: "Library/Containers/com.docker.docker/Data", risk: .protected,
                 warning: String(localized: "Deleting this destroys every image, container and volume. Use Docker’s own tools.", bundle: .module),
                 handling: .inspectOnly(reason: String(localized: "Inspect only. Manage images and volumes in Docker Desktop or with `docker` commands.", bundle: .module))),
            Spec(id: "ml.huggingface", group: .mlModels, title: String(localized: "Hugging Face cache", bundle: .module), detail: String(localized: "Downloaded models and datasets.", bundle: .module), relative: ".cache/huggingface",
                 risk: .review, warning: String(localized: "Models can be very large to download again.", bundle: .module), handling: .selectChildren),
            Spec(id: "ml.xdg", group: .mlModels, title: String(localized: "~/.cache", bundle: .module), detail: String(localized: "Tool caches following the XDG convention (all tools combined).", bundle: .module), relative: ".cache",
                 risk: .review, warning: String(localized: "Shared by many tools; review each folder.", bundle: .module), handling: .selectChildren),
        ]
    }

    public func inspect() async -> [DeveloperItem] {
        let present = specs.filter { spec in
            if case .success(let st) = FileStat.lstat(home + "/" + spec.relative) { return st.identity.type == .directory }
            return false
        }
        let paths = present.map { home + "/" + $0.relative }
        let sizes = await DirectorySizer.measureAll(paths, maxConcurrency: 3)
        var items: [DeveloperItem] = []
        for spec in present {
            let path = home + "/" + spec.relative
            var children: [DeveloperItem.Child] = []
            if case .selectChildren = spec.handling {
                let names = AssociationFinder.children(of: path).filter { !$0.hasPrefix(".") }
                let childPaths = names.map { path + "/" + $0 }.filter {
                    if case .success(let st) = FileStat.lstat($0) { return st.identity.type != .symlink }
                    return false
                }
                let childSizes = await DirectorySizer.measureAll(childPaths, maxConcurrency: 3)
                children = childPaths.compactMap { childPath in
                    guard let size = childSizes[childPath] else { return nil }
                    return DeveloperItem.Child(path: childPath, name: (childPath as NSString).lastPathComponent, size: size, modified: size.newestModification)
                }.sorted { $0.size.allocatedSize > $1.size.allocatedSize }
            }
            items.append(DeveloperItem(id: spec.id, group: spec.group, title: spec.title, detail: spec.detail, path: path,
                                       size: sizes[path], risk: spec.risk, warning: spec.warning, handling: spec.handling,
                                       children: children, toolCommandHint: spec.hint))
        }
        return items
    }

    // MARK: Tools (documented CLIs, absolute paths, argument arrays)

    public static var xcrunPath: String? { ToolRunner.locate(["/usr/bin/xcrun"]) }
    public static var dockerPath: String? {
        ToolRunner.locate(["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"])
    }

    /// Lists simulators via `xcrun simctl list devices --json` (read-only).
    public static func simulatorSummary() -> SimulatorSummary? {
        guard let xcrun = xcrunPath,
              let output = ToolRunner.run(executable: xcrun, arguments: ["simctl", "list", "devices", "--json"], timeout: 30),
              output.status == 0 else { return nil }
        return parseSimulators(json: output.stdout)
    }

    static func parseSimulators(json: String) -> SimulatorSummary? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let devices = root["devices"] as? [String: [[String: Any]]] else { return nil }
        var total = 0
        var unavailable = 0
        for (_, list) in devices {
            for device in list {
                total += 1
                if (device["isAvailable"] as? Bool) == false { unavailable += 1 }
            }
        }
        let runtimes = devices.keys.map { $0.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "") }.sorted()
        return SimulatorSummary(totalDevices: total, unavailableDevices: unavailable, runtimes: runtimes)
    }

    /// Runs Xcode's documented `xcrun simctl delete unavailable`, which removes only simulators whose
    /// runtime is no longer installed. This is permanent (not via the Trash) and requires explicit consent.
    public static func deleteUnavailableSimulators() -> (success: Bool, message: String) {
        guard let xcrun = xcrunPath,
              let output = ToolRunner.run(executable: xcrun, arguments: ["simctl", "delete", "unavailable"], timeout: 300) else {
            return (false, String(localized: "Xcode command-line tools are not available.", bundle: .module))
        }
        if output.timedOut { return (false, String(localized: "simctl did not finish in time.", bundle: .module)) }
        return (output.status == 0, output.status == 0 ? String(localized: "Unavailable simulators were deleted by simctl.", bundle: .module) : output.stderr)
    }

    /// `docker system df` — inspect only.
    public static func dockerSummary() -> DockerSummary {
        guard let docker = dockerPath else {
            return DockerSummary(installed: false, daemonRunning: false, rows: [], message: String(localized: "Docker is not installed.", bundle: .module))
        }
        guard let output = ToolRunner.run(executable: docker, arguments: ["system", "df", "--format", "{{json .}}"], timeout: 30) else {
            return DockerSummary(installed: true, daemonRunning: false, rows: [], message: String(localized: "Docker could not be started.", bundle: .module))
        }
        guard output.status == 0 else {
            return DockerSummary(installed: true, daemonRunning: false, rows: [], message: String(localized: "Docker is installed but not running.", bundle: .module))
        }
        return DockerSummary(installed: true, daemonRunning: true, rows: parseDocker(output.stdout), message: nil)
    }

    static func parseDocker(_ text: String) -> [DockerSummary.Row] {
        text.split(separator: "\n").compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            return DockerSummary.Row(type: obj["Type"] as? String ?? "?", total: "\(obj["TotalCount"] ?? "")",
                                     active: "\(obj["Active"] ?? "")", size: obj["Size"] as? String ?? "",
                                     reclaimable: obj["Reclaimable"] as? String ?? "")
        }
    }
}
