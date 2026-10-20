import SwiftUI

/// Large, friendly empty/intro state on glass, tinted by the module.
struct HeroState<Actions: View>: View {
    let item: SidebarItem
    var symbol: String?
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var busy = false
    @ViewBuilder var actions: Actions

    var body: some View {
        GlassCard(padding: 34, tint: item.hue) {
            HStack(spacing: 30) {
                ScannerCore(intensity: busy ? 0.9 : 0.3, cancelling: false, hue: item.hue) {
                    if busy {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: symbol ?? item.symbol)
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(item.hue)
                    }
                }
                .frame(width: 200, height: 200)
                VStack(alignment: .leading, spacing: 12) {
                    Text(title).font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(message).foregroundStyle(.secondary).lineLimit(4)
                    HStack(spacing: 10) { actions }
                }
                Spacer(minLength: 0)
            }
        }
    }
}
