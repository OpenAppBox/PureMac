import Foundation
import Testing
@testable import PureMacKit

/// Read-only checks against the real Mac. Opt-in: `PUREMAC_LIVE=1 swift test --filter LiveSystem`.
/// Nothing is modified: the scan writes only to a temporary database, no cleanup is executed.
/// Output is aggregate-only (counts, sizes, timings) plus orphan identifiers for false-positive review.
@Suite("Live system (read-only, opt-in)", .serialized)
struct LiveSystemTests {
    var enabled: Bool { ProcessInfo.processInfo.environment["PUREMAC_LIVE"] == "1" }
    let home = FileManager.default.homeDirectoryForCurrentUser.path

    @Test func homeScanPerformanceAndCoverage() async throws {
        guard enabled else { return }
        let db = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("PureMacLive-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + s) } }
        let started = Date()
        let session = try await StorageScanner(databaseURL: db).scan(ScanConfiguration(roots: [.home()])) { _ in }
        let elapsed = Date().timeIntervalSince(started)
        let store = try LocalStore(url: db)
        let issues = try await store.issueCounts(sessionID: session.id)
        let rows = try SQLiteConnection(path: db.path).prepare("SELECT COUNT(*) FROM entry")
        _ = try rows.step()
        print("LIVE scan: status=\(session.status.rawValue) files=\(session.fileCount) dirs=\(session.directoryCount) allocated=\(session.allocatedSize / 1_000_000) MB logical=\(session.logicalSize / 1_000_000) MB hardlinkDups=\(session.hardLinkDuplicateCount) elapsed=\(String(format: "%.1f", elapsed))s rate=\(Int(Double(session.fileCount) / max(elapsed, 0.001)))/s")
        print("LIVE scan: indexRows=\(rows.int64(0)) dbSize=\(await store.databaseSize() / 1_000_000) MB issues=\(issues.map { "\($0.key.rawValue):\($0.value)" }.sorted())")
        let totals = try await store.categoryTotals(sessionID: session.id)
        print("LIVE scan: categories=\(totals.map { "\($0.category.displayName)=\($0.allocatedSize / 1_000_000)MB" })")
        #expect(session.status == .completed)
        let categorized = totals.reduce(0) { $0 + $1.fileCount }
        #expect(categorized == session.fileCount)
    }

    /// A whole-disk scan stores Finder's paths (`/Users/…`, `/Applications/…`), not the Data
    /// volume's (`/System/Volumes/Data/Users/…`), so the home folder and exclusions match.
    @Test func entireDiskScanUsesVisiblePaths() async throws {
        guard enabled else { return }
        // `PUREMAC_LIVE_KEEP=<path>` keeps the database there (to open it in the app with
        // `-PureMacDatabase <path>`); otherwise it is temporary.
        let keep = ProcessInfo.processInfo.environment["PUREMAC_LIVE_KEEP"]
        let db = keep.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("PureMacLiveDisk-\(UUID().uuidString).sqlite")
        defer { if keep == nil { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + s) } } }
        let started = Date()
        let session = try await StorageScanner(databaseURL: db)
            .scan(ScanConfiguration(roots: [ScanRoot(path: PathTools.dataVolume, kind: .dataVolume)])) { _ in }
        let store = try LocalStore(url: db)
        let root = try #require(try await store.roots(sessionID: session.id).first)
        let children = try await store.children(of: root.id, limit: 100).map(\.path)
        let leaked = try SQLiteConnection(path: db.path).prepare("SELECT COUNT(*) FROM entry WHERE path LIKE '/System/Volumes/Data/Users/%'")
        _ = try leaked.step()
        let home = try await store.entry(sessionID: session.id, path: home)
        print("LIVE disk scan: root=\(root.name) files=\(session.fileCount) allocated=\(session.allocatedSize / 1_000_000) MB in \(Int(Date().timeIntervalSince(started)))s children=\(children.sorted())")
        let categories = try await store.categoryTotals(sessionID: session.id)
        print("LIVE disk scan categories: \(categories.map { "\($0.category.rawValue)=\($0.allocatedSize / 1_000_000_000)GB" })")
        let tops = try await store.children(of: root.id, limit: 6).map { "\($0.name):\($0.category.rawValue)/\($0.leadCategory?.rawValue ?? -1)" }
        print("LIVE disk scan top folders: \(tops)")
        #expect(categories.count > 3)                                  // not everything "System & Other"
        #expect(root.path == PathTools.dataVolume)
        #expect(children.contains("/Users") && children.contains("/Applications"))
        #expect(leaked.int(0) == 0)
        #expect(home != nil)
    }

    @Test func applicationsOwnershipAndOrphans() async throws {
        guard enabled else { return }
        var started = Date()
        let apps = await AppDiscoverer().discover()
        print("LIVE apps: count=\(apps.count) protected=\(apps.filter(\.isProtected).count) signing=\(Dictionary(grouping: apps, by: \.signingKind).mapValues(\.count).map { "\($0.key.rawValue):\($0.value)" }.sorted()) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        #expect(!apps.isEmpty)
        let systemAppsProtected = apps.filter { $0.path.hasPrefix("/System/") }.allSatisfy { $0.isProtected }
        #expect(systemAppsProtected)

        started = Date()
        var confidenceCounts: [String: Int] = [:]
        for app in apps.filter({ !$0.isProtected }).prefix(15) {
            for association in await AssociationFinder().associations(for: app, allApps: apps, measureSizes: false) {
                confidenceCounts[association.confidence.rawValue, default: 0] += 1
            }
        }
        print("LIVE ownership (15 apps): \(confidenceCounts.sorted { $0.key < $1.key }) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")

        started = Date()
        let orphans = await OrphanDetector().findOrphans(installedApps: apps, measureSizes: false)
        print("LIVE orphans: count=\(orphans.count) likely=\(orphans.filter { $0.confidence == .likely }.count) ambiguous=\(orphans.filter { $0.confidence == .ambiguous }.count) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        for orphan in orphans.prefix(40) {
            print("LIVE orphan: \(orphan.confidence.rawValue) \(orphan.kind.rawValue) \(orphan.inferredBundleIdentifier)")
        }
        let noneConfirmed = orphans.allSatisfy { $0.confidence != .confirmed }
        let noApple = !orphans.contains { $0.inferredBundleIdentifier.lowercased().hasPrefix("com.apple.") }
        #expect(noneConfirmed)
        #expect(noApple)
    }

    @Test func ruleEvaluationIsReadOnlyOnRealHome() async throws {
        guard enabled else { return }
        let apps = await AppDiscoverer().discover()
        let running = await WorkspaceRunningAppChecker().runningBundleIdentifiers()
        let started = Date()
        let result = await RuleEvaluator(catalog: try CleanupRuleCatalog.bundled(), policy: SafetyPolicy(homeDirectory: home))
            .evaluate(installedApps: apps, runningIdentifiers: running)
        print("LIVE rules: candidates=\(result.candidates.count) low=\(result.candidates.filter { $0.risk == .low }.count) review=\(result.candidates.filter { $0.risk == .review }.count) blocked=\(result.candidates.filter { $0.blockedReason != nil }.count) rejected=\(result.rejections.count) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        for summary in result.summaries { print("LIVE rule: \(summary.ruleID) items=\(summary.itemCount) size=\(summary.allocatedBytes / 1_000_000) MB") }
        let policy = SafetyPolicy(homeDirectory: home)
        let allAllowed = result.candidates.allSatisfy { policy.evaluate($0.path, intent: .ruleCleanup, allowedRoots: [$0.scopeRoot ?? ""]).isAllowed }
        #expect(allAllowed)
    }
}
