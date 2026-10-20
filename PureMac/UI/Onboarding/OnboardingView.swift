import SwiftUI

/// First-run explanation of what PureMac does, what it cannot access, and its no-auto-delete promise.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    let onFinish: () -> Void

    var body: some View {
        ZStack {
            AuroraBackdrop(hue: SidebarItem.overview.hue)
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 22) {
                    ScannerCore(intensity: 0.5, cancelling: false) {
                        Image(nsImage: Brand.appIcon)
                            .resizable().frame(width: 74, height: 74)
                            .shadow(color: Theme.glow.opacity(0.5), radius: 12)
                    }
                    .frame(width: 190, height: 190)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Welcome to PureMac").font(.system(size: 32, weight: .bold, design: .rounded))
                        Text(Brand.tagline).font(.title3).foregroundStyle(.secondary)
                        Text("An OpenAppBox app").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .entrance()
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    feature("magnifyingglass", Theme.brandBlue, "What PureMac scans",
                            "Your home folder by default. It reads names, sizes and dates — never the contents of your files.").entrance(0.1)
                    feature("hand.raised.fill", Theme.brandTeal, "Nothing is deleted automatically",
                            "Every cleanup shows a full preview first. Items go to the Trash, so you can put them back until you empty it.").entrance(0.18)
                    feature("lock.shield.fill", Theme.series[6], "What it can’t see",
                            "macOS protects Mail, Messages, Safari and other apps’ data. PureMac reports these as gaps instead of guessing.").entrance(0.26)
                    feature("network.slash", Theme.series[1], "Private by design",
                            "Fully offline: no account, no analytics, and file names or app lists never leave your Mac.").entrance(0.34)
                }
                Text("When you scan, macOS may ask whether PureMac can access Desktop, Documents, Downloads or data from other apps. You can decline; those folders are then skipped. Full Disk Access is optional.")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(8)
                    .entrance(0.4)
                HStack {
                    Button("Open Full Disk Access Settings…") { SystemActions.openFullDiskAccessSettings() }
                        .buttonStyle(.glow(.secondary, prominent: false))
                    Spacer()
                    Button {
                        app.settings.hasCompletedOnboarding = true
                        onFinish()
                    } label: { Label("Get Started", systemImage: "arrow.right") }
                        .buttonStyle(.glow(Theme.brandBlue))
                        .keyboardShortcut(.defaultAction)
                }
                .entrance(0.45)
            }
            .padding(32)
        }
        .frame(width: 720, height: 620)
    }

    private func feature(_ symbol: String, _ color: Color, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        GlassCard(padding: 16, tint: color) {
            VStack(alignment: .leading, spacing: 8) {
                IconTile(symbol: symbol, gradient: .tile(color), size: 32)
                    .shadow(color: color.opacity(0.4), radius: 6, y: 2)
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(8)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
