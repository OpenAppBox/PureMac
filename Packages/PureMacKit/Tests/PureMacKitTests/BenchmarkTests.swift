import Foundation
import Testing
@testable import PureMacKit

/// Opt-in timings (`PUREMAC_BENCH=1 swift test --filter Benchmarks`). Read-only on the real Mac;
/// synthetic files live in a temporary fixture.
@Suite("Benchmarks", .enabled(if: ProcessInfo.processInfo.environment["PUREMAC_BENCH"] == "1"))
struct BenchmarkTests {
    func time(_ label: String, _ body: () async -> Void) async {
        let start = Date()
        await body()
        print(String(format: "[bench] %@: %.2f s", label, Date().timeIntervalSince(start)))
    }

    @Test func associationsForEveryInstalledApp() async {
        let apps = await AppDiscoverer().discover()
        let removable = apps.filter { !$0.isProtected }
        var items = 0
        await time("associations for \(removable.count) apps (bundles measured again)") {
            for await (_, list) in AppFootprint.associations(for: removable, allApps: apps) { items += list.count }
        }
        let bundles = await DirectorySizer.measureAll(removable.map(\.path))
        var reused = 0
        await time("associations for \(removable.count) apps (bundle sizes reused)") {
            for await (_, list) in AppFootprint.associations(for: removable, allApps: apps, knownSizes: bundles) { reused += list.count }
        }
        #expect(items == reused)
    }

    @Test func associationPhases() async {
        let apps = await AppDiscoverer().discover()
        let removable = apps.filter { !$0.isProtected }
        let finder = AssociationFinder()
        await time("matching only (no sizes), sequential") {
            for app in removable { _ = await finder.associations(for: app, allApps: apps, measureSizes: false) }
        }
        await time("measuring the \(removable.count) app bundles") {
            _ = await DirectorySizer.measureAll(removable.map(\.path))
        }
        await time("LaunchJob.readAll ×\(removable.count)") {
            for _ in removable { _ = LaunchJob.readAll(in: PathTools.userHome + "/Library/LaunchAgents"); _ = LaunchJob.readAll(in: "/Library/LaunchAgents"); _ = LaunchJob.readAll(in: "/Library/LaunchDaemons") }
        }
    }

    @Test(.disabled("slow fixture")) func duplicateHashing() async throws {
        let f = try Fixture("bench")
        // 24 pairs of identical 32 MB files (1.5 GB) plus same-size non-duplicates.
        for i in 0..<24 {
            let data = Data((0..<(32 << 20)).lazy.map { UInt8(truncatingIfNeeded: $0 &* (i + 3)) })
            try f.file("a/\(i).bin", data: data)
            try f.file("b/\(i).bin", data: data)
            var other = data; other[other.count / 2] ^= 0xFF
            try f.file("c/\(i).bin", data: other)
        }
        var groups = 0
        await time("duplicate search over 72 files / 2.3 GB") {
            groups = DuplicateFinder().find(roots: [f.path]).groups.count
        }
        #expect(groups == 24)
    }
}
