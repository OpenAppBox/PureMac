import Darwin
import Foundation

/// Per-item checks run immediately before an item is moved. Any failure skips the item.
public struct Preflight: Sendable {
    public var policy: SafetyPolicy

    public init(policy: SafetyPolicy) {
        self.policy = policy
    }

    public enum Verdict: Sendable, Hashable {
        case proceed
        case skip(String)
    }

    public func check(_ item: CleanupCandidate, runningIdentifiers: Set<String>, runningPaths: Set<String>) -> Verdict {
        // 1. Scope: the same allow-list as planning, re-evaluated now (parents re-resolved).
        let roots = item.scopeRoot.map { [$0] } ?? []
        if case .denied(let reason) = policy.evaluate(item.path, intent: item.source.safetyIntent, allowedRoots: roots) {
            return .skip(reason)
        }
        // 2. Identity: the path must still name the exact object that was reviewed.
        let current: FileStat
        switch FileStat.lstat(item.path) {
        case .failure(let error):
            return .skip(error.code == .ENOENT ? String(localized: "It no longer exists.", bundle: .module)
                         : String(localized: "It can no longer be read (\(String(cString: strerror(error.code.rawValue)))).", bundle: .module))
        case .success(let st):
            current = st
        }
        guard current.identity.isSameObject(as: item.identity) else {
            return .skip(String(localized: "It changed since you reviewed it (it was replaced or swapped). Review again.", bundle: .module))
        }
        if let expected = item.expectedContent, !expected.matches(current) {
            return .skip(String(localized: "It was modified since the duplicate search, so it may no longer be a copy. Search again.", bundle: .module))
        }
        if !item.requiredCopies.isEmpty, !item.requiredCopies.contains(where: \.isUnchanged) {
            return .skip(String(localized: "The copy that would be kept is gone or changed since the duplicate search. Search again.", bundle: .module))
        }
        // 3. Ownership and flags.
        let intent = item.source.safetyIntent
        if intent != .appBundleRemoval, intent != .userSelected, current.identity.ownerUID != getuid() {
            return .skip(String(localized: "It belongs to another user or the system; removing it needs an administrator.", bundle: .module))
        }
        if current.isSIPRestricted { return .skip(String(localized: "macOS System Integrity Protection protects it.", bundle: .module)) }
        if current.isImmutable { return .skip(String(localized: "It is locked (immutable). Unlock it in Finder’s Get Info first.", bundle: .module)) }
        let parent = (item.path as NSString).deletingLastPathComponent
        if access(parent, W_OK) != 0 {
            return .skip(String(localized: "PureMac has no permission to change the folder that contains it.", bundle: .module))
        }
        // 4. Activity: the owning app must not be running.
        if item.requiresAppClosed || intent == .appBundleRemoval || intent == .appDataRemoval {
            if let id = item.relatedBundleIdentifier?.lowercased(), runningIdentifiers.contains(id) {
                return .skip(String(localized: "\(item.relatedAppName ?? id) is running. Quit it and try again.", bundle: .module))
            }
            if let appPath = item.relatedAppPath, runningPaths.contains(appPath) {
                return .skip(String(localized: "\(item.relatedAppName ?? String(localized: "The app", bundle: .module)) is running. Quit it and try again.", bundle: .module))
            }
        }
        return .proceed
    }
}
