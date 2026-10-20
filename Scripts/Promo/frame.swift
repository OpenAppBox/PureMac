// Places a window screenshot on a soft PureMac-branded background with a natural shadow, in a
// 16:10 canvas suited to websites and App Store-style listings.
//
//   swift frame.swift <window.png> <framed.png> [dark|light]
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])), let window = NSBitmapImageRep(data: data) else {
    print("usage: frame.swift <window.png> <framed.png> [dark|light]"); exit(2)
}
let light = args.count > 3 && args[3] == "light"
let w = CGFloat(window.pixelsWide), h = CGFloat(window.pixelsHigh)
let canvasW = (w * 1.16).rounded(), canvasH = (canvasW * 10 / 16).rounded()
let size = NSSize(width: canvasW, height: canvasH)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvasW), pixelsHigh: Int(canvasH), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
func c(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let full = NSRect(origin: .zero, size: size)
let base = light ? NSGradient(colors: [c(0xEEF3FF), c(0xE3F4F4), c(0xF3EDFF)])! : NSGradient(colors: [c(0x070D1F), c(0x0B2340), c(0x0A3A44)])!
base.draw(in: full, angle: -35)
// Two soft light fields in the brand colors.
for (center, radius, color) in [(NSPoint(x: canvasW * 0.18, y: canvasH * 0.85), canvasW * 0.42, light ? c(0x7AA7FF, 0.35) : c(0x2F7BFF, 0.35)),
                                (NSPoint(x: canvasW * 0.86, y: canvasH * 0.12), canvasW * 0.40, light ? c(0x5FE0C8, 0.35) : c(0x1FC8A8, 0.28))] {
    NSGradient(colors: [color, color.withAlphaComponent(0)])!.draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
}
let origin = NSPoint(x: ((canvasW - w) / 2).rounded(), y: ((canvasH - h) / 2).rounded() - canvasH * 0.01)
let frame = NSRect(origin: origin, size: NSSize(width: w, height: h))
let radius = w * 0.0105
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(light ? 0.28 : 0.55)
shadow.shadowBlurRadius = w * 0.035
shadow.shadowOffset = NSSize(width: 0, height: -w * 0.012)
shadow.set()
NSColor.black.setFill()
NSBezierPath(roundedRect: frame.insetBy(dx: 2, dy: 2), xRadius: radius, yRadius: radius).fill()
NSGraphicsContext.restoreGraphicsState()
window.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
// A hairline edge like a real window.
NSColor.white.withAlphaComponent(light ? 0.6 : 0.12).setStroke()
let edge = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
edge.lineWidth = 1
edge.stroke()
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("framed \(args[2]) (\(Int(canvasW))×\(Int(canvasH)))")
