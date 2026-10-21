import Foundation
import Testing
@testable import PureMacKit

/// Regression tests for bugs found in the 0.13 stability review. Each test describes the failure it prevents.
@Suite("Regressions 0.13")
struct Review013Tests {
    private func duplicatePair(_ f: Fixture) throws -> (group: DuplicateGroup, remove: DuplicateFile, keep: DuplicateFile) {
        try f.file("Documents/a.bin", size: 50_000, byte: 5)
        try f.file("Documents/b.bin", size: 50_000, byte: 5)
        let group = try #require(DuplicateFinder(minimumSize: 1_000, sampleSize: 512, chunkSize: 4_096).find(roots: [f.path]).groups.first)
        return (group, group.files[0], group.files[1])
    }

    /// Rewrites the start of a file in place: same inode, new content (how many apps save).
    private func editInPlace(_ path: String) throws {
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.write(contentsOf: Data(repeating: 9, count: 100))
        try handle.close()
    }

    private func preflight(_ candidate: CleanupCandidate, home: String) -> Preflight.Verdict {
        Preflight(policy: SafetyPolicy(homeDirectory: home)).check(candidate, runningIdentifiers: [], runningPaths: [])
    }

    // Identity (device + inode) was the only check, so a copy edited in place after the search —
    // no longer a duplicate — was still moved to the Trash as one.
    @Test func duplicateEditedInPlaceIsNotRemoved() throws {
        let f = try Fixture()
        let (group, remove, _) = try duplicatePair(f)
        let candidate = try #require(CleanupPlanner.duplicateCandidates(groups: [group], selectedPaths: [remove.path],
                                                                       policy: SafetyPolicy(homeDirectory: f.path)).candidates.first)
        #expect(preflight(candidate, home: f.path) == .proceed)
        try editInPlace(remove.path)
        guard case .skip = preflight(candidate, home: f.path) else {
            Issue.record("An edited copy must not be removed as a duplicate")
            return
        }
    }

    // The kept copy edited in place: the copy being removed may now be the only one of its content.
    @Test func editedKeptCopyBlocksRemovalOfTheOther() throws {
        let f = try Fixture()
        let (group, remove, keep) = try duplicatePair(f)
        let candidate = try #require(CleanupPlanner.duplicateCandidates(groups: [group], selectedPaths: [remove.path],
                                                                       policy: SafetyPolicy(homeDirectory: f.path)).candidates.first)
        try editInPlace(keep.path)
        guard case .skip = preflight(candidate, home: f.path) else {
            Issue.record("Removing a copy whose kept twin changed could remove the last copy of that content")
            return
        }
        // Planning again sees it too.
        let replanned = try CleanupPlanner.duplicateCandidates(groups: [group], selectedPaths: [remove.path], policy: SafetyPolicy(homeDirectory: f.path))
        #expect(replanned.candidates.isEmpty)
    }

    // Progress was posted once per file while comparing contents — thousands of main-actor updates.
    @Test func duplicateProgressIsThrottled() throws {
        let f = try Fixture()
        for i in 0..<300 { try f.file("Documents/f\(i).bin", size: 2_000, byte: UInt8(i % 2)) }
        let reports = Counter()
        _ = DuplicateFinder(minimumSize: 1_000, sampleSize: 512, chunkSize: 4_096).find(roots: [f.path], progress: { _, _, total in
            if total > 0 { reports.increment() }
        })
        #expect(reports.value < 50, "\(reports.value) progress reports for 300 files")
        #expect(reports.value >= 1, "the final count is always reported")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
