import Foundation
import MokuKit

public struct PatRecognizer {
    public enum Result: Equatable { case click, pat, cancelled }
    private var start = CGPoint.zero
    private var last = CGPoint.zero
    private var beganOnHead = false
    private var distance = 0.0
    private var direction = 0.0
    private var reversals = 0
    private var started = 0.0
    public init() {}
    public mutating func begin(at point: CGPoint, onHead: Bool, time: Double) {
        start = point; last = point; beganOnHead = onHead; distance = 0; direction = 0; reversals = 0; started = time
    }
    public mutating func drag(to point: CGPoint) {
        let dx = point.x - last.x, dy = point.y - last.y
        distance += hypot(dx, dy)
        if abs(dx) >= 2 {
            let sign = dx > 0 ? 1.0 : -1.0
            if direction != 0 && direction != sign { reversals += 1 }
            direction = sign
        }
        last = point
    }
    public func end(time: Double) -> Result {
        if beganOnHead && reversals >= 1 && distance >= 22 && distance < 500 && time - started < 3 && abs(last.y - start.y) < 40 { return .pat }
        if distance < 7 && time - started < 1.2 { return .click }
        return .cancelled
    }
}

struct Expression: Equatable {
    var eye: Double = 1
    var brow: Double = 0
    var ear: Double = 0
    var smile: Double = 0.4
    var tilt: Double = 0
    var posture: Double = 1
    static func mood(_ mood: Mood) -> Expression {
        switch mood {
        case .content: Expression()
        case .happy: Expression(eye: 0.65, brow: 0.2, ear: -0.12, smile: 1, tilt: -0.03)
        case .proud: Expression(eye: 0.85, brow: 0.1, ear: -0.18, smile: 0.8, posture: 1.05)
        case .curious: Expression(eye: 1.15, brow: 0.7, ear: 0.1, smile: 0.2, tilt: 0.14)
        case .concerned: Expression(eye: 0.9, brow: 0.85, ear: 0.2, smile: -0.15, tilt: -0.08, posture: 0.98)
        case .disappointed: Expression(eye: 0.65, brow: 0.65, ear: 0.34, smile: -0.35, tilt: 0.05, posture: 0.95)
        case .annoyed: Expression(eye: 0.7, brow: -0.65, ear: 0.1, smile: -0.2, posture: 1.02)
        case .sleepy: Expression(eye: 0.2, brow: 0, ear: 0.3, smile: 0.1, tilt: -0.08, posture: 0.95)
        }
    }
    func blended(to other: Expression, amount: Double) -> Expression {
        if amount <= 0 { return self }; if amount >= 1 { return other }
        let t = amount; func mix(_ a: Double, _ b: Double) -> Double { a + (b-a)*t }
        return Expression(eye: mix(eye, other.eye), brow: mix(brow, other.brow), ear: mix(ear, other.ear), smile: mix(smile, other.smile), tilt: mix(tilt, other.tilt), posture: mix(posture, other.posture))
    }
}

/// Visibility cannot advance until either the real renderer supplies a frame or loading fails.
enum VisualReadiness: Equatable { case loading, realFrameReady, fallbackReady }
