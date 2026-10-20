import Foundation
import PureMacKit
import Testing
@testable import PureMac

/// Overview's "Largest Folders" after a whole-disk scan: no folder next to the subfolder that
/// holds nearly all of it, no folders from inside app bundles, and a location for each row.
@MainActor
@Suite("Overview lists")
struct OverviewListTests {
    func folder(_ id: Int64, _ path: String, parent: Int64?, size: Int64, kind: EntryKind = .directory) -> FileRecord {
        FileRecord(id: id, sessionID: 1, parentID: parent, depth: path.split(separator: "/").count, kind: kind,
                   name: (path as NSString).lastPathComponent, path: path, logicalSize: size, allocatedSize: size,
                   modified: nil, created: nil, fileCount: 1, directoryCount: 0, smallFileCount: 0, smallFileLogical: 0,
                   smallFileAllocated: 0, device: 1, inode: UInt64(id), flags: [], category: .unclassified)
    }

    @Test func passThroughAndPackageFoldersAreLeftOut() {
        let list = [
            folder(1, "/Users", parent: 0, size: 100),
            folder(2, "/Users/alex", parent: 1, size: 99),               // holds 99% of /Users
            folder(3, "/Applications", parent: 0, size: 60),
            folder(4, "/Applications/Big.app", parent: 3, size: 20, kind: .package),
            folder(5, "/Applications/Big.app/Contents", parent: 4, size: 20),
            folder(6, "/Users/alex/Library", parent: 2, size: 40),       // 40% of alex: both stay
        ]
        let names = ScanModel.withoutPassThroughFolders(list).map(\.path)
        #expect(names == ["/Users/alex", "/Applications", "/Applications/Big.app", "/Users/alex/Library"])
    }

    @Test func rowsSayWhereTheFolderIs() {
        #expect(locationCaption(folder(1, "/Applications", parent: nil, size: 1)) == nil)
        #expect(locationCaption(folder(2, "/System/Library/AssetsV2", parent: nil, size: 1)) == "/System/Library")
        #expect(locationCaption(folder(3, PathTools.userHome + "/Library", parent: nil, size: 1)) == "~")
    }
}
