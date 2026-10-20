import SwiftUI

/// In-content search field (a toolbar `.searchable` forces NSToolbar rebuilds on navigation).
struct SearchField: View {
    @Binding var text: String
    let prompt: LocalizedStringKey

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.cardStroke))
    }
}
