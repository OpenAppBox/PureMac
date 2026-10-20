import Foundation

public struct RuleEvaluation: Sendable {
    public struct Rejection: Sendable, Hashable {
        public var path: String
        public var ruleID: String
        public var reason: String
    }

    public struct RuleSummary: Sendable, Hashable, Identifiable {
        public var id: String { ruleID }
        public var ruleID: String
        public var title: String
        public var itemCount: Int
        public var allocatedBytes: Int64
    }

    public var candidates: [CleanupCandidate]
    public var rejections: [Rejection]
    public var summaries: [RuleSummary]
    public var evaluatedAt: Date

    public init(candidates: [CleanupCandidate], rejections: [Rejection] = [], summaries: [RuleSummary] = [], evaluatedAt: Date = Date()) {
        self.candidates = candidates
        self.rejections = rejections
        self.summaries = summaries
        self.evaluatedAt = evaluatedAt
    }
}

/// Applies the validated rule catalog to the filesystem. **Read-only**: it lists folders and reads
/// metadata, and never modifies anything.
public struct RuleEvaluator: Sendable {
    public var catalog: CleanupRuleCatalog
    public var home: String
    public var policy: SafetyPolicy
    public var now: Date

    /// Rule texts live in `CleanupRules.json` in English; their translations are entries of the
    /// package's string catalog keyed by the English text.
    static func localized(_ text: String) -> String {
        String(localized: String.LocalizationValue(text), bundle: .module)
    }

    public init(catalog: CleanupRuleCatalog, home: String = PathTools.userHome,
                policy: SafetyPolicy, now: Date = Date()) {
        self.catalog = catalog
        self.home = PathTools.realPath(home) ?? home
        self.policy = policy
        self.now = now
    }

    public func evaluate(installedApps: [InstalledApp], runningIdentifiers: Set<String>) async -> RuleEvaluation {
        let appsByID = Dictionary(installedApps.compactMap { app in app.bundleIdentifier.map { ($0.lowercased(), app) } },
                                  uniquingKeysWith: { first, _ in first })
        let running = Set(runningIdentifiers.map { $0.lowercased() })
        let owners = Owners(apps: installedApps.filter { !($0.bundleIdentifier?.lowercased().hasPrefix("com.apple.") ?? true) })

        struct Match { var rule: CleanupRule; var path: String; var root: String; var matchedBundleID: String? }
        var matches: [Match] = []
        var rejections: [RuleEvaluation.Rejection] = []

        for rule in catalog.rules {
            let root = home + "/" + rule.root
            guard case .success(let rootStat) = FileStat.lstat(root), rootStat.identity.type == .directory else { continue }
            for pattern in rule.patterns {
                for (path, bundleID) in expand(pattern: pattern, under: root, rule: rule, owners: owners) {
                    let verdict = policy.evaluate(path, intent: .ruleCleanup, allowedRoots: [root])
                    if let reason = verdict.reason {
                        rejections.append(.init(path: path, ruleID: rule.id, reason: reason))
                        continue
                    }
                    matches.append(Match(rule: rule, path: path, root: root, matchedBundleID: bundleID))
                }
            }
        }

        // Measure every match (bounded concurrency), then build candidates.
        let sizes = await DirectorySizer.measureAll(matches.map(\.path))
        var candidates: [CleanupCandidate] = []
        for match in matches {
            guard case .success(let st) = FileStat.lstat(match.path), st.identity.type != .symlink else { continue }
            let size = sizes[match.path] ?? SizeSummary()
            guard size.allocatedSize > 0 || size.logicalSize > 0 else { continue }
            if let days = match.rule.minimumAgeDays {
                let newest = max(size.newestModification ?? st.modified, st.modified)
                if newest > now.addingTimeInterval(-Double(days) * 86_400) { continue }
            }
            let relatedIDs = (match.rule.bundleIDs ?? []).map { $0.lowercased() } + [match.matchedBundleID].compactMap { $0 }
            let relatedApp = relatedIDs.lazy.compactMap { appsByID[$0] }.first
            var blocked: String?
            if match.rule.requiresAppClosed, let runningID = relatedIDs.first(where: { running.contains($0) }) {
                let name = appsByID[runningID]?.name ?? runningID
                blocked = String(localized: "Quit \(name) first — its cache is in use.", bundle: .module)
            }
            var evidence = [Evidence(.curatedVendorPath, Self.localized(match.rule.evidence))]
            if let id = match.matchedBundleID {
                evidence.append(Evidence(.exactBundleIdentifier, String(localized: "Matches the installed app \(appsByID[id]?.name ?? id) (\(id))", bundle: .module)))
            }
            if size.isPartial {
                evidence.append(Evidence(.systemOwned, String(localized: "Some contents could not be read; the size is a lower bound", bundle: .module), supportsRemoval: false))
            }
            candidates.append(CleanupCandidate(
                path: match.path, title: Self.localized(match.rule.title), reason: Self.localized(match.rule.description), category: match.rule.category,
                risk: match.rule.risk, source: .rule(id: match.rule.id), logicalSize: size.logicalSize,
                allocatedSize: size.allocatedSize, itemCount: max(1, size.fileCount), modified: size.newestModification ?? st.modified,
                identity: st.identity, relatedBundleIdentifier: relatedApp?.bundleIdentifier ?? relatedIDs.first,
                relatedAppName: relatedApp?.name, requiresAppClosed: match.rule.requiresAppClosed,
                regenerationImpact: Self.localized(match.rule.regenerationImpact), evidence: evidence,
                isPreselected: match.rule.risk == .low && blocked == nil, blockedReason: blocked, scopeRoot: match.root,
                relatedAppPath: relatedApp?.path))
        }

        let deduplicated = Self.deduplicate(candidates)
        var summaries: [String: RuleEvaluation.RuleSummary] = [:]
        for candidate in deduplicated {
            guard case .rule(let id) = candidate.source else { continue }
            var summary = summaries[id] ?? .init(ruleID: id, title: candidate.title, itemCount: 0, allocatedBytes: 0)
            summary.itemCount += 1
            summary.allocatedBytes += candidate.allocatedSize
            summaries[id] = summary
        }
        return RuleEvaluation(candidates: deduplicated.sorted { $0.allocatedSize > $1.allocatedSize }, rejections: rejections,
                              summaries: summaries.values.sorted { $0.allocatedBytes > $1.allocatedBytes }, evaluatedAt: now)
    }

    /// Installed, non-Apple apps by the names their data can be found under.
    struct Owners {
        /// Lower-cased bundle identifiers.
        var identifiers: Set<String> = []
        /// Lower-cased app name → bundle identifier (`Steam` → `com.valvesoftware.steam`).
        var names: [String: String] = [:]
        /// Lower-cased data-folder names of Electron apps (their name and executable) → identifier.
        var electronFolders: [String: String] = [:]

        init(apps: [InstalledApp]) {
            for app in apps {
                guard let id = app.bundleIdentifier?.lowercased() else { continue }
                identifiers.insert(id)
                let name = app.name.lowercased()
                // Short or generic names would match folders of other software.
                if name.count >= 3 { names[name] = names[name] ?? id }
                if FileManager.default.fileExists(atPath: app.path + "/Contents/Frameworks/Electron Framework.framework") {
                    for folder in [app.name, app.executableName].compactMap({ $0?.lowercased() }) where folder.count >= 3 && folder != "electron" {
                        electronFolders[folder] = electronFolders[folder] ?? id
                    }
                }
            }
        }

        init(identifiers: Set<String>) { self.identifiers = identifiers }

        /// The app a child name stands for under a token segment, or `nil`.
        func owner(of name: String, token segment: String) -> String? {
            let lower = name.lowercased()
            switch segment {
            case "{appName}": return names[lower]
            case "{electronApp}": return electronFolders[lower]
            default:
                let suffix = segment.dropFirst("{bundleID}".count).lowercased()
                guard lower.hasSuffix(suffix) else { return nil }
                let id = String(lower.dropLast(suffix.count))
                return identifiers.contains(id) ? id : nil
            }
        }
    }

    /// Expands one pattern below `root`. Never descends through symlinks; intermediate segments must be real folders.
    func expand(pattern: [String], under root: String, rule: CleanupRule, owners: Owners) -> [(String, String?)] {
        var frontier: [(path: String, bundleID: String?)] = [(root, nil)]
        for (index, segment) in pattern.enumerated() {
            let isLast = index == pattern.count - 1
            let isToken = segment.hasPrefix("{")
            var next: [(String, String?)] = []
            for (dir, bundleID) in frontier {
                let names: [String]
                if segment == "*" || isToken {
                    names = AssociationFinder.children(of: dir).filter { !$0.hasPrefix(".") }
                } else {
                    names = [segment]
                }
                for name in names {
                    let path = dir + "/" + name
                    guard case .success(let st) = FileStat.lstat(path), st.identity.type != .symlink else { continue }
                    var matchedID = bundleID
                    if isToken {
                        guard let owner = owners.owner(of: name, token: segment) else { continue }
                        matchedID = owner
                    }
                    if !isLast {
                        guard st.identity.type == .directory else { continue }
                    } else {
                        switch rule.itemType {
                        case .directory: guard st.identity.type == .directory else { continue }
                        case .file: guard st.identity.type == .regular else { continue }
                        case .any: break
                        }
                        if let suffixes = rule.nameSuffixes, !suffixes.contains(where: { name.lowercased().hasSuffix($0.lowercased()) }) { continue }
                        if let exclusions = rule.exclusions, exclusions.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { continue }
                    }
                    next.append((path, matchedID))
                }
            }
            frontier = next
        }
        return frontier
    }

    /// Removes overlapping candidates: when one candidate contains another, only the outer one is
    /// kept (so bytes are never counted twice) and it takes the more cautious risk of the two.
    public static func deduplicate(_ candidates: [CleanupCandidate]) -> [CleanupCandidate] {
        let sorted = candidates.sorted { $0.path < $1.path }
        var kept: [CleanupCandidate] = []
        for candidate in sorted {
            if let index = kept.lastIndex(where: { PathTools.isSameOrInside(candidate.path, $0.path) }) {
                if candidate.risk > kept[index].risk {
                    kept[index].risk = candidate.risk
                    kept[index].isPreselected = false
                }
                if kept[index].blockedReason == nil { kept[index].blockedReason = candidate.blockedReason }
                if kept[index].blockedReason != nil { kept[index].isPreselected = false }
                continue
            }
            kept.append(candidate)
        }
        return kept
    }
}
