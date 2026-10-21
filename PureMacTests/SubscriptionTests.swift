import Foundation
import Security
import StoreKit
import StoreKitTest
import Testing
@testable import PureMac

/// The yearly subscription against the local StoreKit configuration (`PureMac.storekit`): no App
/// Store Connect, no network, no real money.
@MainActor
@Suite("Subscription", .serialized)
struct SubscriptionTests {
    private final class BundleMarker {}

    /// StoreKit's test environment refuses unsigned hosts ("not entitled"): these run in signed
    /// builds — ⌘U in Xcode, or the signed pass of `Scripts/test.sh`.
    nonisolated static let hostIsSigned: Bool = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any] else { return false }
        return values[kSecCodeInfoTeamIdentifier as String] != nil
    }()

    private func makeSession() throws -> SKTestSession {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "PureMac", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.clearTransactions()
        return session
    }

    @Test func copiesBuiltFromSourceNeedNoSubscription() {
        #expect(!StoreOrigin.isAppStoreCopy)   // the test host is a development build, not an App Store copy
        let model = SubscriptionModel(required: false)
        #expect(!model.isRequired)
        #expect(!model.isLocked)
        #expect(!AppModel().subscription.isRequired)
    }

    @Test(.enabled(if: hostIsSigned, "StoreKit testing needs a signed build")) func lockedUntilSubscribed() async throws {
        let session = try makeSession()
        let model = SubscriptionModel(required: true)
        #expect(model.isLocked)   // still checking
        await model.refresh()
        #expect(model.state == .inactive)
        #expect(model.isLocked)

        // As the subscribe screen does: the purchase's own transaction unlocks at once.
        await model.apply(try await session.buyProduct(identifier: SubscriptionModel.productID))
        guard case .active(let expires, let willRenew, let billingIssue) = model.state else {
            Issue.record("expected an active subscription, got \(model.state)")
            return
        }
        #expect(expires != nil)
        #expect(willRenew)
        #expect(!billingIssue)
        #expect(!model.isLocked)
    }

    /// Right after a purchase `Transaction.latest` and the subscription status can still describe
    /// an older transaction (seen when re-subscribing); a refresh then — opening Settings — must not
    /// lock PureMac again. (Xcode's test session can't buy the same subscription twice, so this
    /// checks the first purchase.)
    @Test(.enabled(if: hostIsSigned, "StoreKit testing needs a signed build")) func refreshRightAfterPurchaseStaysUnlocked() async throws {
        let session = try makeSession()
        let model = SubscriptionModel(required: true)
        await model.apply(try await session.buyProduct(identifier: SubscriptionModel.productID))
        #expect(!model.isLocked)
        await model.refresh()
        #expect(!model.isLocked)
    }

    @Test(.enabled(if: hostIsSigned, "StoreKit testing needs a signed build")) func cancelledRenewalStaysActiveUntilThePeriodEnds() async throws {
        let session = try makeSession()
        let model = SubscriptionModel(required: true)
        let transaction = try await session.buyProduct(identifier: SubscriptionModel.productID)
        try session.disableAutoRenewForTransaction(identifier: UInt(transaction.id))
        // The renewal status takes StoreKit a moment (the app re-reads it at launch and in Settings).
        func renews() -> Bool { if case .active(_, let willRenew, _) = model.state { willRenew } else { false } }
        await model.apply(transaction)
        for _ in 0..<40 where renews() {
            try await Task.sleep(for: .milliseconds(250))
            await model.apply(transaction)
        }
        guard case .active(_, let willRenew, _) = model.state else {
            Issue.record("expected an active subscription, got \(model.state)")
            return
        }
        #expect(!willRenew)
        #expect(!model.isLocked)
    }

    /// Expiry is decided from the renewal state (Xcode's test session can't expire a StoreKit 2
    /// transaction in place, so this is checked directly).
    @Test func accessFollowsTheRenewalState() {
        let now = Date()
        let later = now.addingTimeInterval(86_400), earlier = now.addingTimeInterval(-86_400)
        #expect(SubscriptionModel.access(renewalState: .subscribed, revoked: false, expires: later, now: now) == (true, false))
        #expect(SubscriptionModel.access(renewalState: .inGracePeriod, revoked: false, expires: earlier, now: now) == (true, true))
        #expect(SubscriptionModel.access(renewalState: .inBillingRetryPeriod, revoked: false, expires: earlier, now: now) == (false, false))
        #expect(SubscriptionModel.access(renewalState: .expired, revoked: false, expires: later, now: now) == (false, false))
        #expect(SubscriptionModel.access(renewalState: .revoked, revoked: true, expires: later, now: now) == (false, false))
        // Offline: the transaction's own dates.
        #expect(SubscriptionModel.access(renewalState: nil, revoked: false, expires: later, now: now) == (true, false))
        #expect(SubscriptionModel.access(renewalState: nil, revoked: false, expires: earlier, now: now) == (false, false))
        #expect(SubscriptionModel.access(renewalState: nil, revoked: true, expires: later, now: now) == (false, false))
    }

    @Test(.enabled(if: hostIsSigned, "StoreKit testing needs a signed build")) func refundLocksAgain() async throws {
        let session = try makeSession()
        let model = SubscriptionModel(required: true)
        let transaction = try await session.buyProduct(identifier: SubscriptionModel.productID)
        await model.apply(transaction)
        #expect(!model.isLocked)
        try session.refundTransaction(identifier: UInt(transaction.id))
        // StoreKit takes a moment to report the refund (the app hears it through Transaction.updates).
        for _ in 0..<40 where model.state != .inactive {
            try await Task.sleep(for: .milliseconds(250))
            await model.refresh()
        }
        #expect(model.state == .inactive)
    }
}
