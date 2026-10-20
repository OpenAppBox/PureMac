import Foundation

/// Converts reviewed selections into immutable plans. Planning is pure and read-only (it only
/// `lstat`s items to capture their identity).
public enum CleanupPlanner {
    public enum UninstallMode: String, Sendable, CaseIterable {
        /// Remove the app and regenerable data (caches, logs, window state); keep settings and documents.
        case keepPersonalData
        /// Also remove the app's settings, containers and support data that are confirmed or likely.
        case complete
    }

    /// Builds the uninstall candidates for an app. Every association becomes a reviewable row; the
    /// mode decides which rows start selected. Shared, protected and administrator-only items are
    /// listed but blocked.
    public static func uninstallCandidates(app: InstalledApp, associations: [AppAssociation], mode: UninstallMode) -> [CleanupCandidate] {
        associations.compactMap { association in
            guard let identity = association.identity else { return nil }
            var blocked: String?
            switch association.confidence {
            case .shared: blocked = String(localized: "Shared with other apps — kept.", bundle: .module)
            case .protected: blocked = association.warning ?? String(localized: "Protected — kept.", bundle: .module)
            default: break
            }
            if association.requiresAdministrator, association.kind != .appBundle {
                blocked = String(localized: "Requires administrator rights — PureMac does not remove system-wide items. Shown for your information.", bundle: .module)
            }
            if app.isProtected { blocked = app.protectionReason ?? String(localized: "Protected by macOS.", bundle: .module) }

            let strongEvidence = association.confidence == .confirmed || association.confidence == .likely
            let preselect: Bool
            switch mode {
            case .keepPersonalData:
                preselect = strongEvidence && !association.kind.holdsPersonalData && association.warning == nil
            case .complete:
                preselect = strongEvidence && association.kind != .groupContainer && association.warning == nil
            }
            let risk: RiskLevel = blocked != nil ? .protected : (association.kind.holdsPersonalData || association.confidence == .ambiguous ? .review : .low)
            let reason = association.evidence.first(where: \.supportsRemoval)?.detail ?? association.evidence.first?.detail ?? association.kind.displayName
            return CleanupCandidate(
                path: association.path, title: association.kind.displayName, reason: reason, category: .appUninstall,
                risk: risk, source: .uninstall(appPath: app.path, kind: association.kind),
                logicalSize: association.logicalSize ?? 0, allocatedSize: association.allocatedSize ?? 0, itemCount: 1,
                modified: association.modified, identity: identity, relatedBundleIdentifier: app.bundleIdentifier,
                relatedAppName: app.name, requiresAppClosed: true,
                regenerationImpact: association.kind.holdsPersonalData ? String(localized: "Settings or data stored here will be lost if you empty the Trash.", bundle: .module) : nil,
                evidence: association.evidence, isPreselected: preselect && blocked == nil, blockedReason: blocked,
                relatedAppPath: app.path, warning: association.warning)
        }
    }

    public static func orphanCandidates(_ orphans: [OrphanCandidate]) -> [CleanupCandidate] {
        orphans.compactMap { orphan in
            guard let identity = orphan.identity else { return nil }
            return CleanupCandidate(
                path: orphan.path, title: orphan.kind.displayName,
                reason: String(localized: "Probable remnant of \(orphan.inferredBundleIdentifier), which is not installed.", bundle: .module),
                category: .appRemnant, risk: .review, source: .orphan(bundleIdentifier: orphan.inferredBundleIdentifier),
                logicalSize: orphan.logicalSize ?? 0, allocatedSize: orphan.allocatedSize ?? 0, itemCount: 1,
                modified: orphan.modified, identity: identity, relatedBundleIdentifier: orphan.inferredBundleIdentifier,
                requiresAppClosed: true, regenerationImpact: String(localized: "If the app is reinstalled later, its previous settings and data will be gone.", bundle: .module),
                evidence: orphan.evidence, isPreselected: false)
        }
    }

    /// Candidates for files the user picked by hand (Storage Explorer). Never preselected by any rule.
    public static func userSelectionCandidates(paths: [String], policy: SafetyPolicy, sizes: [String: SizeSummary]) -> (candidates: [CleanupCandidate], rejected: [(String, String)]) {
        var candidates: [CleanupCandidate] = []
        var rejected: [(String, String)] = []
        for path in paths {
            if let reason = policy.evaluate(path, intent: .userSelected).reason {
                rejected.append((path, reason))
                continue
            }
            guard case .success(let st) = FileStat.lstat(path) else {
                rejected.append((path, String(localized: "It no longer exists.", bundle: .module)))
                continue
            }
            let size = sizes[path] ?? SizeSummary()
            candidates.append(CleanupCandidate(
                path: path, title: (path as NSString).lastPathComponent, reason: String(localized: "You selected this item.", bundle: .module), category: .userSelection,
                risk: .review, source: .userSelection, logicalSize: size.logicalSize, allocatedSize: size.allocatedSize,
                itemCount: max(1, size.fileCount), modified: st.modified, identity: st.identity, isPreselected: true))
        }
        return (candidates, rejected)
    }

    public static func plan(mode: CleanupMode, title: String, selected: [CleanupCandidate]) -> CleanupPlan {
        // Never plan blocked items, and never plan an item twice or an item inside another planned item.
        let allowed = selected.filter { $0.blockedReason == nil }
        return CleanupPlan(mode: mode, title: title, items: RuleEvaluator.deduplicate(allowed))
    }
}
