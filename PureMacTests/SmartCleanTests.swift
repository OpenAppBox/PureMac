import Foundation
import PureMacKit
import Testing
@testable import PureMac

/// Smart Clean for people who don't want to decide much: safe items are proposed, everything else
/// is one explicit tap away — never selected on its own.
@MainActor
@Suite("Smart Clean extras")
struct SmartCleanTests {
    private func candidate(_ path: String, risk: RiskLevel, category: CleanupCategory, daysAgo: Double, bytes: Int64 = 1_000,
                           blocked: String? = nil, source: CandidateSource = .rule(id: "r")) -> CleanupCandidate {
        CleanupCandidate(path: path, title: "t", reason: "r", category: category, risk: risk, source: source, logicalSize: bytes,
                         allocatedSize: bytes, itemCount: 1, modified: Date().addingTimeInterval(-daysAgo * 86_400),
                         identity: FileIdentity(device: 1, inode: UInt64(abs(path.hashValue) % 1_000_000), type: .directory, ownerUID: 501),
                         isPreselected: risk == .low && blocked == nil, blockedReason: blocked)
    }

    private func model() -> SmartCleanModel {
        let model = SmartCleanModel()
        model._testSet(RuleEvaluation(candidates: [
            candidate("/u/Library/Caches/com.a", risk: .low, category: .appCache, daysAgo: 1, bytes: 5_000),
            candidate("/u/Library/Developer/Xcode/DerivedData/Old-abc", risk: .review, category: .developerCache, daysAgo: 60, bytes: 9_000),
            candidate("/u/Library/Developer/Xcode/DerivedData/Current-def", risk: .review, category: .developerCache, daysAgo: 2, bytes: 9_000),
            candidate("/u/.npm/_cacache", risk: .review, category: .packageManagerCache, daysAgo: 30, bytes: 4_000),
            candidate("/u/Downloads/Old.dmg", risk: .review, category: .installers, daysAgo: 90, bytes: 7_000),
            candidate("/u/Library/Caches/com.running", risk: .low, category: .appCache, daysAgo: 1, blocked: "running"),
        ]), leftovers: [
            candidate("/u/Library/Caches/com.gone.app", risk: .review, category: .appRemnant, daysAgo: 200, bytes: 300,
                      source: .orphan(bundleIdentifier: "com.gone.app")),
        ])
        return model
    }

    @Test func onlySafeItemsAreProposed() {
        let model = model()
        #expect(model.selectedCandidates.map(\.path) == ["/u/Library/Caches/com.a"])
        #expect(!SmartCleanModel.Extra.allCases.contains { model.isIncluded($0) }, "no extra is ever on by itself")
    }

    // Developer data in use (changed in the last two weeks) stays out of the one-tap extra.
    @Test func developerExtraSkipsDataInUse() {
        let model = model()
        #expect(Set(model.items(of: .developer).map(\.path)) == ["/u/Library/Developer/Xcode/DerivedData/Old-abc", "/u/.npm/_cacache"])
        #expect(model.bytes(of: .developer) == 13_000)
    }

    @Test func includingAnExtraAddsExactlyItsItems() {
        let model = model()
        model.setIncluded(.installers, true)
        #expect(model.isIncluded(.installers))
        #expect(model.selectedCandidates.contains { $0.path == "/u/Downloads/Old.dmg" })
        model.setIncluded(.leftovers, true)
        #expect(model.selectedBytes == 5_000 + 7_000 + 300)
        #expect(model.makePlan().items.contains { $0.path == "/u/Library/Caches/com.gone.app" }, "leftovers go into the same review")
        model.setIncluded(.installers, false)
        #expect(!model.selectedCandidates.contains { $0.path == "/u/Downloads/Old.dmg" })
        #expect(!model.selectedCandidates.contains { $0.blockedReason != nil }, "items of running apps are never selected")
    }
}
