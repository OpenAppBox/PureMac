import Foundation

/// Metadata read from a bundle's `Contents/Info.plist`.
public struct BundleMetadata: Sendable, Hashable {
    public var bundleIdentifier: String?
    public var name: String
    public var version: String?
    public var build: String?
    public var executable: String?

    public static func read(bundlePath: String) -> BundleMetadata? {
        let plistPath = bundlePath + "/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let fileName = ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let display = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
        return BundleMetadata(
            bundleIdentifier: (plist["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            name: (display?.isEmpty == false ? display! : fileName),
            version: plist["CFBundleShortVersionString"] as? String,
            build: plist["CFBundleVersion"] as? String,
            executable: plist["CFBundleExecutable"] as? String
        )
    }
}

/// Discovers installed applications in standard and user-authorized locations.
public struct AppDiscoverer: Sendable {
    public struct Root: Sendable, Hashable {
        public var path: String
        /// Apps here are part of macOS (sealed system volume) and never removable.
        public var isSystem: Bool
        public init(path: String, isSystem: Bool) {
            self.path = path
            self.isSystem = isSystem
        }
    }

    public var roots: [Root]
    public var maxDepth: Int
    public var inspectSigning: Bool

    public init(roots: [Root]? = nil, maxDepth: Int = 3, inspectSigning: Bool = true) {
        let home = PathTools.userHome
        self.roots = roots ?? [
            Root(path: "/Applications", isSystem: false),
            Root(path: home + "/Applications", isSystem: false),
            Root(path: "/System/Applications", isSystem: true),
        ]
        self.maxDepth = maxDepth
        self.inspectSigning = inspectSigning
    }

    /// All `.app` bundles under the roots (not descending into bundles, never following symlinks).
    public func bundlePaths() -> [(path: String, isSystem: Bool)] {
        var found: [(String, Bool)] = []
        var seen = Set<String>()
        for root in roots {
            guard case .success(let st) = FileStat.lstat(root.path), st.identity.type == .directory else { continue }
            try? FTSWalker.walk(root: root.path) { entry in
                guard case .directoryPre = entry.visit else { return .proceed }
                let path = entry.path
                if path.lowercased().hasSuffix(".app") {
                    if seen.insert(path).inserted { found.append((path, root.isSystem)) }
                    return .skipChildren
                }
                return entry.level >= maxDepth ? .skipChildren : .proceed
            }
        }
        return found
    }

    public func discover() async -> [InstalledApp] {
        let paths = bundlePaths()
        let inspectSigning = inspectSigning
        return await withTaskGroup(of: InstalledApp?.self) { group in
            var iterator = paths.makeIterator()
            var results: [InstalledApp] = []
            func addNext() -> Bool {
                guard let next = iterator.next() else { return false }
                group.addTask { Self.inspect(bundlePath: next.path, isSystemRoot: next.isSystem, inspectSigning: inspectSigning) }
                return true
            }
            for _ in 0..<6 where !addNext() { break }
            while let app = await group.next() {
                if let app { results.append(app) }
                _ = addNext()
            }
            return results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    /// Builds an `InstalledApp` from a bundle on disk.
    public static func inspect(bundlePath: String, isSystemRoot: Bool, inspectSigning: Bool = true) -> InstalledApp? {
        guard let meta = BundleMetadata.read(bundlePath: bundlePath) else {
            // A folder named .app without Info.plist is not a valid app.
            return nil
        }
        let signing = inspectSigning ? CodeSigningInspector.inspect(bundlePath: bundlePath)
            : CodeSigningInspector.Info(kind: .unknown, teamIdentifier: nil, applicationGroups: [])
        let fm = FileManager.default
        let hasMASReceipt = fm.fileExists(atPath: bundlePath + "/Contents/_MASReceipt/receipt")
        let source: AppSource
        if isSystemRoot || bundlePath.hasPrefix("/System/") {
            source = .system
        } else if hasMASReceipt {
            source = .appStore
        } else {
            source = .unknown
        }
        var protectionReason: String?
        if isSystemRoot || bundlePath.hasPrefix("/System/") {
            protectionReason = String(localized: "Part of macOS on the protected system volume.", bundle: .module)
        } else if signing.kind == .apple {
            protectionReason = String(localized: "Apple system app managed by macOS.", bundle: .module)
        }
        return InstalledApp(
            path: bundlePath, name: meta.name, bundleIdentifier: meta.bundleIdentifier, version: meta.version,
            build: meta.build, teamIdentifier: signing.teamIdentifier, signingKind: signing.kind, source: source,
            packageIdentifiers: [], helperBundleIdentifiers: helperIdentifiers(bundlePath: bundlePath, mainID: meta.bundleIdentifier),
            applicationGroups: signing.applicationGroups, isProtected: protectionReason != nil,
            protectionReason: protectionReason, executableName: meta.executable
        )
    }

    /// Bundle identifiers of helpers embedded in standard locations of the bundle.
    static func helperIdentifiers(bundlePath: String, mainID: String?) -> [String] {
        let fm = FileManager.default
        var ids = Set<String>()
        let containers = ["Contents/Library/LoginItems", "Contents/XPCServices", "Contents/Helpers", "Contents/Frameworks",
                          "Contents/PlugIns", "Contents/Library/LaunchServices", "Contents/MacOS"]
        for container in containers {
            let dir = bundlePath + "/" + container
            guard let children = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for child in children.prefix(200) {
                let childPath = dir + "/" + child
                let ext = (child as NSString).pathExtension.lowercased()
                if ["app", "xpc", "appex"].contains(ext), let id = BundleMetadata.read(bundlePath: childPath)?.bundleIdentifier {
                    ids.insert(id)
                } else if container == "Contents/Library/LaunchServices", PathTools.looksLikeBundleIdentifier(child) {
                    // Privileged helper tools are named by their identifier.
                    ids.insert(child)
                }
            }
        }
        // Helpers nested in embedded frameworks (e.g. Sparkle's Downloader/Installer XPC services).
        if let frameworks = try? fm.contentsOfDirectory(atPath: bundlePath + "/Contents/Frameworks") {
            for framework in frameworks.prefix(100) where framework.hasSuffix(".framework") {
                let base = bundlePath + "/Contents/Frameworks/" + framework
                for container in [base + "/XPCServices", base + "/Versions/Current/XPCServices", base + "/Versions/B/XPCServices",
                                  base + "/Versions/A/XPCServices", base + "/Versions/Current/Resources", base + "/Versions/B", base + "/Versions/A"] {
                    guard let children = try? fm.contentsOfDirectory(atPath: container) else { continue }
                    for child in children.prefix(50) {
                        let ext = (child as NSString).pathExtension.lowercased()
                        guard ext == "xpc" || ext == "app" else { continue }
                        if let id = BundleMetadata.read(bundlePath: container + "/" + child)?.bundleIdentifier { ids.insert(id) }
                    }
                }
            }
        }
        if let mainID { ids.remove(mainID) }
        return ids.sorted()
    }
}
