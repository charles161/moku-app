import Foundation
import simd
import Testing
@testable import MokuVisual
import MokuKit

/// The life between the big moments (ExpressionLife.swift): every move leaves and lands at rest with no jump, the
/// rhythm is seeded and never a fixed beat, and lids only change inside a blink.

@Test func everyLifeMoveStartsAndEndsAtRestWithoutAJump() {
    for mood in Mood.allCases {
        for kind in LifeMove.Kind.allCases {
            let move = LifeMove(kind: kind, side: 1, strength: 1.1)
            let start = move.sample(at: 0, mood: mood), end = move.sample(at: move.seconds, mood: mood)
            #expect(start.weights.isEmpty && start.angles.isEmpty, "\(kind) at its start")
            #expect(end.weights.isEmpty && end.angles.isEmpty, "\(kind) at its end")
            // Frame to frame at the pace it's drawn (60 fps for quick ones, else 30): small face steps and joint turns all
            // the way through (a snap would be one big one).
            let fps = move.quick ? 60.0 : 30.0
            var previous = move.sample(at: 0, mood: mood)
            for n in 1...Int(move.seconds * fps) + 1 {
                let now = move.sample(at: Double(n) / fps, mood: mood)
                for name in Set(now.weights.keys).union(previous.weights.keys) {
                    // A nose twitch is quick by nature (a tiny region, under a pixel a frame); everything else is gentler.
                    #expect(abs((now.weights[name] ?? 0) - (previous.weights[name] ?? 0)) <= (name == "nose_twitch" ? 0.4 : 0.16), "\(kind) \(name) at frame \(n)")
                }
                for joint in Set(now.angles.keys).union(previous.angles.keys) {
                    let step = simd_length((now.angles[joint] ?? .zero) - (previous.angles[joint] ?? .zero))
                    #expect(step <= 0.025, "\(kind) \(joint) turns \(step) rad at frame \(n)")  // under 1.5°: what the snap checks flag
                }
                previous = now
            }
        }
    }
}

@Test func lifeMovesStayInsideTheAssetsRanges() {
    for kind in LifeMove.Kind.allCases {
        let move = LifeMove(kind: kind, side: -1, strength: 1.1)
        for n in 0...Int(move.seconds * 60) {
            let sample = move.sample(at: Double(n) / 60, mood: .content)
            for (name, value) in sample.weights where name.hasPrefix("brow_raise_") { #expect(value <= 0.5) }
            #expect((sample.weights["nose_twitch"] ?? 0) <= 0.85)
            for angle in sample.angles.values { #expect(simd_length(angle) < 0.12, "\(kind): a few degrees, never a pose") }
        }
    }
    // A brow and the ear that answers it are on the same side; the right side uses only _R controls.
    let right = LifeMove(kind: .browEar, side: -1, strength: 1).sample(at: 0.3, mood: .content)
    #expect(right.weights.keys.allSatisfy { $0.hasSuffix("_R") } && right.angles.keys.allSatisfy { $0.hasPrefix("ear_R_") })
}

@Test func rhythmIsSeededNeverRepeatsAKindAndKeepsItsFloor() {
    for mood in Mood.allCases {
        var a = LifeRandom(seed: 42), b = LifeRandom(seed: 42)
        var rhythmA = LifeRhythm(now: 0), rhythmB = LifeRhythm(now: 0)
        var now = 0.0, kinds: [LifeMove.Kind] = [], gaps: [Double] = []
        for _ in 0..<200 {
            now = rhythmA.nextAt
            let due = rhythmA.nextAt
            guard let move = rhythmA.next(mood: mood, now: now, using: &a), let twin = rhythmB.next(mood: mood, now: now, using: &b) else { Issue.record("no move for \(mood)"); return }
            #expect(move == twin, "the same seed plays the same life")
            #expect(LifeRhythm.vocabulary(for: mood).contains { $0.0 == move.kind })
            if let last = kinds.last, LifeRhythm.vocabulary(for: mood).count > 1 { #expect(last != move.kind, "never the same kind twice running") }
            kinds.append(move.kind); gaps.append(rhythmA.nextAt - due)
        }
        let pace = LifeRhythm.pace(for: mood)
        #expect(gaps.allSatisfy { $0 >= pace.floor && $0 <= pace.mean * 2.2 + 0.0001 }, "a floor, and never held still for long")
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        #expect(abs(mean - pace.mean) < pace.mean * 0.2, "\(mood): about \(pace.mean) s apart on average, not \(mean)")
        #expect(Set(gaps.map { ($0 * 10).rounded() }).count > 50, "uneven: not on a timer")
    }
}

@Test func rhythmWaitsWhenBusy() {
    var rhythm = LifeRhythm(now: 0), random = LifeRandom(seed: 1)
    #expect(rhythm.next(mood: .content, now: 1, using: &random) == nil)
    rhythm.postpone(until: 10)
    #expect(rhythm.next(mood: .content, now: 9.9, using: &random) == nil)
    #expect(rhythm.next(mood: .content, now: 10, using: &random) != nil)
}

@Test func lidsChooseANewSettingForTheMoodAndNoneWhenEyesAreClosed() {
    var random = LifeRandom(seed: 3)
    for mood in [Mood.content, .curious, .concerned, .disappointed, .annoyed] {
        var lids = LidTension()
        for _ in 0..<30 {
            let before = lids.weights
            lids.choose(for: mood, using: &random)
            #expect(lids.weights != before, "a blink that changes the lids changes them")
            #expect(LidTension.choices(for: mood).contains(lids.weights))
            #expect(lids.weights.values.allSatisfy { abs($0) <= 0.35 }, "a touch softer or brighter, never a new expression")
        }
    }
    for mood in [Mood.happy, .proud, .sleepy] { #expect(LidTension.choices(for: mood).isEmpty) }
    var lids = LidTension(weights: ["blink_L": 0.2]); lids.scale(0.5)
    #expect(lids.weights["blink_L"] == 0.1)
}

@Test func breathFollowsTheLayersCurve() {
    let breath = Breath(startedAt: 10, seconds: 4)
    #expect(breath.amount(at: 10) == 0)
    #expect(abs(breath.amount(at: 12) - 1) < 0.0001)
    #expect(abs(breath.amount(at: 14)) < 0.0001)
    #expect(abs(breath.amount(at: 11) - 0.5) < 0.0001)
    // Smooth all the way round, including before it started.
    var previous = breath.amount(at: 5)
    for n in 1...600 {
        let value = breath.amount(at: 5 + Double(n) / 60)
        #expect(abs(value - previous) < 0.02)
        previous = value
    }
    for mood in Mood.allCases { #expect(Breath.depth(for: mood) > 0 && Breath.depth(for: mood) <= 1.6) }
    #expect(Breath.depth(for: .sleepy) > Breath.depth(for: .happy) && Breath.seconds(for: .sleepy) > Breath.seconds(for: .happy))
}

@Test func readingDartsAreSmallQuickAndComeHome() {
    var eyes = ReadingEyes(), random = LifeRandom(seed: 9)
    var now = 0.0
    for _ in 0..<40 {
        let from = eyes.offset(at: now)
        let rest = eyes.dart(now: now, using: &random)
        #expect(eyes.offset(at: now + 0.2) == from, "armed: it waits for its first frame")
        eyes.begin(at: now + 1.0 / 60)
        #expect(rest >= 0.28, "the eyes rest between darts")
        #expect(eyes.seconds <= 0.5, "a dart is four frames, a sweep back a third of a second")
        // No 30 fps frame turns the eyes more than about 1.1°.
        var last = from
        for k in 1...Int(eyes.seconds * 30) + 1 {
            let at = eyes.offset(at: now + Double(k) / 30)
            #expect(simd_length(at - last) <= 0.02); last = at
        }
        #expect(simd_length(eyes.target - from) <= 0.2)
        #expect(abs(eyes.target.x) <= 0.2 && abs(eyes.target.y) <= 0.05, "they stay on the line, near where Moku looks")
        // Lands: quick away, settling in, no overshoot.
        let mid = eyes.offset(at: now + eyes.seconds / 2), end = eyes.offset(at: now + eyes.seconds + 0.001)
        #expect(simd_length(mid - from) <= simd_length(eyes.target - from) + 0.0001)
        #expect(end == eyes.target)
        now += eyes.seconds + rest
    }
    eyes.settle(now: now)
    #expect(eyes.offset(at: now) != .zero || eyes.target == .zero)
    #expect(eyes.offset(at: now + 0.3) == .zero)
}

@Test func lifeRandomIsDeterministicAndWaitsHaveAFloor() {
    var a = LifeRandom(seed: 5), b = LifeRandom(seed: 5)
    #expect((0..<10).map { _ in a.next() } == (0..<10).map { _ in b.next() })
    var r = LifeRandom(seed: 11)
    let waits = (0..<2000).map { _ in r.wait(floor: 2, mean: 6) }
    #expect(waits.allSatisfy { $0 >= 2 })
    #expect(abs(waits.reduce(0, +) / 2000 - 6) < 0.4)
}

@Test func aCompanionPlaysOnlyWhatItsMorphsAndJointsCanDo() {
    let ears: Set<String> = ["ear_L_01", "ear_L_02", "ear_R_01", "ear_R_02"]
    // No nose twitch and no ears (a robot, say): no nose wiggle, no ear moves; brows still work.
    let robot: Set<String> = ["brows_up", "brows_concern", "blink_L", "blink_R", "cheeks_raise"]
    #expect(!LifeMove.Kind.noseWiggle.playable(shapes: robot, joints: []))
    #expect(!LifeMove.Kind.earPerk.playable(shapes: robot, joints: []))
    #expect(LifeMove.Kind.browsSoft.playable(shapes: robot, joints: []))
    #expect(LifeMove.Kind.earPerk.playable(shapes: [], joints: ears))
    var rhythm = LifeRhythm(now: 0), random = LifeRandom(seed: 2)
    for n in 0..<100 {
        guard let move = rhythm.next(mood: .content, now: rhythm.nextAt + Double(n) * 0, using: &random, playable: { $0.playable(shapes: robot, joints: []) }) else { continue }
        #expect(move.kind.playable(shapes: robot, joints: []))
    }
    // Lids: only settings whose shapes move here.
    var lids = LidTension()
    for _ in 0..<20 { lids.choose(for: .annoyed, using: &random, shapes: ["eyes_narrow"]); #expect(lids.weights.keys.allSatisfy { $0 == "eyes_narrow" }) }
}

/// Happy and proud eyes are closed arcs (no blinks): beats on the layer fill their stillness, and cost no frames.
@Test func layerLeansAreTinySmoothAndKeepTheFeetPlanted() {
    for kind in [LifeMove.Kind.sway, .rock] {
        let move = LifeMove(kind: kind, side: -1, strength: 1.1)
        #expect(move.onLayer && !move.touchesFace && !move.usesEars)
        #expect(move.sample(at: move.seconds / 2, mood: .happy).angles.isEmpty, "\(kind): the image turns, no joint")
        #expect(LayerLean.angle(kind, side: -1, strength: 1.1, at: 0) == 0 && LayerLean.angle(kind, side: -1, strength: 1.1, at: move.seconds) == 0)
        var previous: Float = 0, largest: Float = 0
        for n in 1...Int(move.seconds * 60) + 1 {
            let angle = LayerLean.angle(kind, side: -1, strength: 1.1, at: Double(n) / 60)
            // About a twentieth of a degree a display frame at most: the ear tips move a tenth of a point.
            #expect(abs(angle - previous) < 0.001, "\(kind) at frame \(n)")
            largest = max(largest, abs(angle)); previous = angle
        }
        #expect(largest > 0.015 && largest < 0.03, "\(kind): a degree or so (\(largest * 180 / .pi)°)")
    }
    // The shift puts the feet back where they were: turned about the centre, then shifted.
    for angle: Float in [-0.012, 0.004, 0.0115] {
        let feet: Float = -118, shift = LayerLean.pivot(angle: angle, feet: feet)
        let turned = SIMD2(-feet * sin(angle), feet * cos(angle))
        #expect(simd_length(turned + shift - SIMD2(0, feet)) < 0.0001)
    }
}

@Test func beatsFillOnlyClosedEyedMoodsNeverRepeatAndComeWithinAbout4Seconds() {
    for mood in Mood.allCases {
        let closedArcs = mood == .happy || mood == .proud
        #expect(LifeRhythm.beats(for: mood).isEmpty == !closedArcs, "\(mood)")
        #expect(LifeRhythm.beats(for: mood).allSatisfy { $0.0.onLayer }, "beats cost no frames")
        #expect(LifeRhythm.vocabulary(for: mood).allSatisfy { !$0.0.onLayer }, "face moves keep the mood's pace")
    }
    var rhythm = LifeRhythm(now: 0), random = LifeRandom(seed: 8)
    #expect(rhythm.beat(mood: .happy, stillFor: 0.5, using: &random) == nil, "not while Moku has just moved")
    #expect(rhythm.beat(mood: .content, stillFor: 60, using: &random) == nil, "blinks fill content's stillness")
    var kinds: [LifeMove.Kind] = [], waits: [Double] = []
    for n in 0..<300 {
        // Now and then a face move comes between beats: never the same kind twice running across both.
        if n % 7 == 3, let face = rhythm.next(mood: .happy, now: rhythm.nextAt, using: &random) { kinds.append(face.kind); continue }
        let still = rhythm.beatStill
        waits.append(still)
        #expect(rhythm.beat(mood: .happy, stillFor: still - 0.01, using: &random) == nil)
        guard let beat = rhythm.beat(mood: .happy, stillFor: still, using: &random) else { Issue.record("no beat"); return }
        kinds.append(beat.kind)
    }
    for (a, b) in zip(kinds, kinds.dropFirst()) { #expect(a != b, "never the same kind twice running") }
    #expect(waits.dropFirst().allSatisfy { $0 >= LifeRhythm.beatWait.floor && $0 <= LifeRhythm.beatWait.cap }, "still at most 3.4 s before a beat")
    #expect(Set(waits.map { ($0 * 10).rounded() }).count > 15, "uneven: not on a timer")
    // A beat that never played (a deeper breath that missed its bottom) doesn't count as the last.
    let played = rhythm.beat(mood: .happy, stillFor: 10, using: &random, playable: { $0 != .breathSwell })!
    let missed = rhythm.beat(mood: .happy, stillFor: 10, using: &random, playable: { $0 == .breathSwell })!
    rhythm.dropped(missed.kind)
    for _ in 0..<20 { var copy = rhythm; #expect(copy.beat(mood: .happy, stillFor: 10, using: &random, playable: { $0 != .breathSwell })?.kind != played.kind) }
    // A deeper breath only when the breath is near its bottom (the caller says).
    for _ in 0..<50 { #expect(rhythm.beat(mood: .proud, stillFor: 10, using: &random, playable: { $0 != .breathSwell })?.kind != .breathSwell) }
}

@Test func aDeeperBreathStartsAtTheBottomOfOne() {
    let breath = Breath(startedAt: 10, seconds: 3.2)
    #expect(breath.untilBottom(at: 10) == 0)
    #expect(abs(breath.untilBottom(at: 11) - 2.2) < 1e-9)
    #expect(abs(breath.untilBottom(at: 13.1) - 0.1) < 1e-9)
    #expect(breath.untilBottom(at: 13.2) < 1e-9 || abs(breath.untilBottom(at: 13.2) - 3.2) < 1e-9)
    #expect(breath.amount(at: 10 + 3.2 - 0.0001) < 0.01, "a breath's bottom: the swap shows nothing")
}
