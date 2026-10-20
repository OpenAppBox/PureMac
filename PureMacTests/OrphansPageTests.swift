import Foundation
import PureMacKit
import Testing
@testable import PureMac

/// The Orphaned Remnants page: grouping per removed app, names, and selection.
@MainActor
@Suite("Orphaned Remnants page")
struct OrphansPageTests {
    private func orphan(_ path: String, id: String, likely: Bool, bytes: Int64, daysAgo: Double = 100) -> OrphanCandidate {
        var item = OrphanCandidate(path: path, inferredBundleIdentifier: id, kind: .cache, confidence: likely ? .likely : .ambiguous,
                                   evidence: [], allocatedSize: bytes, modified: Date().addingTimeInterval(-daysAgo * 86_400),
                                   identity: FileIdentity(device: 1, inode: UInt64(abs(path.hashValue) % 100_000), type: .directory, ownerUID: 501))
        item.logicalSize = bytes
        return item
    }

    private func model() -> AppsModel {
        let model = AppsModel()
        model._testSet(orphans: [
            orphan("/u/Library/Caches/com.gone.big", id: "com.gone.big", likely: true, bytes: 5_000),
            orphan("/u/Library/Preferences/com.gone.big.plist", id: "com.gone.big", likely: true, bytes: 10),
            orphan("/u/Library/Application Support/com.gone.big", id: "com.gone.big", likely: false, bytes: 900, daysAgo: 2),
            orphan("/u/Library/Caches/io.tunnelbox.client", id: "io.tunnelbox.client", likely: false, bytes: 300),
        ])
        return model
    }

    @Test func itemsAreGroupedPerRemovedApp() {
        let model = model()
        #expect(model.orphanGroups.count == 2)
        let big = try? #require(model.orphanGroups.first { $0.id == "com.gone.big" })
        #expect(big?.items.count == 3)
        #expect(big?.bytes == 5_910)
        #expect(big?.likelyCount == 2)
        #expect(model.visibleOrphanGroups.first?.id == "com.gone.big", "largest first")
        #expect(model.selectedOrphanGroupID == "com.gone.big")
    }

    // "Select All Likely" looked dead once everything likely was selected (it only disabled itself);
    // it now toggles, so pressing it again clears those items.
    @Test func selectAllLikelyToggles() {
        let model = model()
        model.toggleLikelyOrphans()
        #expect(model.orphanSelection.count == 2)
        #expect(model.allLikelyOrphansSelected)
        model.toggleLikelyOrphans()
        #expect(model.orphanSelection.isEmpty)
    }

    @Test func groupCheckboxPicksLikelyItemsFirst() throws {
        let model = model()
        let big = try #require(model.orphanGroups.first { $0.id == "com.gone.big" })
        model.toggleOrphanGroup(big)
        #expect(model.selectedCount(in: big) == 2, "the ambiguous item stays unselected")
        model.toggleOrphanGroup(big)
        #expect(model.selectedCount(in: big) == 0)
        let tunnel = try #require(model.orphanGroups.first { $0.id == "io.tunnelbox.client" })
        model.toggleOrphanGroup(tunnel)
        #expect(model.selectedCount(in: tunnel) == 1, "with nothing likely, the checkbox picks what is there")
    }

    @Test func filtersAndSearch() {
        let model = model()
        model.orphanFilter = .review
        #expect(Set(model.visibleOrphanGroups.map(\.id)) == ["com.gone.big", "io.tunnelbox.client"])
        model.orphanFilter = .likely
        #expect(model.visibleOrphanGroups.map(\.id) == ["com.gone.big"])
        model.orphanFilter = .all
        model.orphanSearch = "tunnel"
        #expect(model.visibleOrphanGroups.map(\.id) == ["io.tunnelbox.client"])
    }

    @Test func readableNames() {
        #expect(RemovedApp.readableName(of: "com.microsoft.OneDriveStandaloneUpdater") == "One Drive Standalone Updater")
        #expect(RemovedApp.readableName(of: "com.adobe.Acrobat.Pro") == "Acrobat Pro")
        #expect(RemovedApp.readableName(of: "com.openai.chat") == "Openai Chat")
        #expect(RemovedApp.readableName(of: "io.tunnelbox.client") == "Tunnelbox")
        #expect(RemovedApp.readableName(of: "com.microsoft.SharePoint-mac") == "Share Point")
        #expect(RemovedApp.readableName(of: "com.parallax.videoconverter") == "Videoconverter")
        #expect(RemovedApp.vendorName(of: "com.parallax.videoconverter") == "Parallax")
        #expect(RemovedApp.vendorName(of: "com.app.x") == nil)
    }

    // A second caller returned at once while discovery was still running, so the orphan search ran
    // against an empty app list: extensions and helpers of installed apps (OneDrive's FileProvider,
    // Affinity's extensions…) were listed as "Likely" leftovers.
    @Test(.timeLimit(.minutes(1))) func concurrentLoadsWaitForTheAppList() async {
        let model = AppsModel()
        async let first: Void = model.load()
        async let second: Void = model.load()
        _ = await second
        #expect(!model.apps.isEmpty, "the second caller must see the complete list")
        _ = await first
    }
}
