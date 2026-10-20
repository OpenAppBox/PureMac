import Foundation
import PureMacKit
import Testing
@testable import PureMac

/// After a cleanup the Storage Explorer shows the new folder sizes without a rescan.
@MainActor
@Suite("Explorer after cleanup", .serialized)
struct ExplorerIndexTests {
    @Test func openFolderShrinksAfterAMoveAndGrowsBackAfterPutBack() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("PureMacExplorerIndex-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        for (path, size) in [("models/big.bin", 400_000), ("models/small.bin", 100_000), ("other.bin", 50_000)] {
            let url = URL(fileURLWithPath: home + "/" + path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: size).write(to: url)
        }
        let app = AppModel()
        await app.bootstrap()
        _ = try await StorageScanner(databaseURL: app.databaseURL, home: home)
            .scan(ScanConfiguration(roots: [ScanRoot(path: home, kind: .folder)], smallFileThreshold: 8192, progressInterval: 0)) { _ in }
        await app.explorer.sessionDidChange()
        let models = try #require(app.explorer.rows.first { $0.name == "models" })
        let rootBefore = try #require(app.explorer.current).allocatedSize
        await app.explorer.open(models)
        let big = try #require(app.explorer.rows.first { $0.name == "big.bin" })

        let outcome = CleanupItemOutcome(path: big.path, status: .movedToTrash, allocatedSize: big.allocatedSize, logicalSize: big.logicalSize)
        await app.cleanupDidFinish(CleanupResult(planID: UUID(), operationID: nil, mode: .userFiles, startedAt: Date(), finishedAt: Date(),
                                                 outcomes: [outcome], wasCancelled: false, freeSpaceBefore: nil, freeSpaceAfter: nil))
        // The open folder, its rows and the breadcrumb above it all reflect the removal.
        #expect(app.explorer.current?.allocatedSize == models.allocatedSize - big.allocatedSize)
        #expect(!app.explorer.rows.contains { $0.name == "big.bin" })
        #expect(app.explorer.breadcrumbs.first?.allocatedSize == rootBefore - big.allocatedSize)
        #expect(app.scan.largestFiles.allSatisfy { $0.path != big.path })

        await app.adjustIndex([IndexChange(path: big.path, allocatedSize: big.allocatedSize, logicalSize: big.logicalSize)], restoring: true)
        #expect(app.explorer.current?.allocatedSize == models.allocatedSize)
        #expect(app.explorer.rows.contains { $0.name == "big.bin" })
    }

    /// The Logical column marks sizes inflated by sparse, compressed or iCloud-only data.
    @Test func logicalSizeHintOnlyForRealGaps() {
        func record(_ logical: Int64, _ allocated: Int64, container: Bool = true, flags: EntryFlags = []) -> FileRecord {
            FileRecord(id: 1, sessionID: 1, parentID: nil, depth: 1, kind: container ? .directory : .file, name: "x", path: "/x",
                       logicalSize: logical, allocatedSize: allocated, modified: nil, created: nil, fileCount: 1, directoryCount: 0,
                       smallFileCount: 0, smallFileLogical: 0, smallFileAllocated: 0, device: 1, inode: 1, flags: flags, category: .appData)
        }
        #expect(record(135_620_000_000, 32_940_000_000).logicalExceedsDisk)       // ~/Library with Docker.raw
        #expect(!record(2_170_000_000, 2_280_000_000).logicalExceedsDisk)         // normal: allocation ≥ logical
        #expect(!record(150_000_000, 90_000_000).logicalExceedsDisk)              // gap under 100 MB
        #expect(record(64_000_000_000, 750_000_000, container: false, flags: .sparseOrDataless).logicalExceedsDisk)
    }
}
