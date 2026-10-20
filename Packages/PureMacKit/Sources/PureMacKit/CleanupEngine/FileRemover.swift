import Darwin
import Foundation

/// Moves one filesystem item to a recoverable location. Implementations must *rename* the item
/// (never copy-and-delete, never recurse), so a symlink is moved as a link and never followed.
public protocol FileRemover: Sendable {
    /// Moves the item and returns where it ended up.
    func moveToTrash(_ path: String) throws -> String
}

/// The real implementation: `FileManager.trashItem(at:resultingItemURL:)` — the same mechanism
/// Finder uses; the item can be put back until the Trash is emptied.
public struct SystemTrashRemover: FileRemover {
    public init() {}

    public func moveToTrash(_ path: String) throws -> String {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        guard let resulting else { throw CocoaError(.fileWriteUnknown) }
        return (resulting as URL).path
    }
}

/// Test/fixture remover: atomically renames into a private folder. Used by automated tests so that
/// nothing ever lands in the developer's real Trash.
public struct FolderTrashRemover: FileRemover {
    public let trashDirectory: String

    public init(trashDirectory: String) {
        self.trashDirectory = trashDirectory
    }

    public func moveToTrash(_ path: String) throws -> String {
        try FileManager.default.createDirectory(atPath: trashDirectory, withIntermediateDirectories: true)
        let name = (path as NSString).lastPathComponent
        var destination = trashDirectory + "/" + name
        var counter = 1
        while case .success = FileStat.lstat(destination) {
            destination = trashDirectory + "/\(name) \(counter)"
            counter += 1
        }
        guard rename(path, destination) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return destination
    }
}

/// A remover that fails for chosen paths (tests of partial failure).
public struct FailingRemover: FileRemover {
    public let base: any FileRemover
    public let failingPaths: Set<String>

    public init(base: any FileRemover, failingPaths: Set<String>) {
        self.base = base
        self.failingPaths = failingPaths
    }

    public func moveToTrash(_ path: String) throws -> String {
        if failingPaths.contains(path) { throw CocoaError(.fileWriteNoPermission) }
        return try base.moveToTrash(path)
    }
}
