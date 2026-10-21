// An App Store screenshot: a headline and a sub-line above a window screenshot, on the
// PureMac-branded background. The canvas is 1440×900 (a Mac App Store size); long headlines are
// set smaller so they always fit on one line.
//
//   swift appstore_frame.swift <window.png> <out.png> <dark|light> <headline> <subline>
import AppKit

let args = CommandLine.arguments
guard args.count >= 6, let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])), let window = NSBitmapImageRep(data: data) else {
    print("usage: appstore_frame.swift <window.png> <out.png> <dark|light> <headline> <subline>"); exit(2)
}
let light = args[3] == "light"
let headline = args[4], subline = args[5]
let canvasW: CGFloat = 1440, canvasH: CGFloat = 900
let size = NSSize(width: canvasW, height: canvasH)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvasW), pixelsHigh: Int(canvasH), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
func c(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// The largest font size up to `size` at which `text` fits in `width` on one line.
func fitted(_ text: String, size: CGFloat, weight: NSFont.Weight, width: CGFloat, color: NSColor) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    var points = size
    while true {
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: points, weight: weight),
                                                                       .foregroundColor: color, .paragraphStyle: paragraph])
        if attributed.size().width <= width || points <= 18 { return attributed }
        points -= 1
    }
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let full = NSRect(origin: .zero, size: size)
let base = light ? NSGradient(colors: [c(0xEEF3FF), c(0xE3F4F4), c(0xF3EDFF)])! : NSGradient(colors: [c(0x070D1F), c(0x0B2340), c(0x0A3A44)])!
base.draw(in: full, angle: -35)
for (center, radius, color) in [(NSPoint(x: canvasW * 0.18, y: canvasH * 0.85), canvasW * 0.42, light ? c(0x7AA7FF, 0.35) : c(0x2F7BFF, 0.35)),
                                (NSPoint(x: canvasW * 0.86, y: canvasH * 0.12), canvasW * 0.40, light ? c(0x5FE0C8, 0.35) : c(0x1FC8A8, 0.28))] {
    NSGradient(colors: [color, color.withAlphaComponent(0)])!.draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
}

// Text, top down (AppKit's origin is bottom-left).
let textWidth = canvasW - 120
let title = fitted(headline, size: 46, weight: .bold, width: textWidth, color: light ? c(0x0B1530) : .white)
let sub = fitted(subline, size: 24, weight: .regular, width: textWidth, color: light ? c(0x0B1530, 0.68) : NSColor.white.withAlphaComponent(0.74))
let titleTop: CGFloat = 44
let titleHeight = title.size().height, subHeight = sub.size().height
title.draw(in: NSRect(x: 60, y: canvasH - titleTop - titleHeight, width: textWidth, height: titleHeight))
let subTop = titleTop + titleHeight + 6
sub.draw(in: NSRect(x: 60, y: canvasH - subTop - subHeight, width: textWidth, height: subHeight))

// The window, as large as the space below the text allows.
let windowTop = subTop + subHeight + 30
let available = canvasH - windowTop - 30
let scale = min(available / CGFloat(window.pixelsHigh), (canvasW - 120) / CGFloat(window.pixelsWide))
let w = (CGFloat(window.pixelsWide) * scale).rounded(), h = (CGFloat(window.pixelsHigh) * scale).rounded()
let frame = NSRect(x: ((canvasW - w) / 2).rounded(), y: 30 + ((available - h) / 2).rounded(), width: w, height: h)
let radius = w * 0.0105
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(light ? 0.26 : 0.55)
shadow.shadowBlurRadius = w * 0.03
shadow.shadowOffset = NSSize(width: 0, height: -w * 0.01)
shadow.set()
NSColor.black.setFill()
NSBezierPath(roundedRect: frame.insetBy(dx: 2, dy: 2), xRadius: radius, yRadius: radius).fill()
NSGraphicsContext.restoreGraphicsState()
window.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
NSColor.white.withAlphaComponent(light ? 0.6 : 0.12).setStroke()
let edge = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
edge.lineWidth = 1
edge.stroke()
NSGraphicsContext.restoreGraphicsState()

// App Store screenshots must not have transparency: flatten onto an opaque RGB image.
let cg = rep.cgImage!
let ctx = CGContext(data: nil, width: Int(canvasW), height: Int(canvasH), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
let flat = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try flat.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("App Store screenshot \(args[2]) (\(Int(canvasW))×\(Int(canvasH)))")
