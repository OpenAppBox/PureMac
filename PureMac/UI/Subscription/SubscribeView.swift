import PureMacKit
import StoreKit
import SwiftUI

/// Shown instead of the main window in App Store copies until StoreKit confirms the yearly
/// subscription. StoreKit's own `SubscriptionStoreView` shows the localized price, the renewal
/// terms, Restore Purchases and the policy links Apple requires; PureMac adds what it does.
struct SubscribeView: View {
    @Environment(AppModel.self) private var app
    @State private var showingHistory = false

    var body: some View {
        ZStack {
            AuroraBackdrop(hue: SidebarItem.smartClean.hue)
            if app.subscription.state == .checking {
                ProgressView("Checking your subscription…")
            } else {
                VStack(spacing: 14) {
                    SubscriptionStoreView(productIDs: [SubscriptionModel.productID]) { header }
                        .storeButton(.visible, for: .restorePurchases)
                        .storeButton(.hidden, for: .cancellation)   // nothing to go back to
                        .subscriptionStorePolicyDestination(url: SubscriptionModel.termsOfUseURL, for: .termsOfService)
                        .subscriptionStorePolicyDestination(url: SubscriptionModel.privacyPolicyURL, for: .privacyPolicy)
                        .onInAppPurchaseCompletion { _, result in await app.subscription.purchaseCompleted(result) }
                        .frame(maxWidth: 640, maxHeight: 640)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    if !app.history.operations.isEmpty { historyLine }
                }
                .padding(32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Never hold files hostage: what earlier cleanups moved to the Trash can still be put back.
        .task { await app.history.reload() }
        .sheet(isPresented: $showingHistory) {
            VStack(spacing: 0) {
                HistoryView()
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { showingHistory = false }.keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
            .frame(minWidth: 900, minHeight: 620)
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(nsImage: Brand.appIcon).resizable().frame(width: 88, height: 88).accessibilityHidden(true)
            Text("Welcome to PureMac").font(.largeTitle.weight(.bold))
            Text("One yearly subscription includes every feature, all updates and support.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 8) {
                promise("checkmark.shield.fill", "Reviewed, narrowly scoped rules for caches, logs and leftovers. Nothing is removed without your confirmation.")
                promise("trash.fill", "Every cleanup shows a full preview first. Items go to the Trash, so you can put them back until you empty it.")
                promise("lock.fill", "Fully offline: no account, no analytics, and file names or app lists never leave your Mac.")
            }
            .frame(maxWidth: 480, alignment: .leading)
            .padding(.top, 4)
        }
        .padding(.vertical, 12)
    }

    private func promise(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.brandTeal)
        }
    }

    private var historyLine: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
            Text("Your cleanup history stays available, so you can still put items back from the Trash.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Open History") { showingHistory = true }
        }
        .frame(maxWidth: 640)
    }
}
