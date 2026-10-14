import AppKit
import QuartzCore

/// How Tetsu moves from one place to another, seated (launch QA, lens 4: the bunny and the robot faded the same way).
/// A bunny fades, soft and slow. A machine doesn't: a bright scan line sweeps down over it and erases it where it sits,
/// and where it's going the line sweeps up and prints it again (the hologram's own print). The window stays opaque; a
/// mask on the stage and a thin line of light over it, both Core Animation, do all of it, so there are no renders.
/// Reduce Motion keeps the bunny's soft fade.
@MainActor final class StageBeam {
    static let outSeconds = 0.26, inSeconds = 0.38
    private let mask = CALayer()
    private let line = CALayer()
    private let glow = CAGradientLayer()
    private var running = false

    /// The robot spans, in stage points, from just under its feet to above its antennae.
    static let bottom: CGFloat = 8, top: CGFloat = 184

    /// Erases the robot top to bottom over `seconds`: what's above the line is gone, and stays gone until `reveal`.
    /// `stage` is the layer everything of the character is in (in stage points); the light is drawn over it in `host`
    /// (the view's layer, in points of the panel), so the mask doesn't cut it.
    func erase(stage: CALayer, host: CALayer, scale: CGFloat, seconds: Double) { sweep(stage: stage, host: host, scale: scale, erasing: true, seconds: seconds) }
    /// Prints it again bottom to top. Call `finish` once it's whole.
    func reveal(stage: CALayer, host: CALayer, scale: CGFloat, seconds: Double) { sweep(stage: stage, host: host, scale: scale, erasing: false, seconds: seconds) }

    private func sweep(stage: CALayer, host: CALayer, scale: CGFloat, erasing: Bool, seconds: Double) {
        let from = erasing ? Self.top : Self.bottom, to = erasing ? Self.bottom : Self.top
        prepare(stage: stage, host: host, scale: scale, erasing: erasing)
        let ease = CAMediaTimingFunction(controlPoints: 0.35, 0, 0.45, 1)
        func slide(_ layer: CALayer, _ key: String, from: CGFloat, to: CGFloat) {
            let a = CABasicAnimation(keyPath: key); a.fromValue = from; a.toValue = to; a.duration = seconds; a.timingFunction = ease
            a.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            layer.add(a, forKey: key)
        }
        // The model values go to where it ends (after an erase the robot stays gone; a reveal ends with it all showing)
        // and the animations carry it there.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mask.bounds.size.height = erasing ? to : stage.bounds.height
        line.position.y = to * scale; glow.position.y = to * scale
        CATransaction.commit()
        slide(mask, "bounds.size.height", from: from, to: to)
        slide(line, "position.y", from: from * scale, to: to * scale)
        slide(glow, "position.y", from: from * scale, to: to * scale)
        for layer in [line, glow] {
            let shine = CAKeyframeAnimation(keyPath: "opacity"); shine.values = [0, 1, 1, 0]; shine.keyTimes = [0, 0.12, 0.8, 1]; shine.duration = seconds
            layer.add(shine, forKey: "shine")
        }
    }

    /// The layers at rest at the start of a sweep (the mask in place, the line and glow over the host, unseen).
    private func prepare(stage: CALayer, host: CALayer, scale: CGFloat, erasing: Bool) {
        let from = erasing ? Self.top : Self.bottom
        let width = 150 * scale, centre = stage.bounds.midX * scale
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mask.removeAllAnimations(); line.removeAllAnimations(); glow.removeAllAnimations()
        // The mask is a block from the stage's bottom edge up to the line: what's under the line shows.
        mask.backgroundColor = CGColor(gray: 0, alpha: 1)
        mask.anchorPoint = CGPoint(x: 0.5, y: 0)
        mask.position = CGPoint(x: stage.bounds.midX, y: 0)
        mask.bounds = CGRect(x: 0, y: 0, width: stage.bounds.width, height: erasing ? stage.bounds.height : Self.bottom)
        stage.mask = mask
        // The line: thin and bright, wider than the robot, with a soft glow trailing it where it has been.
        line.name = "stageBeam line"; glow.name = "stageBeam glow"
        line.backgroundColor = CGColor(srgbRed: 0.6, green: 0.97, blue: 1, alpha: 1)
        line.bounds = CGRect(x: 0, y: 0, width: width, height: max(1.5, 1.5 * scale))
        line.shadowColor = CGColor(srgbRed: 0.35, green: 0.93, blue: 1, alpha: 1); line.shadowRadius = 4 * scale; line.shadowOpacity = 1; line.shadowOffset = .zero
        glow.bounds = CGRect(x: 0, y: 0, width: width, height: 26 * scale)
        glow.colors = [CGColor(srgbRed: 0.35, green: 0.93, blue: 1, alpha: 0), CGColor(srgbRed: 0.35, green: 0.93, blue: 1, alpha: 0.28)]
        // The glow trails the line: above it going down (bright at its foot), below it going up (bright at its head).
        glow.startPoint = CGPoint(x: 0.5, y: erasing ? 1 : 0); glow.endPoint = CGPoint(x: 0.5, y: erasing ? 0 : 1)
        glow.anchorPoint = CGPoint(x: 0.5, y: erasing ? 0 : 1)
        line.position = CGPoint(x: centre, y: from * scale); glow.position = line.position
        line.opacity = 0; glow.opacity = 0
        for layer in [glow, line] where layer.superlayer !== host { layer.removeFromSuperlayer(); host.addSublayer(layer) }
        CATransaction.commit()
        running = true
    }

    /// Review: the sweep held `progress` of the way (0…1, linear), for the demo's stills (`--beam-check`).
    func pose(stage: CALayer, host: CALayer, scale: CGFloat, erasing: Bool, progress: CGFloat) {
        prepare(stage: stage, host: host, scale: scale, erasing: erasing)
        let from = erasing ? Self.top : Self.bottom, to = erasing ? Self.bottom : Self.top
        let y = from + (to - from) * progress
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mask.bounds.size.height = y; line.position.y = y * scale; glow.position.y = y * scale; line.opacity = 1; glow.opacity = 1
        CATransaction.commit()
    }

    /// The robot is whole again (or the move was cut short): the mask and the line go.
    func finish(stage: CALayer) {
        guard running else { return }
        running = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        stage.mask = nil
        mask.removeAllAnimations(); line.removeAllAnimations(); glow.removeAllAnimations()
        line.removeFromSuperlayer(); glow.removeFromSuperlayer()
        CATransaction.commit()
    }
}
