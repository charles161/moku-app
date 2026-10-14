import AppKit
import QuartzCore

/// Named articulated layers are the inexpensive stand-in for the art rig.
@MainActor
final class PlushPuppet {
    let root = CALayer()
    let body = CALayer()
    let head = CALayer()
    var joints: [String: CALayer] = [:]
    var hitLayers: [CALayer] = []
    let leftEye = CALayer(), rightEye = CALayer()
    let leftBrow = CAShapeLayer(), rightBrow = CAShapeLayer(), mouth = CAShapeLayer()
    let shadow = CAGradientLayer()
    let cream = NSColor(red: 0.98, green: 0.94, blue: 0.85, alpha: 1)

    init() {
        root.frame = CGRect(x: 0, y: 0, width: 160, height: 160)
        root.name = "root"; joints["root"] = root
        shadow.type = .radial; shadow.colors = [NSColor.black.withAlphaComponent(0.22).cgColor, NSColor.clear.cgColor]
        shadow.startPoint = CGPoint(x: 0.5, y: 0.5); shadow.endPoint = CGPoint(x: 1, y: 1)
        shadow.frame = CGRect(x: 28, y: 8, width: 105, height: 17); root.addSublayer(shadow)
        body.frame = root.bounds; body.name = "hips"; root.addSublayer(body); joints["hips"] = body
        _ = ball("tail", CGRect(x: 112, y: 26, width: 24, height: 27), in: body)
        _ = ball("chest", CGRect(x: 48, y: 17, width: 68, height: 66), in: body)
        _ = ball("foot_L", CGRect(x: 40, y: 13, width: 37, height: 25), in: body)
        _ = ball("foot_R", CGRect(x: 87, y: 13, width: 37, height: 25), in: body)
        _ = ball("arm_L", CGRect(x: 42, y: 36, width: 25, height: 36), in: body)
        _ = ball("arm_R", CGRect(x: 99, y: 36, width: 25, height: 36), in: body)
        head.frame = CGRect(x: 25, y: 55, width: 114, height: 100); head.name = "head"
        body.addSublayer(head); joints["head"] = head
        let l = ball("ear_L_01", CGRect(x: 17, y: 50, width: 29, height: 51), in: head)
        let r = ball("ear_R_01", CGRect(x: 67, y: 50, width: 29, height: 51), in: head)
        l.setAffineTransform(CGAffineTransform(rotationAngle: 0.18)); r.setAffineTransform(CGAffineTransform(rotationAngle: -0.12))
        let pink = NSColor(red: 0.92, green: 0.65, blue: 0.62, alpha: 1)
        _ = ball("ear_L_02", CGRect(x: 8, y: 8, width: 14, height: 35), in: l, color: pink, interactive: false)
        _ = ball("ear_R_02", CGRect(x: 8, y: 8, width: 14, height: 35), in: r, color: pink, interactive: false)
        _ = ball("face", CGRect(x: 4, y: 0, width: 106, height: 78), in: head)
        for (eye, x, name) in [(leftEye, 31.0, "eye_L"), (rightEye, 76.0, "eye_R")] {
            eye.frame = CGRect(x: x, y: 33, width: 10, height: 14); eye.name = name
            eye.backgroundColor = NSColor(red: 0.17, green: 0.12, blue: 0.10, alpha: 1).cgColor
            eye.cornerRadius = 5; head.addSublayer(eye); joints[name] = eye
            let glint = CALayer(); glint.frame = CGRect(x: 2, y: 8, width: 3.5, height: 4)
            glint.cornerRadius = 2; glint.backgroundColor = NSColor.white.cgColor; eye.addSublayer(glint)
        }
        for x in [18.0, 81.0] {
            let cheek = CAGradientLayer(); cheek.type = .radial
            cheek.colors = [pink.withAlphaComponent(0.45).cgColor, pink.withAlphaComponent(0).cgColor]
            cheek.startPoint = CGPoint(x: 0.5, y: 0.5); cheek.endPoint = CGPoint(x: 1, y: 1)
            cheek.frame = CGRect(x: x, y: 21, width: 21, height: 14); head.addSublayer(cheek)
        }
        _ = ball("nose", CGRect(x: 52, y: 28, width: 9, height: 6), in: head, color: pink, interactive: false)
        for shape in [leftBrow, rightBrow, mouth] {
            shape.strokeColor = NSColor(red: 0.31, green: 0.23, blue: 0.19, alpha: 1).cgColor
            shape.fillColor = nil; shape.lineWidth = 1.7; shape.lineCap = .round; head.addSublayer(shape)
        }
        let p = CGMutablePath(); p.move(to: CGPoint(x: 47, y: 25)); p.addQuadCurve(to: CGPoint(x: 56, y: 24), control: CGPoint(x: 52, y: 18))
        p.addQuadCurve(to: CGPoint(x: 65, y: 25), control: CGPoint(x: 61, y: 18)); mouth.path = p
    }

    @discardableResult
    func ball(_ name: String, _ frame: CGRect, in parent: CALayer, color: NSColor? = nil, interactive: Bool = true) -> CALayer {
        let base = color ?? cream
        let layer = CAGradientLayer(); layer.name = name; layer.frame = frame; layer.type = .radial
        layer.startPoint = CGPoint(x: 0.32, y: 0.8); layer.endPoint = CGPoint(x: 0.95, y: 0.1)
        layer.colors = [base.blended(withFraction: 0.32, of: .white)!.cgColor, base.cgColor, base.blended(withFraction: 0.24, of: NSColor(red: 0.53, green: 0.42, blue: 0.34, alpha: 1))!.cgColor]
        layer.locations = [0, 0.5, 1]; layer.cornerRadius = min(frame.width, frame.height) / 2
        let mask = CAShapeLayer(); mask.path = CGPath(ellipseIn: CGRect(origin: .zero, size: frame.size), transform: nil); layer.mask = mask
        parent.addSublayer(layer); joints[name] = layer
        if interactive { hitLayers.append(layer) }
        return layer
    }

    func contains(_ point: CGPoint) -> Bool {
        hitLayers.contains { layer in
            let rendered = layer.presentation() ?? layer
            let source = root.presentation() ?? root
            return StageGeometry.contains(rendered.convert(point, from: source), ellipse: rendered.bounds)
        }
    }
    func idle(reduced: Bool) {
        let breath = CABasicAnimation(keyPath: "transform.scale.y"); breath.fromValue = 1; breath.toValue = reduced ? 1.005 : 1.025
        breath.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        breath.duration = 2.1; breath.autoreverses = true; breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); body.add(breath, forKey: "breath")
    }
    func stop() { root.removeAllAnimations(); body.removeAllAnimations(); for joint in joints.values { joint.removeAllAnimations() } }
    func blink() {
        for eye in [leftEye, rightEye] {
            let blink = CAKeyframeAnimation(keyPath: "transform.scale.y"); blink.values = [1, 0.08, 1]; blink.keyTimes = [0, 0.48, 1]; blink.duration = 0.19
            eye.add(blink, forKey: "blink")
        }
    }
}
