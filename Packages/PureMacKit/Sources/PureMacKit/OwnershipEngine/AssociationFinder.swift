import Foundation

/// Locations inside `~/Library` that hold per-app data, and how child names map to identifiers.
struct LibraryLocation: Sendable {
    var relative: String
    var kind: AssociationKind
    /// Suffixes stripped from a child name to obtain its identifier key.
    var suffixes: [String]
    /// Whether app-name (not identifier) matches are considered here (always `ambiguous`).
    var allowsNameMatch: Bool

    static let user: [LibraryLocation] = [
        .init(relative: "Caches", kind: .cache, suffixes: [], allowsNameMatch: true),
        .init(relative: "Preferences", kind: .preferences, suffixes: [".plist"], allowsNameMatch: false),
        .init(relative: "Preferences/ByHost", kind: .preferences, suffixes: [".plist"], allowsNameMatch: false),
        .init(relative: "Application Support", kind: .applicationSupport, suffixes: [], allowsNameMatch: true),
        .init(relative: "Containers", kind: .container, suffixes: [], allowsNameMatch: false),
        .init(relative: "Logs", kind: .logs, suffixes: [], allowsNameMatch: true),
        .init(relative: "Saved Application State", kind: .savedState, suffixes: [".savedState"], allowsNameMatch: false),
        .init(relative: "HTTPStorages", kind: .httpStorage, suffixes: [".binarycookies"], allowsNameMatch: false),
        .init(relative: "WebKit", kind: .webKitData, suffixes: [], allowsNameMatch: false),
        .init(relative: "Cookies", kind: .cookies, suffixes: [".binarycookies"], allowsNameMatch: false),
        .init(relative: "Application Scripts", kind: .applicationScripts, suffixes: [], allowsNameMatch: false),
    ]

    static let system: [LibraryLocation] = [
        .init(relative: "Application Support", kind: .systemLevel, suffixes: [], allowsNameMatch: false),
        .init(relative: "Caches", kind: .systemLevel, suffixes: [], allowsNameMatch: false),
        .init(relative: "Preferences", kind: .systemLevel, suffixes: [".plist"], allowsNameMatch: false),
        .init(relative: "PrivilegedHelperTools", kind: .systemLevel, suffixes: [], allowsNameMatch: false),
    ]

    /// Identifier key of a child name (suffix stripped; ByHost UUID removed).
    func key(for name: String) -> String {
        var key = name
        for suffix in suffixes where key.lowercased().hasSuffix(suffix.lowercased()) {
            key = String(key.dropLast(suffix.count))
            break
        }
        if relative.hasSuffix("ByHost"), let dot = key.lastIndex(of: ".") {
            // com.example.app.0A1B2C3D-...  →  com.example.app
            let tail = key[key.index(after: dot)...]
            if tail.count >= 12, tail.allSatisfy({ $0.isHexDigit || $0 == "-" }) { key = String(key[..<dot]) }
        }
        return key
    }
}

/// Builds evidence-based associations between an installed app and files in the Library folders.
///
/// Matching never relies on substrings. In order of strength: exact bundle identifier (or embedded
/// helper identifier) → `confirmed`; identifier followed by a `.` component → `likely`; curated
/// vendor path → `likely`; exact app-name folder → `ambiguous`. Items whose identifier belongs to a
/// *different* installed app are attributed to that app instead; identifiers declared by several
/// apps are `shared`.
public struct AssociationFinder: Sendable {
    public var libraryPath: String
    public var systemLibraryPath: String
    public var catalog: OwnershipCatalog

    public init(home: String = PathTools.userHome, systemLibraryPath: String = "/Library",
                catalog: OwnershipCatalog = .bundled()) {
        self.libraryPath = home + "/Library"
        self.systemLibraryPath = systemLibraryPath
        self.catalog = catalog
    }

    struct OwnerIndex {
        /// identifier (lowercased) → paths of apps declaring it (main or helper id)
        var owners: [String: Set<String>] = [:]
        /// app group (lowercased) → app paths declaring it
        var groupOwners: [String: Set<String>] = [:]
        /// lowercased app names → app paths
        var names: [String: Set<String>] = [:]

        init(apps: [InstalledApp]) {
            for app in apps {
                for id in app.allBundleIdentifiers { owners[id, default: []].insert(app.path) }
                for group in app.applicationGroups { groupOwners[group.lowercased(), default: []].insert(app.path) }
                names[app.name.lowercased(), default: []].insert(app.path)
                if let exe = app.executableName?.lowercased(), exe != app.name.lowercased() {
                    names[exe, default: []].insert(app.path)
                }
            }
        }

        /// The installed app(s) that most specifically own an identifier key: exact match wins,
        /// otherwise the longest declared identifier that is a dotted prefix of the key.
        func bestOwners(of key: String) -> (owners: Set<String>, exact: Bool, matchedID: String)? {
            let lower = key.lowercased()
            if let exact = owners[lower] { return (exact, true, lower) }
            var candidate = lower
            while let dot = candidate.lastIndex(of: ".") {
                candidate = String(candidate[..<dot])
                if candidate.split(separator: ".").count < 2 { break }
                if let owners = owners[candidate] { return (owners, false, candidate) }
            }
            return nil
        }
    }

    /// - Parameter knownSizes: sizes already measured (typically the app bundles), reused instead of
    ///   walking those folders again.
    public func associations(for app: InstalledApp, allApps: [InstalledApp], measureSizes: Bool = true,
                             knownSizes: [String: SizeSummary] = [:]) async -> [AppAssociation] {
        let index = OwnerIndex(apps: allApps.contains(where: { $0.path == app.path }) ? allApps : allApps + [app])
        var found: [String: AppAssociation] = [:]

        func add(_ association: AppAssociation) {
            if var existing = found[association.path] {
                existing.evidence += association.evidence.filter { !existing.evidence.contains($0) }
                if association.confidence < existing.confidence { existing.confidence = association.confidence }
                if existing.warning == nil { existing.warning = association.warning }
                found[association.path] = existing
            } else {
                found[association.path] = association
            }
        }

        add(AppAssociation(path: app.path, kind: .appBundle, confidence: app.isProtected ? .protected : .confirmed,
                           evidence: [Evidence(.exactBundleIdentifier, String(localized: "The application bundle itself", bundle: .module))],
                           warning: app.protectionReason))

        let ids = app.allBundleIdentifiers
        let mainID = app.bundleIdentifier?.lowercased()

        // Identifier-keyed user Library locations.
        for location in LibraryLocation.user {
            let dir = libraryPath + "/" + location.relative
            for name in Self.children(of: dir) {
                let key = location.key(for: name)
                let path = dir + "/" + name
                if location.relative == "Preferences", name == "ByHost" { continue }
                if SafetyPolicy.isAppleComponentName(key) && !(mainID?.hasPrefix("com.apple.") ?? false) { continue }
                if let match = index.bestOwners(of: key), !match.owners.isDisjoint(with: [app.path]) {
                    guard ids.contains(match.matchedID) else { continue }
                    let others = match.owners.subtracting([app.path])
                    let isHelper = match.matchedID != mainID
                    var evidence: [Evidence] = []
                    let confidence: AssociationConfidence
                    if !others.isEmpty {
                        confidence = .shared
                        evidence.append(Evidence(.sharedByMultipleApps, String(localized: "The identifier \(match.matchedID) is also declared by \(others.count) other installed app(s).", bundle: .module), supportsRemoval: false))
                    } else if match.exact {
                        confidence = .confirmed
                        evidence.append(isHelper
                            ? Evidence(.helperBundleIdentifier, String(localized: "Named after \(match.matchedID), a helper embedded in this app", bundle: .module))
                            : Evidence(.exactBundleIdentifier, String(localized: "Named exactly after the app’s bundle identifier \(match.matchedID)", bundle: .module)))
                    } else {
                        confidence = .likely
                        evidence.append(Evidence(.bundleIdentifierPrefix, String(localized: "Name starts with the app’s identifier \(match.matchedID) followed by a component", bundle: .module)))
                    }
                    var warning: String?
                    if location.kind == .container { warning = catalog.criticalWarning(forContainer: key) }
                    add(AppAssociation(path: path, kind: location.kind, confidence: confidence, evidence: evidence, warning: warning))
                } else if location.allowsNameMatch, index.bestOwners(of: key) == nil {
                    let lower = key.lowercased()
                    let candidates = [app.name.lowercased(), app.executableName?.lowercased()].compactMap { $0 }
                    guard lower.count >= 3, candidates.contains(lower) else { continue }
                    let sameNamed = index.names[lower] ?? []
                    guard sameNamed.count <= 1 else { continue } // two installed apps share the name → not attributable
                    add(AppAssociation(path: path, kind: location.kind, confidence: .ambiguous,
                                       evidence: [Evidence(.nameMatchOnly, String(localized: "Folder name matches the app name “\(key)”, but no identifier confirms it", bundle: .module), supportsRemoval: false)]))
                }
            }
        }

        // Group containers: entitlement evidence only.
        for name in Self.children(of: libraryPath + "/Group Containers") {
            let lower = name.lowercased()
            let path = libraryPath + "/Group Containers/" + name
            if SafetyPolicy.isAppleComponentName(lower) { continue }
            if app.applicationGroups.map({ $0.lowercased() }).contains(lower) {
                let declaring = index.groupOwners[lower] ?? [app.path]
                if declaring.count > 1 {
                    add(AppAssociation(path: path, kind: .groupContainer, confidence: .shared,
                                       evidence: [Evidence(.sharedByMultipleApps, String(localized: "App group \(name) is declared by \(declaring.count) installed apps", bundle: .module), supportsRemoval: false)]))
                } else {
                    add(AppAssociation(path: path, kind: .groupContainer, confidence: .likely,
                                       evidence: [Evidence(.applicationGroupEntitlement, String(localized: "The app’s code signature declares the app group \(name)", bundle: .module)),
                                                  Evidence(.sharedByMultipleApps, String(localized: "Group containers can be shared with other apps or extensions from the same developer", bundle: .module), supportsRemoval: false)]))
                }
            } else if let team = app.teamIdentifier, lower.hasPrefix(team.lowercased() + ".") {
                add(AppAssociation(path: path, kind: .groupContainer, confidence: .ambiguous,
                                   evidence: [Evidence(.nameMatchOnly, String(localized: "Starts with the developer’s team ID \(team), but this app does not declare the group", bundle: .module), supportsRemoval: false)]))
            }
        }

        // Curated vendor paths.
        for entry in catalog.apps where ids.contains(entry.bundleID.lowercased()) {
            for vendor in entry.paths {
                let path = libraryPath + "/" + vendor.path
                guard case .success = FileStat.lstat(path) else { continue }
                add(AppAssociation(path: path, kind: vendor.kind, confidence: .likely,
                                   evidence: [Evidence(.curatedVendorPath, String(localized: "Documented data location of \(entry.bundleID) in PureMac’s ownership catalog", bundle: .module))],
                                   warning: vendor.warning.map(RuleEvaluator.localized)))
            }
        }

        // User launch agents.
        for job in LaunchJob.readAll(in: libraryPath + "/LaunchAgents") {
            if let evidence = Self.launchEvidence(job: job, app: app, ids: ids) {
                add(AppAssociation(path: job.plistPath, kind: .launchAgent, confidence: evidence.confidence, evidence: [evidence.evidence]))
            }
        }

        // System-wide locations: shown for completeness, removal needs an administrator.
        for location in LibraryLocation.system {
            let dir = systemLibraryPath + "/" + location.relative
            for name in Self.children(of: dir) {
                let key = location.key(for: name)
                guard let match = index.bestOwners(of: key), match.owners.contains(app.path), ids.contains(match.matchedID) else { continue }
                add(AppAssociation(path: dir + "/" + name, kind: .systemLevel, confidence: match.exact ? .confirmed : .likely,
                                   evidence: [Evidence(match.exact ? .exactBundleIdentifier : .bundleIdentifierPrefix, String(localized: "System-wide item named after \(match.matchedID)", bundle: .module))],
                                   requiresAdministrator: true))
            }
        }
        for dir in [systemLibraryPath + "/LaunchAgents", systemLibraryPath + "/LaunchDaemons"] {
            for job in LaunchJob.readAll(in: dir) {
                if let evidence = Self.launchEvidence(job: job, app: app, ids: ids) {
                    add(AppAssociation(path: job.plistPath, kind: .systemLevel, confidence: evidence.confidence,
                                       evidence: [evidence.evidence], requiresAdministrator: true))
                }
            }
        }

        var results = Array(found.values)
        for i in results.indices {
            if case .success(let st) = FileStat.lstat(results[i].path) {
                results[i].identity = st.identity
                results[i].modified = st.modified
                results[i].isReadable = access(results[i].path, R_OK) == 0
                if results[i].requiresAdministrator == false, results[i].kind != .appBundle,
                   st.identity.ownerUID != getuid() {
                    results[i].requiresAdministrator = true
                }
            }
        }
        if measureSizes {
            let measured = await DirectorySizer.measureAll(results.map(\.path).filter { knownSizes[$0] == nil })
            let sizes = measured.merging(knownSizes) { fresh, _ in fresh }
            for i in results.indices {
                if let size = sizes[results[i].path] {
                    results[i].logicalSize = size.logicalSize
                    results[i].allocatedSize = size.allocatedSize
                    results[i].isPartiallyMeasured = size.isPartial
                    if let newest = size.newestModification { results[i].modified = newest }
                }
            }
        }
        return results.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return AssociationKind.allCases.firstIndex(of: lhs.kind)! < AssociationKind.allCases.firstIndex(of: rhs.kind)! }
            return lhs.path < rhs.path
        }
    }

    static func launchEvidence(job: LaunchJob, app: InstalledApp, ids: Set<String>) -> (confidence: AssociationConfidence, evidence: Evidence)? {
        if job.associatedBundleIdentifiers.contains(where: { ids.contains($0.lowercased()) }) {
            return (.confirmed, Evidence(.launchAgentLabel, String(localized: "The job declares this app in AssociatedBundleIdentifiers", bundle: .module)))
        }
        if let program = job.program, PathTools.isStrictlyInside(program, app.path) {
            return (.confirmed, Evidence(.launchAgentProgramInBundle, String(localized: "The job runs a program inside this app’s bundle", bundle: .module)))
        }
        if let label = job.label?.lowercased() {
            if ids.contains(label) {
                return (.confirmed, Evidence(.exactBundleIdentifier, String(localized: "The job’s label is the app’s identifier \(label)", bundle: .module)))
            }
            if let id = ids.first(where: { label.hasPrefix($0 + ".") }) {
                return (.likely, Evidence(.bundleIdentifierPrefix, String(localized: "The job’s label starts with the app’s identifier \(id)", bundle: .module)))
            }
        }
        return nil
    }

    static func children(of directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter { $0 != ".DS_Store" && $0 != ".localized" }
    }
}
