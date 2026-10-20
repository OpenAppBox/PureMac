import Foundation

/// Bundled, versioned catalog of documented vendor data paths and known non-app identifiers.
public struct OwnershipCatalog: Codable, Sendable {
    public struct VendorPath: Codable, Sendable, Hashable {
        public var path: String
        public var kind: AssociationKind
        public var warning: String?
    }

    public struct AppEntry: Codable, Sendable, Hashable {
        public var bundleID: String
        /// The app's usual name (shown for its leftovers when the app is gone).
        public var name: String?
        public var paths: [VendorPath]
    }

    public struct CriticalContainer: Codable, Sendable, Hashable {
        public var bundleID: String
        public var warning: String
    }

    public var schemaVersion: Int
    public var catalogVersion: String
    public var apps: [AppEntry]
    public var criticalContainers: [CriticalContainer]
    public var nonAppIdentifierPrefixes: [String]

    public enum ValidationError: Error, Equatable {
        case unsupportedSchema(Int)
        case invalidPath(String)
    }

    public static let empty = OwnershipCatalog(schemaVersion: 1, catalogVersion: "0", apps: [], criticalContainers: [], nonAppIdentifierPrefixes: ["com.apple."])

    public static func bundled() -> OwnershipCatalog {
        guard let url = Bundle.module.url(forResource: "OwnershipCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(OwnershipCatalog.self, from: data),
              (try? catalog.validate()) != nil
        else { return .empty }
        return catalog
    }

    /// Rejects absolute paths, traversal, and paths that would name a standard Library folder itself.
    public func validate() throws {
        guard schemaVersion == 1 else { throw ValidationError.unsupportedSchema(schemaVersion) }
        for entry in apps {
            for vendor in entry.paths {
                let parts = vendor.path.split(separator: "/").map(String.init)
                guard !vendor.path.hasPrefix("/"), parts.count >= 2, !parts.contains(".."), !parts.contains("."),
                      !parts.contains(where: { $0.contains("*") }) else {
                    throw ValidationError.invalidPath(vendor.path)
                }
            }
        }
    }

    func isNonAppIdentifier(_ id: String) -> Bool {
        let lower = id.lowercased()
        return nonAppIdentifierPrefixes.contains { lower.hasPrefix($0.lowercased()) }
    }

    func criticalWarning(forContainer id: String) -> String? {
        let match = criticalContainers.first(where: { $0.bundleID.lowercased() == id.lowercased() })
        return match.map { RuleEvaluator.localized($0.warning) }
    }
}

/// A parsed launchd job definition (`~/Library/LaunchAgents/*.plist` and friends).
public struct LaunchJob: Sendable, Hashable {
    public var plistPath: String
    public var label: String?
    public var program: String?
    public var associatedBundleIdentifiers: [String]
    public var isDisabled: Bool

    public static func read(_ path: String) -> LaunchJob? {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let arguments = plist["ProgramArguments"] as? [String]
        let program = (plist["Program"] as? String) ?? (plist["BundleProgram"] as? String) ?? arguments?.first
        var associated: [String] = []
        if let list = plist["AssociatedBundleIdentifiers"] as? [String] { associated = list }
        if let single = plist["AssociatedBundleIdentifiers"] as? String { associated = [single] }
        return LaunchJob(plistPath: path, label: plist["Label"] as? String, program: program,
                         associatedBundleIdentifiers: associated, isDisabled: (plist["Disabled"] as? Bool) ?? false)
    }

    /// Reads every job plist directly inside `directory`.
    public static func readAll(in directory: String) -> [LaunchJob] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return names.filter { $0.hasSuffix(".plist") }.sorted().compactMap { read(directory + "/" + $0) }
    }

    /// Whether the job's program lives at a path that currently exists (broken agents point nowhere).
    public var programExists: Bool {
        guard let program, program.hasPrefix("/") else { return true }
        return FileManager.default.fileExists(atPath: program)
    }
}
