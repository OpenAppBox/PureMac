import Foundation

/// Risk classification for a cleanup candidate.
public enum RiskLevel: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    /// Narrowly scoped, regenerable data. May be preselected; still requires confirmation.
    case low
    /// Possibly valuable. Never preselected; the user must opt in item by item.
    case review
    /// Never removable by PureMac.
    case protected

    public var displayName: String {
        switch self {
        case .low: String(localized: "Recommended", bundle: .module)
        case .review: String(localized: "Review required", bundle: .module)
        case .protected: String(localized: "Protected", bundle: .module)
        }
    }

    private var rank: Int {
        switch self {
        case .low: 0
        case .review: 1
        case .protected: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

public enum CleanupCategory: String, Codable, Sendable, Hashable, CaseIterable {
    case appCache
    case browserCache
    case developerCache
    case packageManagerCache
    case logs
    case crashReports
    case installers
    case appRemnant
    case appUninstall
    case userSelection
    case duplicate

    public var displayName: String {
        switch self {
        case .appCache: String(localized: "Application Caches", bundle: .module)
        case .browserCache: String(localized: "Browser Caches", bundle: .module)
        case .developerCache: String(localized: "Developer Build Data", bundle: .module)
        case .packageManagerCache: String(localized: "Package Manager Caches", bundle: .module)
        case .logs: String(localized: "Logs", bundle: .module)
        case .crashReports: String(localized: "Crash & Diagnostic Reports", bundle: .module)
        case .installers: String(localized: "Downloaded Installers", bundle: .module)
        case .appRemnant: String(localized: "Orphaned App Remnants", bundle: .module)
        case .appUninstall: String(localized: "Application Removal", bundle: .module)
        case .userSelection: String(localized: "Selected Files", bundle: .module)
        case .duplicate: String(localized: "Duplicate Copies", bundle: .module)
        }
    }

    public var symbolName: String {
        switch self {
        case .appCache: "shippingbox"
        case .browserCache: "globe"
        case .developerCache: "hammer"
        case .packageManagerCache: "cube.box"
        case .logs: "doc.text"
        case .crashReports: "exclamationmark.bubble"
        case .installers: "arrow.down.circle"
        case .appRemnant: "puzzlepiece.extension"
        case .appUninstall: "app.badge"
        case .userSelection: "hand.point.up.left"
        case .duplicate: "doc.on.doc"
        }
    }
}

/// Where a candidate came from. The source determines which safety scope applies at execution.
public enum CandidateSource: Codable, Sendable, Hashable {
    case rule(id: String)
    case orphan(bundleIdentifier: String)
    case uninstall(appPath: String, kind: AssociationKind)
    case userSelection
    case duplicate(groupID: String)

    public var safetyIntent: SafetyIntent {
        switch self {
        case .rule: .ruleCleanup
        case .orphan: .orphanRemoval
        case .uninstall(_, let kind): kind == .appBundle ? .appBundleRemoval : .appDataRemoval
        case .userSelection, .duplicate: .userSelected
        }
    }
}

/// The purpose of a removal, which selects the allow-list scope checked by `SafetyPolicy`.
public enum SafetyIntent: String, Codable, Sendable, Hashable {
    /// Automatic rule-based candidate. Restricted to the rule's approved roots inside `~/Library` (and a few tool caches).
    case ruleCleanup
    /// Orphaned remnant. Restricted to the user Library's app-data locations.
    case orphanRemoval
    /// Removing an `.app` bundle. Restricted to Applications folders.
    case appBundleRemoval
    /// Removing an app's associated data. Restricted to the user Library.
    case appDataRemoval
    /// A file the user explicitly picked (Storage Explorer, Duplicates). Allowed in the user's
    /// own space, still never system locations or critical folders themselves.
    case userSelected
}

/// A file as it was when it was reviewed. Identity alone does not show that the *content* is
/// unchanged — an app that saves in place keeps the inode — so size and modification time are
/// compared too.
public struct FileSnapshot: Sendable, Hashable {
    public var path: String
    public var identity: FileIdentity
    public var logicalSize: Int64
    public var modified: Date

    public init(path: String, identity: FileIdentity, logicalSize: Int64, modified: Date) {
        self.path = path
        self.identity = identity
        self.logicalSize = logicalSize
        self.modified = modified
    }

    /// Whether `path` still holds this exact object with the same size and modification time.
    public var isUnchanged: Bool {
        guard case .success(let st) = FileStat.lstat(path) else { return false }
        return matches(st)
    }

    public func matches(_ st: FileStat) -> Bool {
        st.identity.isSameObject(as: identity) && st.logicalSize == logicalSize && st.modified == modified
    }
}

public struct CleanupCandidate: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public var path: String
    public var title: String
    public var reason: String
    public var category: CleanupCategory
    public var risk: RiskLevel
    public var source: CandidateSource
    public var logicalSize: Int64
    public var allocatedSize: Int64
    public var itemCount: Int64
    public var modified: Date?
    public var identity: FileIdentity
    public var relatedBundleIdentifier: String?
    public var relatedAppName: String?
    public var requiresAppClosed: Bool
    public var regenerationImpact: String?
    public var evidence: [Evidence]
    /// Low-risk items are proposed as selected; the user still reviews and confirms.
    public var isPreselected: Bool
    /// When set the candidate cannot currently be selected (e.g. the owning app is running).
    public var blockedReason: String?
    /// For rule candidates: the approved base folder the item must stay strictly inside.
    public var scopeRoot: String?
    /// Path of the app bundle whose activity blocks removal (uninstall), if any.
    public var relatedAppPath: String?
    /// Extra caution shown in the review (critical data, shared data).
    public var warning: String?
    /// When set, the item is removed only if its content is still exactly as reviewed (duplicates:
    /// a copy edited since the search is no longer a duplicate).
    public var expectedContent: FileSnapshot?
    /// When non-empty, at least one of these must still be unchanged (duplicates: the copy that is
    /// kept), or the item is not removed.
    public var requiredCopies: [FileSnapshot] = []

    public init(path: String, title: String, reason: String, category: CleanupCategory, risk: RiskLevel,
                source: CandidateSource, logicalSize: Int64, allocatedSize: Int64, itemCount: Int64,
                modified: Date?, identity: FileIdentity, relatedBundleIdentifier: String? = nil,
                relatedAppName: String? = nil, requiresAppClosed: Bool = false,
                regenerationImpact: String? = nil, evidence: [Evidence] = [], isPreselected: Bool = false,
                blockedReason: String? = nil, scopeRoot: String? = nil, relatedAppPath: String? = nil, warning: String? = nil) {
        self.scopeRoot = scopeRoot
        self.relatedAppPath = relatedAppPath
        self.warning = warning
        self.path = path
        self.title = title
        self.reason = reason
        self.category = category
        self.risk = risk
        self.source = source
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.itemCount = itemCount
        self.modified = modified
        self.identity = identity
        self.relatedBundleIdentifier = relatedBundleIdentifier
        self.relatedAppName = relatedAppName
        self.requiresAppClosed = requiresAppClosed
        self.regenerationImpact = regenerationImpact
        self.evidence = evidence
        self.isPreselected = isPreselected
        self.blockedReason = blockedReason
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { (path as NSString).lastPathComponent }
}

public enum CleanupMode: String, Codable, Sendable, Hashable {
    case smartClean
    case uninstallKeepData
    case uninstallComplete
    case orphanRemoval
    case userFiles
    case duplicates
    case restore
    /// Regenerable data (caches, logs, window state) of an installed app; the app stays.
    case appData

    public var displayName: String {
        switch self {
        case .appData: String(localized: "Clear app caches and logs", bundle: .module)
        case .smartClean: String(localized: "Smart Clean", bundle: .module)
        case .uninstallKeepData: String(localized: "Uninstall (keep personal data)", bundle: .module)
        case .uninstallComplete: String(localized: "Complete removal", bundle: .module)
        case .orphanRemoval: String(localized: "Remove orphaned remnants", bundle: .module)
        case .userFiles: String(localized: "Move selected files to Trash", bundle: .module)
        case .duplicates: String(localized: "Remove duplicate copies", bundle: .module)
        case .restore: String(localized: "Restore from Trash", bundle: .module)
        }
    }
}

/// A reviewed, immutable list of items to move to Trash. Creating a plan never touches the filesystem.
public struct CleanupPlan: Identifiable, Sendable, Hashable {
    public var id: UUID
    public var createdAt: Date
    public var mode: CleanupMode
    public var items: [CleanupCandidate]
    /// Free space on the affected volumes at planning time (for honest before/after reporting).
    public var title: String

    public init(id: UUID = UUID(), createdAt: Date = Date(), mode: CleanupMode, title: String, items: [CleanupCandidate]) {
        self.id = id
        self.createdAt = createdAt
        self.mode = mode
        self.title = title
        self.items = items
    }

    public var identifiedLogicalBytes: Int64 { items.reduce(0) { $0 + $1.logicalSize } }
    public var identifiedAllocatedBytes: Int64 { items.reduce(0) { $0 + $1.allocatedSize } }

    /// A copyable, human-readable dry-run description. Paths are included because the user asked
    /// for this plan; it is never written to logs automatically.
    public func dryRunReport(formatter: (Int64) -> String) -> String {
        var lines: [String] = []
        lines.append("PureMac dry-run plan — \(title)")
        lines.append("Created: \(ISO8601DateFormatter().string(from: createdAt))")
        lines.append("Mode: \(mode.displayName)")
        lines.append("Items: \(items.count)   Identified size: \(formatter(identifiedAllocatedBytes)) allocated / \(formatter(identifiedLogicalBytes)) logical")
        lines.append("Action: move to Trash (recoverable until the Trash is emptied). Nothing is permanently deleted.")
        lines.append("")
        for (index, item) in items.enumerated() {
            lines.append("\(index + 1). [\(item.risk.displayName)] \(item.path)")
            lines.append("    \(formatter(item.allocatedSize)) — \(item.reason)")
            if let impact = item.regenerationImpact { lines.append("    Impact: \(impact)") }
        }
        lines.append("")
        lines.append("Note: moving items to Trash does not free disk space until the Trash is emptied. APFS clones, hard links and snapshots can make the actual change smaller than the identified size.")
        return lines.joined(separator: "\n")
    }
}

public enum CleanupItemStatus: String, Codable, Sendable, Hashable {
    case pending
    case movedToTrash
    case skipped
    case failed
    case restored
}

public struct CleanupItemOutcome: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public var path: String
    public var status: CleanupItemStatus
    public var trashPath: String?
    public var allocatedSize: Int64
    public var logicalSize: Int64
    public var message: String?

    public init(path: String, status: CleanupItemStatus, trashPath: String? = nil, allocatedSize: Int64,
                logicalSize: Int64, message: String? = nil) {
        self.path = path
        self.status = status
        self.trashPath = trashPath
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
        self.message = message
    }
}

/// Outcome of executing a plan, with the different byte figures kept strictly apart.
public struct CleanupResult: Sendable, Hashable {
    public var planID: UUID
    public var operationID: Int64?
    public var mode: CleanupMode
    public var startedAt: Date
    public var finishedAt: Date
    public var outcomes: [CleanupItemOutcome]
    public var wasCancelled: Bool
    /// Volume free space (bytes) measured right before and after the operation.
    public var freeSpaceBefore: Int64?
    public var freeSpaceAfter: Int64?
    /// Set when PureMac could not save part of this operation's history. The outcomes are still
    /// exact; History may show fewer details. When an item's record failed, the run stopped there.
    public var journalProblem: String?

    public init(planID: UUID, operationID: Int64?, mode: CleanupMode, startedAt: Date, finishedAt: Date,
                outcomes: [CleanupItemOutcome], wasCancelled: Bool, freeSpaceBefore: Int64?, freeSpaceAfter: Int64?,
                journalProblem: String? = nil) {
        self.journalProblem = journalProblem
        self.planID = planID
        self.operationID = operationID
        self.mode = mode
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcomes = outcomes
        self.wasCancelled = wasCancelled
        self.freeSpaceBefore = freeSpaceBefore
        self.freeSpaceAfter = freeSpaceAfter
    }

    public var identifiedBytes: Int64 { outcomes.reduce(0) { $0 + $1.allocatedSize } }
    public var bytesMovedToTrash: Int64 {
        outcomes.filter { $0.status == .movedToTrash }.reduce(0) { $0 + $1.allocatedSize }
    }
    /// PureMac never permanently deletes files itself; kept explicit for honest reporting.
    public var bytesPermanentlyDeleted: Int64 { 0 }
    public var observedFreeSpaceDelta: Int64? {
        guard let before = freeSpaceBefore, let after = freeSpaceAfter else { return nil }
        return after - before
    }
    public var movedCount: Int { outcomes.filter { $0.status == .movedToTrash }.count }
    public var failedCount: Int { outcomes.filter { $0.status == .failed }.count }
    public var skippedCount: Int { outcomes.filter { $0.status == .skipped }.count }
}

/// A persisted cleanup operation (history entry).
public struct CleanupOperationRecord: Identifiable, Sendable, Hashable {
    public var id: Int64
    public var planID: UUID
    public var mode: CleanupMode
    public var title: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: String
    public var itemCount: Int
    public var movedCount: Int
    public var failedCount: Int
    public var skippedCount: Int
    public var bytesIdentified: Int64
    public var bytesMovedToTrash: Int64
    public var freeSpaceBefore: Int64?
    public var freeSpaceAfter: Int64?
    public var hasDetails: Bool

    public init(id: Int64, planID: UUID, mode: CleanupMode, title: String, startedAt: Date, finishedAt: Date?,
                status: String, itemCount: Int, movedCount: Int, failedCount: Int, skippedCount: Int,
                bytesIdentified: Int64, bytesMovedToTrash: Int64, freeSpaceBefore: Int64?, freeSpaceAfter: Int64?,
                hasDetails: Bool) {
        self.id = id
        self.planID = planID
        self.mode = mode
        self.title = title
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.itemCount = itemCount
        self.movedCount = movedCount
        self.failedCount = failedCount
        self.skippedCount = skippedCount
        self.bytesIdentified = bytesIdentified
        self.bytesMovedToTrash = bytesMovedToTrash
        self.freeSpaceBefore = freeSpaceBefore
        self.freeSpaceAfter = freeSpaceAfter
        self.hasDetails = hasDetails
    }
}

public struct CleanupItemRecord: Identifiable, Sendable, Hashable {
    public var id: Int64
    public var operationID: Int64
    public var sequence: Int
    public var originalPath: String?
    public var trashPath: String?
    public var allocatedSize: Int64
    public var status: CleanupItemStatus
    public var message: String?
    public var identity: FileIdentity?
    public var restoredAt: Date?

    public init(id: Int64, operationID: Int64, sequence: Int, originalPath: String?, trashPath: String?,
                allocatedSize: Int64, status: CleanupItemStatus, message: String?, identity: FileIdentity?,
                restoredAt: Date?) {
        self.id = id
        self.operationID = operationID
        self.sequence = sequence
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.allocatedSize = allocatedSize
        self.status = status
        self.message = message
        self.identity = identity
        self.restoredAt = restoredAt
    }
}
