import AppKit
import QuartzCore
import MokuKit

extension PlushPuppet {
    func animate(_ layer: CALayer, key: String, values: [Double], duration: Double, repeatCount: Float = 0) {
        let a = CAKeyframeAnimation(keyPath: key); a.values = values; a.duration = duration; a.repeatCount = repeatCount
        a.calculationMode = .cubic; a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 60, preferred: 60)
        layer.add(a, forKey: key)
    }
    func expression(_ expression: Expression, reduced: Bool) {
        CATransaction.begin(); CATransaction.setAnimationDuration(reduced ? 0.2 : 0.65)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        leftEye.transform = CATransform3DMakeScale(1, expression.eye, 1); rightEye.transform = leftEye.transform
        head.transform = CATransform3DMakeRotation(expression.tilt, 0, 0, 1)
        joints["chest"]?.transform = CATransform3DMakeScale(1, expression.posture, 1)
        joints["ear_L_01"]?.transform = CATransform3DMakeRotation(0.18 + expression.ear, 0, 0, 1)
        joints["ear_R_01"]?.transform = CATransform3DMakeRotation(-0.12 - expression.ear * 0.8, 0, 0, 1)
        for (brow, x, side) in [(leftBrow, 30.0, 1.0), (rightBrow, 75.0, -1.0)] {
            let p = CGMutablePath(); p.move(to: CGPoint(x: x, y: 52 - expression.brow * 2 * side))
            p.addQuadCurve(to: CGPoint(x: x + 11, y: 52 + expression.brow * 2 * side), control: CGPoint(x: x + 5, y: 54))
            brow.path = p; brow.opacity = Float(min(1, abs(expression.brow) + 0.15))
        }
        let p = CGMutablePath(); p.move(to: CGPoint(x: 47, y: 24))
        p.addQuadCurve(to: CGPoint(x: 65, y: 24), control: CGPoint(x: 56, y: 24 - expression.smile * 11))
        mouth.path = p; CATransaction.commit()
    }
    func look(x: Double, y: Double, reduced: Bool) {
        CATransaction.begin(); CATransaction.setAnimationDuration(0.14)
        leftEye.position = CGPoint(x: 36 + x * 3.2, y: 40 + y * 2.5)
        rightEye.position = CGPoint(x: 81 + x * 3.2, y: 40 + y * 2.5); CATransaction.commit()
        CATransaction.begin(); CATransaction.setAnimationDuration(reduced ? 0.2 : 0.6)
        head.position = CGPoint(x: 82 + x * 2.5, y: 105 + y * 1.8); CATransaction.commit()
    }
    func gesture(_ gesture: Gesture, reduced: Bool) {
        let amplitude = reduced ? 0.25 : 1.0
        for joint in joints.values { for key in joint.animationKeys() ?? [] where key != "breath" { joint.removeAnimation(forKey: key) } }
        switch gesture {
        case .smile:
            animate(mouth, key: "transform.scale.x", values: [1, 1.22, 1.12, 1], duration: 1.6)
            for eye in [leftEye, rightEye] { animate(eye, key: "transform.scale.y", values: [1, 0.55, 0.55, 1], duration: 1.6) }
        case .nod: animate(head, key: "transform.rotation.x", values: [0, -0.3, 0.2, -0.15, 0].map { $0 * amplitude }, duration: 1.1)
        case .glance: animate(head, key: "transform.rotation.z", values: [0, 0.12, -0.12, 0].map { $0 * amplitude }, duration: 1.8)
        case .sigh: animate(body, key: "transform.scale.y", values: [1, 1.04, 0.95, 1], duration: 2.4)
        case .standUp: animate(body, key: "transform.scale.y", values: [1, 0.96, 1.16, 1.12, 1], duration: 2.4)
        case .sitDown: animate(body, key: "transform.scale.y", values: [1, 1.07, 0.88, 1.02, 1], duration: 1.7)
        case .wave, .cheer, .celebrate:
            if let arm = joints["arm_R"] { animate(arm, key: "transform.rotation.z", values: [0, -1.9, -1.2, -1.9, -1.2, 0].map { $0 * amplitude }, duration: 2.2) }
            if gesture != .wave {
                if let arm = joints["arm_L"] { animate(arm, key: "transform.rotation.z", values: [0, 1.7, 1.3, 1.7, 0].map { $0 * amplitude }, duration: 2.2) }
                animate(body, key: "transform.translation.y", values: [0, -3, 18, 0, 28, 0, 10, 0].map { $0 * amplitude }, duration: gesture == .celebrate ? 3 : 1.8)
                if gesture == .celebrate && !reduced { petals() }
            }
        case .stretch:
            animate(body, key: "transform.scale.y", values: [1, 0.96, 1.14, 1.14, 1], duration: 3)
            if let arm = joints["arm_L"] { animate(arm, key: "transform.rotation.z", values: [0, 2.5, 2.5, 0].map { $0 * amplitude }, duration: 3) }
        case .drinkWater:
            if let arm = joints["arm_R"] { animate(arm, key: "transform.rotation.z", values: [0, -0.9, -0.9, 0], duration: 3) }
            let cup = CALayer(); cup.frame = CGRect(x: 91, y: 75, width: 17, height: 19); cup.cornerRadius = 4
            cup.backgroundColor = NSColor(red: 0.44, green: 0.64, blue: 0.66, alpha: 1).cgColor; root.addSublayer(cup)
            CATransaction.begin(); CATransaction.setCompletionBlock { cup.removeFromSuperlayer() }
            animate(cup, key: "opacity", values: [0, 1, 1, 0], duration: 3); CATransaction.commit()
        case .yawn:
            animate(mouth, key: "transform.scale.y", values: [1, 3, 3, 1], duration: 2.6)
            for eye in [leftEye, rightEye] { animate(eye, key: "transform.scale.y", values: [1, 0.1, 0.1, 1], duration: 2.6) }
        case .patReaction:
            animate(head, key: "transform.rotation.z", values: [0, 0.12, -0.09, 0.04, 0].map { $0 * amplitude }, duration: 1.6)
            for eye in [leftEye, rightEye] { animate(eye, key: "transform.scale.y", values: [1, 0.15, 0.15, 1], duration: 1.6) }
        case .sniff:
            animate(head, key: "transform.translation.y", values: [0, 1.5, 0.8, 1.5, 0.8, 1.2, 0].map { $0 * amplitude }, duration: 0.9)
            return
        }
        if let ear = joints["ear_R_01"] { animate(ear, key: "transform.rotation.z", values: [-0.12, -0.3, 0.02, -0.17, -0.12].map { $0 * amplitude }, duration: 1.9) }
    }
    func petals() {
        for i in 0..<16 {
            let petal = CALayer(); petal.frame = CGRect(x: 78, y: 80, width: 4, height: 7); petal.cornerRadius = 3
            petal.backgroundColor = [NSColor.systemPink, .systemYellow, .systemGreen][i % 3].withAlphaComponent(0.8).cgColor
            // The model value is the end of the fade: with the default (1) the 16 petals flashed on the chest for a frame
            // when their animation ended, just before they were removed (launch QA, lens 4).
            petal.opacity = 0
            root.addSublayer(petal)
            CATransaction.begin(); CATransaction.setCompletionBlock { petal.removeFromSuperlayer() }
            animate(petal, key: "transform.translation.x", values: [0, Double(i-8)*8, Double(i-8)*10], duration: 2.4)
            animate(petal, key: "transform.translation.y", values: [0, 55 + Double(i%4)*10, -70], duration: 2.4)
            animate(petal, key: "opacity", values: [0, 1, 1, 0], duration: 2.4); CATransaction.commit()
        }
    }
}
