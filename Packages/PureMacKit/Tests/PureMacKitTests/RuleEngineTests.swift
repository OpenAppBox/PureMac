import Foundation
import Testing
@testable import PureMacKit

@Suite("Rule engine")
struct RuleEngineTests {
    func evaluator(_ f: Fixture, catalog: CleanupRuleCatalog? = nil) throws -> RuleEvaluator {
        RuleEvaluator(catalog: try catalog ?? CleanupRuleCatalog.bundled(), home: f.path,
                      policy: SafetyPolicy(homeDirectory: f.path))
    }

    func app(_ f: Fixture, _ id: String, name: String = "App") throws -> InstalledApp {
        f.app(try f.makeApp("Applications/\(name).app", id: id, name: name))
    }

    @Test func catalogIsValid() throws {
        let catalog = try CleanupRuleCatalog.bundled()
        #expect(catalog.rules.count >= 15)
        #expect(catalog.rules.allSatisfy { !$0.tests.isEmpty && $0.risk != .protected })
        // Every test a rule claims in CleanupRules.json must exist in this suite, so no rule can
        // point at coverage that isn't there.
        let declared = Set(catalog.rules.flatMap(\.tests))
        let known: Set<String> = [
            "RuleEngineTests.appCachesMatchInstalledAppsOnly", "RuleEngineTests.browserCacheRulesRequireBrowserClosed",
            "RuleEngineTests.catalogIsValid", "RuleEngineTests.electronCacheRulesOnlyTouchCacheFolders",
            "RuleEngineTests.packageManagerCaches", "RuleEngineTests.developerRulesAreReviewOnly",
            "RuleEngineTests.ageThresholdUsesNewestContent", "RuleEngineTests.installersOnlyMatchInstallerTypes",
            "RuleEngineTests.namedAndUpdateCachesOfInstalledApps", "RuleEngineTests.electronAppCachesAreFoundByFramework",
            "RuleEngineTests.developerToolCaches",
        ]
        #expect(declared.isSubset(of: known), "Unknown tests: \(declared.subtracting(known))")
    }

    @Test func validationRejectsEscapingAndBroadRules() throws {
        func catalog(root: String, pattern: [String], risk: String = "low") -> Data {
            Data("""
            {"schemaVersion":1,"catalogVersion":"t","rules":[{"id":"x","title":"x","description":"x","category":"appCache","risk":"\(risk)",
            "root":"\(root)","patterns":[[\(pattern.map { "\"\($0)\"" }.joined(separator: ","))]],"itemType":"directory","requiresAppClosed":false,
            "removalStrategy":"trashItem","regenerationImpact":"x","evidence":"x","tests":["t"]}]}
            """.utf8)
        }
        #expect(throws: CleanupRuleCatalog.ValidationError.self) { try CleanupRuleCatalog.load(from: catalog(root: "Documents", pattern: ["*"])) }
        #expect(throws: CleanupRuleCatalog.ValidationError.self) { try CleanupRuleCatalog.load(from: catalog(root: "Library", pattern: ["*"])) }
        #expect(throws: CleanupRuleCatalog.ValidationError.self) { try CleanupRuleCatalog.load(from: catalog(root: "Library/Caches", pattern: [".."])) }
        #expect(throws: CleanupRuleCatalog.ValidationError.self) { try CleanupRuleCatalog.load(from: catalog(root: "Library/Caches", pattern: ["**"])) }
        #expect(throws: CleanupRuleCatalog.ValidationError.self) { try CleanupRuleCatalog.load(from: catalog(root: "Library/Caches", pattern: ["a/b"])) }
        #expect(throws: CleanupRuleCatalog.ValidationError.self) { try CleanupRuleCatalog.load(from: catalog(root: "Library/Caches", pattern: ["com.*"])) }
        #expect(throws: CleanupRuleCatalog.ValidationError.self) { try CleanupRuleCatalog.load(from: catalog(root: "Library/Caches", pattern: [])) }
        #expect(throws: CleanupRuleCatalog.ValidationError.self) { try CleanupRuleCatalog.load(from: catalog(root: "Library/Caches", pattern: ["{home}"])) }
        #expect(throws: CleanupRuleCatalog.ValidationError.self) { try CleanupRuleCatalog.load(from: catalog(root: "Library/Caches", pattern: ["x"], risk: "protected")) }
        #expect(throws: CleanupRuleCatalog.ValidationError.self) { try CleanupRuleCatalog.load(from: catalog(root: "/Library/Caches", pattern: ["x"])) }
        #expect(throws: CleanupRuleCatalog.ValidationError.self) { try CleanupRuleCatalog.load(from: catalog(root: "", pattern: ["x"])) }
        #expect((try? CleanupRuleCatalog.load(from: catalog(root: "Library/Caches", pattern: ["Thing"]))) != nil)
    }

    @Test func appCachesMatchInstalledAppsOnly() async throws {
        let f = try Fixture("home")
        let installed = try app(f, "com.example.alpha", name: "Alpha")
        try f.file("Library/Caches/com.example.alpha/blob", size: 20_000)
        try f.file("Library/Caches/com.uninstalled.beta/blob", size: 20_000)
        try f.file("Library/Caches/com.apple.Safari/blob", size: 20_000)
        try f.file("Library/Caches/Random Folder/blob", size: 20_000)
        try f.dir("Library/Caches/com.example.alpha.empty")
        let result = try await evaluator(f).evaluate(installedApps: [installed], runningIdentifiers: [])
        let appCaches = result.candidates.filter { $0.source == .rule(id: "app-caches.installed") }
        #expect(appCaches.map(\.name) == ["com.example.alpha"])
        let candidate = try #require(appCaches.first)
        #expect(candidate.risk == .low)
        #expect(candidate.isPreselected)
        #expect(candidate.relatedAppName == "Alpha")
        #expect(candidate.allocatedSize > 0)
        #expect(candidate.scopeRoot == f.path("Library/Caches"))
    }

    @Test func runningAppBlocksItsCache() async throws {
        let f = try Fixture("home")
        let installed = try app(f, "com.example.alpha", name: "Alpha")
        try f.file("Library/Caches/com.example.alpha/blob", size: 20_000)
        let result = try await evaluator(f).evaluate(installedApps: [installed], runningIdentifiers: ["com.example.alpha"])
        let candidate = try #require(result.candidates.first)
        #expect(candidate.blockedReason != nil)
        #expect(!candidate.isPreselected)
    }

    @Test func browserCacheRulesRequireBrowserClosed() async throws {
        let f = try Fixture("home")
        try f.file("Library/Caches/Google/Chrome/Default/Cache/data_0", size: 30_000)
        try f.file("Library/Caches/Firefox/Profiles/abc.default/cache2/x", size: 30_000)
        let result = try await evaluator(f).evaluate(installedApps: [], runningIdentifiers: ["com.google.chrome"])
        let chrome = try #require(result.candidates.first { $0.source == .rule(id: "browser.chrome.cache") })
        #expect(chrome.blockedReason != nil)
        let firefox = try #require(result.candidates.first { $0.source == .rule(id: "browser.firefox.cache") })
        #expect(firefox.blockedReason == nil && firefox.isPreselected)
    }

    @Test func electronCacheRulesOnlyTouchCacheFolders() async throws {
        let f = try Fixture("home")
        try f.file("Library/Application Support/Slack/Cache/data", size: 10_000)
        try f.file("Library/Application Support/Slack/Code Cache/js", size: 10_000)
        try f.file("Library/Application Support/Slack/storage/messages.db", size: 10_000)
        try f.file("Library/Application Support/Code/User/settings.json", size: 10_000)
        try f.file("Library/Application Support/Code/CachedData/x", size: 10_000)
        let result = try await evaluator(f).evaluate(installedApps: [], runningIdentifiers: [])
        let paths = Set(result.candidates.map(\.path))
        #expect(paths.contains(f.path("Library/Application Support/Slack/Cache")))
        #expect(paths.contains(f.path("Library/Application Support/Code/CachedData")))
        #expect(!paths.contains { $0.contains("storage") || $0.contains("User") })
        #expect(!paths.contains(f.path("Library/Application Support/Slack")))
    }

    // Caches named after the app (`Steam`), not its identifier, and update downloads were missed.
    @Test func namedAndUpdateCachesOfInstalledApps() async throws {
        let f = try Fixture("home")
        let steam = try app(f, "com.valvesoftware.steam", name: "Steam")
        let trae = try app(f, "com.trae.app", name: "Trae")
        try f.file("Library/Caches/Steam/htmlcache/x", size: 20_000)
        try f.file("Library/Caches/com.trae.app.ShipIt/update.zip", size: 20_000)
        try f.file("Library/Caches/Gone/x", size: 20_000)                       // no app named "Gone"
        try f.file("Library/Caches/com.gone.app.ShipIt/update.zip", size: 20_000) // not installed
        try f.file("Library/Caches/Mozilla/updates/Applications/Firefox/update.mar", size: 20_000)
        let result = try await evaluator(f).evaluate(installedApps: [steam, trae], runningIdentifiers: ["com.trae.app"])
        let byRule = Dictionary(grouping: result.candidates) { candidate -> String in
            if case .rule(let id) = candidate.source { return id } else { return "" }
        }
        #expect(byRule["app-caches.named"]?.map(\.name) == ["Steam"])
        #expect(byRule["app-caches.named"]?.first?.relatedAppName == "Steam")
        let update = try #require(byRule["app-updates.shipit"]?.first)
        #expect(update.name == "com.trae.app.ShipIt")
        #expect(update.blockedReason != nil, "the app is running, so its updater may be using it")
        #expect(byRule["browser.firefox.updates"]?.count == 1)
        #expect(!result.candidates.contains { $0.path.contains("Gone") || $0.path.contains("com.gone") })
        #expect(result.candidates.filter { $0.blockedReason == nil }.allSatisfy { $0.risk == .low && $0.isPreselected })
    }

    // Electron apps keep Chromium caches inside their data folder; only apps that contain the
    // Electron framework qualify, and only the cache folders (never Partitions, storage or settings).
    @Test func electronAppCachesAreFoundByFramework() async throws {
        let f = try Fixture("home")
        let claudePath = try f.makeApp("Applications/Claude.app", id: "com.anthropic.claudefordesktop", name: "Claude")
        try f.dir("Applications/Claude.app/Contents/Frameworks/Electron Framework.framework")
        let native = try app(f, "com.example.native", name: "Native")
        try f.file("Library/Application Support/Claude/Cache/Cache_Data/x", size: 20_000)
        try f.file("Library/Application Support/Claude/Code Cache/js/x", size: 20_000)
        try f.file("Library/Application Support/Claude/Service Worker/CacheStorage/x", size: 20_000)
        try f.file("Library/Application Support/Claude/Partitions/main/Cookies", size: 20_000)
        try f.file("Library/Application Support/Claude/config.json", size: 2_000)
        try f.file("Library/Application Support/Native/Cache/x", size: 20_000)    // not an Electron app
        let result = try await evaluator(f).evaluate(installedApps: [f.app(claudePath), native], runningIdentifiers: [])
        let electron = result.candidates.filter { $0.source == .rule(id: "electron.app.cache") }
        #expect(Set(electron.map { ($0.path as NSString).lastPathComponent }) == ["Cache", "Code Cache", "CacheStorage"])
        #expect(electron.allSatisfy { $0.relatedAppName == "Claude" && $0.requiresAppClosed })
        #expect(!result.candidates.contains { $0.path.contains("Partitions") || $0.path.contains("config.json") || $0.path.contains("Native") })
    }

    @Test func developerToolCaches() async throws {
        let f = try Fixture("home")
        try f.file("Library/Caches/go-build/00/x", size: 20_000)
        try f.file("Library/Caches/node-gyp/22.0.0/include/x", size: 20_000)
        try f.file("Library/Caches/ms-playwright/chromium-1140/x", size: 20_000)
        let result = try await evaluator(f).evaluate(installedApps: [], runningIdentifiers: [])
        let tools = result.candidates.filter { $0.source == .rule(id: "dev.tool.caches") }
        #expect(Set(tools.map(\.name)) == ["go-build", "node-gyp"])
        #expect(tools.allSatisfy { $0.risk == .low && $0.isPreselected })
        let browsers = try #require(result.candidates.first { $0.source == .rule(id: "dev.browser-test.downloads") })
        #expect(browsers.risk == .review && !browsers.isPreselected, "large re-downloads stay an explicit choice")
    }

    @Test func packageManagerCaches() async throws {
        let f = try Fixture("home")
        try f.file("Library/Caches/Homebrew/downloads/pkg.tar.gz", size: 10_000)
        try f.file("Library/Caches/pip/http/x", size: 10_000)
        try f.file(".npm/_cacache/index", size: 10_000)
        let result = try await evaluator(f).evaluate(installedApps: [], runningIdentifiers: [])
        #expect(result.candidates.contains { $0.source == .rule(id: "pkg.homebrew.downloads") && $0.risk == .low })
        #expect(result.candidates.contains { $0.source == .rule(id: "pkg.pip.cache") })
        #expect(result.candidates.contains { $0.source == .rule(id: "pkg.npm.cacache") && $0.risk == .review && !$0.isPreselected })
    }

    @Test func developerRulesAreReviewOnly() async throws {
        let f = try Fixture("home")
        try f.file("Library/Developer/Xcode/DerivedData/App-abc/Build/x", size: 10_000)
        try f.file("Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A1)/Symbols/x", size: 10_000)
        try f.file("Library/Developer/Xcode/Archives/2026-01-01/App.xcarchive/x", size: 10_000)
        let result = try await evaluator(f).evaluate(installedApps: [], runningIdentifiers: [])
        let dev = result.candidates.filter { $0.category == .developerCache }
        #expect(dev.count == 2)
        #expect(dev.allSatisfy { $0.risk == .review && !$0.isPreselected })
        #expect(!result.candidates.contains { $0.path.contains("Archives") })
    }

    @Test func ageThresholdUsesNewestContent() async throws {
        let f = try Fixture("home")
        try f.file("Library/Logs/DiagnosticReports/old.ips", size: 5_000)
        try f.setModified("Library/Logs/DiagnosticReports/old.ips", daysAgo: 90)
        try f.file("Library/Logs/DiagnosticReports/new.ips", size: 5_000)
        let installed = try app(f, "com.example.logger", name: "Logger")
        try f.file("Library/Logs/com.example.logger/old.log", size: 5_000)
        try f.file("Library/Logs/com.example.logger/today.log", size: 5_000) // recent content inside an old folder
        try f.setModified("Library/Logs/com.example.logger/old.log", daysAgo: 90)
        try f.setModified("Library/Logs/com.example.logger", daysAgo: 90)
        let result = try await evaluator(f).evaluate(installedApps: [installed], runningIdentifiers: [])
        #expect(result.candidates.filter { $0.category == .crashReports }.map(\.name) == ["old.ips"])
        #expect(!result.candidates.contains { $0.source == .rule(id: "logs.app.old") })
    }

    @Test func installersOnlyMatchInstallerTypes() async throws {
        let f = try Fixture("home")
        for name in ["Tool.dmg", "Setup.pkg", "Photo.jpg", "Report.pdf"] {
            try f.file("Downloads/\(name)", size: 5_000)
            try f.setModified("Downloads/\(name)", daysAgo: 60)
        }
        try f.file("Downloads/Fresh.dmg", size: 5_000)
        try f.dir("Downloads/Folder.dmg")
        let result = try await evaluator(f).evaluate(installedApps: [], runningIdentifiers: [])
        let installers = result.candidates.filter { $0.category == .installers }
        #expect(Set(installers.map(\.name)) == ["Tool.dmg", "Setup.pkg"])
        #expect(installers.allSatisfy { $0.risk == .review && !$0.isPreselected })
    }

    @Test func symlinksInPatternsAreNeverFollowed() async throws {
        let f = try Fixture("home")
        try f.file("Documents/precious/thesis.pdf", size: 50_000)
        try f.dir("Library/Caches/Google/Chrome")
        try f.symlink("Library/Caches/Google/Chrome/Default", to: f.path("Documents/precious"))
        try f.symlink("Library/Caches/pip", to: f.path("Documents"))
        let result = try await evaluator(f).evaluate(installedApps: [], runningIdentifiers: [])
        #expect(result.candidates.isEmpty)
        #expect(f.exists("Documents/precious/thesis.pdf"))
    }

    @Test func overlappingCandidatesAreDeduplicated() {
        let identity = FileIdentity(device: 1, inode: 1, type: .directory, ownerUID: 501)
        func candidate(_ path: String, _ risk: RiskLevel, _ bytes: Int64) -> CleanupCandidate {
            CleanupCandidate(path: path, title: "", reason: "", category: .appCache, risk: risk, source: .rule(id: path),
                             logicalSize: bytes, allocatedSize: bytes, itemCount: 1, modified: nil, identity: identity,
                             isPreselected: risk == .low)
        }
        let result = RuleEvaluator.deduplicate([
            candidate("/h/Library/Caches/a/b", .review, 10), candidate("/h/Library/Caches/a", .low, 100),
            candidate("/h/Library/Caches/ab", .low, 5), candidate("/h/Library/Caches/a", .low, 100),
        ])
        #expect(result.map(\.path) == ["/h/Library/Caches/a", "/h/Library/Caches/ab"])
        #expect(result.first?.risk == .review)          // most cautious wins
        #expect(result.first?.isPreselected == false)
    }

    @Test func userExclusionsBlockRuleMatches() async throws {
        let f = try Fixture("home")
        try f.file("Library/Caches/pip/x", size: 5_000)
        let policy = SafetyPolicy(homeDirectory: f.path, userExclusions: [f.path("Library/Caches/pip")])
        let result = await RuleEvaluator(catalog: try CleanupRuleCatalog.bundled(), home: f.path, policy: policy)
            .evaluate(installedApps: [], runningIdentifiers: [])
        #expect(result.candidates.isEmpty)
        #expect(result.rejections.contains { $0.path.hasSuffix("pip") })
    }

    @Test func evaluationIsReadOnly() async throws {
        let f = try Fixture("home")
        let installed = try app(f, "com.example.alpha", name: "Alpha")
        try f.file("Library/Caches/com.example.alpha/blob", size: 20_000)
        try f.file("Library/Caches/Homebrew/downloads/x", size: 20_000)
        try f.file("Downloads/Old.dmg", size: 20_000)
        try f.setModified("Downloads/Old.dmg", daysAgo: 90)
        let before = f.snapshot()
        _ = try await evaluator(f).evaluate(installedApps: [installed], runningIdentifiers: [])
        #expect(f.snapshot() == before)
    }
}
