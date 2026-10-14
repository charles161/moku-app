import Foundation
import MokuKit

extension WorkState {
    var isDrift: Bool { [.grace, .noticing, .concerned, .drifting, .longDrift].contains(self) }
    var tierAge: Double { switch self { case .noticing: 60; case .concerned: 120; case .drifting: 300; case .longDrift: 720; default: 0 } }
}

/// The stage's attention budget. Inputs are monotonic time and explicit work state;
/// no screen contents or app activity are inferred here.
struct WorkDirection {
    private(set) var state: WorkState = .idle
    private(set) var workPoint: CGPoint?
    private(set) var driftStartedAt: Double?
    private(set) var glanceCount = 0
    private(set) var noticingGlanceUsed = false
    private(set) var sighed = false
    private(set) var nextGlanceAt = Double.infinity
    private(set) var blockedUntil = 0.0
    private(set) var lastMicro: MicroExpression?
    /// A point where the work is. In a drift it isn't taken as the work's place (the drift's window isn't the work), but
    /// it's still a look away from the user: the engine's look back to the work after the sad move (2026-10-14).
    mutating func receive(point: CGPoint) -> Bool {
        if state == .focused || state == .idle { workPoint = point }
        return true
    }
    mutating func set(_ next: WorkState, now: Double) {
        guard next != state else { return }
        let wasDrift = state.isDrift
        state = next
        if next.isDrift {
            if !wasDrift {
                driftStartedAt = now - next.tierAge; glanceCount = 0; noticingGlanceUsed = false; sighed = false; lastMicro = nil
                nextGlanceAt = now
            }
        } else {
            driftStartedAt = nil; glanceCount = 0; noticingGlanceUsed = false; sighed = false; lastMicro = nil; nextGlanceAt = .infinity
        }
    }
    mutating func pause(now: Double) { blockedUntil = max(blockedUntil, now + 8) }
    func pool(reduced: Bool) -> [MicroExpression] {
        guard state.isDrift, state != .grace else { return [] }
        let candidates: [MicroExpression]
        if reduced { candidates = [.brow, .slowBlink] }
        else {
            // Face only: through a drift Moku keeps looking at you (Charles: "just look at me"), so nothing
            // here moves the eyes or head off you.
            switch state {
            case .noticing: candidates = [.ear, .nose, .brow, .slowBlink]
            case .concerned: candidates = [.brow, .slowBlink, .innerBrow, .lipPress]
            case .drifting: candidates = [.lipPress, .narrow, .pout, .exhale]
            case .longDrift: candidates = [.puff, .pout, .narrow, .slowBlink]
            default: candidates = []
            }
        }
        return candidates.filter { $0 != lastMicro && ($0 != .exhale || !sighed) }
    }
    mutating func claim(now: Double, busy: Bool, reduced: Bool, choice: Int, jitter: Double) -> MicroExpression? {
        if busy { pause(now: now); return nil }
        guard state.isDrift, state != .grace, driftStartedAt != nil, glanceCount < 8,
              !(state == .noticing && noticingGlanceUsed) else { return nil }
        // The first reaction belongs to the verdict, not to the later cadence.
        if glanceCount > 0 && (now < blockedUntil || now < nextGlanceAt) { return nil }
        let available = pool(reduced: reduced)
        guard !available.isEmpty else { return nil }
        let expression = available[abs(choice % available.count)]
        glanceCount += 1; lastMicro = expression
        if state == .noticing { noticingGlanceUsed = true }
        if expression == .exhale { sighed = true }
        let interval: Double
        switch state { case .noticing: interval = 60; case .concerned: interval = 67.5; case .drifting: interval = 82.5; default: interval = 90 }
        nextGlanceAt = now + max(45, interval * min(1.2, max(0.8, jitter)))
        return expression
    }
}

struct LanternPhase: Equatable {
    let brightness: Double
    let poolWidth: Double
    let poolOpacity: Float
    let breath: Bool
    let gutter: Bool
    static func forState(_ state: WorkState) -> Self {
        switch state {
        case .focused, .grace: .init(brightness: 1, poolWidth: 120, poolOpacity: 0.22, breath: true, gutter: false)
        case .noticing: .init(brightness: 0.65, poolWidth: 90, poolOpacity: 0.13, breath: true, gutter: false)
        case .concerned: .init(brightness: 0.4, poolWidth: 70, poolOpacity: 0.08, breath: false, gutter: false)
        case .drifting, .longDrift: .init(brightness: 0.25, poolWidth: 56, poolOpacity: 0.05, breath: false, gutter: true)
        case .away, .onBreak: .init(brightness: 0.5, poolWidth: 70, poolOpacity: 0.10, breath: false, gutter: false)
        case .idle: .init(brightness: 0.15, poolWidth: 56, poolOpacity: 0.03, breath: false, gutter: false)
        }
    }
}

/// Shared, monotonic easing keeps face correctives and their joints in phase.
struct MoodTiming {
    static func progress(age: Double, duration: Double = 2.4) -> Float {
        let u = min(1, max(0, age / max(0.001, duration)))
        return Float(u * u * (3 - 2 * u))
    }
}

/// A value easing (smoothstep) from wherever it is to a new goal, after an optional delay, so a change of
/// mind mid-way never jumps.
struct Ease: Equatable {
    private(set) var from: Float = 0, to: Float = 0, at = -100.0, duration = 0.6
    func value(at now: Double) -> Float { from + (to - from) * MoodTiming.progress(age: now - at, duration: duration) }
    mutating func go(to goal: Float, at now: Double, over seconds: Double, after delay: Double = 0) {
        guard goal != to else { return }
        from = value(at: now); to = goal; at = now + delay; duration = seconds
    }
}

/// The smile gesture: after `delay`, the smile and happy crescent eyes rise, hold, and fall on eased curves.
/// Rise and hold end with the engine's 2.5 s look-up (after the 0.45 s turn), so the smile and the eyes open
/// as the head turns back, in one movement.
struct SmileTiming {
    static let rise = 0.45, hold = 1.6, fall = 0.6
    static var length: Double { rise + hold + fall }
    static func amount(age: Double) -> Float {
        if age <= 0 || age >= length { return 0 }
        if age < rise { return MoodTiming.progress(age: age, duration: rise) }
        if age < rise + hold { return 1 }
        return 1 - MoodTiming.progress(age: age - rise - hold, duration: fall)
    }
}

/// Now and then an ear flicks, like a rabbit's: a quick twitch out, then a soft wobble back (a damped
/// spring's kick), about 8° at the base, over about a second.
struct EarFlick {
    static let seconds = 1.1
    /// The base's angle in radians at `age`; the tip follows a beat later.
    static func angle(age: Double) -> Float {
        guard age > 0, age < seconds else { return 0 }
        let fadeOut = 1 - MoodTiming.progress(age: age - 0.8, duration: 0.3)  // lands exactly at rest
        return Float(0.2 * exp(-age / 0.28) * sin(2 * .pi * 2.4 * age)) * fadeOut
    }
}

/// Now and then a paw, both paws, a foot, the head or the whole body moves a little, the way a small living thing never
/// holds perfectly still (Charles: "the legs or hands or head should also move a little ... so subtle, like a
/// true living creature"). Each is a slow ease out and back, never a snap, of a few degrees.
struct Fidget: Equatable {
    enum Kind: CaseIterable, Equatable { case pawShift, footWiggle, headTilt, weightShift, pawsTogether }
    let kind: Kind
    /// Which side moves: 1 is Moku's left, -1 its right.
    let side: Float

    var seconds: Double {
        switch kind {
        case .pawShift: 2.6
        case .footWiggle: 1.8
        case .headTilt: 3.2
        case .weightShift: 3.4
        case .pawsTogether: 2.8
        }
    }

    /// 0 at the start and the end, 1 in between: eases out over the first 35%, back over the last 40%.
    func amount(at age: Double) -> Float {
        guard age > 0, age < seconds else { return 0 }
        let u = age / seconds
        return min(MoodTiming.progress(age: u, duration: 0.35), 1 - MoodTiming.progress(age: u - 0.6, duration: 0.4))
    }

    /// Radians added to `leaf`'s pose at `age`.
    func angles(for leaf: String, at age: Double) -> SIMD3<Float> {
        angles(for: leaf, envelope: amount(at: age), wag: Float(sin(age * 2 * .pi * 1.1)))  // the foot's slow wag
    }
    /// The same move at envelope `e` (0…1) with the foot's wag at `wave` (a machine's: ServoTiming.envelope, no wag).
    func angles(for leaf: String, envelope e: Float, wag wave: Float) -> SIMD3<Float> {
        guard e > 0 else { return .zero }
        let own = side > 0 ? "L" : "R"
        switch (kind, leaf) {
        case (.pawShift, "arm_\(own)"): return SIMD3(-0.11, 0, 0.06 * side) * e   // the paw moves forward a touch and settles
        case (.pawShift, "hand_\(own)"): return SIMD3(0.06, 0, 0) * e
        case (.footWiggle, "foot_\(own)"): return SIMD3(0.05, 0, 0.10 * wave) * e  // toes wag
        case (.headTilt, "head"): return SIMD3(0.02, 0, 0.07 * side) * e          // a small curious tilt
        case (.weightShift, "chest"): return SIMD3(0, 0.03 * side, 0.035 * side) * e
        case (.weightShift, "head"): return SIMD3(0, 0, -0.02 * side) * e          // the head stays level as the body leans
        case (.pawsTogether, "arm_L"): return SIMD3(-0.05, 0, -0.07) * e          // both paws come in toward each other
        case (.pawsTogether, "arm_R"): return SIMD3(-0.05, 0, 0.07) * e
        default: return .zero
        }
    }
}

struct GazeTiming {
    static let duration = 1.25
    static func eyes(_ age: Double) -> Float { MoodTiming.progress(age: age, duration: 0.5) }
    /// When a gaze change's ease starts: one frame before the first frame drawn after it, however long the renderer took
    /// to wake. An idle renderer's first frame came 125 ms after the change and carried a quarter of the eyes' turn, 12 to
    /// 15° in one frame, as Moku settled back to the work after "welcome back" (the motion audit's "settled" beat). A change
    /// made while frames are running keeps its own time.
    static func easeStart(changedAt: Double, firstFrame: Double, frame: Double = 1.0 / 60) -> Double {
        firstFrame - changedAt > 2 * frame ? firstFrame - frame : changedAt
    }
    static func head(_ age: Double, reduced: Bool) -> Float {
        // Critically damped, with eyes leading. Time compression brings the
        // spring to rest continuously at a finite endpoint, without overshoot.
        let u = max(0, (age - 0.15) / (duration - 0.15))
        if u >= 1 { return 1 }
        let t = 4 * u / (1 - u)
        return Float(1 - (1 + t) * exp(-t))
    }
}

/// How a gaze direction (radians: yaw right, pitch up) spreads over the body when Moku turns to
/// watch something: the chest turns a little, the head half of it, the eyes the rest. From a corner the look at
/// the middle of the screen is wide, and a head that carried most of it read as slanted (Charles, 2026-10-14: "just
/// a slight one is enough"): the head turns at most about 20° and tips about 10°, and the eyes carry more.
struct GazeSplit {
    let chestYaw: Float, headYaw: Float, headPitch: Float
    init(_ gaze: SIMD2<Float>) {
        chestYaw = min(0.10, max(-0.10, gaze.x * 0.12))
        headYaw = min(0.35, max(-0.35, (gaze.x - chestYaw) * 0.5))
        headPitch = min(0.18, max(-0.18, gaze.y * 0.5))
    }
    /// The eyes cover whatever the body hasn't turned yet, so they lead and then settle. `moodTurn` is the
    /// extra turn a mood gives the head and chest (yaw right, pitch up); the eyes take it back out.
    func eyes(toward gaze: SIMD2<Float>, moodTurn: SIMD2<Float> = .zero) -> SIMD2<Float> {
        SIMD2(min(0.30, max(-0.30, gaze.x - chestYaw - headYaw - moodTurn.x)),
              min(0.20, max(-0.20, gaze.y - headPitch - moodTurn.y)))
    }
}
