import Foundation
import Testing
@testable import PureMacKit

@Suite("Duplicate finder")
struct DuplicateTests {
    let finder = DuplicateFinder(minimumSize: 1_000, sampleSize: 512, chunkSize: 4_096)

    @Test func findsExactDuplicatesOnly() throws {
        let f = try Fixture()
        let content = Data((0..<200_000).map { UInt8($0 % 251) })
        try f.file("a/photo.jpg", data: content)
        try f.file("b/photo copy.jpg", data: content)
        try f.file("c/deep/x.bin", data: content)
        var differentTail = content
        differentTail[differentTail.count - 1] ^= 0xFF          // same size, same head, different tail
        try f.file("d/near.bin", data: differentTail)
        var differentMiddle = content
        differentMiddle[100_000] ^= 0xFF                         // same head and tail, different middle
        try f.file("e/sneaky.bin", data: differentMiddle)
        try f.file("small/1.txt", size: 10)
        try f.file("small/2.txt", size: 10)                      // below threshold
        let result = finder.find(roots: [f.path])
        #expect(result.groups.count == 1)
        let group = try #require(result.groups.first)
        #expect(Set(group.files.map(\.name)) == ["photo.jpg", "photo copy.jpg", "x.bin"])
        #expect(group.potentialSavings == 2 * (group.files.map(\.allocatedSize).min() ?? 0))
    }

    @Test func hardLinksAreNotDuplicates() throws {
        let f = try Fixture()
        try f.file("orig.bin", size: 50_000, byte: 7)
        try f.hardLink("link.bin", to: "orig.bin")
        var result = finder.find(roots: [f.path])
        #expect(result.groups.isEmpty)
        #expect(result.hardLinkSetsIgnored == 1)
        // A real copy next to hard links forms a group of two distinct files; the links are noted.
        try f.file("copy.bin", size: 50_000, byte: 7)
        result = finder.find(roots: [f.path])
        let group = try #require(result.groups.first)
        #expect(group.files.count == 2)
        #expect(group.files.contains { !$0.hardLinkPaths.isEmpty })
    }

    @Test func symlinksAndPackageInternalsAreIgnored() throws {
        let f = try Fixture()
        try f.file("real.bin", size: 50_000, byte: 3)
        try f.symlink("link.bin", to: f.path("real.bin"))
        try f.file("Tool.app/Contents/Resources/real.bin", size: 50_000, byte: 3)
        #expect(finder.find(roots: [f.path]).groups.isEmpty)
    }

    @Test func cancellationStopsHashing() throws {
        let f = try Fixture()
        for i in 0..<20 { try f.file("d\(i)/x.bin", size: 20_000, byte: 9) }
        let flag = CancellationFlag()
        flag.cancel()
        let result = finder.find(roots: [f.path], isCancelled: { flag.isCancelled })
        #expect(result.wasCancelled)
        #expect(result.groups.isEmpty)
    }

    @Test func planNeverRemovesEveryCopy() throws {
        let f = try Fixture()
        try f.file("Documents/a.bin", size: 50_000, byte: 5)
        try f.file("Documents/b.bin", size: 50_000, byte: 5)
        let result = finder.find(roots: [f.path])
        let group = try #require(result.groups.first)
        let policy = SafetyPolicy(homeDirectory: f.path)
        #expect(throws: CleanupPlanner.DuplicatePlanError.self) {
            _ = try CleanupPlanner.duplicateCandidates(groups: [group], selectedPaths: Set(group.files.map(\.path)), policy: policy)
        }
        let keepOne = try CleanupPlanner.duplicateCandidates(groups: [group], selectedPaths: [group.files[0].path], policy: policy)
        #expect(keepOne.candidates.count == 1)
        #expect(keepOne.candidates.first?.source.safetyIntent == .userSelected)
    }

    @Test func changedCopyIsRejectedAtPlanning() throws {
        let f = try Fixture()
        try f.file("Documents/a.bin", size: 50_000, byte: 5)
        try f.file("Documents/b.bin", size: 50_000, byte: 5)
        let group = try #require(finder.find(roots: [f.path]).groups.first)
        try FileManager.default.removeItem(atPath: group.files[0].path)
        try f.file("Documents/" + group.files[0].name, size: 50_000, byte: 5)  // replaced: new inode
        let planned = try CleanupPlanner.duplicateCandidates(groups: [group], selectedPaths: [group.files[0].path], policy: SafetyPolicy(homeDirectory: f.path))
        #expect(planned.candidates.isEmpty)
        #expect(planned.rejected.count == 1)
    }

    @Test func hashingReadsWithoutModifying() throws {
        let f = try Fixture()
        try f.file("a.bin", size: 30_000, byte: 1)
        try f.file("b.bin", size: 30_000, byte: 1)
        let before = f.snapshot()
        _ = finder.find(roots: [f.path])
        #expect(f.snapshot() == before)
    }
}

@Suite("Developer storage and diagnostics")
struct DeveloperAndDiagnosticsTests {
    @Test func inspectsKnownLocationsWithSizes() async throws {
        let f = try Fixture("home")
        try f.file("Library/Developer/Xcode/DerivedData/App-abc/Build/x", size: 40_000)
        try f.file("Library/Developer/Xcode/DerivedData/Other-def/Build/x", size: 10_000)
        try f.file("Library/Developer/Xcode/Archives/2026-01-01/App.xcarchive/x", size: 10_000)
        try f.file("Library/Containers/com.docker.docker/Data/vms/0/Docker.raw", size: 10_000)
        try f.file(".npm/_cacache/index-v5/x", size: 10_000)
        let items = await DeveloperStorageInspector(home: f.path).inspect()
        let derived = try #require(items.first { $0.id == "xcode.deriveddata" })
        #expect(derived.children.map(\.name) == ["App-abc", "Other-def"])
        #expect(items.first { $0.id == "xcode.archives" }?.warning != nil)
        let docker = try #require(items.first { $0.id == "docker.data" })
        if case .inspectOnly = docker.handling {} else { Issue.record("Docker data must be inspect-only") }
        #expect(docker.risk == .protected)
        #expect(items.contains { $0.id == "pm.npm" })
        #expect(!items.contains { $0.id == "pm.cargo" })   // absent locations are not listed
    }

    @Test func toolRunnerOnlyRunsAllowListedAbsoluteExecutables() {
        #expect(!ToolRunner.isAllowed("/bin/sh"))
        #expect(!ToolRunner.isAllowed("pkgutil"))
        #expect(!ToolRunner.isAllowed("/usr/bin/../bin/sh"))
        #expect(!ToolRunner.isAllowed("/usr/bin/rm"))
        #expect(!ToolRunner.isAllowed("/usr/bin/xcrun"))   // simctl can't run in the App Sandbox
        #expect(ToolRunner.isAllowed("/usr/sbin/pkgutil"))
        #expect(ToolRunner.run(executable: "/bin/rm", arguments: ["-rf", "/tmp/x"]) == nil)
    }

    @Test func liveSnapshotUsesPublicAPIs() async throws {
        let snapshot = SystemDiagnostics.snapshot()
        #expect(snapshot.memory?.physical ?? 0 > 0)
        #expect(snapshot.logicalCPUs > 0)
        // Whole-Mac processor time, which the App Sandbox allows (per-process sampling it hides).
        let first = try #require(snapshot.cpuTicks)
        try await Task.sleep(for: .milliseconds(200))
        let second = try #require(SystemDiagnostics.snapshot().cpuTicks)
        let busy = try #require(second.busyFraction(since: first))
        #expect((0...1).contains(busy))
    }

    @Test func cpuBusyFractionComparesTwoReadings() {
        let a = CPUTicks(busy: 100, total: 1_000)
        #expect(CPUTicks(busy: 400, total: 2_000).busyFraction(since: a) == 0.3)
        #expect(a.busyFraction(since: a) == nil)                                   // no time passed
        #expect(CPUTicks(busy: 50, total: 2_000).busyFraction(since: a) == nil)    // counters reset
    }

    @Test func findingsCiteEvidenceAndNeverPromiseSpeedups() {
        var snapshot = SystemDiagnostics.snapshot()
        snapshot.pressure = .critical
        snapshot.thermalState = .serious
        let findings = SystemDiagnostics.findings(for: snapshot, brokenLaunchItems: 2)
        #expect(findings.count >= 3)
        for finding in findings {
            #expect(!finding.evidence.isEmpty && !finding.expectedEffect.isEmpty)
            let text = (finding.title + finding.suggestion + finding.expectedEffect).lowercased()
            #expect(!text.contains("free ram") || text.contains("cannot"))
            #expect(!text.contains("% faster"))
        }
    }

    @Test func launchInventoryFlagsMissingPrograms() throws {
        let f = try Fixture("home")
        try f.writePlist("Library/LaunchAgents/com.example.ok.plist", ["Label": "com.example.ok", "Program": "/usr/bin/true"])
        try f.writePlist("Library/LaunchAgents/com.example.gone.plist", ["Label": "com.example.gone", "Program": f.path("missing/tool")])
        let items = LaunchItem.inventory(home: f.path).filter { $0.scope == .userAgent }
        #expect(items.count == 2)
        #expect(items.first { $0.label == "com.example.gone" }?.programExists == false)
        #expect(items.first { $0.label == "com.example.ok" }?.programExists == true)
    }
}
