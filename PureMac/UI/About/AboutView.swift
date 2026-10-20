import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: Brand.appIcon)
                .resizable().frame(width: 96, height: 96)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(Brand.productName).font(.title.weight(.semibold))
                Text("Version \(Brand.version) (\(Brand.build))").foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text(Brand.tagline).multilineTextAlignment(.center)
            Text("Works entirely on this Mac — no account, analytics or network access.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Divider()
            HStack(spacing: 10) {
                Image(Brand.publisherLogoAsset)
                    .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                Text(Brand.publisher).font(.headline)
                Link(Brand.websiteURL.host() ?? Brand.websiteURL.absoluteString, destination: Brand.websiteURL)
            }
            Text(Brand.copyright).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 380)
    }
}
