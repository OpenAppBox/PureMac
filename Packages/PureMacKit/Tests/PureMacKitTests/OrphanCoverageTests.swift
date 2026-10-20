import Foundation
import Testing
@testable import PureMacKit

/// What orphan detection finds beyond identifier-named items, and what it still leaves alone.
@Suite("Orphan detection — coverage")
struct OrphanCoverageTests {
    func detector(_ f: Fixture, known: [String: [String]] = [:]) -> OrphanDetector {
        OrphanDetector(home: f.path, catalog: .bundled(), launchServices: FakeLaunchServices(known: known), running: FakeRunningApps())
    }

    func old(_ f: Fixture, _ paths: String...) throws {
        for path in paths { try f.setModified(path, daysAgo: 200) }
    }

    // Folders named after the app, not its identifier, were never found.
    @Test func catalogFolderOfAMissingAppIsFound() async throws {
        let f = try Fixture("home")
        try f.file("Library/Application Support/Spotify/PersistentCache/blob", size: 9_000)
        try old(f, "Library/Application Support/Spotify/PersistentCache/blob", "Library/Application Support/Spotify/PersistentCache",
                "Library/Application Support/Spotify")
        let orphans = await detector(f).findOrphans(installedApps: [])
        let spotify = try #require(orphans.first { $0.path.hasSuffix("Application Support/Spotify") })
        #expect(spotify.inferredBundleIdentifier == "com.spotify.client")
        #expect(spotify.appName == "Spotify")
        #expect(spotify.evidence.contains { $0.kind == .curatedVendorPath })
    }

    // Another build of the same app (beta, App Store version) under a different identifier still uses the folder.
    @Test func catalogFolderStaysWhileAnAppWithThatNameIsInstalled() async throws {
        let f = try Fixture("home")
        try f.dir("Library/Application Support/Spotify")
        let bundle = try f.makeApp("Applications/Spotify.app", id: "com.example.spotify-beta", name: "Spotify")
        #expect(await detector(f).findOrphans(installedApps: [f.app(bundle)]).isEmpty)
    }

    // Catalog folders that can hold personal data are never "likely".
    @Test func catalogFolderWithAWarningNeedsReview() async throws {
        let f = try Fixture("home")
        try f.dir("Library/Application Support/Signal")
        try old(f, "Library/Application Support/Signal")
        let signal = try #require(await detector(f).findOrphans(installedApps: []).first)
        #expect(signal.confidence == .ambiguous)
        #expect(signal.evidence.contains { !$0.supportsRemoval })
    }

    // macOS keeps registering an app that is in the Trash, which hid exactly the leftovers people
    // look for right after uninstalling. Recent use is expected then, not a reason to doubt.
    @Test func leftoversOfAnAppInTheTrashAreFound() async throws {
        let f = try Fixture("home")
        let trashed = try f.makeApp(".Trash/Trashed.app", id: "com.trashed.app", name: "Trashed Pro")
        try f.file("Library/Caches/com.trashed.app/blob", size: 9_000)   // modified just now
        let orphans = await detector(f, known: ["com.trashed.app": [trashed]]).findOrphans(installedApps: [])
        let cache = try #require(orphans.first)
        #expect(cache.confidence == .likely)
        #expect(cache.appName == "Trashed Pro")
        #expect(cache.evidence.contains { $0.kind == .appInTrash })
        #expect(!cache.evidence.contains { $0.kind == .recentlyModified && !$0.supportsRemoval })
    }

    // An app registered anywhere outside a Trash is still installed.
    @Test func appRegisteredOutsideTheTrashIsNotAnOrphan() async throws {
        let f = try Fixture("home")
        try f.dir("Library/Caches/com.portable.app")
        try old(f, "Library/Caches/com.portable.app")
        let found = await detector(f, known: ["com.portable.app": ["/Volumes/USB/Portable.app", f.path(".Trash/Portable.app")]]).findOrphans(installedApps: [])
        #expect(found.isEmpty)
    }

    // Shared group containers: found when no installed app or developer team uses them, never "likely",
    // and left alone while any app of that developer team is installed (Microsoft Office's "UBF8T346G9.Office").
    @Test func groupContainersAreJudgedByTeamAndIdentifier() async throws {
        let f = try Fixture("home")
        try f.dir("Library/Group Containers/ABCDE12345.com.gone.shared")
        try f.dir("Library/Group Containers/group.com.gone.widgets")
        try f.dir("Library/Group Containers/UBF8T346G9.Office")
        try f.dir("Library/Group Containers/UBF8T346G9.com.microsoft.oneauth")
        try old(f, "Library/Group Containers/ABCDE12345.com.gone.shared", "Library/Group Containers/group.com.gone.widgets")
        let office = f.app(try f.makeApp("Applications/Microsoft Word.app", id: "com.microsoft.Word", name: "Microsoft Word"), team: "UBF8T346G9")
        let found = await detector(f).findOrphans(installedApps: [office])
        #expect(Set(found.map { ($0.path as NSString).lastPathComponent }) == ["ABCDE12345.com.gone.shared", "group.com.gone.widgets"])
        #expect(found.allSatisfy { $0.confidence == .ambiguous && $0.kind == .groupContainer })
    }

    // Catalog warnings were shown in English in every language.
    @Test func everyCatalogWarningIsLocalizable() throws {
        let catalog = OwnershipCatalog.bundled()
        let warnings = Set(catalog.apps.flatMap { $0.paths.compactMap(\.warning) } + catalog.criticalContainers.map(\.warning))
        #expect(!warnings.isEmpty)
        let url = LocalizationTests.catalogs[0]
        let strings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])["strings"] as? [String: Any]
        for warning in warnings { #expect(strings?[warning] != nil, "No translations for catalog warning “\(warning)”") }
    }
}
