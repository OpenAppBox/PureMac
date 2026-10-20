import AppKit
import QuartzCore
import SwiftUI

// Continuous animations are implemented with Core Animation layers so they run in the render
// server, not as per-frame SwiftUI updates on the main thread (which cost ~25–40% CPU when idle).

private func resolved(_ color: Color, in appearance: NSAppearance, alpha: CGFloat? = nil) -> CGColor {
    var cg = NSColor.gray.cgColor
    appearance.performAsCurrentDrawingAppearance {
        let ns = NSColor(color)
        cg = (alpha.map { ns.withAlphaComponent($0 * ns.alphaComponent) } ?? ns).cgColor
    }
    return cg
}

// MARK: - Aurora backdrop layer

#if DEBUG
@MainActor enum LayerViewCounter {
    static var aurora = 0
    static var orbit = 0
}
#endif

final class AuroraLayerView: NSView {
    var hue: Color = Theme.brandBlue { didSet { applyColors() } }
    var intensity: CGFloat = 1 { didSet { applyColors() } }
    var animated = true { didSet { if oldValue != animated { needsLayout = true } } }

    private let base = CAGradientLayer()
    private let blobs = [CAGradientLayer(), CAGradientLayer(), CAGradientLayer()]
    private var lastSize: CGSize = .zero

    #if DEBUG
    deinit { MainActor.assumeIsolated { LayerViewCounter.aurora -= 1 } }
    #endif

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        #if DEBUG
        LayerViewCounter.aurora += 1
        #endif
        wantsLayer = true
        layer = CALayer()
        layer?.addSublayer(base)
        for blob in blobs {
            blob.type = .radial
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 1, y: 1)
            layer?.addSublayer(blob)
        }
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        let appearance = effectiveAppearance
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let strength = (dark ? 0.30 : 0.20) * intensity
        CATransaction.begin()
        // Hue changes crossfade in the render server (implicit CA animation), not per SwiftUI frame.
        CATransaction.setAnimationDuration(0.45)
        base.colors = [resolved(Theme.canvasTop, in: appearance), resolved(Theme.canvasBottom, in: appearance)]
        for (blob, color) in zip(blobs, [hue, Theme.brandTeal, Theme.brandBlue]) {
            blob.colors = [resolved(color, in: appearance, alpha: strength), resolved(color, in: appearance, alpha: 0)]
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let changed = size != lastSize
        lastSize = size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.frame = bounds
        let span = max(size.width, size.height)
        let specs: [(scale: CGFloat, from: CGPoint, to: CGPoint)] = [
            (0.9, CGPoint(x: 0.62, y: 0.16), CGPoint(x: 0.78, y: 0.05)),
            (0.7, CGPoint(x: 0.2, y: 0.78), CGPoint(x: 0.08, y: 0.92)),
            (0.55, CGPoint(x: 0.12, y: 0.34), CGPoint(x: 0.3, y: 0.2)),
        ]
        for (blob, spec) in zip(blobs, specs) {
            let d = span * spec.scale
            blob.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            let from = CGPoint(x: size.width * spec.from.x, y: size.height * spec.from.y)
            let to = CGPoint(x: size.width * spec.to.x, y: size.height * spec.to.y)
            blob.position = from
            if changed || blob.animation(forKey: "drift") == nil {
                blob.removeAnimation(forKey: "drift")
                if animated {
                    let drift = CABasicAnimation(keyPath: "position")
                    drift.fromValue = NSValue(point: from)
                    drift.toValue = NSValue(point: to)
                    drift.duration = 18
                    drift.autoreverses = true
                    drift.repeatCount = .infinity
                    drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    blob.add(drift, forKey: "drift")
                }
            }
        }
        CATransaction.commit()
    }
}

struct AuroraLayer: NSViewRepresentable {
    var hue: Color
    var intensity: Double
    var animated: Bool

    func makeNSView(context: Context) -> AuroraLayerView {
        let view = AuroraLayerView()
        view.hue = hue
        view.intensity = intensity
        view.animated = animated
        return view
    }

    func updateNSView(_ view: AuroraLayerView, context: Context) {
        view.hue = hue
        view.intensity = intensity
        view.animated = animated
    }
}

// MARK: - Scanner core layer

/// Ticks, a conic radar sweep, three orbiting arcs, a breathing glow and an emitter — all
/// render-server animations.
final class OrbitCoreView: NSView {
    var hue: Color = Theme.brandBlue { didSet { applyColors() } }
    var accent: Color = Theme.brandTeal { didSet { applyColors() } }
    var animated = true { didSet { if oldValue != animated { rebuildAnimations() } } }
    var intensity: CGFloat = 0.4 { didSet { updateEmitter() } }

    private let glow = CAGradientLayer()
    private let ticks = CAShapeLayer()
    private let sweep = CAGradientLayer()
    private let sweepMask = CAShapeLayer()
    private let arcs = [CAShapeLayer(), CAShapeLayer(), CAShapeLayer()]
    private let emitter = CAEmitterLayer()
    private let spark = CAEmitterCell()
    private var lastSize: CGSize = .zero

    #if DEBUG
    deinit { MainActor.assumeIsolated { LayerViewCounter.orbit -= 1 } }
    #endif

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        #if DEBUG
        LayerViewCounter.orbit += 1
        #endif
        wantsLayer = true
        layer = CALayer()
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        sweep.type = .conic
        sweep.startPoint = CGPoint(x: 0.5, y: 0.5)
        sweep.endPoint = CGPoint(x: 0.5, y: 0)
        sweep.mask = sweepMask
        ticks.fillColor = nil
        ticks.lineWidth = 1.5
        for arc in arcs {
            arc.fillColor = nil
            arc.lineCap = .round
            arc.shadowOpacity = 0.8
            arc.shadowRadius = 4
            arc.shadowOffset = .zero
        }
        spark.contents = Self.dotImage()
        spark.lifetime = 2.4
        spark.velocity = 34
        spark.velocityRange = 18
        spark.emissionRange = .pi * 2
        spark.alphaSpeed = -0.4
        spark.scale = 0.22
        spark.scaleRange = 0.12
        spark.scaleSpeed = -0.05
        emitter.emitterShape = .circle
        emitter.emitterMode = .outline
        emitter.renderMode = .additive
        emitter.emitterCells = [spark]
        [glow, emitter, ticks, sweep].forEach { layer?.addSublayer($0) }
        arcs.forEach { layer?.addSublayer($0) }
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private static func dotImage() -> CGImage? {
        let size = 16
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: 8, y: 8), startRadius: 0, endCenter: CGPoint(x: 8, y: 8), endRadius: 8, options: [])
        }
        return ctx.makeImage()
    }

    private func applyColors() {
        let appearance = effectiveAppearance
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.colors = [resolved(hue, in: appearance, alpha: 0.38), resolved(hue, in: appearance, alpha: 0)]
        ticks.strokeColor = resolved(Theme.track, in: appearance)
        sweep.colors = [resolved(hue, in: appearance, alpha: 0.45), resolved(hue, in: appearance, alpha: 0), resolved(hue, in: appearance, alpha: 0)]
        sweep.locations = [0, 0.33, 1]
        let arcColors = [resolved(hue, in: appearance), resolved(accent, in: appearance), resolved(hue, in: appearance, alpha: 0.7)]
        for (arc, color) in zip(arcs, arcColors) {
            arc.strokeColor = color
            arc.shadowColor = color
        }
        spark.color = resolved(accent, in: appearance)
        CATransaction.commit()
    }

    private func updateEmitter() {
        emitter.birthRate = animated ? Float(0.35 + intensity * 1.6) : 0
        spark.birthRate = 14
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        guard size.width > 0, size.height > 0, size != lastSize else { return }
        lastSize = size
        let side = min(size.width, size.height)
        let rect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = rect
        emitter.frame = bounds
        emitter.emitterPosition = center
        emitter.emitterSize = CGSize(width: side * 0.5, height: side * 0.5)

        let tickPath = CGMutablePath()
        let r = side / 2 - 4
        for i in 0..<72 {
            let a = Double(i) / 72 * 2 * .pi
            let inner = r - (i % 6 == 0 ? 9 : 4)
            tickPath.move(to: CGPoint(x: center.x + CGFloat(cos(a)) * inner, y: center.y + CGFloat(sin(a)) * inner))
            tickPath.addLine(to: CGPoint(x: center.x + CGFloat(cos(a)) * r, y: center.y + CGFloat(sin(a)) * r))
        }
        ticks.frame = bounds
        ticks.path = tickPath

        let sweepRect = rect.insetBy(dx: 22, dy: 22)
        sweep.bounds = CGRect(origin: .zero, size: sweepRect.size)
        sweep.position = center
        sweepMask.frame = sweep.bounds
        sweepMask.path = CGPath(ellipseIn: sweep.bounds, transform: nil)

        let specs: [(inset: CGFloat, from: CGFloat, to: CGFloat, width: CGFloat)] = [(14, 0, 0.22, 4), (34, 0.5, 0.62, 3), (52, 0.2, 0.3, 2)]
        for (arc, spec) in zip(arcs, specs) {
            let arcRect = CGRect(origin: .zero, size: rect.insetBy(dx: spec.inset, dy: spec.inset).size)
            arc.bounds = arcRect
            arc.position = center
            arc.path = CGPath(ellipseIn: arcRect, transform: nil)
            arc.strokeStart = spec.from
            arc.strokeEnd = spec.to
            arc.lineWidth = spec.width
        }
        CATransaction.commit()
        rebuildAnimations()
    }

    private func rebuildAnimations() {
        let layers: [(CALayer, Double)] = [(sweep, 3.2), (arcs[0], 3.2), (arcs[1], -2.0), (arcs[2], 1.35)]
        for (layer, period) in layers {
            layer.removeAnimation(forKey: "spin")
            guard animated else { continue }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = period > 0 ? -2 * Double.pi : 2 * Double.pi
            spin.duration = abs(period)
            spin.repeatCount = .infinity
            layer.add(spin, forKey: "spin")
        }
        glow.removeAnimation(forKey: "breathe")
        if animated {
            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 0.94
            breathe.toValue = 1.06
            breathe.duration = 1.6
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(breathe, forKey: "breathe")
        }
        updateEmitter()
    }
}

struct OrbitCore: NSViewRepresentable {
    var hue: Color
    var accent: Color
    var intensity: Double
    var animated: Bool

    func makeNSView(context: Context) -> OrbitCoreView {
        let view = OrbitCoreView()
        view.hue = hue
        view.accent = accent
        view.intensity = intensity
        view.animated = animated
        return view
    }

    func updateNSView(_ view: OrbitCoreView, context: Context) {
        view.hue = hue
        view.accent = accent
        view.intensity = CGFloat(intensity)
        view.animated = animated
    }
}

/// Native indeterminate spinner ring for compact status (render-server driven).
struct SpinnerRing: NSViewRepresentable {
    func makeNSView(context: Context) -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        return indicator
    }
    func updateNSView(_ nsView: NSProgressIndicator, context: Context) {}
}
