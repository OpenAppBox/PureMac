import Darwin
import Foundation
@testable import PureMacKit

/// An isolated, ephemeral directory tree for tests. Every destructive test operates **only** inside
/// a fixture; nothing points at the developer's real home, Library, Applications or Trash.
final class Fixture: @unchecked Sendable {
    let root: URL
    private let fm = FileManager.default

    init(_ name: String = "fixture") throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PureMacTests-\(UUID().uuidString)", isDirectory: true)
        let resolved = PathTools.realPath(base.deletingLastPathComponent().path).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? base.deletingLastPathComponent()
        root = resolved.appendingPathComponent(base.lastPathComponent, isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        // Restore permissions so cleanup can't fail on chmod-000 fixtures.
        if let enumerator = fm.enumerator(atPath: root.deletingLastPathComponent().path) {
            for case let rel as String in enumerator {
                chmod(root.deletingLastPathComponent().appendingPathComponent(rel).path, 0o755)
            }
        }
        chmod(root.path, 0o755)
        try? fm.removeItem(at: root.deletingLastPathComponent())
    }

    var path: String { root.path }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }
    func path(_ relative: String) -> String { url(relative).path }

    @discardableResult
    func dir(_ relative: String) throws -> URL {
        let u = url(relative)
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Writes a file with `size` bytes of real (non-sparse) data.
    @discardableResult
    func file(_ relative: String, size: Int = 16, byte: UInt8 = 0x41) throws -> URL {
        let u = url(relative)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: byte, count: size).write(to: u)
        return u
    }

    /// Writes a file with custom content.
    @discardableResult
    func file(_ relative: String, data: Data) throws -> URL {
        let u = url(relative)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
        return u
    }

    /// Creates a sparse file: large logical size, almost no allocated blocks.
    func sparseFile(_ relative: String, logicalSize: Int64) throws {
        let u = url(relative)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(u.path, O_CREAT | O_WRONLY, 0o644)
        precondition(fd >= 0)
        ftruncate(fd, off_t(logicalSize))
        close(fd)
    }

    func symlink(_ relative: String, to destination: String) throws {
        let u = url(relative)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: u.path, withDestinationPath: destination)
    }

    func hardLink(_ relative: String, to existing: String) throws {
        let u = url(relative)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.linkItem(atPath: path(existing), toPath: u.path)
    }

    func exists(_ relative: String) -> Bool {
        var st = stat()
        return lstat(path(relative), &st) == 0
    }

    func setModified(_ relative: String, daysAgo: Double) throws {
        let date = Date().addingTimeInterval(-daysAgo * 86_400)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: path(relative))
    }

    func identity(_ relative: String) throws -> FileIdentity {
        try FileStat.lstat(path(relative)).get().identity
    }

    /// Recursive snapshot of every path with its identity, size and mtime (for "no modification" checks).
    func snapshot() -> [String: String] {
        var out: [String: String] = [:]
        try? FTSWalker.walk(root: path) { entry in
            if let st = entry.stat {
                out[entry.path] = "\(st.identity.inode)-\(st.logicalSize)-\(st.modified.timeIntervalSince1970)-\(st.mode)"
            }
            return .proceed
        }
        return out
    }

    func databaseURL() -> URL {
        root.deletingLastPathComponent().appendingPathComponent("test-\(UUID().uuidString).sqlite")
    }
}
