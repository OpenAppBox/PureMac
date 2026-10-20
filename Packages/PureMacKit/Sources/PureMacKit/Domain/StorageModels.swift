import Foundation

// MARK: - File identity

/// The kind of filesystem object, as reported by `lstat` (symlinks are never followed).
public enum FileObjectType: Int, Codable, Sendable, Hashable {
    case regular = 0
    case directory = 1
    case symlink = 2
    case other = 3
}

/// Stable identity of a filesystem object at a point in time.
///
/// Used to detect that a path still refers to the *same* object between planning and execution
/// (protects against path substitution / TOCTOU swaps).
public struct FileIdentity: Codable, Sendable, Hashable {
    public var device: Int32
    public var inode: UInt64
    public var type: FileObjectType
    public var ownerUID: UInt32

    public init(device: Int32, inode: UInt64, type: FileObjectType, ownerUID: UInt32) {
        self.device = device
        self.inode = inode
        self.type = type
        self.ownerUID = ownerUID
    }

    /// Two identities refer to the same object when device, inode and object type agree.
    public func isSameObject(as other: FileIdentity) -> Bool {
        device == other.device && inode == other.inode && type == other.type
    }
}

// MARK: - Index entries

/// Kind of a row in the scan index.
public enum EntryKind: Int, Codable, Sendable, Hashable {
    case file = 0
    case directory = 1
    case package = 2
    case symlink = 3
    case other = 4
}

/// Coarse storage category. Every scanned file is attributed to exactly one category so that
/// category totals never double-count.
public enum StorageCategory: Int, Codable, Sendable, CaseIterable, Hashable {
    case applications = 0
    case documents = 1
    case media = 2
    case developer = 3
    case caches = 4
    case backups = 5
    case archives = 6
    case systemOther = 7
    case unclassified = 8
    case cloud = 9
    case appData = 10
    case mail = 11

    public var displayName: String {
        switch self {
        case .applications: String(localized: "Applications", bundle: .module)
        case .documents: String(localized: "Documents", bundle: .module)
        case .media: String(localized: "Photos, Music & Video", bundle: .module)
        case .developer: String(localized: "Developer", bundle: .module)
        case .caches: String(localized: "Caches", bundle: .module)
        case .backups: String(localized: "Backups", bundle: .module)
        case .archives: String(localized: "Archives & Installers", bundle: .module)
        case .systemOther: String(localized: "System & Other", bundle: .module)
        case .unclassified: String(localized: "Unclassified", bundle: .module)
        case .cloud: String(localized: "Cloud Storage", bundle: .module)
        case .appData: String(localized: "App Data", bundle: .module)
        case .mail: String(localized: "Mail & Messages", bundle: .module)
        }
    }
}

/// Bit flags stored with each index entry.
public struct EntryFlags: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Another path to the same inode was already counted; allocated bytes are not counted again.
    public static let hardLinkDuplicate = EntryFlags(rawValue: 1 << 0)
    /// The directory could not be read; its totals are incomplete.
    public static let unreadable = EntryFlags(rawValue: 1 << 1)
    /// The directory was excluded by the user; it was not traversed.
    public static let excluded = EntryFlags(rawValue: 1 << 2)
    /// Some descendant could not be read; totals are a lower bound.
    public static let partial = EntryFlags(rawValue: 1 << 3)
    /// The entry is a mount point of another volume and was not traversed.
    public static let mountBoundary = EntryFlags(rawValue: 1 << 4)
    /// Logical size exceeds allocation significantly (sparse, compressed or cloud-evicted file).
    public static let sparseOrDataless = EntryFlags(rawValue: 1 << 5)
    /// Moved to the Trash after the scan: hidden, and its size is no longer counted by its folders.
    public static let movedToTrash = EntryFlags(rawValue: 1 << 6)
    /// Inside an item that was moved to the Trash after the scan (hidden).
    public static let insideMovedItem = EntryFlags(rawValue: 1 << 7)

    /// Entries no longer on disk where the scan saw them; every listing leaves them out.
    public static let hiddenMask = movedToTrash.rawValue | insideMovedItem.rawValue
}

/// One row of the persistent scan index: a directory (always) or a file above the
/// size threshold. Small files are folded into their parent's `smallFile*` aggregates.
public struct FileRecord: Identifiable, Sendable, Hashable {
    public var id: Int64
    public var sessionID: Int64
    public var parentID: Int64?
    public var depth: Int
    public var kind: EntryKind
    public var name: String
    public var path: String
    /// Sum of `st_size` (apparent / logical size).
    public var logicalSize: Int64
    /// Sum of `st_blocks * 512` (space allocated on disk), hard links counted once.
    public var allocatedSize: Int64
    public var modified: Date?
    public var created: Date?
    /// Number of regular files contained (recursive) — 1 for a file.
    public var fileCount: Int64
    public var directoryCount: Int64
    /// Files directly inside this directory that were below the indexing threshold.
    public var smallFileCount: Int64
    public var smallFileLogical: Int64
    public var smallFileAllocated: Int64
    public var device: Int32
    public var inode: UInt64
    public var flags: EntryFlags
    public var category: StorageCategory
    /// For a mixed folder (`category == .unclassified`): its largest category, which no single
    /// category dominates. `nil` for files, for folders with a clear category and for older scans.
    public var leadCategory: StorageCategory?

    /// The category a storage map colors this item by: a mixed folder takes its largest category.
    public var mapCategory: StorageCategory {
        category == .unclassified ? (leadCategory ?? .unclassified) : category
    }

    public init(id: Int64, sessionID: Int64, parentID: Int64?, depth: Int, kind: EntryKind, name: String,
                path: String, logicalSize: Int64, allocatedSize: Int64, modified: Date?, created: Date?,
                fileCount: Int64, directoryCount: Int64, smallFileCount: Int64, smallFileLogical: Int64,
                smallFileAllocated: Int64, device: Int32, inode: UInt64, flags: EntryFlags, category: StorageCategory,
                leadCategory: StorageCategory? = nil) {
        self.leadCategory = leadCategory
        self.id = id
        self.sessionID = sessionID
        self.parentID = parentID
        self.depth = depth
        self.kind = kind
        self.name = name
        self.path = path
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.modified = modified
        self.created = created
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.smallFileCount = smallFileCount
        self.smallFileLogical = smallFileLogical
        self.smallFileAllocated = smallFileAllocated
        self.device = device
        self.inode = inode
        self.flags = flags
        self.category = category
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var isContainer: Bool { kind == .directory || kind == .package }
    public var fileExtension: String { (name as NSString).pathExtension.lowercased() }
}

// MARK: - Scan sessions

public enum ScanStatus: String, Codable, Sendable, Hashable {
    case running
    case completed
    case cancelled
    case failed
    /// The app quit or crashed while the scan was running.
    case interrupted
}

/// A root directory chosen for scanning.
public struct ScanRoot: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case home
        case dataVolume
        case folder
        case externalVolume
    }

    public var path: String
    public var kind: Kind
    public var id: String { path }

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }

    public static func home(_ home: URL = PathTools.userHomeURL) -> ScanRoot {
        ScanRoot(path: home.standardizedFileURL.path, kind: .home)
    }
}

public struct CategoryTotal: Codable, Sendable, Hashable {
    public var category: StorageCategory
    public var fileCount: Int64
    public var logicalSize: Int64
    public var allocatedSize: Int64

    public init(category: StorageCategory, fileCount: Int64 = 0, logicalSize: Int64 = 0, allocatedSize: Int64 = 0) {
        self.category = category
        self.fileCount = fileCount
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
    }
}

public struct ScanSession: Identifiable, Sendable, Hashable {
    public var id: Int64
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: ScanStatus
    public var roots: [ScanRoot]
    public var excludedPaths: [String]
    public var fileCount: Int64
    public var directoryCount: Int64
    public var logicalSize: Int64
    /// Allocated bytes with hard links counted once.
    public var allocatedSize: Int64
    public var hardLinkDuplicateCount: Int64
    public var issueCount: Int64
    public var smallFileThreshold: Int64
    /// Whether the detailed per-directory index of this session is still stored.
    public var hasIndex: Bool

    public init(id: Int64, startedAt: Date, finishedAt: Date?, status: ScanStatus, roots: [ScanRoot],
                excludedPaths: [String], fileCount: Int64, directoryCount: Int64, logicalSize: Int64,
                allocatedSize: Int64, hardLinkDuplicateCount: Int64, issueCount: Int64,
                smallFileThreshold: Int64, hasIndex: Bool) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.roots = roots
        self.excludedPaths = excludedPaths
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.hardLinkDuplicateCount = hardLinkDuplicateCount
        self.issueCount = issueCount
        self.smallFileThreshold = smallFileThreshold
        self.hasIndex = hasIndex
    }

    public var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }
}

// MARK: - Issues and coverage

public enum ScanIssueKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// EPERM / EACCES — usually macOS privacy protection (TCC) or file permissions.
    case permissionDenied
    /// The item vanished between listing and inspection (normal on a live system).
    case vanished
    /// A directory cycle was detected and not followed.
    case cycle
    /// Generic I/O or metadata error.
    case ioError
    /// The path was excluded by the user.
    case excluded
    /// A different volume is mounted here and was not traversed.
    case mountBoundary
    /// The scan root itself does not exist or is not a directory.
    case missingRoot

    public var displayName: String {
        switch self {
        case .permissionDenied: String(localized: "Access denied", bundle: .module)
        case .vanished: String(localized: "Changed during scan", bundle: .module)
        case .cycle: String(localized: "Directory cycle", bundle: .module)
        case .ioError: String(localized: "Read error", bundle: .module)
        case .excluded: String(localized: "Excluded", bundle: .module)
        case .mountBoundary: String(localized: "Other volume", bundle: .module)
        case .missingRoot: String(localized: "Missing scan location", bundle: .module)
        }
    }
}

public struct ScanIssue: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(kind.rawValue):\(path)" }
    public var path: String
    public var kind: ScanIssueKind
    public var errorCode: Int32
    public var message: String

    public init(path: String, kind: ScanIssueKind, errorCode: Int32 = 0, message: String = "") {
        self.path = path
        self.kind = kind
        self.errorCode = errorCode
        self.message = message
    }

    public static func classify(errno code: Int32) -> ScanIssueKind {
        switch code {
        case EPERM, EACCES: .permissionDenied
        case ENOENT, ENOTDIR: .vanished
        case ELOOP: .cycle
        default: .ioError
        }
    }
}

/// Live progress of a running scan. Values are monotonic within one scan.
public struct ScanProgress: Sendable, Hashable {
    public var filesVisited: Int64 = 0
    public var directoriesVisited: Int64 = 0
    public var logicalBytes: Int64 = 0
    public var allocatedBytes: Int64 = 0
    public var issueCount: Int64 = 0
    public var currentRoot: String = ""
    /// Path relative to the current root of the directory being read.
    public var currentRelativePath: String = ""
    public var elapsed: TimeInterval = 0
    public var isCancelling: Bool = false
    /// Allocated bytes found so far per category (indexed by `StorageCategory.rawValue`).
    public var categoryAllocated: [Int64] = Array(repeating: 0, count: StorageCategory.allCases.count + 1)
    /// Name of the top-level folder (directly below the root) currently being read.
    public var currentTopLevel: String = ""

    public init() {}
}

// MARK: - Volumes

public struct VolumeInfo: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public var url: URL
    public var name: String
    public var totalCapacity: Int64?
    /// Free bytes as reported by `volumeAvailableCapacityKey`.
    public var availableCapacity: Int64?
    /// Free bytes including purgeable space the system can reclaim on demand.
    public var availableForImportantUsage: Int64?
    public var fileSystemType: String?
    public var isInternal: Bool
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isLocal: Bool
    public var isReadOnly: Bool
    public var isRootFileSystem: Bool
    public var deviceID: Int32?

    public init(url: URL, name: String, totalCapacity: Int64?, availableCapacity: Int64?,
                availableForImportantUsage: Int64?, fileSystemType: String?, isInternal: Bool,
                isRemovable: Bool, isEjectable: Bool, isLocal: Bool, isReadOnly: Bool,
                isRootFileSystem: Bool, deviceID: Int32?) {
        self.url = url
        self.name = name
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.availableForImportantUsage = availableForImportantUsage
        self.fileSystemType = fileSystemType
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isLocal = isLocal
        self.isReadOnly = isReadOnly
        self.isRootFileSystem = isRootFileSystem
        self.deviceID = deviceID
    }

    public var usedCapacity: Int64? {
        guard let total = totalCapacity, let free = availableCapacity else { return nil }
        return max(0, total - free)
    }

    /// Space the system reports as purgeable (free for important usage minus plain free space).
    public var purgeableEstimate: Int64? {
        guard let important = availableForImportantUsage, let free = availableCapacity else { return nil }
        return max(0, important - free)
    }
}
