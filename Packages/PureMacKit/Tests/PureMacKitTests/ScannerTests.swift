import Darwin
import Foundation
import Testing
@testable import PureMacKit

@Suite("Storage scanner")
struct ScannerTests {
    func scan(_ fixture: Fixture, threshold: Int64 = 8192, excluded: [String] = [], roots: [ScanRoot]? = nil,
              progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async throws -> (ScanSession, LocalStore) {
        let dbURL = fixture.databaseURL()
        let scanner = StorageScanner(databaseURL: dbURL, home: fixture.path)
        let config = ScanConfiguration(roots: roots ?? [ScanRoot(path: fixture.path, kind: .folder)], excludedPaths: excluded,
                                       smallFileThreshold: threshold, progressInterval: 0)
        let session = try await scanner.scan(config, progress: progress)
        return (session, try LocalStore(url: dbURL))
    }

    @Test func aggregatesSizesAndCountsDirectories() async throws {
        let f = try Fixture()
        try f.file("a/one.bin", size: 10_000)
        try f.file("a/two.bin", size: 20_000)
        try f.file("a/b/three.bin", size: 30_000)
        try f.file("small.txt", size: 10)
        let (session, store) = try await scan(f)
        #expect(session.status == .completed)
        #expect(session.fileCount == 4)
        #expect(session.logicalSize == 60_010)
        #expect(session.directoryCount == 3) // root, a, a/b

        let root = try #require(try await store.roots(sessionID: session.id).first)
        #expect(root.logicalSize == 60_010)
        #expect(root.fileCount == 4)
        #expect(root.smallFileCount == 1)        // small.txt folded into root
        #expect(root.allocatedSize >= root.smallFileAllocated)

        let children = try await store.children(of: root.id)
        let a = try #require(children.first { $0.name == "a" })
        #expect(a.logicalSize == 60_000)
        #expect(a.directoryCount == 1)
        #expect(a.fileCount == 3)
        // Children sorted by allocated size descending.
        let aChildren = try await store.children(of: a.id)
        #expect(aChildren.map(\.allocatedSize) == aChildren.map(\.allocatedSize).sorted(by: >))
        let ancestry = try await store.ancestry(of: try #require(aChildren.first { $0.name == "b" }).id)
        #expect(ancestry.map(\.name).suffix(2) == ["a", "b"])
    }

    @Test func largestFilesQueryAndExtensionTotals() async throws {
        let f = try Fixture()
        try f.file("x/movie.mov", size: 90_000)
        try f.file("x/doc.pdf", size: 50_000)
        try f.file("y/archive.zip", size: 70_000)
        let (session, store) = try await scan(f)
        let largest = try await store.files(sessionID: session.id, query: FileQuery())
        #expect(largest.map(\.name) == ["movie.mov", "archive.zip", "doc.pdf"])
        var q = FileQuery()
        q.extensions = ["pdf"]
        #expect(try await store.files(sessionID: session.id, query: q).map(\.name) == ["doc.pdf"])
        let ext = try await store.extensionTotals(sessionID: session.id)
        #expect(Set(ext.map(\.ext)) == ["mov", "zip", "pdf"])
        #expect(try await store.search(sessionID: session.id, text: "arch").map(\.name) == ["archive.zip"])
    }

    @Test func symlinksAreNeverFollowedAndLoopsTerminate() async throws {
        let outside = try Fixture("outside")
        try outside.file("huge.bin", size: 500_000)
        let f = try Fixture()
        try f.file("real.bin", size: 8_000)
        try f.symlink("link-to-huge", to: outside.path("huge.bin"))
        try f.symlink("link-to-outside-dir", to: outside.path)
        try f.dir("loop")
        try f.symlink("loop/self", to: f.path("loop"))
        try f.symlink("loop/parent", to: "..")
        try f.symlink("dangling", to: "/nonexistent/target")
        let (session, store) = try await scan(f)
        #expect(session.status == .completed)
        // Only real.bin plus tiny symlink entries are counted; the 500 KB target is not.
        #expect(session.logicalSize < 100_000)
        let all = try await store.search(sessionID: session.id, text: "huge")
        #expect(all.isEmpty)
    }

    @Test func hardLinksAreCountedOnce() async throws {
        let f = try Fixture()
        try f.file("orig.bin", size: 100_000)
        try f.hardLink("dir/link1.bin", to: "orig.bin")
        try f.hardLink("dir/link2.bin", to: "orig.bin")
        let (session, store) = try await scan(f)
        #expect(session.hardLinkDuplicateCount == 2)
        #expect(session.logicalSize == 300_000)          // logical counts each path
        let single = try FileStat.lstat(f.path("orig.bin")).get().allocatedSize
        #expect(session.allocatedSize < single * 2)      // allocation counted once
        let files = try await store.files(sessionID: session.id, query: FileQuery())
        #expect(files.filter { $0.flags.contains(.hardLinkDuplicate) }.count == 2)
    }

    @Test func logicalAndAllocatedSizesAreTrackedSeparately() async throws {
        let f = try Fixture()
        try f.sparseFile("sparse.img", logicalSize: 64 << 20)
        let (session, store) = try await scan(f)
        #expect(session.logicalSize == 64 << 20)
        #expect(session.allocatedSize < 1 << 20)
        let entry = try #require(try await store.search(sessionID: session.id, text: "sparse").first)
        #expect(entry.flags.contains(.sparseOrDataless))
        #expect(entry.logicalSize > entry.allocatedSize)
    }

    @Test func packagesUnicodeAndSpecialCharacters() async throws {
        let f = try Fixture()
        try f.file("Tool.app/Contents/MacOS/Tool", size: 9_000)
        try f.file("Çalışma Belgeleri/rapor ğüşiöç.pdf", size: 9_000)
        try f.file("emoji 📦/with spaces & 'quotes' \"dq\" %_.bin", size: 9_000)
        try f.file("日本語/ファイル.txt", size: 9_000)
        let (session, store) = try await scan(f)
        #expect(session.fileCount == 4)
        let app = try #require(try await store.search(sessionID: session.id, text: "Tool.app").first)
        #expect(app.kind == .package)
        #expect(try await store.search(sessionID: session.id, text: "ğüşiöç").count == 1)
        #expect(try await store.search(sessionID: session.id, text: "%_").count == 1) // LIKE metacharacters are literal
        #expect(try await store.search(sessionID: session.id, text: "ファイル").count == 1)
    }

    @Test func deeplyNestedPaths() async throws {
        let f = try Fixture()
        let deep = (0..<80).map { "d\($0)" }.joined(separator: "/")
        try f.file(deep + "/leaf.bin", size: 5_000)
        let (session, _) = try await scan(f)
        #expect(session.fileCount == 1)
        #expect(session.directoryCount == 81)
    }

    @Test func unreadableDirectoriesAreReportedAsCoverageGaps() async throws {
        let f = try Fixture()
        try f.file("open/a.bin", size: 5_000)
        try f.file("locked/secret.bin", size: 5_000)
        chmod(f.path("locked"), 0o000)
        defer { chmod(f.path("locked"), 0o755) }
        let (session, store) = try await scan(f)
        #expect(session.status == .completed)
        #expect(session.fileCount == 1)
        let issues = try await store.issues(sessionID: session.id)
        #expect(issues.contains { $0.kind == .permissionDenied && $0.path.hasSuffix("/locked") })
        let root = try #require(try await store.roots(sessionID: session.id).first)
        #expect(root.flags.contains(.partial))
        let locked = try #require(try await store.children(of: root.id).first { $0.name == "locked" })
        #expect(locked.flags.contains(.unreadable))
    }

    @Test func exclusionsAreNotTraversed() async throws {
        let f = try Fixture()
        try f.file("keep/a.bin", size: 5_000)
        try f.file("skip/b.bin", size: 5_000)
        let (session, store) = try await scan(f, excluded: [f.path("skip")])
        #expect(session.fileCount == 1)
        #expect(try await store.issues(sessionID: session.id, kind: .excluded).count == 1)
    }

    @Test func nestedRootsAreNotDoubleCounted() async throws {
        let f = try Fixture()
        try f.file("inner/a.bin", size: 5_000)
        let (session, _) = try await scan(f, roots: [ScanRoot(path: f.path("inner"), kind: .folder), ScanRoot(path: f.path, kind: .folder)])
        #expect(session.roots.count == 1)
        #expect(session.fileCount == 1)
    }

    @Test func missingRootIsReported() async throws {
        let f = try Fixture()
        let (session, store) = try await scan(f, roots: [ScanRoot(path: f.path("does-not-exist"), kind: .folder)])
        #expect(session.fileCount == 0)
        #expect(try await store.issues(sessionID: session.id, kind: .missingRoot).count == 1)
    }

    @Test func cancellationProducesConsistentPartialIndex() async throws {
        let f = try Fixture()
        for d in 0..<40 {
            for i in 0..<250 { try f.file("d\(d)/f\(i).bin", size: 64) }
        }
        let dbURL = f.databaseURL()
        let scanner = StorageScanner(databaseURL: dbURL, home: f.path)
        let counter = OSAllocatedCounter()
        let task = Task {
            try await scanner.scan(ScanConfiguration(roots: [ScanRoot(path: f.path, kind: .folder)], progressInterval: 0)) { p in
                counter.record(p.filesVisited)
            }
        }
        while counter.calls == 0 { try await Task.sleep(nanoseconds: 200_000) }
        task.cancel()
        let session = try await task.value
        #expect(session.status == .cancelled)
        #expect(session.fileCount < 10_000)
        let store = try LocalStore(url: dbURL)
        let root = try #require(try await store.roots(sessionID: session.id).first)
        #expect(root.flags.contains(.partial))
        #expect(root.fileCount == session.fileCount)
        #expect(try await store.latestBrowsableSession()?.id == session.id)
    }

    @Test func itemsRemovedDuringScanDoNotBreakTheScan() async throws {
        let f = try Fixture()
        for i in 0..<600 { try f.file("first/f\(i).bin", size: 32) }
        for i in 0..<600 { try f.file("victim/sub/f\(i).bin", size: 32) }
        let victim = f.path("victim")
        let (session, _) = try await scan(f) { _ in
            try? FileManager.default.removeItem(atPath: victim)
        }
        #expect(session.status == .completed)
        #expect(session.fileCount <= 1_200)
    }

    @Test func categoriesAreAttributedOnce() async throws {
        let f = try Fixture()
        try f.file("Library/Caches/com.example/blob.bin", size: 10_000)
        try f.file("Library/Caches/com.example/clip.mov", size: 10_000)  // cache context wins over media
        try f.file("Movies/clip.mov", size: 10_000)
        try f.file("Documents/a.pdf", size: 10_000)
        try f.file("Downloads/setup.dmg", size: 10_000)
        try f.file("code/node_modules/x/index.js", size: 10_000)
        try f.file("Projects/app/cache/model.bin", size: 10_000)        // a user folder named "cache" is not a cache
        try f.file(".cache/pip/wheel.whl", size: 10_000)                 // a real cache
        try f.file(".cache/lm-studio/models/m.gguf", size: 10_000)       // downloaded models are app data
        let (session, store) = try await scan(f)
        let totals = Dictionary(uniqueKeysWithValues: try await store.categoryTotals(sessionID: session.id).map { ($0.category, $0) })
        #expect(totals[.caches]?.fileCount == 3)
        #expect(totals[.appData]?.fileCount == 1)
        #expect(totals[.unclassified]?.fileCount == 1)
        #expect(totals[.media]?.fileCount == 1)
        #expect(totals[.documents]?.fileCount == 1)
        #expect(totals[.archives]?.fileCount == 1)
        #expect(totals[.developer]?.fileCount == 1)
        #expect(totals.values.reduce(0) { $0 + $1.fileCount } == session.fileCount)
        // Folders without a location context take the category holding most of their bytes.
        let root = try #require(try await store.roots(sessionID: session.id).first)
        let children = try await store.children(of: root.id)
        #expect(children.first { $0.name == "Movies" }?.category == .media)
        #expect(children.first { $0.name == "Documents" }?.category == .documents)
    }

    @Test func progressIsReported() async throws {
        let f = try Fixture()
        for i in 0..<2_000 { try f.file("p/f\(i)", size: 8) }
        let counter = OSAllocatedCounter()
        _ = try await scan(f) { p in counter.record(p.filesVisited) }
        #expect(counter.calls > 0)
        #expect(counter.maxValue == 2_000)
    }

    @Test func pruningKeepsSummariesForTrends() async throws {
        let f = try Fixture()
        try f.file("a/x.bin", size: 5_000)
        let dbURL = f.databaseURL()
        let scanner = StorageScanner(databaseURL: dbURL, home: f.path)
        let config = ScanConfiguration(roots: [ScanRoot(path: f.path, kind: .folder)], smallFileThreshold: 1024)
        var ids: [Int64] = []
        for _ in 0..<3 { ids.append(try await scanner.scan(config) { _ in }.id) }
        let store = try LocalStore(url: dbURL)
        try await store.pruneIndexes(keep: 2)
        #expect(try await store.session(id: ids[0])?.hasIndex == false)
        #expect(try await store.roots(sessionID: ids[0]).isEmpty)
        #expect(try await store.session(id: ids[2])?.hasIndex == true)
        #expect(try await store.growth(path: f.path).count == 3)
        // The write-ahead log is handed back after pruning.
        let wal = (try? FileManager.default.attributesOfItem(atPath: dbURL.path + "-wal")[.size] as? Int) ?? 0
        #expect(wal <= DatabaseSchema.walSizeLimit)
        #expect(wal == 0)
    }
}

/// Small lock-protected counter for progress callbacks.
final class OSAllocatedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _max: Int64 = 0
    func record(_ value: Int64) {
        lock.lock(); _calls += 1; _max = max(_max, value); lock.unlock()
    }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var maxValue: Int64 { lock.lock(); defer { lock.unlock() }; return _max }
}
