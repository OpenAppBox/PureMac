import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Fast icon lookup. `NSWorkspace.icon(forFile:)` hits LaunchServices and the file system on every
/// call; rendering hundreds of rows called it on the main thread for every body evaluation.
/// Plain files and folders share one icon per type; only bundles and volumes are looked up per path.
@MainActor
enum IconCache {
    private static let byPath = NSCache<NSString, NSImage>()
    private static var byType: [String: NSImage] = [:]
    private static let folderIcon = NSWorkspace.shared.icon(for: .folder)

    /// Extensions whose icon is specific to the item (apps, bundles, packages).
    private static let perItemExtensions: Set<String> = ["app", "bundle", "framework", "prefpane", "plugin", "appex", "xcarchive",
                                                        "photoslibrary", "musiclibrary", "pkg", "mpkg", "dmg", "kext", "xpc"]

    static func icon(forPath path: String, isDirectory: Bool? = nil) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        // A folder merely named like a bundle (a cache folder "com.example.app") gets a folder icon,
        // not a blank document; real bundles have a Contents folder.
        if perItemExtensions.contains(ext), ext == "app" || ext == "bundle" || ext == "framework",
           FileManager.default.isDirectoryFast(path), !FileManager.default.isDirectoryFast(path + "/Contents") {
            return folderIcon
        }
        if perItemExtensions.contains(ext) || path.hasPrefix("/Volumes/") && (path as NSString).pathComponents.count == 3 {
            if let cached = byPath.object(forKey: path as NSString) { return cached }
            let image = NSWorkspace.shared.icon(forFile: path)
            byPath.setObject(image, forKey: path as NSString)
            return image
        }
        // Folders named like bundle IDs (com.example.app) have a dot but are still folders.
        let directory = isDirectory ?? FileManager.default.isDirectoryFast(path)
        if directory { return folderIcon }
        let key = ext.isEmpty ? "public.data" : ext
        if let cached = byType[key] { return cached }
        let type = UTType(filenameExtension: ext) ?? .data
        let image = NSWorkspace.shared.icon(for: type)
        byType[key] = image
        return image
    }
}

extension FileManager {
    /// `lstat`-based directory check without following symlinks (cheap, no LaunchServices).
    func isDirectoryFast(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }
}

/// Samples an app icon's dominant color off the main thread, from a 16-pixel rendition
/// (never the full multi-resolution icon). Results are cached for the session.
actor IconTintStore {
    static let shared = IconTintStore()
    private var cache: [String: Color] = [:]

    func tint(forPath path: String) -> Color? {
        if let cached = cache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        var rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = { ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 8, height: 8)); return ctx.data }() else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: 8 * 8 * 4)
        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0
        for i in 0..<64 {
            let a = Double(pixels[i * 4 + 3]) / 255
            guard a > 0.5 else { continue }
            let pr = Double(pixels[i * 4]) / 255 / a, pg = Double(pixels[i * 4 + 1]) / 255 / a, pb = Double(pixels[i * 4 + 2]) / 255 / a
            let w = 0.15 + (max(pr, pg, pb) - min(pr, pg, pb))   // favor saturated pixels over white/gray
            r += pr * w; g += pg * w; b += pb * w; weight += w
        }
        guard weight > 0 else { return nil }
        let color = Color(.sRGB, red: r / weight, green: g / weight, blue: b / weight)
        cache[path] = color
        return color
    }
}
