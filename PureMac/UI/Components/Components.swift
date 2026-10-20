import PureMacKit
import SwiftUI

/// A rounded content container used for summary cards.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        GlassCard(padding: padding) { content }
    }
}

struct CardTitle: View {
    let title: LocalizedStringKey
    var systemImage: String
    var body: some View {
        Label { Text(title).font(.headline) } icon: {
            Image(systemName: systemImage).foregroundStyle(Theme.brandBlue)
        }
    }
}

/// A big number with a caption.
struct Metric: View {
    let value: String
    let caption: LocalizedStringKey
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit()
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Horizontal capacity bar with labeled segments.
struct CapacityBar: View {
    struct Segment: Identifiable {
        var id: String
        var value: Double
        var color: Color
        var label: String
    }

    let segments: [Segment]
    let total: Double

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color.gradient)
                        .frame(width: max(0, geo.size.width * segment.value / max(total, 1)))
                        .help(segment.label)
                }
                Spacer(minLength: 0)
            }
            .background(Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .frame(height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(segments.map(\.label).joined(separator: ", ")))
    }
}

struct RiskBadge: View {
    let risk: RiskLevel
    var body: some View {
        Text(risk.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel(Text("Risk: \(risk.displayName)"))
    }

    private var color: Color {
        switch risk {
        case .low: .accentColor
        case .review: .orange
        case .protected: .secondary
        }
    }
}

struct ConfidenceBadge: View {
    let confidence: AssociationConfidence
    var body: some View {
        Text(confidence.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel(Text("Association: \(confidence.displayName)"))
    }

    private var color: Color {
        switch confidence {
        case .confirmed: .accentColor
        case .likely: .teal
        case .ambiguous: .orange
        case .shared: .purple
        case .protected: .secondary
        }
    }
}

/// Inline notice for limitations, partial results and errors.
struct NoticeView: View {
    enum Tone { case info, warning, error }
    let tone: Tone
    let title: LocalizedStringKey
    var message: LocalizedStringKey?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch tone {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private var color: Color {
        switch tone {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

/// File icon from Finder (cached by NSWorkspace).
struct FileIcon: View {
    let path: String
    var size: CGFloat = 16
    var body: some View {
        Image(nsImage: IconCache.icon(forPath: path))
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The one place a page says what is selected and offers the next step. Floats at the bottom of
/// the content; the action always opens a review (⌘⌫), never removes anything directly.
struct SelectionActionBar: View {
    enum Subject { case items, apps, copies }

    let count: Int
    var subject: Subject = .items
    var bytes: Int64?
    var tint: Color
    var actionTitle: LocalizedStringKey = "Review & Move to Trash"
    var actionSymbol = "trash"
    var isDisabled = false
    var secondary: AnyView?
    let onClear: () -> Void
    let action: () -> Void
    @Environment(\.byteStyle) private var byteStyle

    // Localize the whole counted phrase so each language can inflect both the noun and verb.
    private var selectionSummary: String {
        switch subject {
        case .items: String(localized: "\(count) items selected")
        case .apps: String(localized: "\(count) apps selected")
        case .copies: String(localized: "\(count) copies selected")
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                if let bytes {
                    RollingText(text: ByteFormat.string(bytes, style: byteStyle), font: .metric(18))
                }
                Text(selectionSummary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button("Clear", action: onClear)
                .buttonStyle(.borderless)
                .help("Deselect everything")
            if let secondary { secondary }
            Button(action: action) { Label(actionTitle, systemImage: actionSymbol).lineLimit(1).fixedSize() }
                .buttonStyle(.glow(tint))
                .disabled(isDisabled || count == 0)
                .keyboardShortcut(.delete, modifiers: [.command])
                .help("Opens a review of exactly what will move to the Trash (⌘⌫). Nothing is removed until you confirm.")
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.cardHighlight, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .padding(.bottom, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// A checkbox bound to membership of `id` in a set.
struct SetCheckbox<ID: Hashable>: View {
    let id: ID
    @Binding var selection: Set<ID>
    var label: String
    var isDisabled = false

    var body: some View {
        Toggle(isOn: Binding(get: { selection.contains(id) },
                             set: { on in if on { selection.insert(id) } else { selection.remove(id) } })) { EmptyView() }
            .toggleStyle(.checkbox)
            .disabled(isDisabled)
            .accessibilityLabel(label)
    }
}

/// A compact "sort / filter" menu button for list headers.
struct ListMenuPicker<Value: Hashable & Identifiable>: View {
    let title: LocalizedStringKey
    let symbol: String
    @Binding var value: Value
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        Menu {
            Picker(title, selection: $value) {
                ForEach(options) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(label(value), systemImage: symbol).font(.caption.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(title)
    }
}

extension View {
    /// Floats `bar` at the bottom while `isPresented`. The spring applies to the bar only, so the
    /// page underneath (tables, treemaps) never animates along with it.
    func selectionBar<Bar: View>(isPresented: Bool, @ViewBuilder bar: () -> Bar) -> some View {
        overlay(alignment: .bottom) {
            ZStack {
                if isPresented { bar() }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isPresented)
        }
    }
}
