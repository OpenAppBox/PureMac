import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public var code: Int32
    public var message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

/// A write succeeded in SQLite but changed a different number of rows than it had to (for example an
/// `UPDATE` whose row no longer exists).
public struct SQLiteChangeCountError: Error, CustomStringConvertible, Sendable {
    public var expected: Int
    public var actual: Int
    public var description: String { "SQLite write changed \(actual) row(s) instead of \(expected)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal SQLite3 connection wrapper. A connection is **not** thread-safe; each owner
/// (an actor or a single background thread) uses its own connection.
///
/// Lifetime: every `SQLiteStatement` holds its connection strongly, so the connection is closed only
/// after its last statement is finalized. (Calling SQLite on a closed connection — even just
/// `sqlite3_errmsg` to describe an error — is API misuse.) A connection never references its
/// statements, so there is no retain cycle.
public final class SQLiteConnection {
    private(set) var handle: OpaquePointer?
    public let path: String

    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteError(code: rc, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
        sqlite3_extended_result_codes(db, 1)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    public func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw SQLiteError(code: rc, message: message)
        }
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw lastError(rc) }
        return SQLiteStatement(stmt, connection: self)
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    public var changes: Int { Int(sqlite3_changes(handle)) }

    /// Runs a write that must change exactly `expected` rows. A write that matches no row succeeds
    /// in SQLite; this turns it into an error so callers cannot record something that did not happen.
    public func write(_ sql: String, _ values: SQLValue?..., expected: Int = 1) throws {
        try prepare(sql).bindAll(values).runToEnd()
        let changed = changes
        guard changed == expected else {
            throw SQLiteChangeCountError(expected: expected, actual: changed)
        }
    }

    func lastError(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)))
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Returns `true` when `PRAGMA quick_check` reports no corruption.
    public func passesQuickCheck() -> Bool {
        guard let stmt = try? prepare("PRAGMA quick_check") else { return false }
        guard (try? stmt.step()) == true else { return false }
        return stmt.string(0) == "ok"
    }
}

public final class SQLiteStatement {
    private var stmt: OpaquePointer?
    /// Strong: the statement must be finalized before its connection is closed.
    let connection: SQLiteConnection

    init(_ stmt: OpaquePointer, connection: SQLiteConnection) {
        self.stmt = stmt
        self.connection = connection
    }

    deinit { sqlite3_finalize(stmt) }

    @discardableResult
    public func bind(_ values: SQLValue?...) throws -> SQLiteStatement {
        try bindAll(values)
    }

    @discardableResult
    public func bindAll(_ values: [SQLValue?]) throws -> SQLiteStatement {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let rc: Int32
            switch value {
            case nil:
                rc = sqlite3_bind_null(stmt, position)
            case .int(let v):
                rc = sqlite3_bind_int64(stmt, position, v)
            case .double(let v):
                rc = sqlite3_bind_double(stmt, position, v)
            case .text(let v):
                rc = sqlite3_bind_text(stmt, position, v, -1, SQLITE_TRANSIENT)
            }
            if rc != SQLITE_OK { throw connection.lastError(rc) }
        }
        return self
    }

    /// Steps the statement. Returns `true` while a row is available.
    @discardableResult
    public func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw connection.lastError(rc)
        }
    }

    /// Executes a statement that returns no rows.
    public func run(_ values: SQLValue?...) throws {
        try bindAll(values)
        try runToEnd()
    }

    /// Steps the already bound statement until it is done.
    public func runToEnd() throws {
        while try step() {}
    }

    public func reset() { sqlite3_reset(stmt) }

    public func isNull(_ column: Int32) -> Bool { sqlite3_column_type(stmt, column) == SQLITE_NULL }
    public func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(stmt, column) }
    public func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(stmt, column)) }
    public func double(_ column: Int32) -> Double { sqlite3_column_double(stmt, column) }
    public func optionalInt64(_ column: Int32) -> Int64? { isNull(column) ? nil : int64(column) }
    public func optionalDouble(_ column: Int32) -> Double? { isNull(column) ? nil : double(column) }
    public func string(_ column: Int32) -> String? {
        guard let text = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: text)
    }
    public func date(_ column: Int32) -> Date? { optionalDouble(column).map(Date.init(timeIntervalSince1970:)) }
}

public enum SQLValue: Sendable, Hashable {
    case int(Int64)
    case double(Double)
    case text(String)

    public static func of(_ v: Int64?) -> SQLValue? { v.map(SQLValue.int) }
    public static func of(_ v: Int?) -> SQLValue? { v.map { .int(Int64($0)) } }
    public static func of(_ v: String?) -> SQLValue? { v.map(SQLValue.text) }
    public static func of(_ v: Date?) -> SQLValue? { v.map { .double($0.timeIntervalSince1970) } }
    public static func of(_ v: Bool) -> SQLValue? { .int(v ? 1 : 0) }
}
