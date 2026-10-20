import Foundation
import PureMacKit
import Testing
@testable import PureMac

/// The Duplicates page's choices: one copy of every file always stays.
@MainActor
@Suite("Duplicates choices")
struct DuplicatesModelTests {
    private func file(_ path: String, daysAgo: Double, inode: UInt64) -> DuplicateFile {
        DuplicateFile(path: path, identity: FileIdentity(device: 1, inode: inode, type: .regular, ownerUID: 501),
                      logicalSize: 1_000, allocatedSize: 4_096, modified: Date().addingTimeInterval(-daysAgo * 86_400))
    }

    private func model() -> DuplicatesModel {
        let video = DuplicateGroup(sha256: "a", size: 1_000, files: [
            file("/u/Downloads/clip.mov", daysAgo: 1, inode: 1),
            file("/u/Documents/clip.mov", daysAgo: 30, inode: 2),
            file("/u/Desktop/Old/clip.mov", daysAgo: 90, inode: 3),
        ])
        let pdf = DuplicateGroup(sha256: "b", size: 1_000, files: [
            file("/u/Downloads/tax.pdf", daysAgo: 2, inode: 4),
            file("/u/Documents/tax.pdf", daysAgo: 5, inode: 5),
        ])
        let model = DuplicatesModel()
        model._testSet(DuplicateScanResult(groups: [video, pdf], filesConsidered: 5), roots: ["/u/Downloads", "/u/Documents", "/u/Desktop"])
        return model
    }

    @Test func everyRuleKeepsExactlyOneCopyPerFile() {
        let model = model()
        for rule in DuplicatesModel.KeepRule.standard + [.inFolder("/u/Documents"), .inFolder("/nowhere")] {
            model.selectExtraCopies(keeping: rule)
            for group in model.result!.groups {
                #expect(model.selectedCount(in: group) == group.files.count - 1, "\(rule.id) in \(group.id)")
            }
        }
    }

    @Test func rulesPickTheExpectedKeeper() {
        let video = model().result!.groups.first { $0.sha256 == "a" }!
        #expect(DuplicatesModel.KeepRule.newest.keeper(in: video)?.path == "/u/Downloads/clip.mov")
        #expect(DuplicatesModel.KeepRule.oldest.keeper(in: video)?.path == "/u/Desktop/Old/clip.mov")
        #expect(DuplicatesModel.KeepRule.inFolder("/u/Documents").keeper(in: video)?.path == "/u/Documents/clip.mov")
        // A folder without a copy falls back to the newest copy.
        #expect(DuplicatesModel.KeepRule.inFolder("/u/Music").keeper(in: video)?.path == "/u/Downloads/clip.mov")
    }

    @Test func theLastKeptCopyCannotBeMarkedForRemoval() {
        let model = model()
        let pdf = model.result!.groups.first { $0.sha256 == "b" }!
        model.setRemove(true, pdf.files[0], in: pdf)
        model.setRemove(true, pdf.files[1], in: pdf)
        #expect(model.selectedCount(in: pdf) == 1)
        #expect(model.errorMessage != nil)
        model.keepOnly(pdf.files[1], in: pdf)
        #expect(model.selection.contains(pdf.files[0].path) && !model.selection.contains(pdf.files[1].path))
    }

    @Test func groupCheckboxAndFiltersOnlyTouchListedFiles() {
        let model = model()
        let video = model.result!.groups.first { $0.sha256 == "a" }!
        model.toggleGroup(video)
        #expect(model.selectedCount(in: video) == 2)
        model.toggleGroup(video)
        #expect(model.selectedCount(in: video) == 0)
        model.kindFilter = .document
        #expect(model.visibleGroups.map(\.sha256) == ["b"])
        model.setAllVisible(true)
        #expect(model.selectedCount(in: video) == 0)
        #expect(model.selection.count == 1)
        #expect(model.selectedBytes == 4_096)
        model.kindFilter = nil
        model.searchText = "Old"
        #expect(model.visibleGroups.map(\.sha256) == ["a"])
    }

    @Test func kindsAndFoldersAreSummarizedOnce() {
        let model = model()
        #expect(model.kindTotals.map(\.kind) == [.video, .document])
        // Downloads and Documents hold the same bytes: ties are ordered by name.
        #expect(model.folderTotals.map(\.folder) == ["/u/Documents", "/u/Downloads", "/u/Desktop"])
        #expect(model.folderTotals.reduce(0) { $0 + $1.bytes } == 5 * 4_096)
        #expect(model.selectedGroupID == model.visibleGroups.first?.id)
    }
}
