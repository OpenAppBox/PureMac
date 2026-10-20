import Foundation
import Testing
@testable import PureMacKit

/// A whole-disk scan must look like a home-folder scan, only bigger: real categories (not
/// everything "System & Other"), colors for mixed folders, and changes compared only between
/// scans of the same locations.
@Suite("Whole-disk scans")
struct WholeDiskScanTests {
    @Test func diskRootHasNoCategoryOfItsOwn() {
        let classifier = CategoryClassifier(home: "/Users/alex")
        // `/System/Volumes/Data` starts with `/System`, but it holds the whole disk.
        #expect(classifier.directoryContext(path: PathTools.dataVolume, name: "Macintosh HD", parentContext: nil) == nil)
        #expect(classifier.directoryContext(path: "/Applications", name: "Applications", parentContext: nil) == .applications)
        #expect(classifier.directoryContext(path: "/Users", name: "Users", parentContext: nil) == nil)
        #expect(classifier.directoryContext(path: "/Users/alex/Library", name: "Library", parentContext: nil) == .appData)
        #expect(classifier.directoryContext(path: "/System/Volumes/Data/System", name: "System", parentContext: nil) == .systemOther)
    }

    @Test func mixedFolderRemembersItsLargestCategory() async throws {
        let f = try Fixture()
        // 60% needed to dominate: 40% videos, 35% documents, 25% archives → mixed, led by videos.
        try f.file("mix/clip.mov", size: 40_000)
        try f.file("mix/report.pdf", size: 35_000)
        try f.file("mix/bundle.zip", size: 25_000)
        try f.file("films/a.mov", size: 50_000)
        let db = f.databaseURL()
        let session = try await StorageScanner(databaseURL: db, home: f.path)
            .scan(ScanConfiguration(roots: [ScanRoot(path: f.path, kind: .folder)], smallFileThreshold: 1024, progressInterval: 0)) { _ in }
        let store = try LocalStore(url: db)
        let mix = try #require(try await store.entry(sessionID: session.id, path: f.path("mix")))
        #expect(mix.category == .unclassified)
        #expect(mix.leadCategory == .media)
        #expect(mix.mapCategory == .media)
        let films = try #require(try await store.entry(sessionID: session.id, path: f.path("films")))
        #expect(films.category == .media)
        #expect(films.leadCategory == nil)                       // clear category: nothing extra stored
    }

    @Test func changesCompareOnlyScansOfTheSameLocations() async throws {
        let f = try Fixture()
        let url = f.databaseURL()
        let store = try LocalStore(url: url)
        let home = #"[{"kind":"home","path":"/Users/alex"}]"#
        let disk = #"[{"kind":"dataVolume","path":"/System/Volumes/Data"}]"#
        let db = try SQLiteConnection(path: url.path)
        for (id, roots, movies) in [(1, home, 100), (2, home, 150), (3, disk, 0)] {
            try db.prepare("INSERT INTO scan_session(id, started_at, status, roots) VALUES (?, 0, 'completed', ?)").run(.int(Int64(id)), .text(roots))
            if movies > 0 {
                try db.prepare("INSERT INTO root_summary VALUES (?, '/Users/alex/Movies', 1, ?, ?, 1)").run(.int(Int64(id)), .int(Int64(movies)), .int(Int64(movies)))
            }
        }
        // The newest scan (whole disk) has no earlier whole-disk scan: nothing to compare.
        #expect(try await store.topLevelChanges().isEmpty)
        try db.execute("DELETE FROM scan_session WHERE id = 3")
        let changes = try await store.topLevelChanges()
        #expect(changes.count == 1)
        #expect(changes.first?.previous == 100 && changes.first?.current == 150)
    }
}
