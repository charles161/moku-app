import AppKit
import QuartzCore
import RealityKit
import simd
import MokuKit

/// Tetsu is a machine (next-wave.md §7): it moves like one, and it has two talents only it has (§2): a scan beam while
/// it reads your window, and a hologram of today's rocket when a piece lands. Moku never reaches this code.
extension Companion {
    /// Moves like a machine: servo-like eases (quick, a tiny overshoot and settle), antennae that twitch like sensors,
    /// no breathing squash, a display face (PixelFace) and the robot's talents.
    var isMachine: Bool { self == .tetsu }
}

/// Servo eases: the move happens early and fast, overshoots a touch and settles, and lands exactly at 1 by `duration`
/// (so every caller's timing is unchanged). A second-order spring (about 4.5 Hz, damping 0.5) following a quick
/// smootherstep, tabulated once per duration.
enum ServoTiming {
    @MainActor private static var tables: [Int: [Float]] = [:]
    @MainActor static func progress(age: Double, duration: Double) -> Float {
        guard age > 0 else { return 0 }
        guard age < duration else { return 1 }
        let key = max(1, Int((duration * 100).rounded()))
        let table = tables[key] ?? {
            let made = makeTable(duration: Double(key) / 100); tables[key] = made; return made
        }()
        let x = age / duration * Double(table.count - 1), i = min(table.count - 2, Int(x)), f = Float(x - Double(i))
        return table[i] + (table[i + 1] - table[i]) * f
    }
    private static func makeTable(duration: Double, samples: Int = 160) -> [Float] {
        let move = min(0.5, duration * 0.45), omega = 2 * Double.pi * 4.5, damping = 0.5
        var y = 0.0, v = 0.0, out = [Float](), steps = 8
        let dt = duration / Double(samples - 1) / Double(steps)
        for k in 0..<samples {
            let t = duration * Double(k) / Double(samples - 1)
            if k > 0 {
                for s in 0..<steps {
                    let ts = t - duration / Double(samples - 1) + Double(s + 1) * dt
                    let x = min(1, max(0, ts / move)), target = x * x * x * (x * (x * 6 - 15) + 10)
                    v += (omega * omega * (target - y) - 2 * damping * omega * v) * dt; y += v * dt
                }
            }
            // The last 15% lands exactly on 1, so a held pose never creeps.
            let land = min(1, max(0, (t / duration - 0.85) / 0.15)), k2 = land * land * (3 - 2 * land)
            out.append(Float(y * (1 - k2) + k2))
        }
        return out
    }
    /// The head turning to a new gaze: a quick servo turn instead of the soft spring.
    @MainActor static func head(_ age: Double) -> Float { progress(age: age - 0.06, duration: 0.95) }
    /// A little move done like a machine (a fidget, a lean): out quickly with a tiny settle, held, back the same way, all
    /// within `seconds`. 0…1.
    @MainActor static func envelope(age: Double, seconds: Double) -> Float {
        guard age > 0, age < seconds else { return 0 }
        let move = min(0.45, seconds * 0.22)
        return progress(age: age, duration: move) - progress(age: age - (seconds - move), duration: move)
    }
    /// A curious head tilt (the pointer comes onto Tetsu): in quickly, held a beat, back, each with a tiny settle. 0…1.
    @MainActor static func acknowledge(_ age: Double) -> Float {
        guard age > 0, age < 1.4 else { return 0 }
        return progress(age: age, duration: 0.35) - progress(age: age - 0.85, duration: 0.45)
    }
    /// An antenna twitch (the ear flick): snaps out, holds a beat, snaps back, each with a tiny settle. Radians.
    @MainActor static func twitch(age: Double) -> Float {
        guard age > 0, age < EarFlick.seconds else { return 0 }
        return 0.16 * (progress(age: age, duration: 0.4) - progress(age: age - 0.5, duration: 0.5))
    }
}

/// The three status LEDs on Tetsu's chest plate breathe (next-wave.md §7): a soft glow over them that rises and falls,
/// slowly while it works, dim when it's let down, quick when it's cross (amber once it's red), and like a sleeping Mac's light
/// while it dozes. Core Animation plays it on a small layer inside the character's own image layer, so it costs no
/// renders and moves with every lean, swing and fade; each drawn frame only moves it to where the LEDs are. It shows
/// only while Tetsu sits idle (a clip, a move or a hold hides it: the LEDs can turn away).
@MainActor
final class StatusLights {
    /// How a mood breathes: seconds per breath and the glow's low and high.
    struct Pace: Equatable { var seconds: Double; var low: Float; var high: Float; var cross: Bool }
    static func pace(_ mood: Mood, cross: Bool) -> Pace {
        if cross { return Pace(seconds: 2.2, low: 0.18, high: 0.85, cross: true) }
        switch mood {
        case .sleepy: return Pace(seconds: 5.0, low: 0.0, high: 0.9, cross: false)
        case .disappointed: return Pace(seconds: 4.6, low: 0.05, high: 0.4, cross: false)
        case .annoyed: return Pace(seconds: 2.2, low: 0.18, high: 0.85, cross: false)  // quick; amber once it's red
        default: return Pace(seconds: 3.6, low: 0.12, high: 0.6, cross: false)
        }
    }
    let layer = CALayer()
    private let mask = CALayer()
    private var pace: Pace?
    /// Where the LEDs are on the model (their centre, in the spine joint's space) and how far apart the outer two are.
    let anchor: SIMD4<Float>
    let span: Float

    /// The chest LEDs are the lowest of the LED material's points (the antenna tips and ear pucks sit on the head).
    init?(mesh: MeshResource, transform: simd_float4x4, materialNames: [String], spine: simd_float4x4) {
        guard let led = materialNames.firstIndex(of: "Tetsu_LED") else { return nil }
        var points: [SIMD3<Float>] = []
        for model in mesh.contents.models { for part in model.parts where part.materialIndex == led {
            for position in part.positions.elements { let p = transform * SIMD4<Float>(position, 1); points.append(SIMD3(p.x, p.y, p.z)) }
        } }
        guard let lowest = points.map({ $0.y }).min() else { return nil }
        let chest = points.filter { $0.y < lowest + 0.03 }
        let low = chest.reduce(SIMD3<Float>(repeating: .infinity), simd_min), high = chest.reduce(SIMD3<Float>(repeating: -.infinity), simd_max)
        anchor = spine.inverse * SIMD4((low + high) / 2, 1); span = high.x - low.x
        mask.contents = Self.glow(); mask.contentsGravity = .resize
        layer.name = "statusLights"; layer.mask = mask; layer.opacity = 0; layer.isHidden = true
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "hidden": NSNull(), "opacity": NSNull()]
        mask.actions = ["bounds": NSNull(), "position": NSNull()]
    }

    /// Three soft dots (an alpha mask), the outer two `span` apart once laid out.
    private static func glow() -> CGImage {
        let w = 96, h = 32
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)!
        for x in [24.0, 48.0, 72.0] {
            let gradient = CGGradient(colorSpace: CGColorSpaceCreateDeviceGray(), colorComponents: [0, 1, 0, 0.55, 0, 0], locations: [0, 0.35, 1], count: 3)!
            context.drawRadialGradient(gradient, startCenter: CGPoint(x: x, y: 16), startRadius: 0, endCenter: CGPoint(x: x, y: 16), endRadius: 14, options: [])
        }
        return context.makeImage()!
    }

    /// Lays the glow over the LEDs (in the image layer's points; `across`: the outer two LEDs' distance there) and
    /// breathes at the mood's pace. Hidden when `visible` is false.
    /// The glow is leaving (a clip, a move or a hold has Tetsu's chest turn away): it fades out where it is. Launch QA, lens 4:
    /// it used to vanish at 0.6 opacity on every clip's first frame and reappear at once when the clip ended.
    private var leaving = false, leaveToken = 0
    private func leave() {
        leaving = true; leaveToken += 1
        let token = leaveToken, from = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: "breath"); layer.removeAnimation(forKey: "appear")
        layer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from; fade.toValue = 0; fade.duration = 0.18; fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "leave")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.leaving, self.leaveToken == token else { return }
            self.layer.isHidden = true; self.leaving = false; self.pace = nil
        }
    }

    func show(_ visible: Bool, at point: CGPoint, across: CGFloat, pace next: Pace, reduced: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard visible, across > 0.5 else {
            if !layer.isHidden && !leaving { leave() }
            return
        }
        let width = across * 2, height = width / 3  // the mask's 96 × 32: its dots are 24 apart, the outer two 48
        layer.bounds = CGRect(x: 0, y: 0, width: width, height: height); layer.position = point
        mask.frame = layer.bounds
        let up = !layer.isHidden && !leaving
        guard next != pace || !up else { return }
        // It comes up (or changes pace) from where it is: a fade in over 0.3 s to the breath's low, then the breath.
        let from = up || leaving ? (layer.presentation()?.opacity ?? 0) : 0
        pace = next; layer.isHidden = false; leaving = false; leaveToken += 1
        let colour = next.cross ? CGColor(srgbRed: 1, green: 0.62, blue: 0.18, alpha: 1) : CGColor(srgbRed: 0.35, green: 0.93, blue: 1, alpha: 1)
        if up, !reduced, let before = layer.presentation()?.backgroundColor, before != colour {  // cyan to amber (red) and back: a blend, not a flip
            let blend = CABasicAnimation(keyPath: "backgroundColor"); blend.fromValue = before; blend.toValue = colour; blend.duration = 0.6
            layer.add(blend, forKey: "colour")
        }
        layer.backgroundColor = colour
        layer.removeAnimation(forKey: "breath"); layer.removeAnimation(forKey: "leave"); layer.removeAnimation(forKey: "appear")
        let settled = reduced ? (next.low + next.high) / 2 : next.high  // the model value: a still capture of the stage shows the glow at its peak
        layer.opacity = settled
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = from; appear.toValue = reduced ? settled : next.low; appear.duration = 0.3; appear.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(appear, forKey: "appear")
        if reduced { return }
        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = next.low; breath.toValue = next.high; breath.duration = next.seconds / 2
        breath.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + 0.3
        breath.autoreverses = true; breath.repeatCount = .infinity; breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breath.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
        layer.add(breath, forKey: "breath")
    }
}

/// The scan beam, Tetsu's signature moment (Charles: "i loved the scanning beam"; then "the beam is too concentrated
/// in real one", the website's is better). Drawn as the website draws it (live-demo.js `drawScanBeam`, live-demo.css
/// `.scan-*`, companions.js `scanBeam`): a thin cyan line with a soft glow inside a faint narrow wedge, both fading
/// with distance from the visor, sweeping once from high on the window it reads down to its foot, fading in and out.
/// Its proportions are the site's, measured against Tetsu's height. It lives in Tetsu's own transparent window (never
/// over other apps) and fades out before the window's edge; Core Animation plays it, so it costs no renders. The
/// matrix's bright column crosses the display once in step (PixelFace.scanStep: the same curve and length).
@MainActor
final class ScanBeam {
    private let holder: CALayer = { let layer = CALayer(); layer.name = "scanBeam"; return layer }()
    static let seconds = 2.2
    /// The sweep, from above the line to the work (`from`) to below it (`to`), in degrees, as the site's.
    static let from: CGFloat = 38, to: CGFloat = -12
    /// In stage points, at Tetsu's size (about 135 points from its feet to its antennae): the site's 122 units of reach
    /// against its 156-px robot, its half-point line with a 1.2 px glow, the line starting 9 units out.
    static let reach: CGFloat = 200, lineWidth: CGFloat = 0.9, glow: CGFloat = 1.1, lineStart: CGFloat = 15
    /// The wedge's half-angle, and where the fade with distance begins (a share of the reach), as the site's.
    static let halfAngle: CGFloat = 5 * .pi / 180, fadeFrom: CGFloat = 0.3
    static let cyan = CGColor(srgbRed: 0x59 / 255.0, green: 0xED / 255.0, blue: 1, alpha: 1)
    /// How far through its sweep the beam is at `progress` of the moment (0…1): ease in and out, CSS's ease-in-out.
    static func sweep(_ progress: Double) -> Double { CubicBezier.easeInOut(progress) }
    /// Its opacity at `progress`: in over the first 10%, out over the last 14%, linear (the site's `scan-fade`).
    static func opacity(_ progress: Double) -> Double { progress < 0.1 ? progress / 0.1 : progress > 0.86 ? max(0, (1 - progress) / 0.14) : 1 }

    /// Something bigger takes over (Tetsu turns to you): the beam fades out where it is.
    func stop() {
        guard holder.superlayer != nil else { return }
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = holder.presentation()?.opacity ?? 1; fade.toValue = 0; fade.duration = 0.2
        holder.opacity = 0; holder.removeAnimation(forKey: "fade"); holder.add(fade, forKey: "stop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in if self?.holder.opacity == 0 { self?.holder.removeFromSuperlayer(); self?.holder.opacity = 1 } }
    }
    /// `still`: for review, the beam held where it is that far through its moment (0…1), with no animation.
    func play(in parent: CALayer, from origin: CGPoint, toward gaze: SIMD2<Float>, reduced: Bool, still: Double? = nil) {
        holder.removeAllAnimations(); holder.sublayers = nil; holder.mask = nil; holder.removeFromSuperlayer(); holder.opacity = 1
        guard !reduced else { return }
        // Toward the work (the gaze is yaw right, pitch up; on screen x right, y up), within 30° of level; then from
        // above it to below it, so the sweep goes down the window whichever side the work is on.
        let level = CGFloat(max(-0.52, min(0.52, atan2(gaze.y, abs(gaze.x) < 0.01 ? 1 : abs(gaze.x)))))
        let left = gaze.x <= 0, deg = CGFloat.pi / 180
        let toward = left ? .pi - level : level
        let start = left ? toward - Self.from * deg : toward + Self.from * deg
        let turn = (left ? 1 : -1) * (Self.from - Self.to) * deg
        // As long as the site's, unless the window is smaller: then it ends (fades out) inside it.
        let bounds = parent.bounds
        func room(_ a: CGFloat) -> CGFloat {
            let dx = cos(a), dy = sin(a)
            let x = dx < -0.001 ? (origin.x - bounds.minX) / -dx : dx > 0.001 ? (bounds.maxX - origin.x) / dx : .infinity
            let y = dy < -0.001 ? (origin.y - bounds.minY) / -dy : dy > 0.001 ? (bounds.maxY - origin.y) / dy : .infinity
            return min(x, y)
        }
        let roomAll = (0...10).map { room(start + turn * CGFloat($0) / 10) }.min() ?? Self.reach
        let reach = max(70, min(Self.reach, roomAll - 6))
        holder.frame = bounds
        // The fade with distance: a mask round the visor, whole to 30% of the reach, gone at its end.
        let fade = CAGradientLayer(); fade.type = .radial; fade.frame = bounds
        fade.startPoint = CGPoint(x: origin.x / max(1, bounds.width), y: origin.y / max(1, bounds.height))
        fade.endPoint = CGPoint(x: fade.startPoint.x + reach / max(1, bounds.width), y: fade.startPoint.y + reach / max(1, bounds.height))
        fade.colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
        fade.locations = [0, NSNumber(value: Double(Self.fadeFrom)), 1]
        holder.mask = fade
        // The beam, laid along the start of the sweep and turning about the visor: the wedge, and the line in it.
        let beam = CALayer(); beam.frame = bounds
        beam.anchorPoint = CGPoint(x: origin.x / max(1, bounds.width), y: origin.y / max(1, bounds.height)); beam.position = origin
        func point(_ a: CGFloat, _ r: CGFloat) -> CGPoint { CGPoint(x: origin.x + r * cos(a), y: origin.y + r * sin(a)) }
        let wedge = CAShapeLayer(); wedge.frame = bounds
        let fan = CGMutablePath(); fan.move(to: origin); fan.addLine(to: point(start - Self.halfAngle, reach)); fan.addLine(to: point(start + Self.halfAngle, reach)); fan.closeSubpath()
        wedge.path = fan; wedge.fillColor = Self.cyan.copy(alpha: 0.16)
        let line = CAShapeLayer(); line.frame = bounds
        let stroke = CGMutablePath(); stroke.move(to: point(start, Self.lineStart * reach / Self.reach)); stroke.addLine(to: point(start, reach))
        line.path = stroke; line.fillColor = nil; line.strokeColor = Self.cyan.copy(alpha: 0.8); line.lineWidth = Self.lineWidth; line.lineCap = .round
        line.shadowColor = Self.cyan; line.shadowRadius = Self.glow; line.shadowOpacity = 1; line.shadowOffset = .zero
        beam.sublayers = [wedge, line]
        holder.sublayers = [beam]
        parent.addSublayer(holder)
        if let still {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            beam.transform = CATransform3DMakeRotation(turn * CGFloat(Self.sweep(still)), 0, 0, 1)
            holder.opacity = Float(Self.opacity(still))
            CATransaction.commit(); return
        }
        let sweep = CABasicAnimation(keyPath: "transform.rotation.z")
        sweep.fromValue = 0; sweep.toValue = turn; sweep.duration = Self.seconds
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)  // (0.42, 0, 0.58, 1): CubicBezier.easeInOut
        sweep.isRemovedOnCompletion = false; sweep.fillMode = .forwards
        beam.add(sweep, forKey: "sweep")
        let fadeInOut = CAKeyframeAnimation(keyPath: "opacity")
        fadeInOut.values = [0, 1, 1, 0]; fadeInOut.keyTimes = [0, 0.1, 0.86, 1]; fadeInOut.duration = Self.seconds
        fadeInOut.isRemovedOnCompletion = false; fadeInOut.fillMode = .forwards
        holder.add(fadeInOut, forKey: "fade")
        for animation in [sweep, fadeInOut] as [CAAnimation] { animation.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.seconds + 0.05) { [weak self] in self?.holder.removeFromSuperlayer() }
    }
}

/// A CSS cubic-bezier timing curve (x and y from 0 to 1), for things that keep step with a Core Animation curve.
enum CubicBezier {
    /// ease-in-out, (0.42, 0, 0.58, 1): CAMediaTimingFunction's `.easeInEaseOut`.
    static func easeInOut(_ t: Double) -> Double { value(t, 0.42, 0, 0.58, 1) }
    static func value(_ t: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        let t = min(1, max(0, t))
        func bezier(_ s: Double, _ a: Double, _ b: Double) -> Double { 3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s }
        var lo = 0.0, hi = 1.0, s = t
        for _ in 0..<32 { s = (lo + hi) / 2; if bezier(s, x1, x2) < t { lo = s } else { hi = s } }  // x(s) = t
        return bezier(s, y1, y2)
    }
}

/// The hologram: a small translucent projection of today's rocket over Tetsu's head when a house piece lands. It
/// flickers on above a faint cone of light from the visor, bobs, and flickers off. Core Animation plays it.
@MainActor
final class Hologram {
    private let holder: CALayer = { let layer = CALayer(); layer.name = "hologram"; return layer }()
    static let seconds = 4.6

    /// Today's rocket as far as it's built: `world/<id>/hologram/stage-<n>.png` for the day's stage (1…5).
    static func image(companion: Companion, stage: Int) -> CGImage? {
        guard let url = MokuAssets.file("world/\(companion.rawValue)/hologram/stage-\(max(1, min(5, stage))).png", companion: .moku),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func show(_ image: CGImage, in parent: CALayer, above head: CGPoint, reduced: Bool) {
        holder.removeAllAnimations(); holder.removeFromSuperlayer()
        let size = CGSize(width: 74, height: 74 * CGFloat(image.height) / CGFloat(max(1, image.width)))
        let base = CGPoint(x: head.x, y: min(parent.bounds.maxY - size.height - 4, head.y + 58))
        holder.frame = parent.bounds
        let picture = CALayer()
        picture.contents = image; picture.contentsGravity = .resizeAspect
        picture.frame = CGRect(x: base.x - size.width / 2, y: base.y, width: size.width, height: size.height)
        picture.shadowColor = CGColor(srgbRed: 0.05, green: 0.35, blue: 0.45, alpha: 1); picture.shadowRadius = 2; picture.shadowOpacity = 0.6; picture.shadowOffset = .zero
        // The projection: a faint cone from the visor up to the hologram's base.
        let cone = CAGradientLayer()
        cone.frame = CGRect(x: base.x - size.width / 2, y: head.y + 12, width: size.width, height: max(4, base.y - head.y - 6))
        cone.colors = [CGColor(srgbRed: 0.35, green: 0.93, blue: 1, alpha: 0.0), CGColor(srgbRed: 0.35, green: 0.93, blue: 1, alpha: 0.14)]
        cone.startPoint = CGPoint(x: 0.5, y: 0); cone.endPoint = CGPoint(x: 0.5, y: 1)
        let shape = CAShapeLayer(); let w = cone.bounds.width, h = cone.bounds.height
        let path = CGMutablePath(); path.move(to: CGPoint(x: w / 2 - 5, y: 0)); path.addLine(to: CGPoint(x: w / 2 + 5, y: 0))
        path.addLine(to: CGPoint(x: w * 0.92, y: h)); path.addLine(to: CGPoint(x: w * 0.08, y: h)); path.closeSubpath()
        shape.path = path; cone.mask = shape
        holder.sublayers = [cone, picture]
        parent.addSublayer(holder)
        if !reduced {
            // It prints from its base up as it comes on: a mask grows over it behind a bright scan line.
            let reveal = CALayer(); reveal.backgroundColor = CGColor(gray: 0, alpha: 1)
            reveal.anchorPoint = CGPoint(x: 0.5, y: 0); reveal.frame = picture.bounds; picture.mask = reveal
            let grow = CABasicAnimation(keyPath: "bounds.size.height")
            grow.fromValue = 0; grow.toValue = picture.bounds.height; grow.duration = 0.75; grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let line = CALayer(); line.backgroundColor = CGColor(srgbRed: 0.6, green: 0.97, blue: 1, alpha: 1)
            line.frame = CGRect(x: picture.frame.minX - 4, y: picture.frame.minY, width: picture.frame.width + 8, height: 1.5)
            line.shadowColor = CGColor(srgbRed: 0.35, green: 0.93, blue: 1, alpha: 1); line.shadowRadius = 3; line.shadowOpacity = 1; line.shadowOffset = .zero
            line.opacity = 0; holder.addSublayer(line)
            let rise = CABasicAnimation(keyPath: "position.y")
            rise.fromValue = picture.frame.minY; rise.toValue = picture.frame.maxY; rise.duration = 0.75; rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let shine = CAKeyframeAnimation(keyPath: "opacity"); shine.values = [0, 1, 1, 0]; shine.keyTimes = [0, 0.1, 0.8, 1]; shine.duration = 0.8
            for animation in [grow, rise, shine] { animation.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60) }
            reveal.add(grow, forKey: "print"); line.add(rise, forKey: "rise"); line.add(shine, forKey: "shine")
        }
        let flicker = CAKeyframeAnimation(keyPath: "opacity")
        // On and off like a projector warming up; with Reduce Motion no flashing, just a fade in and out.
        flicker.values = reduced ? [0, 0.85, 0.85, 0] : [0, 0.8, 0.15, 0.9, 0.55, 0.85, 0.85, 0.3, 0.8, 0]
        flicker.keyTimes = reduced ? [0, 0.08, 0.9, 1] : [0, 0.03, 0.05, 0.08, 0.10, 0.13, 0.86, 0.9, 0.93, 1]
        flicker.duration = Self.seconds; flicker.isRemovedOnCompletion = false; flicker.fillMode = .forwards
        holder.add(flicker, forKey: "flicker")
        if !reduced {
            let bob = CABasicAnimation(keyPath: "position.y")
            bob.fromValue = picture.position.y - 1.5; bob.toValue = picture.position.y + 1.5
            bob.duration = 1.1; bob.autoreverses = true; bob.repeatCount = .infinity; bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bob.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
            picture.add(bob, forKey: "bob")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.seconds + 0.05) { [weak self] in self?.holder.removeFromSuperlayer() }
    }
}

extension Notification.Name {
    /// A new piece of today's home landed (the world presenter saw today's units go up). `userInfo["units"]`: how many.
    public static let mokuHousePieceLanded = Notification.Name("MokuVisual.housePieceLanded")
}
