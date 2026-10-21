import AppKit
import Foundation
import Observation
import Security
import StoreKit

/// The yearly subscription, required only in copies installed from the Mac App Store.
///
/// A copy someone built from the source code makes no StoreKit calls and opens normally. In an App
/// Store copy, only a verified transaction whose subscription is active (or in Apple's billing grace
/// period) unlocks PureMac. StoreKit keeps them
/// on the Mac, so a subscriber can use PureMac offline. PureMac itself opens no connections: StoreKit
/// talks to the App Store through the system.
@Observable
final class SubscriptionModel {
    enum State: Equatable {
        /// Not an App Store copy: no subscription needed.
        case notRequired
        /// Reading the entitlements StoreKit keeps on this Mac (usually a moment).
        case checking
        /// `billingIssue`: a renewal failed and Apple's billing grace period keeps it active meanwhile.
        case active(expires: Date?, willRenew: Bool, billingIssue: Bool)
        /// Never subscribed, expired or refunded.
        case inactive
    }

    static let productID = "com.openappbox.PureMac.yearly"
    static let manageURL = URL(string: "https://apps.apple.com/account/subscriptions")!
    static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyPolicyURL = URL(string: "https://www.openappbox.com/privacy")!

    private(set) var state: State
    private(set) var isRestoring = false

    @ObservationIgnored private var updates: Task<Void, Never>?
    /// The newest transaction StoreKit delivered this session (a purchase or an update). Right after
    /// a purchase `Transaction.latest` can still return an older, expired one for a moment.
    @ObservationIgnored private var newest: Transaction?
    @ObservationIgnored private var expiryCheck: Task<Void, Never>?
    @ObservationIgnored private var activation: NSObjectProtocol?
    @ObservationIgnored private var lastRefresh = Date.distantPast

    init(required: Bool) {
        state = required ? .checking : .notRequired
    }

    var isRequired: Bool { state != .notRequired }

    /// The main window shows the subscribe screen instead of PureMac.
    var isLocked: Bool {
        switch state {
        case .checking, .inactive: true
        case .notRequired, .active: false
        }
    }

    /// Reads the current entitlements and listens for changes for the app's lifetime: renewals,
    /// refunds, Ask to Buy approvals and purchases made on another Mac.
    func start() {
        guard isRequired, updates == nil else { return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result else { continue }
                await transaction.finish()
                await self?.apply(transaction)
            }
        }
        // A long-running session also notices cancellations and the end of a grace period: check
        // again when PureMac comes to the front, at most once an hour.
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date().timeIntervalSince(self.lastRefresh) > 3_600 else { return }
                Task { await self.refresh() }
            }
        }
        Task {
            for await result in Transaction.unfinished {
                if case .verified(let transaction) = result { await transaction.finish() }
            }
            await refresh()
        }
    }

    /// Reads the subscription from StoreKit's latest transaction for the product.
    func refresh() async {
        guard isRequired else { return }
        lastRefresh = Date()
        var candidate: Transaction?
        if let result = await Transaction.latest(for: Self.productID), case .verified(let latest) = result { candidate = latest }
        if let newest, newest.purchaseDate > (candidate?.purchaseDate ?? .distantPast) { candidate = newest }
        guard let candidate else {
            state = .inactive
            return
        }
        await update(from: candidate)
    }

    /// A transaction StoreKit just delivered — a purchase, renewal or refund — decides at once
    /// (`Transaction.latest` and the entitlements can take a moment to include it).
    func apply(_ transaction: Transaction) async {
        guard isRequired, transaction.productID == Self.productID else { return }
        await update(from: transaction)
    }

    /// The subscribe screen's purchase result.
    func purchaseCompleted(_ result: Result<Product.PurchaseResult, any Error>) async {
        if case .success(.success(.verified(let transaction))) = result {
            await transaction.finish()
            await apply(transaction)
        } else {
            await refresh()
        }
    }

    private func update(from transaction: Transaction) async {
        if transaction.purchaseDate >= (newest?.purchaseDate ?? .distantPast) { newest = transaction }
        // The status describes the group's latest transaction; right after a new purchase it can
        // still describe the previous one, and then only this transaction's own dates count.
        var status = await transaction.subscriptionStatus
        if let current = status, case .verified(let described) = current.transaction, described.id != transaction.id { status = nil }
        var willRenew = true
        if let status, case .verified(let renewal) = status.renewalInfo { willRenew = renewal.willAutoRenew }
        let (active, billingIssue) = Self.access(renewalState: status?.state, revoked: transaction.revocationDate != nil,
                                                 expires: transaction.expirationDate, now: Date())
        guard active else {
            state = .inactive
            return
        }
        state = .active(expires: transaction.expirationDate, willRenew: willRenew, billingIssue: billingIssue)
        scheduleExpiryCheck(transaction.expirationDate)
    }

    /// Whether a subscription gives access: active or in Apple's billing grace period (flagged as a
    /// billing issue). Billing retry without grace, expired and refunded subscriptions don't. Without
    /// a renewal state (offline, or StoreKit couldn't say) the transaction's own dates decide.
    nonisolated static func access(renewalState: Product.SubscriptionInfo.RenewalState?, revoked: Bool,
                                   expires: Date?, now: Date) -> (active: Bool, billingIssue: Bool) {
        switch renewalState {
        case .subscribed?: (true, false)
        case .inGracePeriod?: (true, true)
        case .expired?, .revoked?, .inBillingRetryPeriod?: (false, false)
        default: (!revoked && (expires ?? .distantFuture) > now, false)
        }
    }

    /// Restore Purchases: asks the App Store for this Apple Account's transactions (may ask the
    /// user to sign in), then reads the entitlements again.
    func restore() async {
        guard isRequired, !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }
        try? await AppStore.sync()
        await refresh()
    }

    /// An expiry doesn't always arrive as a transaction update while PureMac is open; check again
    /// shortly after the current period ends.
    private func scheduleExpiryCheck(_ expires: Date?) {
        expiryCheck?.cancel()
        // In Apple's billing grace period the period has already ended; renewals and the end of the
        // grace period arrive as transaction updates.
        guard let expires, expires > Date() else { return }
        let delay = expires.timeIntervalSinceNow + 60
        expiryCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    #if DEBUG
    /// Tests only: a state without StoreKit.
    func _testSet(_ state: State) { self.state = state }
    #endif
}

/// Whether this copy of PureMac was installed from the Mac App Store (or TestFlight), judged by
/// the code signature Apple applies to those copies — a copy built from source can't carry it.
enum StoreOrigin {
    nonisolated static let isAppStoreCopy: Bool = {
        if let receipt = Bundle.main.appStoreReceiptURL, FileManager.default.fileExists(atPath: receipt.path) { return true }
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        let requirements = [
            "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists",     // Mac App Store
            "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.25.1] exists",  // TestFlight
        ]
        for text in requirements {
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { continue }
            if SecCodeCheckValidity(code, [], requirement) == errSecSuccess { return true }
        }
        return false
    }()

    /// The subscription applies to App Store copies. DEBUG builds can opt in with
    /// `-PureMacStoreKitTesting YES` to try it against the scheme's local StoreKit configuration.
    static var requiresSubscription: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "PureMacStoreKitTesting") { return true }
        #endif
        return isAppStoreCopy
    }
}
