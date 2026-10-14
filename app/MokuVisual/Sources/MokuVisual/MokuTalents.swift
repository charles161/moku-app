import AppKit
import QuartzCore
import MokuKit

// Moku's two talents (next-wave.md §2; seated, characters-perfect.md): a happy bounce with a little twirl of petals on a
// big comeback, and the nose-twitch sniff of a new window (LifeMove.Kind.sniff). Both cost Core Animation, not renders.

/// The comeback bounce: Moku stays seated and bounces on the spot, twice, squashing as it gathers itself and lands and
/// stretching as it rises. Additive over the breath, about the feet, so they land where they were.
enum HappyBounce {
    static let seconds = 0.95
    /// (time 0…1, lift in points, vertical scale): the squash and stretch keep the volume (horizontal = 1 / vertical).
    static let keys: [(t: Double, lift: CGFloat, stretch: CGFloat)] = [
        (0, 0, 1), (0.11, 0, 0.94), (0.28, 6.5, 1.05), (0.38, 7.5, 1.0), (0.52, 0, 0.94),
        (0.64, 2.4, 1.025), (0.74, 0, 0.975), (0.86, 0, 1.006), (1, 0, 1),
    ]
    /// Up eases out (slowing to the top), down eases in (falling faster), squashes ease both ways.
    static func timing(from a: CGFloat, to b: CGFloat) -> CAMediaTimingFunction {
        CAMediaTimingFunction(name: b > a ? .easeOut : b < a ? .easeIn : .easeInEaseOut)
    }
    /// The animation for a layer whose feet are `feet` points above its centre (negative: below).
    static func animation(feet: CGFloat) -> CAAnimationGroup {
        let times = keys.map { NSNumber(value: $0.t) }
        func track(_ path: String, _ values: [CGFloat], timing: [CAMediaTimingFunction]) -> CAKeyframeAnimation {
            let a = CAKeyframeAnimation(keyPath: path); a.values = values.map { NSNumber(value: Double($0)) }; a.keyTimes = times
            a.timingFunctions = timing; a.isAdditive = true; a.duration = seconds; return a
        }
        let lifts = keys.map(\.lift), stretches = keys.map(\.stretch)
        let liftTiming = zip(lifts, lifts.dropFirst()).map { timing(from: $0, to: $1) }
        let squashTiming = stretches.dropFirst().map { _ in CAMediaTimingFunction(name: .easeInEaseOut) }
        // Additive: the scale adds to the breath's; the position keeps the feet planted as the scale changes, plus the lift.
        let group = CAAnimationGroup()
        group.animations = [track("transform.scale.y", stretches.map { $0 - 1 }, timing: squashTiming),
                            track("transform.scale.x", stretches.map { 1 / $0 - 1 }, timing: squashTiming),
                            track("position.y", zip(lifts, stretches).map { $0 + (1 - $1) * feet }, timing: liftTiming)]
        group.duration = seconds
        group.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        return group
    }
    /// The ears' follow-through (radians, about their roots' x): as Moku rises the tips trail down, at the top they float
    /// up, and they flop on landing; every bit of it eases out to rest. `age` is seconds into the bounce.
    static func earLag(at age: Double) -> Float {
        guard age > 0, age < seconds + 0.35 else { return 0 }
        // One after another (overlapping, a falling one and the next rising one would add up to a whip).
        return 0.06 * LifeCurve.bump(age - 0.06, rise: 0.12, hold: 0.02, fall: 0.12)
            - 0.07 * LifeCurve.bump(age - 0.32, rise: 0.12, hold: 0.04, fall: 0.14)
            + 0.04 * LifeCurve.bump(age - 0.62, rise: 0.10, hold: 0.02, fall: 0.12)
            - 0.02 * LifeCurve.bump(age - 0.86, rise: 0.10, hold: 0.02, fall: 0.20)
    }
}

/// The little twirl of petals: a handful of petals in Moku's colours spin up around it in a loose spiral, the ones on
/// the far side passing behind it, and drift down and fade. Core Animation plays it in Moku's own window.
@MainActor
final class PetalTwirl {
    static let seconds = 2.3
    private var petals: [CALayer] = []
    /// Petal pink, a paler blush, cream and one sage leaf (the website's palette).
    static let colours: [CGColor] = [
        CGColor(srgbRed: 0.95, green: 0.68, blue: 0.68, alpha: 1), CGColor(srgbRed: 0.98, green: 0.82, blue: 0.80, alpha: 1),
        CGColor(srgbRed: 0.91, green: 0.56, blue: 0.58, alpha: 1), CGColor(srgbRed: 1.0, green: 0.95, blue: 0.86, alpha: 1),
        CGColor(srgbRed: 0.95, green: 0.68, blue: 0.68, alpha: 1), CGColor(srgbRed: 0.65, green: 0.73, blue: 0.60, alpha: 1),
        CGColor(srgbRed: 0.98, green: 0.82, blue: 0.80, alpha: 1), CGColor(srgbRed: 0.91, green: 0.56, blue: 0.58, alpha: 1),
        CGColor(srgbRed: 1.0, green: 0.95, blue: 0.86, alpha: 1),
    ]
    /// Petal `i`'s size in points (the leaf is longer and slimmer).
    static func size(_ i: Int) -> CGSize { i == leaf ? CGSize(width: 7, height: 12) : CGSize(width: 8.5, height: 10) }
    /// Which of `colours` is the leaf.
    static let leaf = 5
    /// A rounded petal with a soft notch at its tip, `size` points long.
    static func petalPath(size: CGSize) -> CGPath {
        let w = size.width, h = size.height, path = CGMutablePath()
        path.move(to: CGPoint(x: w / 2, y: 0))
        path.addCurve(to: CGPoint(x: w * 0.38, y: h), control1: CGPoint(x: -w * 0.15, y: h * 0.3), control2: CGPoint(x: w * 0.05, y: h * 0.95))
        path.addLine(to: CGPoint(x: w / 2, y: h * 0.86))
        path.addLine(to: CGPoint(x: w * 0.62, y: h))
        path.addCurve(to: CGPoint(x: w / 2, y: 0), control1: CGPoint(x: w * 0.95, y: h * 0.95), control2: CGPoint(x: w * 1.15, y: h * 0.3))
        path.closeSubpath()
        return path
    }
    /// Where petal `i` of `count` is at `u` (0…1 of the twirl), around `centre` (Moku's middle at its feet, stage points):
    /// position, spin, opacity, size, and whether it's on the far side (behind Moku).
    static func state(_ i: Int, of count: Int, at u: Double, centre: CGPoint) -> (point: CGPoint, spin: CGFloat, opacity: Float, scale: CGFloat, behind: Bool) {
        let start = Double(i) / Double(count) * 0.12                     // they set off one after another
        let v = min(1, max(0, (u - start) / (1 - start)))
        let rise = LifeCurve.smooth(min(1, v / 0.62))                       // up the spiral, then drifting
        // Around Moku, outside its outline (its head is about 55 points across from the middle), so no petal crosses its
        // face: from its paws up past its ears, a turn and a bit.
        let angle = Double(i) / Double(count) * 2 * .pi + 2 * .pi * 1.2 * (1 - pow(1 - v, 1.6))
        let radius = 50 + 22 * rise + 5 * sin(Double(i) * 1.7)
        let fall = max(0, (v - 0.62) / 0.38)
        let height = 26 + 128 * rise + 8 * sin(Double(i) * 2.3) - 30 * fall * fall
        let x = Double(centre.x) + radius * cos(angle) + 10 * fall * sin(Double(i) + v * 9)  // a flutter as they fall
        let y = Double(centre.y) + height + radius * 0.24 * sin(angle)       // a tilted ring: the far side is higher
        let opacity = Float(min(1, v / 0.07)) * Float(1 - LifeCurve.smooth((v - 0.72) / 0.28))
        let scale = 0.55 + 0.45 * LifeCurve.smooth(v / 0.18)
        return (CGPoint(x: x, y: y), CGFloat(angle * 0.9 + Double(i)), opacity, CGFloat(scale), sin(angle) > 0 && v > 0)
    }

    /// Plays the twirl in `stage` (the layer Moku's image is in), around `centre`. Nothing when motion is reduced.
    func play(in stage: CALayer, centre: CGPoint, reduced: Bool) {
        petals.forEach { $0.removeFromSuperlayer() }; petals = []
        guard !reduced else { return }
        let count = Self.colours.count, steps = Int(Self.seconds * 30), now = CACurrentMediaTime()
        for i in 0..<count {
            let size = PetalTwirl.size(i)
            let petal = CAShapeLayer(); petal.name = "petal"
            petal.bounds = CGRect(origin: .zero, size: size); petal.path = Self.petalPath(size: size)
            petal.fillColor = Self.colours[i]; petal.opacity = 0
            petal.shadowColor = CGColor(gray: 0.3, alpha: 1); petal.shadowOpacity = 0.12; petal.shadowRadius = 0.6; petal.shadowOffset = CGSize(width: 0, height: -0.4)
            let samples = (0...steps).map { Self.state(i, of: count, at: Double($0) / Double(steps), centre: centre) }
            let times = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
            func track(_ path: String, _ values: [Any], discrete: Bool = false) -> CAKeyframeAnimation {
                let a = CAKeyframeAnimation(keyPath: path); a.values = values; a.keyTimes = times
                if discrete { a.calculationMode = .discrete }
                return a
            }
            let group = CAAnimationGroup()
            group.animations = [track("position", samples.map { NSValue(point: $0.point) }),
                                track("transform.rotation.z", samples.map { NSNumber(value: Double($0.spin)) }),
                                track("transform.scale", samples.map { NSNumber(value: Double($0.scale)) }),
                                track("opacity", samples.map { NSNumber(value: $0.opacity) }),
                                track("zPosition", samples.map { NSNumber(value: $0.behind ? -1 : 1) }, discrete: true)]
            group.beginTime = now; group.duration = Self.seconds; group.fillMode = .both; group.isRemovedOnCompletion = false
            group.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            petal.position = samples[0].point
            stage.addSublayer(petal); petal.add(group, forKey: "twirl")
            petals.append(petal)
        }
        let shown = petals
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.seconds + 0.05) { [weak self] in
            shown.forEach { $0.removeFromSuperlayer() }
            self?.petals.removeAll { petal in shown.contains { $0 === petal } }
        }
    }
}

extension MokuVisualDiagnostics {
    /// `--talents <dir>`: Moku's talents on the clock, recorded frame by frame through the app's renderer: the comeback
    /// (a drift, then the full return: the smile, the bounce, the petals) and two sniffs while it works. Writes
    /// comeback.mp4 and sniff.mp4 at 60 fps as Moku's window shows them (the petals drawn from the same state as their
    /// layers), comeback-strip.png and sniff-strip.png (every 4th frame), and talents.json (stutters and snaps).
    public static func talentsCheck(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let real = stage.view.real else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.setHidden(false)
        stage.timer?.invalidate(); stage.timer = nil
        var report: [String: Any] = [:]
        for (name, seconds) in [("comeback", 4.2), ("sniff", 3.6)] {
            if name == "comeback" {
                stage.setWorkState(.noticing); stage.setMood(.disappointed); stage.setAttention(.user)
            } else {
                stage.setMood(.content); stage.setWorkState(.focused); stage.watchScreenCenter()
            }
            try await Task.sleep(for: .seconds(name == "comeback" ? 5 : 4))
            let recorder = LifeRecorder(folder: directory.appendingPathComponent("\(name)-rendered")), previous = real.onFrame
            let began = CACurrentMediaTime(), layerOrigin = real.imageLayer.frame.origin
            recorder.began = began
            real.onFrame = { previous?(); recorder.frame(real) }
            var petalsAt: Double?
            let sampler = Task { @MainActor in
                while !Task.isCancelled { recorder.sample(real.imageLayer, rendered: real.lastImage, layerMove: real.layerMoveUnderWay); try? await Task.sleep(for: .milliseconds(8)) }
            }
            if name == "comeback" {
                try await Task.sleep(for: .milliseconds(300))
                // In the engine's order: the mood, the return, then the work state.
                stage.setMood(.happy); stage.celebrateReturn(.full); stage.setWorkState(.focused)
                petalsAt = CACurrentMediaTime() - began + 0.47  // celebrateReturn: 100 + 150 + 220 ms
            } else {
                try await Task.sleep(for: .milliseconds(300)); stage.perform(.sniff)
                try await Task.sleep(for: .seconds(1.6)); stage.perform(.sniff)
            }
            try await Task.sleep(for: .seconds(seconds - 0.3))
            sampler.cancel(); real.onFrame = previous
            await recorder.finish()
            let centre = CGPoint(x: real.imageLayer.frame.midX, y: StageGeometry.feet.y), count = PetalTwirl.colours.count
            var strip: [CGImage] = [], n = 0
            try await recorder.writeMovie(to: directory.appendingPathComponent("\(name).mp4"), seconds: seconds, fps: 60, overlay: { context, t, behind in
                guard let at = petalsAt, t >= at, t <= at + PetalTwirl.seconds else { return }
                for i in 0..<count {
                    let state = PetalTwirl.state(i, of: count, at: (t - at) / PetalTwirl.seconds, centre: centre)
                    guard state.behind == behind, state.opacity > 0 else { continue }
                    let size = PetalTwirl.size(i)
                    context.saveGState()
                    context.scaleBy(x: 2, y: 2)
                    context.translateBy(x: state.point.x - layerOrigin.x, y: state.point.y - layerOrigin.y)
                    context.rotate(by: state.spin); context.scaleBy(x: state.scale, y: state.scale)
                    context.translateBy(x: -size.width / 2, y: -size.height / 2)
                    context.setAlpha(CGFloat(state.opacity)); context.setFillColor(PetalTwirl.colours[i])
                    context.addPath(PetalTwirl.petalPath(size: size)); context.fillPath()
                    context.restoreGState()
                }
            }, frames: { _, image in if n % 4 == 0 && strip.count < 40 { strip.append(image) }; n += 1 })
            try recorder.writeCSV(to: directory.appendingPathComponent("\(name)-frames.csv"))
            report[name] = recorder.verdict()
            // A strip of the frames, cropped to Moku and its petals (none when nothing moved: Tetsu doesn't sniff).
            guard !strip.isEmpty else { continue }
            let crop = CGRect(x: 120, y: 60, width: 400, height: 440), w = 200, h = 220
            let context = CGContext(data: nil, width: w * min(10, strip.count), height: h * ((strip.count + 9) / 10), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for (i, image) in strip.enumerated() {
                guard let part = image.cropping(to: crop) else { continue }
                context.draw(part, in: CGRect(x: (i % 10) * w, y: context.height - (i / 10 + 1) * h, width: w, height: h))
            }
            try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(name)-strip.png"))
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("talents.json"))
        stage.setHidden(true)
    }
}
