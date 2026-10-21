import PureMacKit
import SwiftUI

/// macOS only lets a sandboxed app see folders the user chooses. Shown in place
/// of every page until the home folder is granted, so no feature quietly finds nothing.
struct AccessGateView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let home = PathTools.userHome
        let name = FileManager.default.displayName(atPath: home)
        ScreenScaffold(item: .overview) {
        HeroState(item: .overview, symbol: "folder.badge.person.crop",
                  title: "Allow access to your home folder",
                  message: LocalizedStringKey("macOS asks you to choose the folders PureMac may look at. Choose your home folder (“\(name)”) in the next window and click Allow Access. PureMac reads only names, sizes and dates, and never moves anything without your review. You can revoke access in Settings.")) {
            Button {
                app.access.request(home, message: String(localized: "Choose your home folder (“\(name)”) so PureMac can measure it."))
            } label: {
                Label("Choose Home Folder…", systemImage: "folder")
            }
            .buttonStyle(.glow(SidebarItem.overview.hue))
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .entrance()
        }
    }
}
