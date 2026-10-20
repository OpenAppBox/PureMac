import Foundation
import Testing
@testable import PureMacKit

@Suite("Persistence")
struct PersistenceTests {
    @Test func freshDatabaseIsMigratedToCurrentVersion() async throws {
        let f = try Fixture()
        let url = f.databaseURL()
        let store = try LocalStore(url: url)
        #expect(store.recoveredCorruptFile == nil)
        let db = try SQLiteConnection(path: url.path)
        #expect(try DatabaseSchema.userVersion(db) == DatabaseSchema.currentVersion)
        // Reopening is idempotent.
        _ = try LocalStore(url: url)
        #expect(try DatabaseSchema.userVersion(db) == DatabaseSchema.currentVersion)
        _ = store
    }

    @Test func corruptDatabaseIsPreservedAsideAndRecreated() async throws {
        let f = try Fixture()
        let url = f.databaseURL()
        try Data(repeating: 0x5A, count: 8_192).write(to: url)
        let store = try LocalStore(url: url)
        let aside = try #require(store.recoveredCorruptFile)
        #expect(FileManager.default.fileExists(atPath: aside))     // never deleted
        #expect(try await store.sessions().isEmpty)
        try await store.addExclusion(path: "/Users/x/Movies", scope: .scan)
        #expect(try await store.exclusions().count == 1)
    }

    @Test func databaseFromNewerVersionIsNotDestroyed() async throws {
        let f = try Fixture()
        let url = f.databaseURL()
        do {
            let db = try SQLiteConnection(path: url.path)
            try db.execute("CREATE TABLE future(x); PRAGMA user_version = 999")
        }
        let store = try LocalStore(url: url)
        #expect(store.recoveredCorruptFile != nil)
    }

    @Test func exclusionsAreNormalizedAndUnique() async throws {
        let f = try Fixture()
        let store = try LocalStore(url: f.databaseURL())
        #expect(try await store.addExclusion(path: "/Users/x//Movies/", scope: .cleanup))
        #expect(try await !store.addExclusion(path: "/Users/x/Movies", scope: .cleanup))
        #expect(try await !store.addExclusion(path: "relative", scope: .cleanup))
        #expect(try await store.exclusions(scope: .cleanup).map(\.path) == ["/Users/x/Movies"])
    }

    @Test func interruptedSessionsAreMarked() async throws {
        let f = try Fixture()
        let url = f.databaseURL()
        do {
            let db = try SQLiteConnection(path: url.path)
            try DatabaseSchema.migrate(db)
            try db.execute("INSERT INTO scan_session(started_at, status, roots) VALUES (0, 'running', '[]')")
        }
        let store = try LocalStore(url: url)
        try await store.markInterruptedSessions()
        #expect(try await store.sessions().first?.status == .interrupted)
    }

    @Test func clearHistoryRemovesEverything() async throws {
        let f = try Fixture()
        try f.file("a/b.bin", size: 9_000)
        let url = f.databaseURL()
        _ = try await StorageScanner(databaseURL: url, home: f.path)
            .scan(ScanConfiguration(roots: [ScanRoot(path: f.path("a"), kind: .folder)])) { _ in }
        let store = try LocalStore(url: url)
        #expect(try await store.sessions().count == 1)
        try await store.clearScanHistory()
        #expect(try await store.sessions().isEmpty)
        #expect(try await store.latestBrowsableSession() == nil)
    }
}
