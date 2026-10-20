import PureMacKit
import SwiftUI

@main
struct PureMacApp: App {
    @State private var app = AppModel()

    init() {
        AppLanguage.applyWritingDirection()
    }

    var body: some Scene {
        Window("PureMac", id: "main") {
            RootView()
                .environment(app)
                .environment(\.byteStyle, app.settings.byteStyle)
                .environment(\.appReducesMotion, app.settings.reduceAnimations)
                .preferredColorScheme(app.settings.appearance.colorScheme)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .defaultSize(width: 1280, height: 840)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutCommand()
            }
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button("Scan Now") { app.scan.start() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(app.scan.isBusy || app.store == nil)
                Button("Cancel Scan") { app.scan.cancel() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(app.scan.phase != .scanning)
            }
            CommandGroup(replacing: .help) {
                Link("PureMac Help", destination: Brand.websiteURL)
            }
        }

        Window("About PureMac", id: "about") {
            AboutView()
                .environment(app)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(app)
                .environment(\.byteStyle, app.settings.byteStyle)
                .environment(\.appReducesMotion, app.settings.reduceAnimations)
                .preferredColorScheme(app.settings.appearance.colorScheme)
        }
    }
}

private struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("About PureMac") { openWindow(id: "about") }
    }
}
