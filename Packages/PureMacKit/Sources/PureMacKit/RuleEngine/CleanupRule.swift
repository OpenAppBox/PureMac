import Foundation

/// A versioned, data-driven cleanup recipe from `Resources/CleanupRules.json`. Each rule names one
/// narrow root and its patterns, a risk level, what removing a match costs (`regenerationImpact`)
/// and the tests in `RuleEngineTests` that cover it. `CleanupRuleCatalog.validate()` rejects unsafe
/// rules at load: unapproved roots, `..`, wildcards spanning folders, unknown tokens, the protected
/// risk level and rules without tests.
public struct CleanupRule: Codable, Sendable, Hashable, Identifiable {
    public enum ItemType: String, Codable, Sendable { case directory, file, any }
    public enum RemovalStrategy: String, Codable, Sendable { case trashItem }

    public var id: String
    public var title: String
    public var description: String
    public var category: CleanupCategory
    public var risk: RiskLevel
    /// Base folder relative to the home folder; must be on the approved list.
    public var root: String
    /// Path segment patterns below `root`. A segment is a literal name, `*` (any one name), or
    /// `{bundleID}` (an installed, non-Apple app's bundle identifier).
    public var patterns: [[String]]
    public var itemType: ItemType
    public var nameSuffixes: [String]?
    public var bundleIDs: [String]?
    public var minimumAgeDays: Int?
    public var exclusions: [String]?
    public var requiresAppClosed: Bool
    public var removalStrategy: RemovalStrategy
    public var regenerationImpact: String
    public var evidence: String
    public var supportedVersions: String?
    /// Names of the automated tests that cover this rule (documentation; checked by a test).
    public var tests: [String]
}

public struct CleanupRuleCatalog: Codable, Sendable {
    public var schemaVersion: Int
    public var catalogVersion: String
    public var rules: [CleanupRule]

    public static let supportedSchemaVersion = 1

    /// Folders (relative to home) that rules may target. Anything else is rejected at load time.
    public static let approvedRoots: [String] = [
        "Library/Caches", "Library/Logs", "Library/Application Support", "Library/Developer/Xcode",
        "Library/Developer/CoreSimulator/Caches", "Downloads", ".npm", ".cache",
    ]

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case unsupportedSchema(Int)
        case duplicateID(String)
        case rootNotApproved(rule: String, root: String)
        case invalidPattern(rule: String, pattern: [String])
        case protectedRiskInRule(String)
        case missingTests(String)
        case unknownToken(rule: String, segment: String)

        public var description: String {
            switch self {
            case .unsupportedSchema(let v): "Unsupported rule schema version \(v)"
            case .duplicateID(let id): "Duplicate rule id \(id)"
            case .rootNotApproved(let rule, let root): "Rule \(rule): root \(root) is not approved"
            case .invalidPattern(let rule, let pattern): "Rule \(rule): invalid pattern \(pattern)"
            case .protectedRiskInRule(let rule): "Rule \(rule): rules cannot use the protected risk level"
            case .missingTests(let rule): "Rule \(rule): no tests listed"
            case .unknownToken(let rule, let segment): "Rule \(rule): unknown token \(segment)"
            }
        }
    }

    /// Strict validation: approved roots only, no traversal, no wildcards that span folders, no
    /// absolute paths, no rule that could name its own root or the home folder.
    public func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion else { throw ValidationError.unsupportedSchema(schemaVersion) }
        var ids = Set<String>()
        for rule in rules {
            guard ids.insert(rule.id).inserted else { throw ValidationError.duplicateID(rule.id) }
            guard Self.approvedRoots.contains(rule.root) else { throw ValidationError.rootNotApproved(rule: rule.id, root: rule.root) }
            guard rule.risk != .protected else { throw ValidationError.protectedRiskInRule(rule.id) }
            guard !rule.tests.isEmpty else { throw ValidationError.missingTests(rule.id) }
            guard !rule.patterns.isEmpty else { throw ValidationError.invalidPattern(rule: rule.id, pattern: []) }
            for pattern in rule.patterns {
                guard !pattern.isEmpty else { throw ValidationError.invalidPattern(rule: rule.id, pattern: pattern) }
                for segment in pattern {
                    if segment.isEmpty || segment == "." || segment == ".." || segment.contains("/") || segment.contains("\0")
                        || segment == "**" || (segment.contains("*") && segment != "*") {
                        throw ValidationError.invalidPattern(rule: rule.id, pattern: pattern)
                    }
                    if segment.hasPrefix("{"), !Self.isKnownToken(segment) {
                        throw ValidationError.unknownToken(rule: rule.id, segment: segment)
                    }
                }
            }
        }
    }

    /// `{bundleID}` (optionally followed by a literal suffix such as `.ShipIt`), `{appName}` and
    /// `{electronApp}`. Every token stands for one installed, non-Apple app — never a wildcard.
    static func isKnownToken(_ segment: String) -> Bool {
        if segment == "{appName}" || segment == "{electronApp}" { return true }
        guard segment.hasPrefix("{bundleID}") else { return false }
        let suffix = segment.dropFirst("{bundleID}".count)
        return !suffix.contains("{") && !suffix.contains("}") && !suffix.contains("*")
    }

    public static func bundled() throws -> CleanupRuleCatalog {
        guard let url = Bundle.module.url(forResource: "CleanupRules", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try load(from: Data(contentsOf: url))
    }

    public static func load(from data: Data) throws -> CleanupRuleCatalog {
        let catalog = try JSONDecoder().decode(CleanupRuleCatalog.self, from: data)
        try catalog.validate()
        return catalog
    }
}
