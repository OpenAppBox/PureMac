// Renders the placeholder PureMac app icon (1024×1024 PNG) in the OpenAppBox palette.
// Usage: swift Scripts/render_app_icon.swift <output.png>
// Replace it with an official icon via Scripts/make_app_icon.sh <your-1024.png>.
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

// macOS icon grid: 824 pt body centred on a 1024 canvas, continuous-corner radius ≈ 185.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

// Soft drop shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
NSColor(calibratedRed: 0.04, green: 0.23, blue: 0.56, alpha: 1).setFill()
shape.fill()
ctx.restoreGState()

// Background gradient: OpenAppBox blue → deep navy.
ctx.saveGState()
shape.addClip()
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.10, green: 0.53, blue: 1.00, alpha: 1),
    NSColor(calibratedRed: 0.04, green: 0.19, blue: 0.47, alpha: 1),
])!
gradient.draw(in: body, angle: -60)
ctx.restoreGState()

// Storage ring: a donut chart with a teal "reclaimable" segment.
let center = CGPoint(x: 512, y: 500)
let radius: CGFloat = 250
let lineWidth: CGFloat = 92
func arc(from start: CGFloat, to end: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
    path.lineWidth = lineWidth
    path.lineCapStyle = .round
    color.setStroke()
    path.stroke()
}
arc(from: 90, to: -125, color: NSColor.white.withAlphaComponent(0.95))
arc(from: -152, to: -232, color: NSColor(calibratedRed: 0.0, green: 0.88, blue: 0.78, alpha: 1))

// Sparkle in the centre: "pure".
func sparkle(at p: CGPoint, r: CGFloat) {
    let path = NSBezierPath()
    path.move(to: CGPoint(x: p.x, y: p.y + r))
    path.curve(to: CGPoint(x: p.x + r, y: p.y), controlPoint1: CGPoint(x: p.x + r * 0.12, y: p.y + r * 0.12), controlPoint2: CGPoint(x: p.x + r * 0.12, y: p.y + r * 0.12))
    path.curve(to: CGPoint(x: p.x, y: p.y - r), controlPoint1: CGPoint(x: p.x + r * 0.12, y: p.y - r * 0.12), controlPoint2: CGPoint(x: p.x + r * 0.12, y: p.y - r * 0.12))
    path.curve(to: CGPoint(x: p.x - r, y: p.y), controlPoint1: CGPoint(x: p.x - r * 0.12, y: p.y - r * 0.12), controlPoint2: CGPoint(x: p.x - r * 0.12, y: p.y - r * 0.12))
    path.curve(to: CGPoint(x: p.x, y: p.y + r), controlPoint1: CGPoint(x: p.x - r * 0.12, y: p.y + r * 0.12), controlPoint2: CGPoint(x: p.x - r * 0.12, y: p.y + r * 0.12))
    path.close()
    NSColor.white.setFill()
    path.fill()
}
sparkle(at: CGPoint(x: 512, y: 500), r: 120)
sparkle(at: CGPoint(x: 604, y: 596), r: 44)

image.unlockFocus()

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("encode failed") }
try png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
