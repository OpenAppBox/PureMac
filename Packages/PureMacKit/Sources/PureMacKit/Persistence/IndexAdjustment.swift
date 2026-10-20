import Foundation

/// An item moved to the Trash or put back, as a scan index should account for it.
public struct IndexChange: Sendable, Hashable {
    public var path: String
    /// Measured sizes, used only for items the index has no row of their own for (files below the
    /// small-file threshold, which the scan counts in their folder's totals).
    public var allocatedSize: Int64
    public var logicalSize: Int64

    public init(path: String, allocatedSize: Int64, logicalSize: Int64) {
        self.path = path
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
    }
}

public struct IndexAdjustmentSummary: Sendable, Equatable {
    /// Items the index accounted for (others were outside the scan, or already accounted for).
    public var adjustedItems = 0
    /// Allocated bytes taken off (removal) or added back (restore).
    public var allocatedBytes: Int64 = 0
}

/// Keeps a scan index truthful between scans.
///
/// When items move to the Trash, each one (and everything inside it) is flagged and left out of
/// every listing, and its scan-time size is subtracted from all its folders, the category totals,
/// the top-level summaries and the session total — so folder sizes are right without a rescan.
/// Put Back reverses exactly that. Sizes stay *scan-time* sizes: an item is taken off with the size
/// the index counted for it, never a newer measurement, so totals never drift from what was counted.
extension LocalStore {
    public func applyRemoval(sessionID: Int64, changes: [IndexChange]) throws -> IndexAdjustmentSummary {
        try adjust(sessionID: sessionID, changes: changes, sign: -1)
    }

    public func applyRestore(sessionID: Int64, changes: [IndexChange]) throws -> IndexAdjustmentSummary {
        try adjust(sessionID: sessionID, changes: changes, sign: 1)
    }

    private struct Row {
        var id: Int64
        var parentID: Int64?
        var path: String
        var kind: Int
        var logical: Int64
        var allocated: Int64
        var files: Int64
        var dirs: Int64
        var small: (count: Int64, logical: Int64, allocated: Int64)
        var flags: Int
        var category: Int
        var isContainer: Bool { kind == EntryKind.directory.rawValue || kind == EntryKind.package.rawValue }
        var isHidden: Bool { flags & EntryFlags.hiddenMask != 0 }
    }

    private struct Delta {
        var logical: Int64 = 0
        var allocated: Int64 = 0
        var files: Int64 = 0
        var dirs: Int64 = 0
    }

    private static let rowColumns = "id, parent_id, path, kind, logical, allocated, file_count, dir_count, small_count, small_logical, small_allocated, flags, category"

    private func decodeRow(_ s: SQLiteStatement) -> Row {
        Row(id: s.int64(0), parentID: s.optionalInt64(1), path: s.string(2) ?? "", kind: s.int(3), logical: s.int64(4),
            allocated: s.int64(5), files: s.int64(6), dirs: s.int64(7), small: (s.int64(8), s.int64(9), s.int64(10)),
            flags: s.int(11), category: s.int(12))
    }

    private func row(sessionID: Int64, path: String) throws -> Row? {
        let s = try db.prepare("SELECT \(Self.rowColumns) FROM entry WHERE session_id = ? AND path = ? LIMIT 1")
        try s.bind(.int(sessionID), .text(path))
        return try s.step() ? decodeRow(s) : nil
    }

    private func row(id: Int64) throws -> Row? {
        let s = try db.prepare("SELECT \(Self.rowColumns) FROM entry WHERE id = ?")
        try s.bind(.int(id))
        return try s.step() ? decodeRow(s) : nil
    }

    /// Parent first, up to the scan root.
    private func ancestors(of row: Row) throws -> [Row] {
        var chain: [Row] = []
        var next = row.parentID
        while let id = next, chain.count < 4096, let parent = try self.row(id: id) {
            chain.append(parent)
            next = parent.parentID
        }
        return chain
    }

    /// `path > "<p>/"` and `path < "<p>0"` select everything inside `p` using the path index
    /// ('0' is the character after '/').
    private static func subtreeBounds(_ path: String) -> (lower: String, upper: String) {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return (prefix, String(prefix.dropLast()) + "0")
    }

    private func adjust(sessionID: Int64, changes: [IndexChange], sign: Int64) throws -> IndexAdjustmentSummary {
        guard let session = try session(id: sessionID), session.hasIndex else { return IndexAdjustmentSummary() }
        let threshold = session.smallFileThreshold
        return try db.transaction {
            var summary = IndexAdjustmentSummary()
            for change in changes {
                let path = PathTools.normalize(change.path) ?? change.path
                if let row = try row(sessionID: sessionID, path: path) {
                    if try adjustIndexed(row, sessionID: sessionID, sign: sign) {
                        summary.adjustedItems += 1
                        summary.allocatedBytes += row.allocated
                    }
                } else if try adjustSmallFile(path: path, change: change, sessionID: sessionID, threshold: threshold, sign: sign) {
                    summary.adjustedItems += 1
                    summary.allocatedBytes += change.allocatedSize
                }
            }
            return summary
        }
    }

    /// An item with its own index row (a folder, or a file above the small-file threshold).
    private func adjustIndexed(_ row: Row, sessionID: Int64, sign: Int64) throws -> Bool {
        let removed = EntryFlags.movedToTrash.rawValue, inside = EntryFlags.insideMovedItem.rawValue
        let (lower, upper) = Self.subtreeBounds(row.path)
        if sign < 0 {
            // Already taken off (by itself or as part of a folder that went to the Trash).
            guard !row.isHidden else { return false }
            let categories = try categoryBreakdown(of: row, sessionID: sessionID)
            try db.prepare("UPDATE entry SET flags = flags | ? WHERE id = ?").run(.int(Int64(removed)), .int(row.id))
            try db.prepare("UPDATE entry SET flags = flags | ? WHERE session_id = ? AND path > ? AND path < ?")
                .run(.int(Int64(inside)), .int(sessionID), .text(lower), .text(upper))
            try apply(Delta(logical: -row.logical, allocated: -row.allocated, files: -row.files, dirs: -(row.dirs + (row.isContainer ? 1 : 0))),
                      categories: categories, sign: -1, from: row, includingSelf: true, sessionID: sessionID)
        } else {
            guard row.flags & removed != 0 else { return false }
            // Items inside it that are themselves still in the Trash stay hidden.
            let nested = try db.prepare("SELECT path FROM entry WHERE session_id = ? AND path > ? AND path < ? AND (flags & ?) != 0")
            try nested.bind(.int(sessionID), .text(lower), .text(upper), .int(Int64(removed)))
            var nestedPaths: [String] = []
            while try nested.step() { if let p = nested.string(0) { nestedPaths.append(p) } }
            try db.prepare("UPDATE entry SET flags = flags & ~? WHERE id = ?").run(.int(Int64(removed)), .int(row.id))
            try db.prepare("UPDATE entry SET flags = flags & ~? WHERE session_id = ? AND path > ? AND path < ?")
                .run(.int(Int64(inside)), .int(sessionID), .text(lower), .text(upper))
            for p in nestedPaths {
                let (l, u) = Self.subtreeBounds(p)
                try db.prepare("UPDATE entry SET flags = flags | ? WHERE session_id = ? AND path > ? AND path < ?")
                    .run(.int(Int64(inside)), .int(sessionID), .text(l), .text(u))
            }
            var restored = row
            restored.flags &= ~removed
            let categories = try categoryBreakdown(of: restored, sessionID: sessionID)
            try apply(Delta(logical: row.logical, allocated: row.allocated, files: row.files, dirs: row.dirs + (row.isContainer ? 1 : 0)),
                      categories: categories, sign: 1, from: row, includingSelf: true, sessionID: sessionID)
        }
        return true
    }

    /// A file the scan counted only in its folder's small-file totals. It is accounted for only when
    /// it is small enough that the scan would have aggregated it — never a large file created after
    /// the scan, which the index never counted.
    private func adjustSmallFile(path: String, change: IndexChange, sessionID: Int64, threshold: Int64, sign: Int64) throws -> Bool {
        guard change.allocatedSize >= 0, change.allocatedSize < threshold, change.logicalSize < threshold * 4 else { return false }
        var parentPath = (path as NSString).deletingLastPathComponent
        var folder: Row?
        for _ in 0..<64 where folder == nil && parentPath.count > 1 {
            folder = try row(sessionID: sessionID, path: parentPath)
            if folder == nil { parentPath = (parentPath as NSString).deletingLastPathComponent }
        }
        // Only its direct folder holds small-file totals; a deeper unknown path was never scanned.
        guard let folder, folder.path == (path as NSString).deletingLastPathComponent, folder.isContainer, !folder.isHidden else { return false }
        if sign < 0 { guard folder.small.count > 0 else { return false } }
        try db.prepare("""
            UPDATE entry SET small_count = MAX(0, small_count + ?), small_logical = MAX(0, small_logical + ?),
                   small_allocated = MAX(0, small_allocated + ?) WHERE id = ?
            """).run(.int(sign), .int(sign * change.logicalSize), .int(sign * change.allocatedSize), .int(folder.id))
        let delta = Delta(logical: sign * change.logicalSize, allocated: sign * change.allocatedSize, files: sign, dirs: 0)
        try apply(delta, categories: [folder.category: Delta(logical: change.logicalSize, allocated: change.allocatedSize, files: 1)],
                  sign: sign, from: folder, includingSelf: true, sessionID: sessionID, folderIsTarget: true)
        return true
    }

    /// Bytes per category inside `row` that the index currently counts. Indexed files count under
    /// their own category; files aggregated as small files count under their folder's category.
    private func categoryBreakdown(of row: Row, sessionID: Int64) throws -> [Int: Delta] {
        var out: [Int: Delta] = [:]
        if !row.isContainer {
            out[row.category] = Delta(logical: row.logical, allocated: row.allocated, files: 1)
            return out
        }
        let (lower, upper) = Self.subtreeBounds(row.path)
        let hidden = Int64(EntryFlags.hiddenMask)
        let files = try db.prepare("""
            SELECT category, COUNT(*), SUM(logical), SUM(allocated) FROM entry
            WHERE session_id = ? AND path > ? AND path < ? AND kind NOT IN (1, 2) AND (flags & ?) = 0 GROUP BY category
            """)
        try files.bind(.int(sessionID), .text(lower), .text(upper), .int(hidden))
        while try files.step() {
            out[files.int(0), default: Delta()].files += files.int64(1)
            out[files.int(0), default: Delta()].logical += files.int64(2)
            out[files.int(0), default: Delta()].allocated += files.int64(3)
        }
        // The folder itself plus every visible folder inside it carry small-file totals.
        let small = try db.prepare("""
            SELECT category, SUM(small_count), SUM(small_logical), SUM(small_allocated) FROM entry
            WHERE session_id = ? AND ((path > ? AND path < ? AND (flags & ?) = 0) OR id = ?) AND kind IN (1, 2) GROUP BY category
            """)
        try small.bind(.int(sessionID), .text(lower), .text(upper), .int(hidden), .int(row.id))
        while try small.step() {
            out[small.int(0), default: Delta()].files += small.int64(1)
            out[small.int(0), default: Delta()].logical += small.int64(2)
            out[small.int(0), default: Delta()].allocated += small.int64(3)
        }
        return out
    }

    /// Applies `delta` (already signed) to the folders above `row`, and to `row` itself when it is the
    /// folder that held a small file. Top-level summaries include the item's own row so a removed
    /// top-level folder reads 0. `categories` are unsigned amounts; `sign` gives the direction.
    private func apply(_ delta: Delta, categories: [Int: Delta], sign: Int64, from row: Row, includingSelf: Bool,
                       sessionID: Int64, folderIsTarget: Bool = false) throws {
        let ancestors = try ancestors(of: row)
        let folders = folderIsTarget ? [row] + ancestors : ancestors
        let updateEntry = try db.prepare("""
            UPDATE entry SET logical = MAX(0, logical + ?), allocated = MAX(0, allocated + ?),
                   file_count = MAX(0, file_count + ?), dir_count = MAX(0, dir_count + ?) WHERE id = ?
            """)
        for folder in folders {
            try updateEntry.run(.int(delta.logical), .int(delta.allocated), .int(delta.files), .int(delta.dirs), .int(folder.id))
        }
        let updateSummary = try db.prepare("""
            UPDATE root_summary SET logical = MAX(0, logical + ?), allocated = MAX(0, allocated + ?),
                   file_count = MAX(0, file_count + ?) WHERE session_id = ? AND path = ?
            """)
        for path in Set((includingSelf ? [row.path] : []) + ancestors.map(\.path)) {
            try updateSummary.run(.int(delta.logical), .int(delta.allocated), .int(delta.files), .int(sessionID), .text(path))
        }
        let updateCategory = try db.prepare("""
            UPDATE category_total SET file_count = MAX(0, file_count + ?), logical = MAX(0, logical + ?),
                   allocated = MAX(0, allocated + ?) WHERE session_id = ? AND category = ?
            """)
        for (category, amount) in categories {
            try updateCategory.run(.int(sign * amount.files), .int(sign * amount.logical), .int(sign * amount.allocated),
                                   .int(sessionID), .int(Int64(category)))
        }
        try db.prepare("""
            UPDATE scan_session SET file_count = MAX(0, file_count + ?), dir_count = MAX(0, dir_count + ?),
                   logical_bytes = MAX(0, logical_bytes + ?), allocated_bytes = MAX(0, allocated_bytes + ?) WHERE id = ?
            """).run(.int(delta.files), .int(delta.dirs), .int(delta.logical), .int(delta.allocated), .int(sessionID))
    }
}
