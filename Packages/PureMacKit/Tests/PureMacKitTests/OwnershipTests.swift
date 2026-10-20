import Foundation
import Testing
@testable import PureMacKit

@Suite("Application discovery")
struct DiscoveryTests {
    @Test func discoversBundlesWithMetadataAndHelpers() async throws {
        let f = try Fixture()
        try f.makeApp("Applications/Alpha.app", id: "com.example.alpha", name: "Alpha", helpers: [("AlphaLauncher", "com.example.alpha.launcher")])
        try f.makeApp("Applications/Vendor/Beta.app", id: "com.example.beta")
        try f.makeApp("Applications/Broken.app", id: nil)
        try f.dir("Applications/NotAnApp.app")        // no Info.plist → ignored
        try f.symlink("Applications/Link.app", to: f.path("Applications/Alpha.app")) // symlink not followed
        let discoverer = AppDiscoverer(roots: [.init(path: f.path("Applications"), isSystem: false)], inspectSigning: false)
        let apps = await discoverer.discover()
        #expect(apps.map(\.name).sorted() == ["Alpha", "Beta", "Broken"])
        let alpha = try #require(apps.first { $0.name == "Alpha" })
        #expect(alpha.bundleIdentifier == "com.example.alpha")
        #expect(alpha.version == "1.2.3")
        #expect(alpha.helperBundleIdentifiers == ["com.example.alpha.launcher"])
        #expect(!alpha.isProtected)
    }

    @Test func systemRootAppsAreProtected() async throws {
        let f = try Fixture()
        try f.makeApp("System/Applications/Calc.app", id: "com.apple.calculator")
        let apps = await AppDiscoverer(roots: [.init(path: f.path("System/Applications"), isSystem: true)], inspectSigning: false).discover()
        #expect(apps.first?.isProtected == true)
        #expect(apps.first?.source == .system)
    }

    @Test func masReceiptMarksAppStoreSource() throws {
        let f = try Fixture()
        let path = try f.makeApp("Applications/Store.app", id: "com.example.store")
        try f.file("Applications/Store.app/Contents/_MASReceipt/receipt", size: 10)
        #expect(AppDiscoverer.inspect(bundlePath: path, isSystemRoot: false, inspectSigning: false)?.source == .appStore)
    }

    @Test func realSigningInspectionOfASystemApp() {
        // Read-only inspection of a real macOS app; skipped if absent.
        let path = "/System/Applications/Calculator.app"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let info = CodeSigningInspector.inspect(bundlePath: path)
        #expect(info.kind == .apple)
    }
}

@Suite("Ownership engine")
struct OwnershipTests {
    func setup() throws -> (Fixture, AssociationFinder) {
        let f = try Fixture("home")
        return (f, AssociationFinder(home: f.path, systemLibraryPath: f.path("SystemLibrary"), catalog: .bundled()))
    }

    @Test func exactIdentifierMatchesAreConfirmed() async throws {
        let (f, finder) = try setup()
        let bundle = try f.makeApp("Applications/Alpha.app", id: "com.example.Alpha", name: "Alpha")
        try f.file("Library/Caches/com.example.Alpha/cache.db", size: 5_000)
        try f.file("Library/Preferences/com.example.Alpha.plist", size: 100)
        try f.file("Library/Preferences/ByHost/com.example.Alpha.0A1B2C3D-1111-2222-3333-444455556666.plist", size: 100)
        try f.file("Library/Containers/com.example.Alpha/Data/x", size: 100)
        try f.file("Library/Saved Application State/com.example.Alpha.savedState/window.data", size: 100)
        try f.file("Library/HTTPStorages/com.example.Alpha.binarycookies", size: 100)
        try f.file("Library/Application Support/com.example.Alpha/db.sqlite", size: 100)
        let app = f.app(bundle)
        let found = await finder.associations(for: app, allApps: [app])
        let byKind = Dictionary(grouping: found, by: \.kind)
        #expect(byKind[.appBundle]?.count == 1)
        #expect(byKind[.cache]?.first?.confidence == .confirmed)
        #expect(byKind[.preferences]?.count == 2)
        #expect(byKind[.container]?.first?.confidence == .confirmed)
        #expect(byKind[.savedState]?.count == 1)
        #expect(byKind[.httpStorage]?.count == 1)
        #expect(byKind[.applicationSupport]?.first?.confidence == .confirmed)
        #expect(found.allSatisfy { !$0.evidence.isEmpty })
        #expect(byKind[.cache]?.first?.allocatedSize ?? 0 > 0)
    }

    @Test func caseInsensitiveIdentifierAndPrefixMatch() async throws {
        let (f, finder) = try setup()
        let bundle = try f.makeApp("Applications/Alpha.app", id: "com.example.alpha")
        try f.dir("Library/Caches/COM.EXAMPLE.ALPHA")
        try f.dir("Library/Caches/com.example.alpha.ShipIt")
        let app = f.app(bundle)
        let found = await finder.associations(for: app, allApps: [app]).filter { $0.kind == .cache }
        #expect(found.count == 2)
        #expect(found.first { $0.name == "com.example.alpha.ShipIt" }?.confidence == .likely)
    }

    @Test func substringsAndNamePrefixesAreNotMatches() async throws {
        let (f, finder) = try setup()
        let bundle = try f.makeApp("Applications/Note.app", id: "com.example.note", name: "Note")
        try f.dir("Library/Caches/com.example.notebook")        // not a dotted extension
        try f.dir("Library/Caches/com.example.note-backup")     // not a dotted extension
        try f.dir("Library/Application Support/Notes")          // similar name, not exact
        try f.dir("Library/Application Support/MyNote")         // substring
        try f.dir("Library/Caches/com.example")                 // vendor only
        let app = f.app(bundle)
        let found = await finder.associations(for: app, allApps: [app])
        #expect(found.map(\.kind) == [.appBundle])
    }

    @Test func nameOnlyMatchIsAmbiguous() async throws {
        let (f, finder) = try setup()
        let bundle = try f.makeApp("Applications/Zephyr.app", id: "io.zephyr.desktop", name: "Zephyr")
        try f.dir("Library/Application Support/Zephyr")
        let app = f.app(bundle)
        let found = await finder.associations(for: app, allApps: [app])
        let support = try #require(found.first { $0.kind == .applicationSupport })
        #expect(support.confidence == .ambiguous)
        #expect(support.evidence.contains { $0.kind == .nameMatchOnly && !$0.supportsRemoval })
    }

    @Test func duplicateBundleNamesAreNotAttributedByName() async throws {
        let (f, finder) = try setup()
        let a = try f.makeApp("Applications/Studio.app", id: "com.vendora.studio", name: "Studio")
        let b = try f.makeApp("Applications/Other/Studio.app", id: "com.vendorb.studio", name: "Studio")
        try f.dir("Library/Application Support/Studio")
        let appA = f.app(a), appB = f.app(b)
        let found = await finder.associations(for: appA, allApps: [appA, appB])
        #expect(!found.contains { $0.kind == .applicationSupport })
    }

    @Test func mostSpecificInstalledOwnerWins() async throws {
        let (f, finder) = try setup()
        let base = try f.makeApp("Applications/Base.app", id: "com.example.app")
        let pro = try f.makeApp("Applications/Pro.app", id: "com.example.app.pro")
        try f.dir("Library/Caches/com.example.app.pro")
        try f.dir("Library/Caches/com.example.app.pro.helper")
        let baseApp = f.app(base), proApp = f.app(pro)
        let forBase = await finder.associations(for: baseApp, allApps: [baseApp, proApp])
        #expect(!forBase.contains { $0.kind == .cache })
        let forPro = await finder.associations(for: proApp, allApps: [baseApp, proApp])
        #expect(forPro.filter { $0.kind == .cache }.count == 2)
    }

    @Test func helperIdentifierDeclaredByTwoAppsIsShared() async throws {
        let (f, finder) = try setup()
        let a = try f.makeApp("Applications/A.app", id: "com.suite.a", helpers: [("Agent", "com.suite.agent")])
        let b = try f.makeApp("Applications/B.app", id: "com.suite.b", helpers: [("Agent", "com.suite.agent")])
        try f.dir("Library/Application Support/com.suite.agent")
        let appA = f.app(a), appB = f.app(b)
        let found = await finder.associations(for: appA, allApps: [appA, appB])
        #expect(found.first { $0.kind == .applicationSupport }?.confidence == .shared)
    }

    @Test func groupContainersNeedEntitlementEvidenceAndSharedIsShared() async throws {
        let (f, finder) = try setup()
        let a = try f.makeApp("Applications/A.app", id: "com.team.a")
        let b = try f.makeApp("Applications/B.app", id: "com.team.b")
        try f.dir("Library/Group Containers/TEAM123.com.team.shared")
        try f.dir("Library/Group Containers/TEAM123.com.team.aonly")
        try f.dir("Library/Group Containers/TEAM123.com.team.undeclared")
        try f.dir("Library/Group Containers/group.com.apple.notes")
        let appA = f.app(a, groups: ["TEAM123.com.team.shared", "TEAM123.com.team.aonly"], team: "TEAM123")
        let appB = f.app(b, groups: ["TEAM123.com.team.shared"], team: "TEAM123")
        let found = await finder.associations(for: appA, allApps: [appA, appB]).filter { $0.kind == .groupContainer }
        #expect(found.first { $0.name == "TEAM123.com.team.shared" }?.confidence == .shared)
        #expect(found.first { $0.name == "TEAM123.com.team.aonly" }?.confidence == .likely)
        #expect(found.first { $0.name == "TEAM123.com.team.undeclared" }?.confidence == .ambiguous)
        #expect(!found.contains { $0.name.contains("apple") })
    }

    @Test func launchAgentsByProgramPathAndLabel() async throws {
        let (f, finder) = try setup()
        let bundle = try f.makeApp("Applications/Sync.app", id: "com.example.sync")
        try f.writePlist("Library/LaunchAgents/com.example.sync.agent.plist", ["Label": "com.example.sync.agent", "Program": bundle + "/Contents/MacOS/main"])
        try f.writePlist("Library/LaunchAgents/com.example.sync.updater.plist", ["Label": "com.example.sync.updater", "ProgramArguments": ["/usr/local/bin/updater"]])
        try f.writePlist("Library/LaunchAgents/org.unrelated.job.plist", ["Label": "org.unrelated.job", "Program": "/usr/bin/true"])
        let app = f.app(bundle)
        let agents = await finder.associations(for: app, allApps: [app]).filter { $0.kind == .launchAgent }
        #expect(agents.count == 2)
        #expect(agents.first { $0.name.hasSuffix("agent.plist") }?.confidence == .confirmed)
        #expect(agents.first { $0.name.hasSuffix("updater.plist") }?.confidence == .likely)
    }

    @Test func systemLevelItemsRequireAdministrator() async throws {
        let (f, finder) = try setup()
        let bundle = try f.makeApp("Applications/Daemon.app", id: "com.example.daemon")
        try f.dir("SystemLibrary/Application Support/com.example.daemon")
        try f.writePlist("SystemLibrary/LaunchDaemons/com.example.daemon.helper.plist", ["Label": "com.example.daemon.helper", "Program": "/Library/PrivilegedHelperTools/com.example.daemon.helper"])
        let app = f.app(bundle)
        let system = await finder.associations(for: app, allApps: [app]).filter { $0.kind == .systemLevel }
        #expect(system.count == 2)
        let allAdmin = system.allSatisfy { $0.requiresAdministrator }
        #expect(allAdmin)
    }

    @Test func curatedVendorPathsAndCriticalWarnings() async throws {
        let (f, finder) = try setup()
        let chrome = try f.makeApp("Applications/Google Chrome.app", id: "com.google.Chrome", name: "Google Chrome")
        try f.dir("Library/Application Support/Google/Chrome/Default")
        let docker = try f.makeApp("Applications/Docker.app", id: "com.docker.docker", name: "Docker")
        try f.dir("Library/Containers/com.docker.docker/Data/vms")
        let chromeApp = f.app(chrome), dockerApp = f.app(docker)
        let chromeFound = await finder.associations(for: chromeApp, allApps: [chromeApp, dockerApp])
        let profile = try #require(chromeFound.first { $0.path.hasSuffix("Google/Chrome") })
        #expect(profile.confidence == .likely)
        #expect(profile.warning != nil)
        let dockerFound = await finder.associations(for: dockerApp, allApps: [chromeApp, dockerApp])
        #expect(dockerFound.first { $0.kind == .container }?.warning != nil)
    }

    @Test func catalogValidationRejectsUnsafePaths() {
        var catalog = OwnershipCatalog.bundled()
        #expect((try? catalog.validate()) != nil)
        #expect(!catalog.apps.isEmpty)
        catalog.apps = [.init(bundleID: "x.y.z", paths: [.init(path: "../Documents", kind: .applicationSupport)])]
        #expect(throws: OwnershipCatalog.ValidationError.self) { try catalog.validate() }
        catalog.apps = [.init(bundleID: "x.y.z", paths: [.init(path: "Caches", kind: .cache)])]
        #expect(throws: OwnershipCatalog.ValidationError.self) { try catalog.validate() }
        catalog.apps = [.init(bundleID: "x.y.z", paths: [.init(path: "/Users/x/Library/Caches/a", kind: .cache)])]
        #expect(throws: OwnershipCatalog.ValidationError.self) { try catalog.validate() }
    }
}

@Suite("Orphan detection — false-positive avoidance")
struct OrphanTests {
    func detector(_ f: Fixture, running: Set<String> = [], known: [String: [String]] = [:]) -> OrphanDetector {
        OrphanDetector(home: f.path, catalog: .bundled(), launchServices: FakeLaunchServices(known: known),
                       running: FakeRunningApps(ids: running))
    }

    func makeOld(_ f: Fixture, _ relative: String) throws {
        try f.setModified(relative, daysAgo: 200)
    }

    @Test func convergingEvidenceProducesLikelyOrphan() async throws {
        let f = try Fixture("home")
        try f.file("Library/Caches/com.gone.app/blob", size: 9_000)
        try makeOld(f, "Library/Caches/com.gone.app/blob")
        try makeOld(f, "Library/Caches/com.gone.app")
        let orphans = await detector(f).findOrphans(installedApps: [])
        let orphan = try #require(orphans.first)
        #expect(orphan.inferredBundleIdentifier == "com.gone.app")
        #expect(orphan.confidence == .likely)
        #expect(orphan.evidence.contains { $0.kind == .notRegisteredWithLaunchServices })
        #expect(orphan.confidence != .confirmed)
    }

    @Test func installedAppsAndTheirRelativesAreNotOrphans() async throws {
        let f = try Fixture("home")
        let bundle = try f.makeApp("Applications/Alive.app", id: "com.alive.app")
        for name in ["com.alive.app", "com.alive.app.ShipIt", "com.alive"] { try f.dir("Library/Caches/\(name)") }
        try f.file("Library/Preferences/com.alive.app.plist", size: 10)
        let app = f.app(bundle)
        #expect(await detector(f).findOrphans(installedApps: [app]).isEmpty)
    }

    @Test func appsInstalledElsewhereAreNotOrphans() async throws {
        let f = try Fixture("home")
        try f.dir("Library/Caches/com.portable.tool")
        let orphans = await detector(f, known: ["com.portable.tool": ["/Volumes/USB/Tool.app"]]).findOrphans(installedApps: [])
        #expect(orphans.isEmpty)
    }

    @Test func runningProcessesAreNotOrphans() async throws {
        let f = try Fixture("home")
        try f.dir("Library/Application Support/com.background.daemon")
        #expect(await detector(f, running: ["com.background.daemon"]).findOrphans(installedApps: []).isEmpty)
    }

    @Test func appleSDKAndNonIdentifierNamesAreIgnored() async throws {
        let f = try Fixture("home")
        for name in ["com.apple.Safari", "org.swift.swiftpm", "com.plausiblelabs.crashreporter.data", "Google", "Slack",
                     "My Files", "2024.01.02", "com.openappbox.PureMac", "org.sparkle-project.Sparkle"] {
            try f.dir("Library/Caches/\(name)")
        }
        try f.file("Library/Preferences/.GlobalPreferences.plist", size: 10)
        try f.file("Library/Preferences/loginwindow.plist", size: 10)
        #expect(await detector(f).findOrphans(installedApps: []).isEmpty)
    }

    @Test func vendorWithInstalledAppsIsOnlyAmbiguous() async throws {
        let f = try Fixture("home")
        let word = try f.makeApp("Applications/Word.app", id: "com.microsoft.Word")
        try f.dir("Library/Caches/com.microsoft.office.licensing")
        try makeOld(f, "Library/Caches/com.microsoft.office.licensing")
        let orphans = await detector(f).findOrphans(installedApps: [f.app(word)])
        #expect(orphans.count == 1)
        #expect(orphans.first?.confidence == .ambiguous)
        #expect(orphans.first?.evidence.contains { $0.kind == .vendorStillInstalled } == true)
    }

    @Test func recentlyModifiedRemnantIsOnlyAmbiguous() async throws {
        let f = try Fixture("home")
        try f.file("Library/Application Support/com.fresh.app/data", size: 100)
        let orphans = await detector(f).findOrphans(installedApps: [])
        #expect(orphans.first?.confidence == .ambiguous)
    }

    @Test func staleTimestampAloneIsInsufficient() async throws {
        // Old, but the name is not an identifier: never reported.
        let f = try Fixture("home")
        try f.dir("Library/Application Support/OldVendorThing")
        try makeOld(f, "Library/Application Support/OldVendorThing")
        #expect(await detector(f).findOrphans(installedApps: []).isEmpty)
    }

    @Test func referencedByLaunchAgentIsNotAnOrphan() async throws {
        let f = try Fixture("home")
        try f.dir("Library/Application Support/com.agent.owner")
        try f.writePlist("Library/LaunchAgents/com.agent.owner.helper.plist", ["Label": "com.agent.owner.helper", "Program": "/usr/bin/true"])
        let orphans = await detector(f).findOrphans(installedApps: [])
        #expect(!orphans.contains { $0.path.hasSuffix("com.agent.owner") })
    }

    @Test func brokenLaunchAgentOfRemovedAppIsReported() async throws {
        let f = try Fixture("home")
        try f.writePlist("Library/LaunchAgents/com.removed.updater.plist", ["Label": "com.removed.updater", "Program": f.path("Applications/Removed.app/Contents/MacOS/updater")])
        let orphans = await detector(f).findOrphans(installedApps: [])
        #expect(orphans.contains { $0.kind == .launchAgent && $0.inferredBundleIdentifier == "com.removed.updater" })
    }

    @Test func ignoreListIsHonored() async throws {
        let f = try Fixture("home")
        try f.dir("Library/Caches/com.ignored.app")
        #expect(await detector(f).findOrphans(installedApps: [], ignoredIdentifiers: ["com.ignored.app"]).isEmpty)
    }

    @Test func sdkCacheFoldersAreNotAppOrphans() async throws {
        // Found on a real Mac: SDK-created caches are not apps (live-run regression).
        let f = try Fixture("home")
        for name in ["com.onevcat.Kingfisher.ImageCache.default", "com.hackemist.SDImageCache", "io.realm.cache"] {
            try f.dir("Library/Caches/\(name)")
            try makeOld(f, "Library/Caches/\(name)")
        }
        #expect(await detector(f).findOrphans(installedApps: []).isEmpty)
    }

    @Test func frameworkEmbeddedHelpersBelongToTheirApp() async throws {
        // Found on a real Mac: Sparkle's XPC services live inside the app's embedded framework.
        let f = try Fixture("home")
        let bundle = try f.makeApp("Applications/HandBrake.app", id: "fr.handbrake.HandBrake", name: "HandBrake")
        try f.writePlist("Applications/HandBrake.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/Info.plist",
                         ["CFBundleIdentifier": "fr.handbrake.sparkle-project.DownloaderService"])
        try f.dir("Library/Containers/fr.handbrake.sparkle-project.DownloaderService")
        let app = f.app(bundle)
        #expect(app.helperBundleIdentifiers.contains("fr.handbrake.sparkle-project.DownloaderService"))
        #expect(await detector(f).findOrphans(installedApps: [app]).isEmpty)
        let finder = AssociationFinder(home: f.path, systemLibraryPath: f.path("none"), catalog: .bundled())
        let found = await finder.associations(for: app, allApps: [app], measureSizes: false)
        #expect(found.first { $0.kind == .container }?.confidence == .confirmed)
    }

    @Test func symlinkedRemnantsAreSkipped() async throws {
        let f = try Fixture("home")
        try f.dir("elsewhere")
        try f.symlink("Library/Caches/com.linked.app", to: f.path("elsewhere"))
        #expect(await detector(f).findOrphans(installedApps: []).isEmpty)
    }
}
