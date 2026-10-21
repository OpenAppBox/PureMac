import Foundation

/// Versioned schema migrations, tracked with `PRAGMA user_version`.
public enum DatabaseSchema {
    /// Ordered migrations; index `i` upgrades from version `i` to `i + 1`. Never edit a shipped migration.
    static let migrations: [String] = [
        // v1 — initial schema
        """
        CREATE TABLE scan_session(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            started_at REAL NOT NULL,
            finished_at REAL,
            status TEXT NOT NULL,
            roots TEXT NOT NULL,
            excluded TEXT NOT NULL DEFAULT '[]',
            file_count INTEGER NOT NULL DEFAULT 0,
            dir_count INTEGER NOT NULL DEFAULT 0,
            logical_bytes INTEGER NOT NULL DEFAULT 0,
            allocated_bytes INTEGER NOT NULL DEFAULT 0,
            hardlink_dups INTEGER NOT NULL DEFAULT 0,
            issue_count INTEGER NOT NULL DEFAULT 0,
            small_threshold INTEGER NOT NULL DEFAULT 0,
            has_index INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE entry(
            id INTEGER PRIMARY KEY,
            session_id INTEGER NOT NULL,
            parent_id INTEGER,
            depth INTEGER NOT NULL,
            kind INTEGER NOT NULL,
            name TEXT NOT NULL,
            name_key TEXT NOT NULL,
            path TEXT NOT NULL,
            ext TEXT,
            logical INTEGER NOT NULL,
            allocated INTEGER NOT NULL,
            modified REAL,
            created REAL,
            file_count INTEGER NOT NULL,
            dir_count INTEGER NOT NULL,
            small_count INTEGER NOT NULL,
            small_logical INTEGER NOT NULL,
            small_allocated INTEGER NOT NULL,
            device INTEGER NOT NULL,
            inode INTEGER NOT NULL,
            flags INTEGER NOT NULL,
            category INTEGER NOT NULL
        );
        CREATE INDEX entry_parent ON entry(parent_id, allocated DESC);
        CREATE INDEX entry_session_kind_size ON entry(session_id, kind, allocated DESC);
        CREATE INDEX entry_session_path ON entry(session_id, path);
        CREATE TABLE scan_issue(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL,
            path TEXT NOT NULL,
            kind TEXT NOT NULL,
            code INTEGER NOT NULL,
            message TEXT NOT NULL
        );
        CREATE INDEX scan_issue_session ON scan_issue(session_id);
        CREATE TABLE category_total(
            session_id INTEGER NOT NULL,
            category INTEGER NOT NULL,
            file_count INTEGER NOT NULL,
            logical INTEGER NOT NULL,
            allocated INTEGER NOT NULL,
            PRIMARY KEY(session_id, category)
        );
        CREATE TABLE root_summary(
            session_id INTEGER NOT NULL,
            path TEXT NOT NULL,
            depth INTEGER NOT NULL,
            logical INTEGER NOT NULL,
            allocated INTEGER NOT NULL,
            file_count INTEGER NOT NULL
        );
        CREATE INDEX root_summary_path ON root_summary(path, session_id);
        CREATE TABLE exclusion(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL,
            scope TEXT NOT NULL,
            created_at REAL NOT NULL,
            UNIQUE(path, scope)
        );
        CREATE TABLE cleanup_operation(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            plan_uuid TEXT NOT NULL,
            mode TEXT NOT NULL,
            title TEXT NOT NULL,
            started_at REAL NOT NULL,
            finished_at REAL,
            status TEXT NOT NULL,
            item_count INTEGER NOT NULL DEFAULT 0,
            moved INTEGER NOT NULL DEFAULT 0,
            failed INTEGER NOT NULL DEFAULT 0,
            skipped INTEGER NOT NULL DEFAULT 0,
            bytes_identified INTEGER NOT NULL DEFAULT 0,
            bytes_trashed INTEGER NOT NULL DEFAULT 0,
            free_before INTEGER,
            free_after INTEGER,
            detailed INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE cleanup_item(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            operation_id INTEGER NOT NULL,
            seq INTEGER NOT NULL,
            path TEXT,
            trash_path TEXT,
            bytes INTEGER NOT NULL,
            status TEXT NOT NULL,
            message TEXT,
            device INTEGER,
            inode INTEGER,
            obj_type INTEGER,
            restored_at REAL
        );
        CREATE INDEX cleanup_item_operation ON cleanup_item(operation_id, seq);
        """,
        // v2 — the largest category of a mixed folder, for coloring storage maps
        """
        ALTER TABLE entry ADD COLUMN lead_category INTEGER;
        """,
    ]

    public static var currentVersion: Int { migrations.count }

    public enum MigrationError: Error {
        case databaseFromNewerVersion(Int)
    }

    static func userVersion(_ db: SQLiteConnection) throws -> Int {
        let stmt = try db.prepare("PRAGMA user_version")
        _ = try stmt.step()
        return stmt.int(0)
    }

    /// Applies pending migrations inside a transaction each.
    /// The version is read inside each write transaction, so two connections opening a new database
    /// at the same time cannot both apply the same migration.
    public static func migrate(_ db: SQLiteConnection) throws {
        let initial = try userVersion(db)
        if initial > currentVersion { throw MigrationError.databaseFromNewerVersion(initial) }
        guard initial < currentVersion else { return }
        while try db.transaction({ () throws -> Bool in
            let version = try userVersion(db)
            if version > currentVersion { throw MigrationError.databaseFromNewerVersion(version) }
            guard version < currentVersion else { return false }
            try db.execute(migrations[version])
            try db.execute("PRAGMA user_version = \(version + 1)")
            return true
        }) {}
    }

    /// How hard a connection waits for the disk on commit.
    public enum Durability: Sendable {
        /// `synchronous = FULL`: a committed transaction survives power loss. For the cleanup
        /// journal — a record must be on disk before the file it describes is moved.
        case full
        /// `synchronous = NORMAL`: survives an app crash; the scanner's large batched inserts.
        case normal
    }

    /// Opens the database at `url`, creating and migrating it. A corrupt or incompatible file is
    /// renamed aside (never deleted) and a fresh database is created. Only the app's main store does
    /// this, once at launch: a second connection must never move a database another one has open.
    ///
    /// - Returns: the connection and, if recovery happened, the path of the preserved file.
    public static func openOrRecover(at url: URL, durability: Durability = .full) throws -> (SQLiteConnection, recoveredFile: String?) {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let db = try SQLiteConnection(path: url.path)
            guard db.passesQuickCheck() else { throw SQLiteError(code: 11, message: "quick_check failed") }
            try configure(db, durability: durability)
            try migrate(db)
            return (db, nil)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = url.path + ".corrupt-\(stamp)"
            try? FileManager.default.moveItem(atPath: url.path, toPath: aside)
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.moveItem(atPath: url.path + suffix, toPath: aside + suffix)
            }
            let db = try SQLiteConnection(path: url.path)
            try configure(db, durability: durability)
            try migrate(db)
            return (db, aside)
        }
    }

    /// Opens (creating and migrating when needed) without recovery: a failure is reported, never
    /// answered by moving the file aside.
    public static func open(at url: URL, durability: Durability) throws -> SQLiteConnection {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteConnection(path: url.path)
        try configure(db, durability: durability)
        try migrate(db)
        return db
    }

    static func configure(_ db: SQLiteConnection, durability: Durability) throws {
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute(durability == .full ? "PRAGMA synchronous = FULL" : "PRAGMA synchronous = NORMAL")
        try db.execute("PRAGMA temp_store = MEMORY")
        // Without a limit the write-ahead log keeps the size of the largest scan ever written
        // (hundreds of MB after a whole-disk scan); with it, checkpoints trim the file back.
        try db.execute("PRAGMA journal_size_limit = \(walSizeLimit)")
    }

    /// Largest size the write-ahead log keeps on disk between checkpoints.
    static let walSizeLimit = 32 * 1024 * 1024
}
