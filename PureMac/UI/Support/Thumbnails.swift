import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Quick Look thumbnails, generated off the main thread and cached. Files without a content
/// thumbnail (or that fail) show their Finder icon instead.
@MainActor
enum ThumbnailCache {
    private static let images = NSCache<NSString, NSImage>()
    private static var failed: Set<String> = []

    static func cached(_ path: String, size: CGFloat) -> NSImage? {
        images.object(forKey: key(path, size) as NSString)
    }

    static func thumbnail(_ path: String, size: CGFloat) async -> NSImage? {
        let key = key(path, size)
        if let image = images.object(forKey: key as NSString) { return image }
        guard !failed.contains(key) else { return nil }
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: size, height: size),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            failed.insert(key)
            return nil
        }
        let image = representation.nsImage
        images.setObject(image, forKey: key as NSString)
        return image
    }

    private static func key(_ path: String, _ size: CGFloat) -> String { "\(Int(size))|\(path)" }
}

struct FileThumbnail: View {
    let path: String
    var size: CGFloat = 32
    /// The loaded image and the path it belongs to, so a reused view never shows the previous file.
    @State private var loaded: (path: String, image: NSImage?)?

    var body: some View {
        Group {
            if let image = (loaded?.path == path ? loaded?.image : nil) ?? ThumbnailCache.cached(path, size: size) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: max(3, size * 0.08), style: .continuous))
            } else {
                FileIcon(path: path, size: size)
            }
        }
        .frame(width: size, height: size)
        .task(id: path) {
            let image = await ThumbnailCache.thumbnail(path, size: size)
            loaded = (path, image)
        }
        .accessibilityHidden(true)
    }
}
