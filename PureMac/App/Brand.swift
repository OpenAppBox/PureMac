import Foundation
import AppKit
import SwiftUI

/// Product identity. The app icon (`AppIcon`) and the publisher logo (`OpenAppBoxLogo`) live in
/// `Assets.xcassets`; `Scripts/make_app_icon.sh <icon-1024.png>` regenerates every icon size.
enum Brand {
    static let productName = "PureMac"
    static let publisher = "OpenAppBox"
    static let tagline = "Understand your Mac. Reclaim your space. Keep what matters."
    /// Opened only when the user clicks the link in About.
    static let websiteURL = URL(string: "https://openappbox.com")!
    /// Asset catalog image set holding the publisher logo (`OpenAppBoxLogo.imageset`).
    static let publisherLogoAsset = "OpenAppBoxLogo"

    /// The app icon from the asset catalog (works even when hosted by the test runner).
    static var appIcon: NSImage {
        NSImage(named: NSImage.applicationIconName) ?? NSApp.applicationIconImage
    }

    static var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "© \(publisher)"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
}
