import QuartzCore
import simd
import Foundation
import MokuKit

/// Time-driven states are advanced by the existing stage tick, never a new idle timer.
struct HoverDwell {
    private var enteredAt: Double?
    private(set) var active = false
    mutating func update(inside: Bool, allowed: Bool, now: Double) -> Bool? {
        guard inside && allowed else {
            enteredAt = nil
            if active { active = false; return false }
            return nil
        }
        if enteredAt == nil { enteredAt = now }
        if !active && now - (enteredAt ?? now) >= 0.3 { active = true; return true }
        return nil
    }
}

enum MicroExpression: String, CaseIterable, Sendable {
    case brow, ear, nose, gazePoint, lookDown, doubleBlink, lipPress, tilt, innerBrow, slowBlink, pout, exhale, narrow, puff, sideGlance, smile
    static func vocabulary(for mood: Mood) -> [Self] {
        switch mood {
        case .curious: [.brow, .ear, .doubleBlink]
        case .concerned: [.lipPress, .tilt, .innerBrow]
        case .disappointed: [.slowBlink, .pout, .exhale]
        case .annoyed: [.narrow, .puff, .sideGlance]
        case .content, .happy, .proud: [.smile, .slowBlink]
        case .sleepy: []
        }
    }
    var duration: Double {
        switch self {
        case .ear: 0.25
        case .nose: 0.4
        case .doubleBlink: 0.48
        case .slowBlink: 0.7
        case .brow, .innerBrow, .tilt: 0.8
        case .lipPress, .puff, .lookDown, .narrow: 0.9
        case .pout: 1
        case .gazePoint, .exhale, .sideGlance, .smile: 1.2
        }
    }
    func strength(at progress: Double) -> Float {
        guard progress > 0, progress < 1 else { return 0 }
        if self == .slowBlink {
            // Eased both ways: a straight-line opening stopped at full speed and read as a jitter.
            let age = progress * duration
            if age < 0.25 { return Float(BlinkTiming.smooth(age / 0.25)) }
            if age < 0.4 { return 1 }
            return Float(1 - BlinkTiming.smooth((age - 0.4) / 0.3))
        }
        let wave = sin(progress * .pi * (self == .doubleBlink ? 2 : 1))
        return Float(wave * wave)
    }
}

struct MicroSchedule {
    private(set) var nextAt: Double = 0
    private(set) var endsAt: Double = 0
    mutating func reset(now: Double, delay: Double) { nextAt = now + min(8, max(3, delay)); endsAt = now }
    mutating func claim(now: Double, allowed: Bool, expression: MicroExpression, delay: Double) -> Bool {
        guard allowed, now >= nextAt, now >= endsAt else { return false }
        endsAt = now + expression.duration
        nextAt = now + min(8, max(3, delay))
        return true
    }
}

extension Mood {
    /// Moods in which Moku should read as smiling at any size (characters-perfect.md): nothing layered on top may take
    /// the smile away.
    var isPleased: Bool { self == .content || self == .happy || self == .proud }
}

/// The face channels that make a smile read at the size the app shows Moku (about 100 px): closed happy arcs, smiling
/// lower lids, lifted cheeks and the blush. The hairline w barely reads there, so it isn't one of them.
enum SmileChannels {
    static let floor: Set<String> = ["eyes_happy", "eyes_proud", "lid_smile_lower", "cheeks_raise", "blush_more"]
}

/// A clip's face laid over the mood's. Clips are authored from a content face (lids a little down, a small smile), so
/// replacing the mood's face with theirs snapped it at the clip's first frame and threw a happy Moku's arcs open. A
/// clip now moves each channel by the same share as it moves from its own first frame: up by that share of the room
/// left, down by that share of the way to zero. It starts and ends on the mood's face, and in a pleased mood it can add
/// to the smile but never take it away.
enum ClipFace {
    /// The expression channels laid over the mood. The rest (ears, arms, a display's moments, the material switches) are
    /// the clip's own, as before.
    static let relative: Set<String> = ["blink_L", "blink_R", "eyes_happy", "eyes_wide", "brows_up", "brows_concern", "brows_angry", "smile", "frown",
                                        "mouth_open", "pout", "cheeks_puff", "mouth_smile_open", "cheeks_raise", "blush_more", "eyes_look_down",
                                        "brow_raise_L", "brow_raise_R", "lips_press", "eyes_narrow", "lid_flat", "lid_sad", "lid_smile_lower", "eyes_proud", "nose_twitch"]
    static func weight(mood: Float, clip: Float, start: Float, name: String, pleased: Bool) -> Float {
        let delta = clip - start
        var value = delta >= 0 ? mood + delta * (1 - mood) / max(0.05, 1 - start) : mood + delta * mood / max(0.05, start)
        value = min(1, max(0, value))
        if pleased && SmileChannels.floor.contains(name) { value = max(value, mood) }
        return value
    }
}

/// A mood change into or out of closed happy arcs (content to happy, a return, proud). Blending the eyes' weight evenly
/// left them half shut for most of the change, which reads as heavy lids, not a smile. Instead the smile leads: the
/// lower lids rise first (a smiling squint), and the eyes close into arcs quickly, a third of the way in; on the way
/// out they open early, onto the squint. A sad face (a frown, worried brows, lowered lids) clears in the first half.
struct SmileBridge: Equatable {
    enum Way: Equatable { case none, intoArcs, outOfArcs }
    let way: Way
    let duration: Double
    /// How long the arcs take: closing, about a slow blink; opening (onto the squint, as the head turns back to the
    /// work), unhurried.
    var arcSeconds: Double { way == .intoArcs ? min(0.25, 0.4 * duration) : min(0.5, 0.45 * duration) }
    var arcsAt: Double { way == .intoArcs ? 0.35 * duration : 0.08 * duration }
    static let sad: Set<String> = ["frown", "brows_concern", "brows_angry", "lid_sad", "pout", "lips_press", "blink_L", "blink_R", "eyes_narrow", "lid_flat"]
    /// `fromArcs`, `toArcs`: how closed the eyes' arcs are before and in the new mood; `toPleased`: the new mood's.
    init(fromArcs: Float, toArcs: Float, toPleased: Bool, duration: Double) {
        self.duration = duration
        way = toArcs >= 0.5 && fromArcs < 0.3 ? .intoArcs : fromArcs >= 0.5 && toArcs < 0.3 && toPleased ? .outOfArcs : .none
    }
    /// How far `name` is through the change, `age` seconds in (0…1, eased, no speed at either end).
    func progress(_ name: String, age: Double) -> Float {
        guard way != .none else { return MoodTiming.progress(age: age, duration: duration) }
        if name == "eyes_happy" || name == "eyes_proud" { return Float(LifeCurve.smooth((age - arcsAt) / arcSeconds)) }
        // Into arcs the smiling lower lids hold until the arcs take them (a dip first and a rise back read as a wobble).
        if way == .intoArcs && name == "lid_smile_lower" { return Float(LifeCurve.smooth((age - arcsAt) / arcSeconds)) }
        if Self.sad.contains(name) || (way == .outOfArcs && name == "lid_smile_lower") { return MoodTiming.progress(age: age, duration: duration * 0.5) }
        return MoodTiming.progress(age: age, duration: duration)
    }
    /// The smiling squint under the arcs (a floor for `lid_smile_lower`; arcs closing take it away again).
    func squint(age: Double) -> Float {
        switch way {
        case .none: 0
        case .intoArcs: 0.6 * Float(LifeCurve.smooth(age / arcsAt))
        case .outOfArcs: 0.6 * Float(1 - LifeCurve.smooth((age - arcsAt - arcSeconds) / max(0.01, duration - arcsAt - arcSeconds)))
        }
    }
}

struct MicroSample {
    var weights: [String: Float] = [:]
    var head = SIMD3<Float>.zero
    var ear: Float = 0
    var chest: Float = 0
    var gaze = SIMD2<Float>.zero
    /// `pleased`: the mood is pleased (`Mood.isPleased`), so a slow blink closes into happy arcs, not flat lids.
    init(_ expression: MicroExpression?, progress: Double, shapes: Set<String>, baseline: [String: Float] = [:], pleased: Bool = false) {
        guard let expression else { return }
        let s = expression.strength(at: progress)
        switch expression {
        case .brow:
            let side = (baseline["brow_raise_L"] ?? 0) >= 0.4 ? "brow_raise_R" : "brow_raise_L"
            weights[shapes.contains(side) ? side : "brows_up"] = 0.3 * s; head.z = 0.10 * s
        case .ear: ear = 0.26 * s
        case .nose: weights["nose_twitch"] = 0.3 * Float(pow(sin(progress * .pi * 3), 2))
        case .gazePoint: gaze.x = -0.6 * s; gaze.y = 0.35 * s; head.y = -0.10 * s
        case .lookDown: gaze.y = -0.5 * s
        case .doubleBlink: weights["blink_L"] = s; weights["blink_R"] = s
        case .slowBlink:
            // A cat's slow blink is affection: a pleased Moku closes its eyes into smiling arcs, not into a flat line,
            // which reads as asleep at the size it's shown. Otherwise (a drift) the lids close.
            if pleased && shapes.contains("eyes_happy") { weights["eyes_happy"] = s; weights["cheeks_raise"] = 0.2 * s }
            else { weights["blink_L"] = s; weights["blink_R"] = s }
        case .lipPress: weights[shapes.contains("lips_press") ? "lips_press" : "pout"] = 0.28 * s
        case .tilt: head.z = 0.055 * s
        case .innerBrow: weights["brows_concern"] = 0.22 * s
        case .pout: weights["pout"] = 0.3 * s
        case .exhale: chest = 0.05 * s; head.x = 0.018 * s
        case .narrow:
            if shapes.contains("eyes_narrow") { weights["eyes_narrow"] = 0.3 * s }
            else { weights["blink_L"] = 0.3 * s; weights["blink_R"] = 0.3 * s }
        case .puff: weights["cheeks_puff"] = 0.25 * s; if progress > 0.88 { weights["mouth_open"] = 0.15 * Float(sin((progress - 0.88) / 0.12 * .pi)) }
        case .sideGlance: gaze.x = 0.45 * s; head.y = 0.17 * s
        case .smile:
            // The look-up smile: the cheeks lift and it smiles at you, its eyes round and open (Charles, 2026-10-08:
            // closing them into happy arcs here read as Moku shutting its eyes for no reason; those are a pat's). No
            // raised lower lids either: with open eyes they read "weirdish" (2026-10-05).
            weights["smile"] = 0.4 * s; weights["cheeks_raise"] = 0.3 * s; weights["blush_more"] = 0.25 * s
        }
    }
}

extension MokuVisualDiagnostics {
    @MainActor public static func simulateHover(stage: MokuCharacterStage, inside: Bool) {
        guard stage.rendersOffscreen else { return }
        stage.simulatedHover = inside; stage.updateHit()
    }
    @MainActor public static func playMicro(stage: MokuCharacterStage, name: String) {
        guard stage.rendersOffscreen, let expression = MicroExpression(rawValue: name) else { return }
        stage.view.real?.microExpression(expression)
    }
    @MainActor public static func clipHistory(stage: MokuCharacterStage) -> [String] { stage.view.real?.clipHistory ?? [] }
    /// After a clip, the head eases back to where Moku was looking (the work) instead of snapping: plays `gesture`
    /// while Moku watches a point on the left of the screen, samples the head joint every frame from `from` s to
    /// `to` s after it starts, and writes the largest head turn between two frames (degrees) to clip-exit.json.
    @MainActor public static func clipExitCheck(stage: MokuCharacterStage, gesture: Gesture, from: Double, to: Double, directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.setHidden(false); stage.setWorkState(.focused); stage.setMood(.content)
        stage.setAttention(.point(CGPoint(x: 200, y: 500)))
        try await Task.sleep(for: .seconds(3))
        let start = CACurrentMediaTime()
        stage.perform(gesture)
        var previous: simd_quatf?, biggest: Float = 0, at = 0.0, samples: [[Double]] = []
        while CACurrentMediaTime() - start < to {
            try await Task.sleep(for: .milliseconds(16))
            let t = CACurrentMediaTime() - start
            guard t >= from, let v = stage.view.real?.displayedHeadRotation else { continue }
            let q = simd_quatf(vector: v)
            if let p = previous {
                let step = 2 * acos(min(1, abs(simd_dot(p.vector, q.vector)))) * 180 / .pi
                if step > biggest { biggest = step; at = t }
                samples.append([t, Double(step)])
            }
            previous = q
        }
        let report: [String: Any] = ["gesture": gesture.rawValue, "biggestHeadStepDeg": biggest, "atSeconds": at, "samples": samples.count]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("clip-exit.json"))
    }
    /// Starts one of the little movements by name (pawShift, footWiggle, headTilt, weightShift, pawsTogether); its length in seconds.
    @MainActor public static func fidget(stage: MokuCharacterStage, name: String) -> Double? {
        guard let kind = Fidget.Kind.allCases.first(where: { "\($0)" == name }), stage.view.real?.fidget(kind) == true else { return nil }
        return Fidget(kind: kind, side: 1).seconds
    }
}

/// A blink the way eyelids do it: shut quickly, a beat closed, then open more slowly and settle. The opening is
/// what reads as jitter when it's quick or stops at full speed (Charles: "when its opening the eyes its animation
/// is jittery"). Rendered frame by frame, never a crossfade between two snapshots.
enum BlinkTiming {
    static let close = 0.075, hold = 0.035, open = 0.17
    static var duration: Double { close + hold + open }
    /// How shut the lids are `age` seconds into a blink: 0 open, 1 closed.
    static func amount(age: Double) -> Float {
        guard age > 0, age < duration else { return 0 }
        if age < close { let u = age / close; return Float(u * u) }      // speeds up as it drops
        if age < close + hold { return 1 }
        let u = (age - close - hold) / open
        return Float(pow(1 - u, 3))                                      // quick at first, settles open
    }
    static func smooth(_ u: Double) -> Double { let x = min(1, max(0, u)); return x * x * (3 - 2 * x) }
}

// MARK: - Life between the big moments (moku-look-v2.md, step 6)
//
// Breathing, lids, little brow/ear/nose moves and reading darts. Every shape starts and ends at rest with no speed,
// so nothing can snap; they ride frames that are being drawn anyway where they can (lids change inside a blink, face
// moves join a blink, the 3D breath follows only drawn frames), and the rhythm is seeded randomness with floors.

/// Seeded randomness (SplitMix64): a reel replays exactly with MOKU_LIFE_SEED; in the app nothing repeats on a timer.
struct LifeRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    static var seed: UInt64 {
        if let pinned = ProcessInfo.processInfo.environment["MOKU_LIFE_SEED"].flatMap(UInt64.init) { return pinned }
        return UInt64(Date().timeIntervalSince1970 * 1000) ^ UInt64(ProcessInfo.processInfo.processIdentifier) << 32
    }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ r: ClosedRange<Double>) -> Double { r.lowerBound + (r.upperBound - r.lowerBound) * unit() }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
    /// A wait of at least `floor`, around `mean` on average, with an uneven tail (the mean of two exponentials) cut at
    /// `cap`: never a fixed beat, and never so long that Moku looks held still.
    mutating func wait(floor: Double, mean: Double, cap: Double = .infinity) -> Double {
        let a = -log(max(1e-6, unit())), b = -log(max(1e-6, unit()))
        return min(cap, floor + (mean - floor) * (a + b) / 2)
    }
    mutating func pick<T>(_ weighted: [(T, Double)]) -> T? {
        let total = weighted.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        var x = unit() * total
        for (item, weight) in weighted { x -= weight; if x < 0 { return item } }
        return weighted.last?.0
    }
}

/// Shapes over time. Each is 0 before and after, and leaves and lands with no speed.
/// How far the pointer's delight has come (0…1). It eases on the clock from where it was when the pointer came onto the
/// character or left it, so it never depends on how long the renderer had been asleep when the frame is drawn: it used to
/// take a step of the frame's time, so the first frame after a pause took all of it and the eyes shut in one frame.
enum HoverDelight {
    static let riseSeconds = 0.3, fallSeconds = 0.4
    static func strength(from: Float, rising: Bool, age: Double) -> Float {
        let target: Float = rising ? 1 : 0
        return from + (target - from) * Float(LifeCurve.smooth(age / (rising ? riseSeconds : fallSeconds)))
    }
}

enum LifeCurve {
    static func smooth(_ x: Double) -> Double { let x = min(1, max(0, x)); return x * x * x * (x * (x * 6 - 15) + 10) }
    /// Up over `rise`, held for `hold`, down over `fall`.
    static func bump(_ age: Double, rise: Double, hold: Double, fall: Double) -> Float {
        guard age > 0, age < rise + hold + fall else { return 0 }
        if age < rise { return Float(smooth(age / rise)) }
        if age < rise + hold { return 1 }
        return Float(1 - smooth((age - rise - hold) / fall))
    }
    /// One quick twitch, `length` long, starting at `start`.
    static func twitch(_ age: Double, start: Double, length: Double) -> Float {
        let u = (age - start) / length
        guard u > 0, u < 1 else { return 0 }
        let s = sin(u * .pi); return Float(s * s)
    }
    /// A kick and a damped wobble back (an ear answering): eased in over `onset` and faded to rest by `end`.
    static func wobble(_ age: Double, hertz: Double, decay: Double, end: Double, onset: Double = 0.08) -> Float {
        guard age > 0, age < end else { return 0 }
        let onset = smooth(age / onset), landing = 1 - smooth((age - (end - 0.3)) / 0.3)
        return Float(exp(-age / decay) * sin(2 * .pi * hertz * age) * onset * landing)
    }
}

/// Moku's breath. The image layer breathes on Core Animation all the time, anchored at the feet (no frames drawn for
/// it); whenever frames are drawn anyway, the chest swells and the cheeks fill in 3D, in phase with it.
struct Breath: Equatable {
    var startedAt = 0.0, seconds = 4.8
    /// 0 breathed out … 1 breathed in, on the layer's own ease-in-out curve.
    func amount(at now: Double) -> Float {
        var u = (now - startedAt) / (seconds / 2)
        u -= 2 * Foundation.floor(u / 2)
        let x = u < 1 ? u : 2 - u
        return Float(x * x * (3 - 2 * x))
    }
    /// Seconds until the next bottom of a breath (0 at one).
    func untilBottom(at now: Double) -> Double {
        let into = (now - startedAt) - seconds * Foundation.floor((now - startedAt) / seconds)
        return into < 1e-9 ? 0 : seconds - into
    }
    static func seconds(for mood: Mood) -> Double {
        switch mood { case .content: 4.8; case .happy: 3.2; case .proud: 5.5; case .curious: 4; case .concerned: 3.6; case .disappointed: 6; case .annoyed: 4; case .sleepy: 6.5 }
    }
    /// How deep: a doze and a sad sigh breathe slow and deep, happiness quick and light.
    static func depth(for mood: Mood) -> Float {
        switch mood { case .content: 1; case .happy: 0.8; case .proud: 1.1; case .curious: 0.85; case .concerned: 1.1; case .disappointed: 1.3; case .annoyed: 1.2; case .sleepy: 1.6 }
    }
    /// The 3D breath follows the layer's only on drawn frames, and catches up no faster than this (per second, in
    /// depths), so a frame drawn after a pause never jumps.
    static let catchUp: Float = 1.1
    /// The layer's stretch at full depth: tall (the head rises), and a little wide (the chest fills).
    static let rise: Float = 0.009, widen: Float = 0.003
}

/// Eyelids that tense and relax with the mood. A new setting is chosen while the eyes are shut in a blink, so the
/// change is never seen happening: the eyes simply open a little softer, or a little brighter.
struct LidTension: Equatable {
    var weights: [String: Float] = [:]
    /// Settings for a mood. Happy and proud eyes are closed arcs and sleepy ones shut: no blinks, nothing here.
    static func choices(for mood: Mood) -> [[String: Float]] {
        switch mood {
        // Content keeps smiling through every setting: softer is the lower lids up a touch more, brighter is the eyes a
        // touch rounder. Upper lids lowered on their own read as tired at the size Moku is shown, so they never come
        // without the lower lids rising too.
        case .content: [[:], ["lid_smile_lower": 0.15, "cheeks_raise": 0.1], ["blink_L": 0.06, "blink_R": 0.06, "lid_smile_lower": 0.14],
                        ["eyes_wide": 0.06, "lid_smile_lower": -0.12], ["blink_L": 0.04, "blink_R": 0.09, "lid_smile_lower": 0.1]]
        case .curious: [[:], ["eyes_wide": 0.12], ["blink_L": 0.08, "blink_R": 0.08]]
        case .concerned: [[:], ["eyes_wide": 0.10], ["lid_sad": 0.18]]
        case .disappointed: [[:], ["lid_sad": 0.25], ["blink_L": 0.10, "blink_R": 0.10, "lid_sad": 0.15], ["blink_L": -0.10, "blink_R": -0.10],
                             ["blink_L": 0.05, "blink_R": 0.14]]
        case .annoyed: [[:], ["eyes_narrow": 0.22, "lid_flat": 0.15], ["eyes_narrow": 0.32], ["lid_flat": 0.25]]
        case .happy, .proud, .sleepy: []
        }
    }
    /// A different setting from the one shown (when the mood has any), using only lids this character moves.
    mutating func choose(for mood: Mood, using random: inout LifeRandom, shapes: Set<String>? = nil) {
        let options = Self.choices(for: mood).filter { option in option != weights && (shapes.map { option.keys.allSatisfy($0.contains) } ?? true) }
        guard !options.isEmpty else { weights = [:]; return }
        weights = options[min(options.count - 1, Int(random.unit() * Double(options.count)))]
    }
    mutating func scale(_ amount: Float) { weights = weights.mapValues { $0 * amount } }
}

/// What a life move adds on a frame: face weights, joint angles (radians, by joint), and an eye turn.
struct LifeSample {
    var weights: [String: Float] = [:]
    var angles: [String: SIMD3<Float>] = [:]
    func scaled(_ k: Float) -> LifeSample {
        LifeSample(weights: weights.mapValues { $0 * k }, angles: angles.mapValues { $0 * k })
    }
}

/// The little moves between the big ones. Brows and ears answer each other; one side moves alone; the nose twitches.
struct LifeMove: Equatable {
    enum Kind: String, CaseIterable, Sendable {
        /// A quick bunny double twitch of the nose.
        case noseWiggle
        /// One brow lifts; the ear tip on that side answers a beat later.
        case browEar
        /// One ear twitches; the brow on that side answers.
        case earBrow
        /// One ear perks (or droops, when sad or sleepy) and settles, the tip lagging.
        case earPerk
        /// Both brows lift a touch, both ear tips bob (happy).
        case browsSoft
        /// The inner brows pinch a little more, the ear tips sink (sad, worried).
        case innerBrow
        /// The cheeks lift, the smile and the smiling lids with them (happy, proud).
        case cheekSqueeze
        /// Dozing: the lids part a crack and close again, one more than the other.
        case eyeCrack
        /// Dozing: a slow nose twitch and a flick of an ear tip, as if dreaming.
        case dreamTwitch
        /// One ear dips; the other answers a beat later, softer (happy, proud: their eyes are closed arcs).
        case earAnswer
        /// On the layer (no frames drawn): Moku leans a touch to one side, about its feet, and back.
        case sway
        /// On the layer: a slow rock, one side, then the other, then home.
        case rock
        /// On the layer: the next breath is a deeper one, a contented sigh. It starts at the bottom of a breath and
        /// lasts one breath.
        case breathSwell
        /// A window new to Moku came to the front (Moku's talent, next-wave.md §2): three quick sniffs, the chin
        /// lifting a touch toward it, the ears perked and the eyes a little wider. Only when asked (`Gesture.sniff`).
        case sniff
    }
    let kind: Kind
    /// 1: Moku's left (its _L controls), -1: its right.
    let side: Float
    /// 0.75…1.1, so no two are quite alike.
    let strength: Float
    var seconds: Double {
        switch kind {
        case .noseWiggle: 0.32
        case .browEar: 1.0
        case .earBrow: 0.8
        case .earPerk: 0.95
        case .browsSoft: 1.0
        case .innerBrow: 1.0
        case .cheekSqueeze: 0.9
        case .eyeCrack: 1.15
        case .dreamTwitch: 0.8
        case .earAnswer: 1.0
        case .sniff: 0.95
        case .sway, .rock: LayerLean.seconds(kind)
        case .breathSwell: 0  // one breath: the mood's (Breath.seconds)
        }
    }
    /// Played by Core Animation on the image layer: no frames drawn, so it costs nothing to the CPU.
    var onLayer: Bool { kind.onLayer }
    /// Whether it changes the face (which rebuilds the face mesh each frame it moves); the others move bones only.
    var touchesFace: Bool { kind != .earPerk && kind != .earAnswer && !onLayer }
    /// Quick enough to need 60 fps; the rest is slow and small, and 30 is plenty.
    var quick: Bool { [.noseWiggle, .dreamTwitch, .sniff].contains(kind) }
    var usesEars: Bool { ![.noseWiggle, .cheekSqueeze, .eyeCrack].contains(kind) && !onLayer }

    func sample(at age: Double, mood: Mood) -> LifeSample {
        var out = LifeSample()
        guard age > 0, age < seconds, !onLayer else { return out }
        let own = side > 0 ? "L" : "R", other = side > 0 ? "R" : "L", s = strength
        let sad = mood == .disappointed || mood == .concerned || mood == .sleepy
        switch kind {
        case .noseWiggle:
            // The nose scrunches twice, and the cheeks (the whisker pads) lift with it.
            let twitch = LifeCurve.twitch(age, start: 0, length: 0.12) + 0.72 * LifeCurve.twitch(age, start: 0.17, length: 0.13)
            out.weights["nose_twitch"] = min(0.85, 0.8 * s) * twitch; out.weights["cheeks_raise"] = 0.12 * s * twitch
        case .browEar:
            out.weights["brow_raise_\(own)"] = 0.26 * s * LifeCurve.bump(age, rise: 0.18, hold: 0.22, fall: 0.38)
            out.angles["ear_\(own)_01"] = SIMD3(-0.06 * s * LifeCurve.bump(age - 0.14, rise: 0.2, hold: 0.16, fall: 0.38), 0, 0)
            out.angles["ear_\(own)_02"] = SIMD3(0.04 * s * LifeCurve.bump(age - 0.22, rise: 0.2, hold: 0.12, fall: 0.36), 0, 0)
        case .earBrow:
            out.angles["ear_\(own)_01"] = SIMD3(0, 0, side * 0.07 * s * LifeCurve.bump(age, rise: 0.24, hold: 0.08, fall: 0.34))
            out.angles["ear_\(own)_02"] = SIMD3(0, 0, side * 0.05 * s * LifeCurve.bump(age - 0.06, rise: 0.24, hold: 0.08, fall: 0.34))
            out.weights["brow_raise_\(own)"] = 0.2 * s * LifeCurve.bump(age - 0.2, rise: 0.16, hold: 0.12, fall: 0.3)
        case .earPerk:
            let k = LifeCurve.bump(age, rise: 0.28, hold: 0.26, fall: 0.38), tip = LifeCurve.bump(age - 0.08, rise: 0.28, hold: 0.22, fall: 0.36)
            out.angles["ear_\(own)_01"] = SIMD3((sad ? 0.07 : -0.08) * s * k, 0, 0)
            out.angles["ear_\(own)_02"] = SIMD3((sad ? 0.04 : 0.05) * s * tip, 0, 0)
        case .browsSoft:
            out.weights["brows_up"] = 0.16 * s * LifeCurve.bump(age, rise: 0.18, hold: 0.2, fall: 0.42)
            let bob = -0.05 * s * LifeCurve.bump(age - 0.1, rise: 0.25, hold: 0.12, fall: 0.4)
            out.angles["ear_\(own)_02"] = SIMD3(bob, 0, 0); out.angles["ear_\(other)_02"] = SIMD3(bob * 0.8, 0, 0)
        case .innerBrow:
            let k = LifeCurve.bump(age, rise: 0.25, hold: 0.25, fall: 0.45)
            out.weights["brows_concern"] = 0.2 * s * k; out.weights["lid_sad"] = 0.12 * s * k
            let sink = 0.06 * s * LifeCurve.bump(age - 0.1, rise: 0.28, hold: 0.2, fall: 0.4)
            out.angles["ear_\(own)_02"] = SIMD3(sink, 0, 0); out.angles["ear_\(other)_02"] = SIMD3(sink * 0.7, 0, 0)
        case .cheekSqueeze:
            let k = LifeCurve.bump(age, rise: 0.18, hold: 0.24, fall: 0.44)
            out.weights["cheeks_raise"] = 0.22 * s * k; out.weights["smile"] = 0.12 * s * k; out.weights["blush_more"] = 0.15 * s * k
            out.weights[mood == .happy ? "eyes_happy" : "lid_smile_lower"] = (mood == .happy ? 0.08 : 0.18) * s * k
        case .eyeCrack:
            let k = LifeCurve.bump(age, rise: 0.32, hold: 0.32, fall: 0.48)
            out.weights["blink_\(own)"] = -0.2 * s * k; out.weights["blink_\(other)"] = -0.1 * s * k
        case .dreamTwitch:
            out.weights["nose_twitch"] = 0.24 * s * LifeCurve.twitch(age, start: 0.05, length: 0.24)
            out.angles["ear_\(own)_01"] = SIMD3(0, 0, side * 0.06 * s * LifeCurve.wobble(age - 0.18, hertz: 2.2, decay: 0.18, end: 0.62))
        case .earAnswer:
            // The ear dips and its tip lags; the other ear answers a quarter second later, smaller.
            out.angles["ear_\(own)_01"] = SIMD3(0.06 * s * LifeCurve.bump(age, rise: 0.22, hold: 0.1, fall: 0.36), 0, 0)
            out.angles["ear_\(own)_02"] = SIMD3(0.04 * s * LifeCurve.bump(age - 0.07, rise: 0.22, hold: 0.08, fall: 0.36), 0, 0)
            out.angles["ear_\(other)_01"] = SIMD3(0.04 * s * LifeCurve.bump(age - 0.26, rise: 0.2, hold: 0.06, fall: 0.4), 0, 0)
            out.angles["ear_\(other)_02"] = SIMD3(0.03 * s * LifeCurve.bump(age - 0.32, rise: 0.2, hold: 0.04, fall: 0.38), 0, 0)
        case .sniff:
            // Sniff, sniff, sniff: each a little softer, the whisker pads lifting with the nose, the head bobbing with it.
            let sniffs = LifeCurve.twitch(age, start: 0.10, length: 0.13) + 0.85 * LifeCurve.twitch(age, start: 0.30, length: 0.13)
                + 0.7 * LifeCurve.twitch(age, start: 0.50, length: 0.13)
            let interest = LifeCurve.bump(age, rise: 0.15, hold: 0.45, fall: 0.35)
            let perk = LifeCurve.bump(age - 0.05, rise: 0.2, hold: 0.4, fall: 0.3)
            out.weights["nose_twitch"] = min(0.85, 0.8 * s) * sniffs; out.weights["cheeks_raise"] = 0.18 * s * sniffs
            out.weights["eyes_wide"] = 0.2 * s * interest; out.weights["brows_up"] = 0.15 * s * interest
            out.angles["head"] = SIMD3(-0.06 * s * interest - 0.015 * s * sniffs, 0, 0)
            out.angles["ear_L_01"] = SIMD3(-0.08 * s * perk, 0, 0); out.angles["ear_R_01"] = SIMD3(-0.08 * s * perk, 0, 0)
        case .sway, .rock, .breathSwell:
            break  // on the layer (LayerLean, the breath)
        }
        return out
    }
}

extension LifeMove.Kind {
    var onLayer: Bool { self == .sway || self == .rock || self == .breathSwell }
}

/// The layer moves' lean: radians the image turns about Moku's feet (positive: counterclockwise), 0 at both ends and
/// with no speed there. About a degree and a half at most: Moku's ear tips shift a point or two, slowly.
enum LayerLean {
    static func seconds(_ kind: LifeMove.Kind) -> Double { kind == .rock ? 3.0 : 2.2 }
    static func angle(_ kind: LifeMove.Kind, side: Float, strength: Float, at age: Double) -> Float {
        switch kind {
        case .sway:
            return side * 0.024 * strength * LifeCurve.bump(age, rise: 0.95, hold: 0.25, fall: 1.0)
        case .rock:
            // To one side, through home to the other (a touch less), and home, pausing at each side.
            guard age > 0, age < 3.0 else { return 0 }
            let a = 0.017 * strength * side
            if age < 0.8 { return a * Float(LifeCurve.smooth(age / 0.8)) }
            if age < 2.0 { return a + (-0.8 * a - a) * Float(LifeCurve.smooth((age - 0.8) / 1.2)) }
            return -0.8 * a * (1 - Float(LifeCurve.smooth((age - 2.0) / 1.0)))
        default:
            return 0
        }
    }
    /// The layer's shift that keeps the feet planted while it turns `angle` about its centre: the feet are `feet`
    /// points above the centre (negative: below).
    static func pivot(angle: Float, feet: Float) -> SIMD2<Float> { SIMD2(feet * sin(angle), feet * (1 - cos(angle))) }
}


extension LifeMove.Kind {
    /// Whether a character can play this move: the morphs it's built on move something there, and the joints exist.
    /// Every companion shares the names, but not every one moves every morph.
    func playable(shapes: Set<String>, joints: Set<String>) -> Bool {
        let ears = joints.isSuperset(of: ["ear_L_01", "ear_L_02", "ear_R_01", "ear_R_02"])
        switch self {
        case .noseWiggle, .sniff: return shapes.contains("nose_twitch")
        case .browEar, .earBrow: return ears && shapes.isSuperset(of: ["brow_raise_L", "brow_raise_R"])
        case .earPerk: return ears
        case .browsSoft: return shapes.contains("brows_up")
        case .innerBrow: return shapes.contains("brows_concern")
        case .cheekSqueeze: return shapes.contains("cheeks_raise")
        case .eyeCrack: return shapes.isSuperset(of: ["blink_L", "blink_R"])
        case .dreamTwitch: return shapes.contains("nose_twitch") || ears
        case .earAnswer: return ears
        case .sway, .rock, .breathSwell: return true  // the whole image: any character
        }
    }
}

/// When the next little move comes and which: per mood, a weighted vocabulary, a floor between moves and a mean,
/// never the same kind twice running.
struct LifeRhythm {
    private(set) var nextAt: Double
    private(set) var last: LifeMove.Kind?
    init(now: Double) { nextAt = now + 3 }
    static func vocabulary(for mood: Mood) -> [(LifeMove.Kind, Double)] {
        switch mood {
        case .content: [(.noseWiggle, 3), (.browEar, 2), (.earBrow, 2), (.earPerk, 2)]
        case .happy: [(.noseWiggle, 1), (.cheekSqueeze, 2), (.browsSoft, 1), (.earPerk, 1), (.earAnswer, 2)]
        case .proud: [(.cheekSqueeze, 2), (.browsSoft, 1), (.earPerk, 1), (.earAnswer, 1)]
        case .curious: [(.noseWiggle, 4), (.browEar, 3), (.earPerk, 3)]
        case .concerned: [(.innerBrow, 3), (.earPerk, 1), (.noseWiggle, 1)]
        case .disappointed: [(.innerBrow, 1), (.earPerk, 2)]
        case .annoyed: [(.noseWiggle, 2), (.earPerk, 2)]
        case .sleepy: [(.dreamTwitch, 3), (.eyeCrack, 1)]
        }
    }
    /// Seconds between moves: the floor, and the mean.
    static func pace(for mood: Mood) -> (floor: Double, mean: Double) {
        switch mood {
        case .curious: (4, 10)
        case .content: (6, 16)
        case .happy, .proud: (8, 22)
        case .concerned, .annoyed: (10, 26)
        // The drift's sadness, the longest of them: slower, to stay within the energy budget (moves were its only
        // added frames; on the GPU face it measured +16% CPU at (10, 28)).
        case .disappointed: (16, 44)
        case .sleepy: (9, 22)
        }
    }
    /// The move due now (if any), and when the one after it comes. `playable`: what this character can play. `slowedBy`:
    /// the wait to the next move is that many times longer (Low Power Mode, a hot Mac, long focus: PowerPolicy).
    mutating func next(mood: Mood, now: Double, slowedBy scale: Double = 1, using random: inout LifeRandom, playable: (LifeMove.Kind) -> Bool = { _ in true }) -> LifeMove? {
        guard now >= nextAt else { return nil }
        let pace = Self.pace(for: mood)
        nextAt = now + scale * random.wait(floor: pace.floor, mean: pace.mean, cap: pace.mean * 2.2)
        return pick(from: Self.vocabulary(for: mood), using: &random, playable: playable)
    }
    /// Busy now: try again a little later.
    mutating func postpone(until time: Double) { nextAt = max(nextAt, time) }
    private var beforeLast: LifeMove.Kind?
    /// The last move picked never played (it waited too long): the one before it counts as the last again.
    mutating func dropped(_ kind: LifeMove.Kind) { if last == kind { last = beforeLast } }

    // Beats: happy and proud eyes are closed arcs, so no blinks keep them alive between the face moves above. Little
    // moves on the layer (no frames drawn: they cost nothing) fill the stillness instead, so Moku is never still for
    // more than about 4 s. The face moves keep the mood's own pace.

    /// The layer moves a mood's stillness is filled with (none: its blinks do it).
    static func beats(for mood: Mood) -> [(LifeMove.Kind, Double)] {
        switch mood {
        case .happy, .proud: [(.sway, 2), (.rock, 1), (.breathSwell, 3)]
        default: []
        }
    }
    /// How long Moku is still before a beat (seconds, after the last thing that moved): a floor, a mean and a cap.
    /// (A deeper breath may then wait up to 1.2 s more for the bottom of a breath.)
    static let beatWait = (floor: 1.2, mean: 2.3, cap: 3.4)
    /// The stillness the next beat waits for (seeded, uneven).
    private(set) var beatStill = 2.3
    /// A beat, once Moku has been still `beatStill` seconds (`stillFor`); nil when none is due, or the mood has none.
    mutating func beat(mood: Mood, stillFor: Double, using random: inout LifeRandom, playable: (LifeMove.Kind) -> Bool = { _ in true }) -> LifeMove? {
        let beats = Self.beats(for: mood)
        guard !beats.isEmpty, stillFor >= beatStill else { return nil }
        guard let move = pick(from: beats, using: &random, playable: playable) else { return nil }
        beatStill = random.wait(floor: Self.beatWait.floor, mean: Self.beatWait.mean, cap: Self.beatWait.cap)
        return move
    }
    /// Never the same kind twice running, face moves and beats alike.
    private mutating func pick(from vocabulary: [(LifeMove.Kind, Double)], using random: inout LifeRandom, playable: (LifeMove.Kind) -> Bool) -> LifeMove? {
        let options = vocabulary.filter { $0.0 != last && playable($0.0) }
        guard let kind = random.pick(options) else { return nil }
        beforeLast = last; last = kind
        return LifeMove(kind: kind, side: random.chance(0.5) ? 1 : -1, strength: Float(random.range(0.75...1.1)))
    }
}

/// Reading: the eyes hop along a line in small quick darts (two frames at 30 fps), then sweep back to the start of the
/// next line, a touch lower, and rest. Radians added to the eyes' turn (yaw to your right, pitch up).
struct ReadingEyes: Equatable {
    private(set) var from = SIMD2<Float>.zero, to = SIMD2<Float>.zero, at = -100.0, seconds = 0.1
    private var dartsLeft = 0
    /// A dart starts on the first frame drawn for it (the clock starts there, a sixtieth in), however late that frame
    /// comes, so its first frame never carries most of it.
    private(set) var armed = false
    mutating func begin(at now: Double) { guard armed else { return }; armed = false; at = now - 1.0 / 60 }
    func offset(at now: Double) -> SIMD2<Float> {
        if armed { return from }
        let u = (now - at) / seconds
        if u >= 1 { return to }
        if u <= 0 { return from }
        let e = Float(u * u * (3 - 2 * u))  // a saccade's speed rises and falls: no frame carries it all
        return from + (to - from) * e
    }
    var target: SIMD2<Float> { to }
    func moving(at now: Double) -> Bool { armed || now - at < seconds }
    /// Sets up the next dart (it starts on the next frame drawn); returns how long the eyes rest before the one after.
    mutating func dart(now: Double, using random: inout LifeRandom) -> Double {
        from = offset(at: now); at = now; armed = true
        if dartsLeft > 0 {
            dartsLeft -= 1
            to = SIMD2(from.x + Float(random.range(0.035...0.05)), from.y + Float(random.range(-0.008...0.008)))
            seconds = Self.seconds(from: from, to: to)
            return random.range(0.3...0.6)
        }
        // The sweep back to where the next line starts (a touch lower, back up after a few lines); darts follow.
        let y = from.y < -0.03 ? Float(0.012) : from.y - 0.012
        to = SIMD2(-0.06, y); seconds = Self.seconds(from: from, to: to)
        dartsLeft = Int(random.range(2...3.99))
        return random.range(0.3...0.5)
    }
    /// A line is read: the next dart is the sweep to a new one (when, the caller decides).
    var atLineEnd: Bool { dartsLeft == 0 }
    /// Long enough that no 30 fps frame turns the eyes more than about 1.1°, well under what the snap checks flag (a
    /// dart is four frames; the sweep back, longer, about a third of a second).
    static func seconds(from: SIMD2<Float>, to: SIMD2<Float>) -> Double { max(0.12, Double(simd_length(to - from)) * 2.6) }
    /// Held at `offset` (look development).
    static func fixed(_ offset: SIMD2<Float>) -> ReadingEyes { var eyes = ReadingEyes(); eyes.from = offset; eyes.to = offset; return eyes }
    /// Back to the middle (reading stopped, or the gaze moved on), over `seconds`.
    mutating func settle(now: Double, over duration: Double = 0.3) {
        guard to != .zero || from != .zero else { return }
        from = offset(at: now); to = .zero; at = now; seconds = duration; dartsLeft = 0; armed = false
    }
}

/// When the little moves come: an ear flick, and a paw, a foot, the head or the body. Each on its own clock (`every`,
/// varied by a third), but never on top of a bigger moment (the minute's look-up and smile, a gesture, a line, a hover):
/// the ear comes about 20 s after one and the paw or foot about 40 s after, and the two are at least 12 s apart. So a
/// minute of focus reads smile, ear, foot, smile instead of everything at once (Charles, 2026-10-06: "the ear shake, leg
/// shake etc come along with the one minute see me and smile part, make sure its midway like into 20-40-60 seconds").
struct LittleMoveSchedule: Equatable {
    static let earAfterMoment = 20.0, moveAfterMoment = 40.0, apart = 12.0
    /// Each little move waits at least this long for its next turn, so the ear doesn't come again at 40 s, on the paw's
    /// beat: the minute's next smile sets both again.
    static let turn = 40.0
    var nextEar: Double, nextMove: Double
    /// A bigger moment is on now (called every tick while it lasts): the little moves wait for its end, then 20 and 40 s.
    mutating func moment(at now: Double, jitter: Double = 1) {
        nextEar = max(nextEar, now + Self.earAfterMoment * jitter)
        nextMove = max(nextMove, now + Self.moveAfterMoment * jitter)
    }
    /// The ear flicked: its next in about `every`, and the paw or foot not within `apart` of it.
    mutating func earDone(at now: Double, every: Double, jitter: Double) {
        nextEar = now + max(every * jitter, Self.turn)
        nextMove = max(nextMove, now + Self.apart)
    }
    mutating func moveDone(at now: Double, every: Double, jitter: Double) {
        nextMove = now + max(every * jitter, Self.turn)
        nextEar = max(nextEar, now + Self.apart)
    }
}

