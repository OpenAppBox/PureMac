import SwiftUI

// MARK: - Motion preference

private struct ReducedMotionKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// App-level "Reduce animations" (Settings), honored in addition to the system's Reduce Motion.
    var appReducesMotion: Bool {
        get { self[ReducedMotionKey.self] }
        set { self[ReducedMotionKey.self] = newValue }
    }
}

private struct IntroAnimationsKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// `true` the first time a screen is shown in a session. Intro animations (entrances, chart
    /// reveals, bar growth) play only then, so returning to a screen is instant.
    var playsIntroAnimations: Bool {
        get { self[IntroAnimationsKey.self] }
        set { self[IntroAnimationsKey.self] = newValue }
    }
}

/// Reads both the system Reduce Motion setting and PureMac's own preference.
@propertyWrapper
struct MotionReduced: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.appReducesMotion) private var app
    var wrappedValue: Bool { system || app }
}

// MARK: - Aurora backdrop

/// Soft drifting light fields over a deep canvas. The drift runs as Core Animation in the render
/// server (no per-frame SwiftUI work) and stops with Reduce Motion or PureMac's own setting.
struct AuroraBackdrop: View {
    var hue: Color
    var intensity: Double = 1
    @MotionReduced private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        AuroraLayer(hue: hue, intensity: intensity, animated: !reduceMotion)
        // Extend under the title bar, but not horizontally under the floating sidebar.
        .ignoresSafeArea(edges: .vertical)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Static noise texture (drawn once).
private struct GrainOverlay: View {
    var body: some View {
        Canvas { context, size in
            var generator = SeededGenerator(seed: 7)
            let count = Int(size.width * size.height / 900)
            for _ in 0..<count {
                let x = CGFloat.random(in: 0..<size.width, using: &generator)
                let y = CGFloat.random(in: 0..<size.height, using: &generator)
                context.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white))
            }
        }
        .allowsHitTesting(false)
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Glass card

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 18
    var tint: Color?
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // No live backdrop blur: a translucent surface over the soft aurora looks the same
                // and costs nothing per frame. The shadow is on the shape only (never the content).
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .fill(Theme.cardSurface)
                        .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
                    if let tint {
                        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                            .fill(tint.opacity(0.07))
                    }
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .strokeBorder(hovering ? Theme.cardHighlight : Theme.cardStroke, lineWidth: 1)
                }
            }
            .onHover { hovering = $0 }
    }
}

/// A colored rounded-square icon tile.
struct IconTile: View {
    let symbol: String
    var gradient: LinearGradient
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(gradient)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
            }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension LinearGradient {
    static func tile(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color.opacity(0.95), color.mix(with: .black, by: 0.28)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Big screen header: icon tile, title, subtitle, and trailing accessory.
struct ModuleHeader<Trailing: View>: View {
    let item: SidebarItem
    let subtitle: LocalizedStringKey
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(symbol: item.symbol, gradient: item.gradient, size: 44)
                .shadow(color: item.hue.opacity(0.45), radius: 12, y: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 26, weight: .bold, design: .rounded))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.bottom, 4)
    }
}

extension ModuleHeader where Trailing == EmptyView {
    init(item: SidebarItem, subtitle: LocalizedStringKey) {
        self.init(item: item, subtitle: subtitle) { EmptyView() }
    }
}

/// Standard screen scaffold: aurora backdrop + scrolling content column.
struct ScreenScaffold<Content: View>: View {
    let item: SidebarItem
    var scrolls = true
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            if scrolls {
                ScrollView {
                    // Lazy: cards below the fold are built and laid out only when scrolled to.
                    LazyVStack(alignment: .leading, spacing: 18) { content }
                        .padding(.horizontal, 26)
                        .padding(.vertical, 22)
                        .frame(maxWidth: 1240, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
                .scrollContentBackground(.hidden)
                #if DEBUG
                .defaultScrollAnchor(UserDefaults.standard.bool(forKey: "PureMacDemoScrollBottom") ? .bottom : .top)
                #endif
            } else {
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
    }
}

// MARK: - Buttons

/// Primary call-to-action with a luminous gradient.
struct GlowButtonStyle: ButtonStyle {
    var color: Color = Theme.brandBlue
    var prominent = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(prominent ? .white : color)
            .background {
                Capsule()
                    .fill(prominent
                          ? AnyShapeStyle(LinearGradient(colors: [color.mix(with: .white, by: 0.12), color.mix(with: .black, by: 0.12)], startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(color.opacity(0.12)))
            }
            .overlay { Capsule().strokeBorder(.white.opacity(prominent ? 0.25 : 0), lineWidth: 0.5) }
            .shadow(color: prominent ? color.opacity(0.35) : .clear, radius: 6, y: 2)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GlowButtonStyle {
    static var glow: GlowButtonStyle { GlowButtonStyle() }
    static func glow(_ color: Color, prominent: Bool = true) -> GlowButtonStyle { GlowButtonStyle(color: color, prominent: prominent) }
}

// MARK: - Motion helpers

/// Staggered entrance: fades and lifts content in, once. Disabled with Reduce Motion.
struct Entrance: ViewModifier {
    let delay: Double
    @MotionReduced private var motionReduced
    @Environment(\.playsIntroAnimations) private var playsIntro
    @State private var shown = false
    private var reduceMotion: Bool { motionReduced || !playsIntro }

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.22).delay(min(delay, 0.1) * 0.6)) { shown = true }
            }
    }
}

extension View {
    func entrance(_ delay: Double = 0) -> some View { modifier(Entrance(delay: delay)) }
}

/// A number that rolls between values.
struct RollingText: View {
    let text: String
    var font: Font = .metric()
    /// Digit-roll transition; reserve for a few hero numbers (each roll re-renders glyphs per frame).
    var rolls = false

    var body: some View {
        if rolls {
            Text(text)
                .font(font)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.3), value: text)
        } else {
            Text(text).font(font).monospacedDigit()
        }
    }
}

/// Label + value pair for hero stats.
struct StatBlock: View {
    let value: String
    let label: LocalizedStringKey
    var tint: Color?
    var size: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            RollingText(text: value, font: .metric(size))
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Small uppercase section label.
struct Eyebrow: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text).font(.eyebrow).foregroundStyle(.secondary).tracking(0.6)
    }
}

/// Loading placeholder emphasis. Static on purpose: a repeating shimmer re-renders every frame.
extension View {
    func shimmer() -> some View { opacity(0.6) }
}
