import Foundation
import Testing
@testable import PureMacKit

/// Regression tests for bugs found in the 0.12 review. Each test describes the failure it prevents.
@Suite("Regressions")
struct RegressionTests {
    // macOS volumes are case-insensitive by default: "keychains" *is* "Keychains".
    @Test func protectedLocationsMatchCaseInsensitively() throws {
        let f = try Fixture("home")
        try f.dir("Library/Keychains")
        try f.dir("Documents")
        try f.dir(".Trash")
        let policy = SafetyPolicy(homeDirectory: f.path)
        for path in ["Library/keychains", "Library/KEYCHAINS/login.keychain-db", "documents", ".trash/old.zip",
                     "Library/caches", "Library/application support/MobileSync"] {
            #expect(!policy.evaluate(f.path(path), intent: .userSelected).isAllowed, "\(path) must stay protected")
        }
        try f.dir("Library/Developer/Xcode/Archives")
        #expect(!policy.evaluate(f.path("Library/developer/xcode/archives/A"), intent: .ruleCleanup,
                                 allowedRoots: [f.path("Library/Developer")]).isAllowed)
    }

    // Scanning the whole Data volume plus a folder in the home folder scanned that folder twice:
    // /Users/… is the same place as /System/Volumes/Data/Users/… (a firmlink).
    @Test func rootsInsideTheDataVolumeAreNotScannedTwice() {
        let data = ScanRoot(path: "/System/Volumes/Data", kind: .dataVolume)
        let users = ScanRoot(path: "/Users", kind: .folder)
        #expect(ScanConfiguration(roots: [data, users]).effectiveRoots.map(\.path) == ["/System/Volumes/Data"])
        #expect(ScanConfiguration(roots: [users, data]).effectiveRoots.map(\.path) == ["/System/Volumes/Data"])
        // An external volume is a different device and stays a separate root.
        let external = ScanRoot(path: "/Volumes", kind: .externalVolume)
        #expect(ScanConfiguration(roots: [data, external]).effectiveRoots.count == 2)
    }

    // A folder named after an installed app's *app group* (e.g. in Application Scripts) was
    // reported as a likely orphan.
    @Test func appGroupFoldersOfInstalledAppsAreNotOrphans() async throws {
        let f = try Fixture("home")
        let bundle = try f.makeApp("Applications/Vendor.app", id: "com.vendor.app")
        let app = f.app(bundle, groups: ["group.com.vendor.shared"])
        for path in ["Library/Application Scripts/group.com.vendor.shared", "Library/Caches/group.com.vendor.shared",
                     "Library/Application Scripts/group.com.vendor.other"] {
            try f.dir(path)
            try f.setModified(path, daysAgo: 200)
        }
        let orphans = await OrphanDetector(home: f.path, catalog: .bundled(), launchServices: FakeLaunchServices(),
                                           running: FakeRunningApps()).findOrphans(installedApps: [app])
        #expect(!orphans.contains { $0.inferredBundleIdentifier.lowercased() == "group.com.vendor.shared" })
        // Another group of the same, still-installed vendor is at most ambiguous, never likely.
        #expect(orphans.filter { $0.inferredBundleIdentifier.lowercased().hasPrefix("group.com.vendor.") }.allSatisfy { $0.confidence != .likely })
    }

    @Test func groupFoldersOfRemovedAppsCanStillBeOrphans() async throws {
        let f = try Fixture("home")
        try f.dir("Library/Application Scripts/group.com.gone.shared")
        try f.setModified("Library/Application Scripts/group.com.gone.shared", daysAgo: 200)
        let orphans = await OrphanDetector(home: f.path, catalog: .bundled(), launchServices: FakeLaunchServices(),
                                           running: FakeRunningApps()).findOrphans(installedApps: [])
        #expect(orphans.contains { $0.inferredBundleIdentifier == "group.com.gone.shared" && $0.confidence == .likely })
    }

    // Removing "the other copies" must never remove the last one: if the copy meant to be kept
    // disappeared or changed after the duplicate search, nothing is planned.
    @Test func duplicatesAreNotPlannedWhenTheKeptCopyIsGone() throws {
        let f = try Fixture()
        try f.file("Documents/a.bin", size: 50_000, byte: 5)
        try f.file("Documents/b.bin", size: 50_000, byte: 5)
        let group = try #require(DuplicateFinder(minimumSize: 1_000, sampleSize: 512, chunkSize: 4_096).find(roots: [f.path]).groups.first)
        let remove = group.files[0], keep = group.files[1]
        try FileManager.default.removeItem(atPath: keep.path)
        let planned = try CleanupPlanner.duplicateCandidates(groups: [group], selectedPaths: [remove.path], policy: SafetyPolicy(homeDirectory: f.path))
        #expect(planned.candidates.isEmpty)
        #expect(planned.rejected.map(\.0) == [remove.path])
    }

    // Overlapping search folders visited files twice and reported them as hard links.
    @Test func overlappingDuplicateRootsAreSearchedOnce() throws {
        let f = try Fixture()
        try f.file("Documents/a.bin", size: 50_000, byte: 7)
        try f.file("Documents/b.bin", size: 50_000, byte: 7)
        let result = DuplicateFinder(minimumSize: 1_000, sampleSize: 512, chunkSize: 4_096)
            .find(roots: [f.path, f.path("Documents"), f.path("Documents/")])
        let group = try #require(result.groups.first)
        #expect(group.files.count == 2)
        #expect(group.files.allSatisfy { $0.hardLinkPaths.isEmpty })
        #expect(result.hardLinkSetsIgnored == 0)
        #expect(result.filesConsidered == 2)
    }

    // "Not an Orphan — Ignore" on a preferences file stored "com.x.app.plist", which never matched
    // the identifier "com.x.app", so the item kept coming back.
    @Test func ignoringAnItemWithASuffixIgnoresItsIdentifier() async throws {
        let f = try Fixture("home")
        try f.file("Library/Preferences/com.ignored.app.plist", size: 2_000)
        try f.dir("Library/Saved Application State/com.ignored.app.savedState")
        let detector = OrphanDetector(home: f.path, catalog: .bundled(), launchServices: FakeLaunchServices(), running: FakeRunningApps())
        #expect(await !detector.findOrphans(installedApps: []).isEmpty)
        #expect(await detector.findOrphans(installedApps: [], ignoredIdentifiers: ["com.ignored.app.plist"]).isEmpty)
    }
}
