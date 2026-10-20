import Foundation

/// Finds probable remnants of applications that are no longer installed.
///
/// An item is reported only when evidence converges:
/// 1. it sits in an identifier-keyed Library location and its name is a well-formed bundle identifier;
/// 2. no installed app declares that identifier, a parent of it, or an extension of it;
/// 3. LaunchServices knows no application with that identifier anywhere on disk;
/// 4. no running process has that identifier;
/// 5. no launch agent references it;
/// 6. it is not an Apple component, a known SDK/framework identifier, or on the ignore list.
///
/// The result is `likely` only when, additionally, the vendor has no other installed apps and the
/// item has not been modified recently. Otherwise it is `ambiguous`. A stale timestamp alone never
/// qualifies an item. Orphans are never preselected for removal.
///
/// Beyond identifier-named items it also finds:
/// - folders PureMac's ownership catalog documents for an app that is not installed (`Application
///   Support/Spotify`), unless an installed app carries that name;
/// - leftovers of an app that is in the Trash (macOS still registers it there, which used to hide
///   exactly the leftovers people look for right after uninstalling);
/// - shared group containers no installed app or developer team uses (always `ambiguous`).
public struct OrphanDetector: Sendable {
    public var libraryPath: String
    public var catalog: OwnershipCatalog
    public var launchServices: any LaunchServicesQuerying
    public var running: any RunningAppChecking
    public var now: Date
    public var recentDays: Int

    public init(home: String = PathTools.userHome, catalog: OwnershipCatalog = .bundled(),
                launchServices: any LaunchServicesQuerying = WorkspaceLaunchServices(),
                running: any RunningAppChecking = WorkspaceRunningAppChecker(), now: Date = Date(), recentDays: Int = 30) {
        self.libraryPath = home + "/Library"
        self.catalog = catalog
        self.launchServices = launchServices
        self.running = running
        self.now = now
        self.recentDays = recentDays
    }

    static let locations: [LibraryLocation] = LibraryLocation.user.filter { $0.relative != "Preferences/ByHost" }
        + [LibraryLocation(relative: "Preferences/ByHost", kind: .preferences, suffixes: [".plist"], allowsNameMatch: false),
           LibraryLocation(relative: "Group Containers", kind: .groupContainer, suffixes: [], allowsNameMatch: false)]

    /// Where LaunchServices still registers an app: in a Trash, the app is uninstalled.
    static func isInTrash(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.contains("/.Trashes/")
    }

    /// `ABCDE12345.com.vendor.app` → (team `ABCDE12345`, `com.vendor.app`); `nil` without a team prefix.
    static func teamPrefixed(_ name: String) -> (team: String, identifier: String)? {
        guard let dot = name.firstIndex(of: "."), name.distance(from: name.startIndex, to: dot) == 10 else { return nil }
        let team = String(name[..<dot])
        guard team.allSatisfy({ ($0.isUppercase || $0.isNumber) && $0.isASCII }), team.contains(where: \.isNumber) else { return nil }
        let rest = String(name[name.index(after: dot)...])
        return rest.split(separator: ".").count >= 2 ? (team, rest) : nil
    }

    public func findOrphans(installedApps: [InstalledApp], ignoredIdentifiers: Set<String> = [], measureSizes: Bool = true) async -> [OrphanCandidate] {
        let index = AssociationFinder.OwnerIndex(apps: installedApps)
        let installedIDs = Set(index.owners.keys)
        let vendors = Set(installedIDs.map(Self.vendor(of:)))
        let installedGroups = Set(installedApps.flatMap { $0.applicationGroups.map { $0.lowercased() } })
        let runningIDs = await running.runningBundleIdentifiers()
        let jobs = LaunchJob.readAll(in: libraryPath + "/LaunchAgents")
        let jobLabels = jobs.compactMap { $0.label?.lowercased() }
        // Ignored entries come from item names, which can carry a suffix (com.x.app.plist).
        let ignored = Set(ignoredIdentifiers.map { Self.identifier(fromItemName: $0.lowercased()) })
        let installedTeams = Set(installedApps.compactMap { $0.teamIdentifier?.uppercased() })
        let installedNames = Set(installedApps.map { Self.nameKey($0.name) })

        var candidates: [OrphanCandidate] = []
        /// Per identifier: `nil` = not registered, `[]`… = registered only in the Trash, or known elsewhere.
        var launchServicesCache: [String: LaunchServicesVerdict] = [:]
        func launchServicesVerdict(_ key: String) async -> LaunchServicesVerdict {
            let lower = key.lowercased()
            if let cached = launchServicesCache[lower] { return cached }
            let registered = await launchServices.applicationPaths(forBundleIdentifier: key)
            let verdict: LaunchServicesVerdict = registered.isEmpty ? .unknown
                : registered.allSatisfy(Self.isInTrash) ? .inTrash(registered[0]) : .installedElsewhere
            launchServicesCache[lower] = verdict
            return verdict
        }

        for location in Self.locations {
            let dir = libraryPath + "/" + location.relative
            for name in AssociationFinder.children(of: dir) {
                if location.relative == "Preferences", name == "ByHost" { continue }
                var key = location.key(for: name)
                if location.kind == .groupContainer {
                    // Team-prefixed groups belong to a developer: in use while any of their apps is installed.
                    if let prefixed = Self.teamPrefixed(name) {
                        if installedTeams.contains(prefixed.team) { continue }
                        key = prefixed.identifier
                    } else if !name.lowercased().hasPrefix("group.") {
                        continue
                    }
                }
                let lower = key.lowercased()
                guard PathTools.looksLikeBundleIdentifier(key) || (location.kind == .groupContainer && key.split(separator: ".").count >= 2) else { continue }
                guard !SafetyPolicy.isAppleComponentName(lower), !catalog.isNonAppIdentifier(lower), !ignored.contains(lower) else { continue }
                // An app group declared by an installed app is in use.
                if installedGroups.contains(lower) { continue }
                // "group.<identifier>" folders are judged by the identifier inside the group name.
                let owner = Self.ownerKey(lower)
                // Installed: exact, a dotted parent of an installed id, or an extension of one.
                if index.bestOwners(of: owner) != nil { continue }
                if installedIDs.contains(where: { $0.hasPrefix(owner + ".") }) { continue }
                if runningIDs.contains(lower) || runningIDs.contains(where: { $0.hasPrefix(lower + ".") }) { continue }
                if location.kind != .launchAgent, jobLabels.contains(where: { $0 == lower || $0.hasPrefix(lower + ".") }) { continue }
                let registration = await launchServicesVerdict(location.kind == .groupContainer ? owner : key)
                if case .installedElsewhere = registration { continue }

                let path = dir + "/" + name
                guard case .success(let st) = FileStat.lstat(path), st.identity.type != .symlink else { continue }
                var evidence: [Evidence] = [
                    Evidence(.exactBundleIdentifier, String(localized: "Named after the bundle identifier \(key) in \(location.relative)", bundle: .module)),
                    Evidence(.noInstalledOwner, String(localized: "No installed app declares \(key) or a related identifier", bundle: .module)),
                ]
                var appName: String?
                if case .inTrash(let trashed) = registration {
                    appName = Self.appName(ofBundle: trashed)
                    evidence.append(Evidence(.appInTrash, String(localized: "The app itself is in the Trash (\((trashed as NSString).lastPathComponent))", bundle: .module)))
                } else {
                    evidence.append(Evidence(.notRegisteredWithLaunchServices, String(localized: "macOS (LaunchServices) knows no application with this identifier anywhere on disk", bundle: .module)))
                }
                var confidence: AssociationConfidence = .likely
                let vendor = Self.vendor(of: owner)
                if vendors.contains(vendor) {
                    confidence = .ambiguous
                    evidence.append(Evidence(.vendorStillInstalled, String(localized: "Another app from the same vendor (\(vendor)) is installed and may share this data", bundle: .module), supportsRemoval: false))
                }
                if location.kind == .groupContainer {
                    confidence = .ambiguous
                    evidence.append(Evidence(.sharedByMultipleApps, String(localized: "Group containers can be shared with other apps or extensions from the same developer", bundle: .module), supportsRemoval: false))
                }
                var candidate = OrphanCandidate(path: path, inferredBundleIdentifier: key, kind: location.kind,
                                                confidence: confidence, evidence: evidence, modified: st.modified, identity: st.identity)
                candidate.appName = appName
                candidates.append(candidate)
            }
        }

        // User launch agents whose job identifies an app that is gone and whose program no longer exists.
        for job in jobs {
            guard let label = job.label, PathTools.looksLikeBundleIdentifier(label) else { continue }
            let lower = label.lowercased()
            guard !SafetyPolicy.isAppleComponentName(lower), !catalog.isNonAppIdentifier(lower), !ignored.contains(lower) else { continue }
            if index.bestOwners(of: lower) != nil || installedIDs.contains(where: { $0.hasPrefix(lower + ".") }) { continue }
            if runningIDs.contains(lower) { continue }
            guard !job.programExists, case .success(let st) = FileStat.lstat(job.plistPath) else { continue }
            candidates.append(OrphanCandidate(
                path: job.plistPath, inferredBundleIdentifier: label, kind: .launchAgent, confidence: .likely,
                evidence: [Evidence(.launchAgentLabel, String(localized: "Launch agent \(label) belongs to no installed app", bundle: .module)),
                           Evidence(.noInstalledOwner, String(localized: "Its program \(job.program ?? "?") no longer exists", bundle: .module))],
                modified: st.modified, identity: st.identity))
        }

        // Folders the catalog documents for an app that is not installed (named after the app, not its identifier).
        var seen = Set(candidates.map(\.path))
        for entry in catalog.apps {
            let id = entry.bundleID
            let lower = id.lowercased()
            guard !ignored.contains(lower), index.bestOwners(of: lower) == nil, !installedIDs.contains(where: { $0.hasPrefix(lower + ".") }),
                  !runningIDs.contains(lower) else { continue }
            let registration = await launchServicesVerdict(id)
            if case .installedElsewhere = registration { continue }
            for vendorPath in entry.paths {
                let path = libraryPath + "/" + vendorPath.path
                let folderName = (vendorPath.path as NSString).lastPathComponent
                // An installed app with this name is a different build of the same app (another
                // identifier, e.g. a beta or a Mac App Store version): never an orphan.
                guard !seen.contains(path), !installedNames.contains(Self.nameKey(folderName)),
                      !installedNames.contains(Self.nameKey(entry.name ?? folderName)),
                      case .success(let st) = FileStat.lstat(path), st.identity.type != .symlink else { continue }
                seen.insert(path)
                var evidence = [
                    Evidence(.curatedVendorPath, String(localized: "Documented data location of \(id) in PureMac’s ownership catalog", bundle: .module)),
                    Evidence(.noInstalledOwner, String(localized: "No installed app declares \(id) or a related identifier", bundle: .module)),
                ]
                var appName = entry.name ?? folderName
                if case .inTrash(let trashed) = registration {
                    appName = Self.appName(ofBundle: trashed)
                    evidence.append(Evidence(.appInTrash, String(localized: "The app itself is in the Trash (\((trashed as NSString).lastPathComponent))", bundle: .module)))
                } else {
                    evidence.append(Evidence(.notRegisteredWithLaunchServices, String(localized: "macOS (LaunchServices) knows no application with this identifier anywhere on disk", bundle: .module)))
                }
                var confidence: AssociationConfidence = .likely
                let vendor = Self.vendor(of: lower)
                if vendors.contains(vendor) {
                    confidence = .ambiguous
                    evidence.append(Evidence(.vendorStillInstalled, String(localized: "Another app from the same vendor (\(vendor)) is installed and may share this data", bundle: .module), supportsRemoval: false))
                }
                if let warning = vendorPath.warning {
                    confidence = .ambiguous
                    evidence.append(Evidence(.nameMatchOnly, RuleEvaluator.localized(warning), supportsRemoval: false))
                }
                var candidate = OrphanCandidate(path: path, inferredBundleIdentifier: id, kind: vendorPath.kind,
                                                confidence: confidence, evidence: evidence, modified: st.modified, identity: st.identity)
                candidate.appName = appName
                candidates.append(candidate)
            }
        }

        if measureSizes {
            let sizes = await DirectorySizer.measureAll(candidates.map(\.path))
            for i in candidates.indices {
                guard let size = sizes[candidates[i].path] else { continue }
                candidates[i].logicalSize = size.logicalSize
                candidates[i].allocatedSize = size.allocatedSize
                if let newest = size.newestModification { candidates[i].modified = newest }
            }
        }

        // Recent activity argues against "no longer used" (applied after sizing so the newest
        // modification anywhere inside the item counts).
        let recentCutoff = now.addingTimeInterval(-Double(recentDays) * 86_400)
        for i in candidates.indices {
            let appTrashed = candidates[i].evidence.contains { $0.kind == .appInTrash }
            if let modified = candidates[i].modified, modified > recentCutoff, appTrashed {
                // Used until it was uninstalled: recent use is expected, not a sign it is still in use.
                candidates[i].evidence.append(Evidence(.recentlyModified, String(localized: "Last used \(Self.days(since: modified, now: now)) day(s) ago, before the app went to the Trash", bundle: .module)))
            } else if let modified = candidates[i].modified, modified > recentCutoff {
                candidates[i].confidence = .ambiguous
                candidates[i].evidence.append(Evidence(.recentlyModified, String(localized: "Modified \(Self.days(since: modified, now: now)) day(s) ago — something may still be using it", bundle: .module), supportsRemoval: false))
            } else if let modified = candidates[i].modified {
                candidates[i].evidence.append(Evidence(.staleModification, String(localized: "Not modified for \(Self.days(since: modified, now: now)) days", bundle: .module)))
            }
        }
        return candidates.sorted { ($0.allocatedSize ?? 0) > ($1.allocatedSize ?? 0) }
    }

    enum LaunchServicesVerdict {
        case unknown
        case inTrash(String)
        case installedElsewhere
    }

    /// Lower-cased name without `.app`, for comparing app names with folder names.
    static func nameKey(_ name: String) -> String {
        let lower = name.lowercased()
        return lower.hasSuffix(".app") ? String(lower.dropLast(4)) : lower
    }

    /// The display name of an app bundle (Info.plist), else its file name.
    static func appName(ofBundle path: String) -> String {
        if let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") {
            if let name = info["CFBundleDisplayName"] as? String, !name.isEmpty { return name }
            if let name = info["CFBundleName"] as? String, !name.isEmpty { return name }
        }
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// `com.x.app.plist` → `com.x.app` (the suffixes of identifier-keyed Library items).
    static func identifier(fromItemName name: String) -> String {
        for suffix in [".plist", ".savedstate", ".binarycookies"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    /// The identifier an item name stands for: `group.com.example.shared` → `com.example.shared`.
    static func ownerKey(_ lower: String) -> String {
        lower.hasPrefix("group.") ? String(lower.dropFirst("group.".count)) : lower
    }

    static func vendor(of id: String) -> String {
        id.split(separator: ".").prefix(2).joined(separator: ".")
    }

    static func days(since date: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(date) / 86_400))
    }
}
