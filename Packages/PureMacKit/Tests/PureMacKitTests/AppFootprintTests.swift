import Foundation
import Testing
@testable import PureMacKit

@Suite("App footprint")
struct AppFootprintTests {
    @Test func measuresEveryBundleExactlyOnce() async throws {
        let f = try Fixture()
        try f.file("Applications/Alpha.app/Contents/MacOS/Alpha", size: 200_000)
        try f.file("Applications/Beta.app/Contents/MacOS/Beta", size: 50_000)
        try f.file("Applications/Beta.app/Contents/Resources/a.bin", size: 50_000)
        let paths = [f.path("Applications/Alpha.app"), f.path("Applications/Beta.app")]
        var results: [String: AppMeasurement] = [:]
        for await measured in AppFootprint.measure(paths: paths, maxConcurrency: 1) {
            #expect(results[measured.path] == nil)
            results[measured.path] = measured
        }
        #expect(Set(results.keys) == Set(paths))
        #expect(results[paths[0]]?.bundle.fileCount == 1)
        #expect(results[paths[1]]?.bundle.fileCount == 2)
        #expect((results[paths[0]]?.bundle.allocatedSize ?? 0) >= 200_000)
    }

    @Test func stoppingTheConsumerEndsTheStream() async throws {
        let f = try Fixture()
        let paths = try (0..<20).map { i in try f.file("Applications/A\(i).app/x", size: 16).deletingLastPathComponent().path }
        var seen = 0
        for await _ in AppFootprint.measure(paths: paths, maxConcurrency: 2) {
            seen += 1
            if seen == 3 { break }
        }
        #expect(seen == 3)
    }

    @Test func dataBytesExcludeTheBundleAndItemsNeverRemovedWithTheApp() {
        func item(_ kind: AssociationKind, _ confidence: AssociationConfidence, _ bytes: Int64) -> AppAssociation {
            AppAssociation(path: "/x/\(kind.rawValue)-\(confidence.rawValue)", kind: kind, confidence: confidence, evidence: [], allocatedSize: bytes)
        }
        let associations = [
            item(.appBundle, .confirmed, 1_000),
            item(.cache, .confirmed, 100),
            item(.applicationSupport, .likely, 50),
            item(.groupContainer, .shared, 400),
            item(.systemLevel, .protected, 800),
            item(.logs, .ambiguous, 7),
        ]
        #expect(associations.associatedDataBytes == 157)
    }
}
