import Foundation
import Testing
@testable import PureMacKit

/// Moving items to the Trash updates the scan index in place: folders shrink, removed items
/// disappear from every listing, and Put Back restores the exact numbers — without a rescan.
@Suite("Index adjustment after cleanup")
struct IndexAdjustmentTests {
    private struct Totals: Equatable {
        var rootLogical: Int64, rootAllocated: Int64, rootFiles: Int64, rootDirs: Int64
        var sessionLogical: Int64, sessionAllocated: Int64, sessionFiles: Int64
        var categoryAllocated: Int64
    }

    private func scan(_ f: Fixture) async throws -> (ScanSession, LocalStore) {
        let url = f.databaseURL()
        let config = ScanConfiguration(roots: [ScanRoot(path: f.path, kind: .folder)], smallFileThreshold: 8192, progressInterval: 0)
        let session = try await StorageScanner(databaseURL: url, home: f.path).scan(config) { _ in }
        return (session, try LocalStore(url: url))
    }

    private func totals(_ store: LocalStore, _ id: Int64) async throws -> Totals {
        let root = try #require(try await store.roots(sessionID: id).first)
        let session = try #require(try await store.session(id: id))
        let categories = try await store.categoryTotals(sessionID: id).reduce(0) { $0 + $1.allocatedSize }
        return Totals(rootLogical: root.logicalSize, rootAllocated: root.allocatedSize, rootFiles: root.fileCount, rootDirs: root.directoryCount,
                      sessionLogical: session.logicalSize, sessionAllocated: session.allocatedSize, sessionFiles: session.fileCount,
                      categoryAllocated: categories)
    }

    private func fixture() throws -> Fixture {
        let f = try Fixture()
        try f.file("a/one.bin", size: 100_000)
        try f.file("a/b/big.bin", size: 300_000)
        try f.file("a/b/c/deep.bin", size: 50_000)
        try f.file("other.bin", size: 20_000)
        try f.file("note.txt", size: 100)
        return f
    }

    private func change(_ store: LocalStore, _ id: Int64, _ path: String) async throws -> IndexChange {
        let record = try #require(try await store.entry(sessionID: id, path: path))
        return IndexChange(path: path, allocatedSize: record.allocatedSize, logicalSize: record.logicalSize)
    }

    @Test func removingAFileShrinksEveryFolderAboveIt() async throws {
        let f = try fixture()
        let (session, store) = try await scan(f)
        let before = try await totals(store, session.id)
        let big = try #require(try await store.entry(sessionID: session.id, path: f.path("a/b/big.bin")))
        let a = try #require(try await store.entry(sessionID: session.id, path: f.path("a")))

        let result = try await store.applyRemoval(sessionID: session.id, changes: [try await change(store, session.id, big.path)])
        #expect(result.adjustedItems == 1)
        let after = try await totals(store, session.id)
        #expect(after.rootLogical == before.rootLogical - big.logicalSize)
        #expect(after.rootAllocated == before.rootAllocated - big.allocatedSize)
        #expect(after.rootFiles == before.rootFiles - 1)
        #expect(after.sessionAllocated == before.sessionAllocated - big.allocatedSize)
        #expect(after.categoryAllocated == before.categoryAllocated - big.allocatedSize)
        let aAfter = try #require(try await store.entry(id: a.id))
        #expect(aAfter.allocatedSize == a.allocatedSize - big.allocatedSize)
        // Gone from every listing.
        #expect(try await store.files(sessionID: session.id, query: FileQuery()).allSatisfy { $0.path != big.path })
        #expect(try await store.search(sessionID: session.id, text: "big").isEmpty)
        let b = try #require(try await store.entry(sessionID: session.id, path: f.path("a/b")))
        #expect(try await store.children(of: b.id).allSatisfy { $0.path != big.path })
    }

    @Test func removingAFolderHidesEverythingInsideAndRestoreIsExact() async throws {
        let f = try fixture()
        let (session, store) = try await scan(f)
        let before = try await totals(store, session.id)
        let a = try #require(try await store.entry(sessionID: session.id, path: f.path("a")))
        let changeA = IndexChange(path: a.path, allocatedSize: a.allocatedSize, logicalSize: a.logicalSize)

        _ = try await store.applyRemoval(sessionID: session.id, changes: [changeA])
        let removed = try await totals(store, session.id)
        #expect(removed.rootAllocated == before.rootAllocated - a.allocatedSize)
        #expect(removed.rootDirs == before.rootDirs - a.directoryCount - 1)
        #expect(try await store.files(sessionID: session.id, query: FileQuery()).allSatisfy { !$0.path.hasPrefix(a.path + "/") })
        #expect(try await store.largestDirectories(sessionID: session.id).allSatisfy { !PathTools.isSameOrInside($0.path, a.path) })
        // Applying the same removal again changes nothing.
        let again = try await store.applyRemoval(sessionID: session.id, changes: [changeA])
        #expect(again.adjustedItems == 0)
        #expect(try await totals(store, session.id) == removed)

        let restored = try await store.applyRestore(sessionID: session.id, changes: [changeA])
        #expect(restored.adjustedItems == 1)
        #expect(try await totals(store, session.id) == before)
        #expect(try await store.files(sessionID: session.id, query: FileQuery()).contains { $0.path == f.path("a/b/c/deep.bin") })
    }

    @Test func aFileRemovedEarlierStaysRemovedWhenItsFolderIsPutBack() async throws {
        let f = try fixture()
        let (session, store) = try await scan(f)
        let before = try await totals(store, session.id)
        let deep = try await change(store, session.id, f.path("a/b/c/deep.bin"))
        _ = try await store.applyRemoval(sessionID: session.id, changes: [deep])
        let a = try await change(store, session.id, f.path("a"))   // already without deep.bin
        _ = try await store.applyRemoval(sessionID: session.id, changes: [a])
        _ = try await store.applyRestore(sessionID: session.id, changes: [a])
        let after = try await totals(store, session.id)
        #expect(after.rootAllocated == before.rootAllocated - deep.allocatedSize)
        #expect(try await store.files(sessionID: session.id, query: FileQuery()).allSatisfy { $0.path != deep.path })
        #expect(try await store.files(sessionID: session.id, query: FileQuery()).contains { $0.path == f.path("a/one.bin") })
        _ = try await store.applyRestore(sessionID: session.id, changes: [deep])
        #expect(try await totals(store, session.id) == before)
    }

    @Test func smallFilesAreTakenOffTheirFolderButUnknownLargeFilesAreNot() async throws {
        let f = try fixture()
        let (session, store) = try await scan(f)
        let before = try await totals(store, session.id)
        let st = try FileStat.lstat(f.path("note.txt")).get()
        let note = IndexChange(path: f.path("note.txt"), allocatedSize: st.allocatedSize, logicalSize: st.logicalSize)
        #expect(try await store.applyRemoval(sessionID: session.id, changes: [note]).adjustedItems == 1)
        let after = try await totals(store, session.id)
        #expect(after.rootLogical == before.rootLogical - st.logicalSize)
        #expect(after.rootFiles == before.rootFiles - 1)
        let root = try #require(try await store.roots(sessionID: session.id).first)
        #expect(root.smallFileCount == 0)
        // A large file the scan never saw (created afterwards) must not reduce anything.
        let unseen = IndexChange(path: f.path("a/new-download.zip"), allocatedSize: 5_000_000_000, logicalSize: 5_000_000_000)
        #expect(try await store.applyRemoval(sessionID: session.id, changes: [unseen]).adjustedItems == 0)
        // Nor does anything outside the scan.
        let outside = IndexChange(path: "/elsewhere/file.txt", allocatedSize: 10, logicalSize: 10)
        #expect(try await store.applyRemoval(sessionID: session.id, changes: [outside]).adjustedItems == 0)
        #expect(try await totals(store, session.id) == after)
        _ = try await store.applyRestore(sessionID: session.id, changes: [note])
        #expect(try await totals(store, session.id) == before)
    }
}
