import Foundation

public enum ChildSort: String, Sendable, CaseIterable {
    case allocatedDescending
    case logicalDescending
    case nameAscending
    case modifiedDescending

    var sql: String {
        switch self {
        case .allocatedDescending: "allocated DESC, name ASC"
        case .logicalDescending: "logical DESC, name ASC"
        case .nameAscending: "name COLLATE NOCASE ASC"
        case .modifiedDescending: "modified DESC, name ASC"
        }
    }
}

/// Filter for "largest files" style queries over the index.
public struct FileQuery: Sendable, Hashable {
    public var extensions: Set<String> = []
    public var categories: Set<StorageCategory> = []
    public var modifiedBefore: Date?
    public var modifiedAfter: Date?
    public var minimumAllocated: Int64 = 0
    public var pathPrefix: String?
    public var nameContains: String?
    public var limit: Int = 200

    public init() {}
}

public struct ExtensionTotal: Sendable, Hashable, Identifiable {
    public var id: String { ext }
    public var ext: String
    public var fileCount: Int64
    public var allocated: Int64
}

public struct GrowthPoint: Sendable, Hashable, Identifiable {
    public var id: String { "\(sessionID)-\(path)" }
    public var sessionID: Int64
    public var date: Date
    public var path: String
    public var allocated: Int64
}

public enum ExclusionScope: String, Sendable, Codable, CaseIterable {
    case scan
    case cleanup
}

/// Row ids of a journaled cleanup: the operation and one pending item per plan item, in plan order.
public struct CleanupJournal: Sendable, Hashable {
    public var operationID: Int64
    public var itemIDs: [Int64]
}

public struct Exclusion: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var path: String
    public var scope: ExclusionScope
    public var createdAt: Date
}

/// The app's local database: scan index queries, exclusions, and the cleanup journal.
///
/// Stored at `~/Library/Application Support/com.openappbox.PureMac/PureMac.sqlite`. Nothing in it
/// ever leaves the Mac.
public actor LocalStore {
    public nonisolated let url: URL
    public nonisolated let recoveredCorruptFile: String?
    /// Internal so the index-adjustment extension (IndexAdjustment.swift) can share the connection.
    let db: SQLiteConnection

    public init(url: URL) throws {
        self.url = url
        let (connection, recovered) = try DatabaseSchema.openOrRecover(at: url)
        db = connection
        recoveredCorruptFile = recovered
    }

    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("com.openappbox.PureMac", isDirectory: true).appendingPathComponent("PureMac.sqlite")
    }

    // MARK: Sessions

    static let sessionColumns = "id, started_at, finished_at, status, roots, excluded, file_count, dir_count, logical_bytes, allocated_bytes, hardlink_dups, issue_count, small_threshold, has_index"

    private func decodeSession(_ s: SQLiteStatement) -> ScanSession {
        let roots = (s.string(4)?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([ScanRoot].self, from: $0) } ?? []
        let excluded = (s.string(5)?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        return ScanSession(
            id: s.int64(0), startedAt: s.date(1) ?? .distantPast, finishedAt: s.date(2),
            status: ScanStatus(rawValue: s.string(3) ?? "") ?? .failed, roots: roots, excludedPaths: excluded,
            fileCount: s.int64(6), directoryCount: s.int64(7), logicalSize: s.int64(8), allocatedSize: s.int64(9),
            hardLinkDuplicateCount: s.int64(10), issueCount: s.int64(11), smallFileThreshold: s.int64(12),
            hasIndex: s.int64(13) != 0
        )
    }

    /// Marks sessions left `running` by a previous process as interrupted. Call once at launch.
    public func markInterruptedSessions() throws {
        try db.prepare("UPDATE scan_session SET status = 'interrupted', finished_at = COALESCE(finished_at, started_at) WHERE status = 'running'").run()
    }

    public func sessions(limit: Int = 50) throws -> [ScanSession] {
        let s = try db.prepare("SELECT \(Self.sessionColumns) FROM scan_session ORDER BY id DESC LIMIT ?")
        try s.bind(.int(Int64(limit)))
        var out: [ScanSession] = []
        while try s.step() { out.append(decodeSession(s)) }
        return out
    }

    /// The newest session that has a browsable index (completed or cancelled-partial).
    public func latestBrowsableSession() throws -> ScanSession? {
        let s = try db.prepare("SELECT \(Self.sessionColumns) FROM scan_session WHERE has_index = 1 AND dir_count > 0 AND status IN ('completed', 'cancelled') ORDER BY id DESC LIMIT 1")
        return try s.step() ? decodeSession(s) : nil
    }

    public func session(id: Int64) throws -> ScanSession? {
        let s = try db.prepare("SELECT \(Self.sessionColumns) FROM scan_session WHERE id = ?")
        try s.bind(.int(id))
        return try s.step() ? decodeSession(s) : nil
    }

    // MARK: Entries

    static let entryColumns = "id, session_id, parent_id, depth, kind, name, path, logical, allocated, modified, created, file_count, dir_count, small_count, small_logical, small_allocated, device, inode, flags, category, lead_category"

    private func decodeEntry(_ s: SQLiteStatement) -> FileRecord {
        FileRecord(
            id: s.int64(0), sessionID: s.int64(1), parentID: s.optionalInt64(2), depth: s.int(3),
            kind: EntryKind(rawValue: s.int(4)) ?? .other, name: s.string(5) ?? "", path: s.string(6) ?? "",
            logicalSize: s.int64(7), allocatedSize: s.int64(8), modified: s.date(9), created: s.date(10),
            fileCount: s.int64(11), directoryCount: s.int64(12), smallFileCount: s.int64(13),
            smallFileLogical: s.int64(14), smallFileAllocated: s.int64(15), device: Int32(truncatingIfNeeded: s.int64(16)),
            inode: UInt64(bitPattern: s.int64(17)), flags: EntryFlags(rawValue: s.int(18)),
            category: StorageCategory(rawValue: s.int(19)) ?? .unclassified,
            leadCategory: s.optionalInt64(20).flatMap { StorageCategory(rawValue: Int($0)) }
        )
    }

    private func collect(_ s: SQLiteStatement) throws -> [FileRecord] {
        var out: [FileRecord] = []
        while try s.step() { out.append(decodeEntry(s)) }
        return out
    }

    public func roots(sessionID: Int64) throws -> [FileRecord] {
        let s = try db.prepare("SELECT \(Self.entryColumns) FROM entry WHERE session_id = ? AND parent_id IS NULL AND (flags & \(EntryFlags.hiddenMask)) = 0 ORDER BY allocated DESC")
        try s.bind(.int(sessionID))
        return try collect(s)
    }

    public func entry(id: Int64) throws -> FileRecord? {
        let s = try db.prepare("SELECT \(Self.entryColumns) FROM entry WHERE id = ?")
        try s.bind(.int(id))
        return try s.step() ? decodeEntry(s) : nil
    }

    public func entry(sessionID: Int64, path: String) throws -> FileRecord? {
        let s = try db.prepare("SELECT \(Self.entryColumns) FROM entry WHERE session_id = ? AND path = ? LIMIT 1")
        try s.bind(.int(sessionID), .text(path))
        return try s.step() ? decodeEntry(s) : nil
    }

    /// Children of a directory, one page at a time (only rows that are displayed are loaded).
    public func children(of parentID: Int64, sort: ChildSort = .allocatedDescending, limit: Int = 500, offset: Int = 0) throws -> [FileRecord] {
        let s = try db.prepare("SELECT \(Self.entryColumns) FROM entry WHERE parent_id = ? AND (flags & \(EntryFlags.hiddenMask)) = 0 ORDER BY \(sort.sql) LIMIT ? OFFSET ?")
        try s.bind(.int(parentID), .int(Int64(limit)), .int(Int64(offset)))
        return try collect(s)
    }

    public func childCount(of parentID: Int64) throws -> Int {
        let s = try db.prepare("SELECT COUNT(*) FROM entry WHERE parent_id = ? AND (flags & \(EntryFlags.hiddenMask)) = 0")
        try s.bind(.int(parentID))
        _ = try s.step()
        return s.int(0)
    }

    /// The chain from the root down to (and including) `id`, for breadcrumbs.
    public func ancestry(of id: Int64) throws -> [FileRecord] {
        var chain: [FileRecord] = []
        var current = try entry(id: id)
        var guardCount = 0
        while let record = current, guardCount < 4096 {
            chain.append(record)
            guardCount += 1
            current = try record.parentID.flatMap { try entry(id: $0) }
        }
        return chain.reversed()
    }

    public func files(sessionID: Int64, query: FileQuery) throws -> [FileRecord] {
        var clauses = ["session_id = ?", "kind = \(EntryKind.file.rawValue)", "allocated >= ?", "(flags & \(EntryFlags.hiddenMask)) = 0"]
        var values: [SQLValue?] = [.int(sessionID), .int(query.minimumAllocated)]
        if !query.extensions.isEmpty {
            clauses.append("ext IN (\(query.extensions.map { _ in "?" }.joined(separator: ",")))")
            values += query.extensions.sorted().map { .text($0) }
        }
        if !query.categories.isEmpty {
            clauses.append("category IN (\(query.categories.map { String($0.rawValue) }.sorted().joined(separator: ",")))")
        }
        if let before = query.modifiedBefore { clauses.append("modified < ?"); values.append(.of(before)) }
        if let after = query.modifiedAfter { clauses.append("modified > ?"); values.append(.of(after)) }
        if let prefix = query.pathPrefix {
            clauses.append("path LIKE ? ESCAPE '\\'")
            values.append(.text(PathTools.likeEscaped(prefix) + "/%"))
        }
        if let name = query.nameContains, !name.isEmpty {
            clauses.append("name_key LIKE ? ESCAPE '\\'")
            values.append(.text("%" + PathTools.likeEscaped(SearchKey.make(name)) + "%"))
        }
        let s = try db.prepare("SELECT \(Self.entryColumns) FROM entry WHERE \(clauses.joined(separator: " AND ")) ORDER BY allocated DESC LIMIT ?")
        values.append(.int(Int64(query.limit)))
        try s.bindAll(values)
        return try collect(s)
    }

    /// Name search over indexed rows (directories and large files).
    public func search(sessionID: Int64, text: String, limit: Int = 300) throws -> [FileRecord] {
        let s = try db.prepare("SELECT \(Self.entryColumns) FROM entry WHERE session_id = ? AND name_key LIKE ? ESCAPE '\\' AND (flags & \(EntryFlags.hiddenMask)) = 0 ORDER BY allocated DESC LIMIT ?")
        try s.bind(.int(sessionID), .text("%" + PathTools.likeEscaped(SearchKey.make(text)) + "%"), .int(Int64(limit)))
        return try collect(s)
    }

    /// Largest directories at or below a depth (for "largest folders").
    public func largestDirectories(sessionID: Int64, maxDepth: Int = 4, limit: Int = 50) throws -> [FileRecord] {
        let s = try db.prepare("SELECT \(Self.entryColumns) FROM entry WHERE session_id = ? AND kind IN (1, 2) AND depth BETWEEN 1 AND ? AND (flags & \(EntryFlags.hiddenMask)) = 0 ORDER BY allocated DESC LIMIT ?")
        try s.bind(.int(sessionID), .int(Int64(maxDepth)), .int(Int64(limit)))
        return try collect(s)
    }

    public func categoryTotals(sessionID: Int64) throws -> [CategoryTotal] {
        let s = try db.prepare("SELECT category, file_count, logical, allocated FROM category_total WHERE session_id = ? ORDER BY allocated DESC")
        try s.bind(.int(sessionID))
        var out: [CategoryTotal] = []
        while try s.step() {
            out.append(CategoryTotal(category: StorageCategory(rawValue: s.int(0)) ?? .unclassified, fileCount: s.int64(1), logicalSize: s.int64(2), allocatedSize: s.int64(3)))
        }
        return out
    }

    /// Totals by extension over *indexed* files (files above the small-file threshold).
    public func extensionTotals(sessionID: Int64, limit: Int = 30) throws -> [ExtensionTotal] {
        let s = try db.prepare("SELECT ext, COUNT(*), SUM(allocated) FROM entry WHERE session_id = ? AND kind = 0 AND ext IS NOT NULL AND (flags & \(EntryFlags.hiddenMask)) = 0 GROUP BY ext ORDER BY SUM(allocated) DESC LIMIT ?")
        try s.bind(.int(sessionID), .int(Int64(limit)))
        var out: [ExtensionTotal] = []
        while try s.step() { out.append(ExtensionTotal(ext: s.string(0) ?? "", fileCount: s.int64(1), allocated: s.int64(2))) }
        return out
    }

    public func issues(sessionID: Int64, kind: ScanIssueKind? = nil, limit: Int = 500) throws -> [ScanIssue] {
        let sql = kind == nil
            ? "SELECT path, kind, code, message FROM scan_issue WHERE session_id = ? ORDER BY id LIMIT ?"
            : "SELECT path, kind, code, message FROM scan_issue WHERE session_id = ? AND kind = ? ORDER BY id LIMIT ?"
        let s = try db.prepare(sql)
        if let kind { try s.bind(.int(sessionID), .text(kind.rawValue), .int(Int64(limit))) } else { try s.bind(.int(sessionID), .int(Int64(limit))) }
        var out: [ScanIssue] = []
        while try s.step() {
            out.append(ScanIssue(path: s.string(0) ?? "", kind: ScanIssueKind(rawValue: s.string(1) ?? "") ?? .ioError, errorCode: Int32(truncatingIfNeeded: s.int64(2)), message: s.string(3) ?? ""))
        }
        return out
    }

    public func issueCounts(sessionID: Int64) throws -> [ScanIssueKind: Int] {
        let s = try db.prepare("SELECT kind, COUNT(*) FROM scan_issue WHERE session_id = ? GROUP BY kind")
        try s.bind(.int(sessionID))
        var out: [ScanIssueKind: Int] = [:]
        while try s.step() {
            if let kind = ScanIssueKind(rawValue: s.string(0) ?? "") { out[kind] = s.int(1) }
        }
        return out
    }

    /// Size history of top-level folders across sessions (kept even after old indexes are pruned).
    public func growth(path: String, limit: Int = 30) throws -> [GrowthPoint] {
        let s = try db.prepare("""
            SELECT r.session_id, s.started_at, r.path, r.allocated FROM root_summary r JOIN scan_session s ON s.id = r.session_id
            WHERE r.path = ? AND s.status = 'completed' ORDER BY r.session_id DESC LIMIT ?
            """)
        try s.bind(.text(path), .int(Int64(limit)))
        var out: [GrowthPoint] = []
        while try s.step() { out.append(GrowthPoint(sessionID: s.int64(0), date: s.date(1) ?? .distantPast, path: s.string(2) ?? "", allocated: s.int64(3))) }
        return out.reversed()
    }

    /// Compares top-level folder sizes between the most recent completed session and the previous
    /// completed one that scanned the same locations (a home-folder scan and a whole-disk scan are
    /// not compared).
    public func topLevelChanges(limit: Int = 15) throws -> [(path: String, previous: Int64, current: Int64)] {
        let ids = try db.prepare("""
            SELECT c.id, (SELECT p.id FROM scan_session p WHERE p.status = 'completed' AND p.id < c.id AND p.roots = c.roots
                          ORDER BY p.id DESC LIMIT 1)
            FROM scan_session c WHERE c.status = 'completed' ORDER BY c.id DESC LIMIT 1
            """)
        guard try ids.step(), !ids.isNull(1) else { return [] }
        let sessionIDs = [ids.int64(0), ids.int64(1)]
        let s = try db.prepare("""
            SELECT c.path, COALESCE(p.allocated, 0), c.allocated FROM root_summary c
            LEFT JOIN root_summary p ON p.path = c.path AND p.session_id = ?
            WHERE c.session_id = ? AND c.depth = 1 ORDER BY ABS(c.allocated - COALESCE(p.allocated, 0)) DESC LIMIT ?
            """)
        try s.bind(.int(sessionIDs[1]), .int(sessionIDs[0]), .int(Int64(limit)))
        var out: [(String, Int64, Int64)] = []
        while try s.step() { out.append((s.string(0) ?? "", s.int64(1), s.int64(2))) }
        return out
    }

    // MARK: Maintenance

    /// Keeps the detailed index only for the newest `keep` browsable sessions; older sessions keep
    /// their summary rows (for trends). Also caps stored issues of pruned sessions.
    public func pruneIndexes(keep: Int = 2) throws {
        let s = try db.prepare("SELECT id FROM scan_session WHERE has_index = 1 ORDER BY id DESC LIMIT -1 OFFSET ?")
        try s.bind(.int(Int64(keep)))
        var stale: [Int64] = []
        while try s.step() { stale.append(s.int64(0)) }
        guard !stale.isEmpty else { return }
        try db.transaction {
            let deleteEntries = try db.prepare("DELETE FROM entry WHERE session_id = ?")
            let deleteIssues = try db.prepare("DELETE FROM scan_issue WHERE session_id = ?")
            let mark = try db.prepare("UPDATE scan_session SET has_index = 0 WHERE id = ?")
            for id in stale {
                try deleteEntries.run(.int(id))
                try deleteIssues.run(.int(id))
                try mark.run(.int(id))
            }
        }
        // Pruning frees a whole scan's rows: hand the log's space back now (best effort — a scan
        // still writing simply keeps it until a later checkpoint).
        try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// Deletes every scan session, index row, issue and trend summary.
    public func clearScanHistory() throws {
        try db.transaction {
            for table in ["entry", "scan_issue", "category_total", "root_summary", "scan_session"] {
                try db.execute("DELETE FROM \(table)")
            }
        }
        try db.execute("VACUUM")
    }

    public func clearCleanupHistory() throws {
        try db.transaction {
            try db.execute("DELETE FROM cleanup_item")
            try db.execute("DELETE FROM cleanup_operation")
        }
        try db.execute("VACUUM")
    }

    public func databaseSize() -> Int64 {
        var total: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            if case .success(let st) = FileStat.lstat(url.path + suffix) { total += st.allocatedSize }
        }
        return total
    }

    // MARK: Exclusions

    public func exclusions(scope: ExclusionScope? = nil) throws -> [Exclusion] {
        let s = try db.prepare(scope == nil
            ? "SELECT id, path, scope, created_at FROM exclusion ORDER BY path"
            : "SELECT id, path, scope, created_at FROM exclusion WHERE scope = ? ORDER BY path")
        if let scope { try s.bind(.text(scope.rawValue)) }
        var out: [Exclusion] = []
        while try s.step() {
            out.append(Exclusion(id: s.int64(0), path: s.string(1) ?? "", scope: ExclusionScope(rawValue: s.string(2) ?? "") ?? .scan, createdAt: s.date(3) ?? Date()))
        }
        return out
    }

    @discardableResult
    public func addExclusion(path: String, scope: ExclusionScope) throws -> Bool {
        guard let normalized = PathTools.normalize(path) else { return false }
        try db.prepare("INSERT OR IGNORE INTO exclusion(path, scope, created_at) VALUES (?, ?, ?)").run(.text(normalized), .text(scope.rawValue), .of(Date()))
        return db.changes > 0
    }

    public func removeExclusion(id: Int64) throws {
        try db.prepare("DELETE FROM exclusion WHERE id = ?").run(.int(id))
    }

    // MARK: Cleanup journal

    /// Writes the operation row and one `pending` row per item in a single transaction, *before* any
    /// item is touched (crash-safe journal). Either everything is committed or nothing is.
    public func beginOperation(plan: CleanupPlan, detailed: Bool) throws -> CleanupJournal {
        try db.transaction {
            try db.write("""
                INSERT INTO cleanup_operation(plan_uuid, mode, title, started_at, status, item_count, bytes_identified, detailed)
                VALUES (?, ?, ?, ?, 'running', ?, ?, ?)
                """, .text(plan.id.uuidString), .text(plan.mode.rawValue), .text(plan.title), .of(Date()),
                .of(plan.items.count), .int(plan.identifiedAllocatedBytes), .of(detailed))
            let operationID = db.lastInsertRowID
            let insert = try db.prepare("""
                INSERT INTO cleanup_item(operation_id, seq, path, bytes, status, device, inode, obj_type) VALUES (?, ?, ?, ?, 'pending', ?, ?, ?)
                """)
            var itemIDs: [Int64] = []
            itemIDs.reserveCapacity(plan.items.count)
            for (sequence, candidate) in plan.items.enumerated() {
                try insert.run(.int(operationID), .of(sequence), detailed ? .text(candidate.path) : nil, .int(candidate.allocatedSize),
                               .int(Int64(candidate.identity.device)), .int(Int64(bitPattern: candidate.identity.inode)),
                               .of(candidate.identity.type.rawValue))
                let changed = db.changes
                guard changed == 1 else { throw SQLiteChangeCountError(expected: 1, actual: changed) }
                itemIDs.append(db.lastInsertRowID)
            }
            return CleanupJournal(operationID: operationID, itemIDs: itemIDs)
        }
    }

    /// Records what happened to one item. Throws when the row was not updated.
    public func journalOutcome(itemID: Int64, outcome: CleanupItemOutcome, detailed: Bool) throws {
        try db.write("UPDATE cleanup_item SET status = ?, trash_path = ?, message = ? WHERE id = ? AND status = 'pending'",
                     .text(outcome.status.rawValue), detailed ? .of(outcome.trashPath) : nil, .of(outcome.message), .int(itemID))
    }

    /// Writes the final summary. `incomplete` marks an operation that stopped because its history
    /// could not be saved.
    public func finishOperation(id: Int64, result: CleanupResult) throws {
        let status = result.journalProblem != nil ? "incomplete" : (result.wasCancelled ? "cancelled" : "finished")
        try db.write("""
            UPDATE cleanup_operation SET finished_at = ?, status = ?, moved = ?, failed = ?, skipped = ?, bytes_trashed = ?,
                   free_before = ?, free_after = ? WHERE id = ?
            """, .of(result.finishedAt), .text(status), .of(result.movedCount),
            .of(result.failedCount), .of(result.skippedCount), .int(result.bytesMovedToTrash),
            .of(result.freeSpaceBefore), .of(result.freeSpaceAfter), .int(id))
    }

    /// Marks operations left `running` by a previous process as interrupted, with the counts its
    /// items recorded. Items still `pending` were not recorded: they may or may not have moved.
    public func markInterruptedOperations() throws {
        try db.execute("""
            UPDATE cleanup_operation SET status = 'interrupted', finished_at = COALESCE(finished_at, started_at),
                moved = (SELECT COUNT(*) FROM cleanup_item i WHERE i.operation_id = cleanup_operation.id AND i.status IN ('movedToTrash', 'restored')),
                failed = (SELECT COUNT(*) FROM cleanup_item i WHERE i.operation_id = cleanup_operation.id AND i.status = 'failed'),
                skipped = (SELECT COUNT(*) FROM cleanup_item i WHERE i.operation_id = cleanup_operation.id AND i.status = 'skipped'),
                bytes_trashed = (SELECT COALESCE(SUM(bytes), 0) FROM cleanup_item i WHERE i.operation_id = cleanup_operation.id AND i.status IN ('movedToTrash', 'restored'))
            WHERE status = 'running'
            """)
    }

    public func operations(limit: Int = 100) throws -> [CleanupOperationRecord] {
        let s = try db.prepare("""
            SELECT id, plan_uuid, mode, title, started_at, finished_at, status, item_count, moved, failed, skipped,
                   bytes_identified, bytes_trashed, free_before, free_after, detailed
            FROM cleanup_operation ORDER BY id DESC LIMIT ?
            """)
        try s.bind(.int(Int64(limit)))
        var out: [CleanupOperationRecord] = []
        while try s.step() {
            out.append(CleanupOperationRecord(
                id: s.int64(0), planID: UUID(uuidString: s.string(1) ?? "") ?? UUID(), mode: CleanupMode(rawValue: s.string(2) ?? "") ?? .smartClean,
                title: s.string(3) ?? "", startedAt: s.date(4) ?? Date(), finishedAt: s.date(5), status: s.string(6) ?? "",
                itemCount: s.int(7), movedCount: s.int(8), failedCount: s.int(9), skippedCount: s.int(10),
                bytesIdentified: s.int64(11), bytesMovedToTrash: s.int64(12), freeSpaceBefore: s.optionalInt64(13),
                freeSpaceAfter: s.optionalInt64(14), hasDetails: s.int64(15) != 0))
        }
        return out
    }

    public func items(operationID: Int64) throws -> [CleanupItemRecord] {
        let s = try db.prepare("SELECT id, operation_id, seq, path, trash_path, bytes, status, message, device, inode, obj_type, restored_at FROM cleanup_item WHERE operation_id = ? ORDER BY seq")
        try s.bind(.int(operationID))
        var out: [CleanupItemRecord] = []
        while try s.step() {
            var identity: FileIdentity?
            if !s.isNull(8), !s.isNull(9) {
                identity = FileIdentity(device: Int32(truncatingIfNeeded: s.int64(8)), inode: UInt64(bitPattern: s.int64(9)),
                                        type: FileObjectType(rawValue: s.int(10)) ?? .other, ownerUID: getuid())
            }
            out.append(CleanupItemRecord(
                id: s.int64(0), operationID: s.int64(1), sequence: s.int(2), originalPath: s.string(3), trashPath: s.string(4),
                allocatedSize: s.int64(5), status: CleanupItemStatus(rawValue: s.string(6) ?? "") ?? .failed,
                message: s.string(7), identity: identity, restoredAt: s.date(11)))
        }
        return out
    }

    /// Records a Put Back. Throws when the item was not recorded as moved to the Trash.
    public func markRestored(itemID: Int64) throws {
        try db.write("UPDATE cleanup_item SET status = 'restored', restored_at = ? WHERE id = ? AND status = 'movedToTrash'", .of(Date()), .int(itemID))
    }
}
