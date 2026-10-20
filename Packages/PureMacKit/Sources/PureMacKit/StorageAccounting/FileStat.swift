import Darwin
import Foundation

/// BSD file flags relevant to safety decisions (from `<sys/stat.h>`).
public enum BSDFileFlags {
    public static let userImmutable: UInt32 = 0x0000_0002 // UF_IMMUTABLE
    public static let userAppend: UInt32 = 0x0000_0004 // UF_APPEND
    public static let systemImmutable: UInt32 = 0x0002_0000 // SF_IMMUTABLE
    public static let systemAppend: UInt32 = 0x0004_0000 // SF_APPEND
    /// SF_RESTRICTED — protected by System Integrity Protection.
    public static let restricted: UInt32 = 0x0008_0000
    /// SF_DATALESS — contents are not present locally (e.g. evicted iCloud file).
    public static let dataless: UInt32 = 0x4000_0000
}

/// `lstat(2)` metadata. Never follows symbolic links and never reads file contents.
public struct FileStat: Sendable, Hashable {
    public var identity: FileIdentity
    public var logicalSize: Int64
    public var allocatedSize: Int64
    public var linkCount: Int
    public var modified: Date
    public var created: Date
    public var mode: UInt16
    public var flags: UInt32

    public init(_ st: stat) {
        let type: FileObjectType
        switch st.st_mode & S_IFMT {
        case S_IFREG: type = .regular
        case S_IFDIR: type = .directory
        case S_IFLNK: type = .symlink
        default: type = .other
        }
        identity = FileIdentity(device: st.st_dev, inode: UInt64(st.st_ino), type: type, ownerUID: st.st_uid)
        logicalSize = Int64(st.st_size)
        allocatedSize = Int64(st.st_blocks) * 512
        linkCount = Int(st.st_nlink)
        modified = Date(timespec: st.st_mtimespec)
        created = Date(timespec: st.st_birthtimespec)
        mode = st.st_mode
        flags = st.st_flags
    }

    public var isImmutable: Bool {
        flags & (BSDFileFlags.userImmutable | BSDFileFlags.systemImmutable | BSDFileFlags.userAppend | BSDFileFlags.systemAppend) != 0
    }

    public var isSIPRestricted: Bool { flags & BSDFileFlags.restricted != 0 }
    public var isDataless: Bool { flags & BSDFileFlags.dataless != 0 }

    /// `lstat` the path. Returns the POSIX error code on failure.
    public static func lstat(_ path: String) -> Result<FileStat, POSIXError> {
        var st = stat()
        let rc = path.withCString { Darwin.lstat($0, &st) }
        if rc != 0 {
            return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
        }
        return .success(FileStat(st))
    }
}

extension Date {
    init(timespec ts: timespec) {
        self.init(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000)
    }
}

/// Tracks hard-linked inodes so that one underlying file's allocation is counted once.
///
/// Only files with `st_nlink > 1` are remembered, which keeps memory bounded on typical systems.
/// APFS clones share blocks without sharing an inode and cannot be detected this way; PureMac
/// does not claim to know unique physical ownership of cloned files.
public struct HardLinkLedger: Sendable {
    private struct Key: Hashable { let device: Int32; let inode: UInt64 }
    private var seen = Set<Key>()
    public private(set) var duplicateCount: Int64 = 0

    public init() {}

    /// Returns `true` the first time an inode is seen (its bytes should be counted).
    public mutating func shouldCount(device: Int32, inode: UInt64, linkCount: Int) -> Bool {
        guard linkCount > 1 else { return true }
        let inserted = seen.insert(Key(device: device, inode: inode)).inserted
        if !inserted { duplicateCount += 1 }
        return inserted
    }
}
