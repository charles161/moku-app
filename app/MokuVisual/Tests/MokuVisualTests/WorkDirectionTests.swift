import Foundation
import Testing
import MokuKit
@testable import MokuVisual

@Test func driftHoldsTheLastWorkPointAndNeverReadsTheDriftWindow() {
    var director = WorkDirection(); director.set(.focused, now: 0)
    let work = CGPoint(x: -900, y: 600), feed = CGPoint(x: 1200, y: 300)
    let acceptedWork = director.receive(point: work)
    #expect(acceptedWork)
    // In a drift a point is still a look at the screen (2026-10-14), but never the work's place.
    director.set(.grace, now: 10)
    _ = director.receive(point: feed)
    #expect(director.workPoint == work)
    director.set(.longDrift, now: 740)
    _ = director.receive(point: feed)
    #expect(director.workPoint == work)
}
@Test func glancesRespectGraceCooldownTierCapsAndPerDriftBudget() {
    var director = WorkDirection(); director.set(.grace, now: 0)
    let early = director.claim(now: 59, busy: false, reduced: false, choice: 0, jitter: 0.8)
    #expect(early == nil)
    director.set(.noticing, now: 60)
    let first = director.claim(now: 60, busy: false, reduced: false, choice: 0, jitter: 0.8)
    #expect(first != nil)
    let repeated = director.claim(now: 119, busy: false, reduced: false, choice: 0, jitter: 0.8)
    #expect(repeated == nil)
    director.set(.concerned, now: 120); director.pause(now: 120)
    let blocked = director.claim(now: 127.99, busy: false, reduced: false, choice: 0, jitter: 1)
    #expect(blocked == nil)
    let afterCooldown = director.claim(now: 128, busy: false, reduced: false, choice: 0, jitter: 1)
    #expect(afterCooldown != nil && afterCooldown != first)
    for i in 1...20 { _ = director.claim(now: 128 + Double(i)*100, busy: false, reduced: false, choice: i, jitter: 1) }
    #expect(director.glanceCount == 8)
    director.set(.focused, now: 3000)
    #expect(director.glanceCount == 0 && director.nextGlanceAt == .infinity)
}
@Test func reducedMotionOnlyUsesBrowAndBlinkAndAllLanternStatesStayLit() {
    var director = WorkDirection(); director.set(.longDrift, now: 0)
    #expect(Set(director.pool(reduced: true)) == Set([.brow, .slowBlink]))
    for state in WorkState.allCases {
        let phase = LanternPhase.forState(state)
        #expect(phase.brightness >= 0.15 && phase.poolOpacity >= 0.03)
    }
    #expect(!LanternPhase.forState(.concerned).breath)
    #expect(LanternPhase.forState(.longDrift).gutter)
}
@Test func moodTransitionsAreContinuousMonotonicAndEaseAtBothEnds() {
    for duration in [0.6, 1.5, 2.4, 3.0, 4.0] {
        let values = (0...100).map { MoodTiming.progress(age: Double($0) * duration / 100, duration: duration) }
        #expect(values.first == 0 && values.last == 1)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(values[1] < 0.001 && values[99] > 0.999)
        #expect(abs(values[50] - 0.5) < 0.001)
        // Retargeting takes the currently displayed value as its start.
        let interrupted = 0.8 * MoodTiming.progress(age: 0.7, duration: duration)
        #expect(interrupted + (0.2 - interrupted) * MoodTiming.progress(age: 0, duration: duration) == interrupted)
    }
}

@Test func eyesLeadASlowMonotonicHeadSpringWithoutOvershoot() {
    #expect(GazeTiming.eyes(0) == 0 && GazeTiming.eyes(0.5) == 1)
    #expect(GazeTiming.eyes(0.25) == 0.5)
    #expect(GazeTiming.head(0.15, reduced: false) == 0)
    for reduced in [false, true] {
        let values = stride(from: 0.0, through: GazeTiming.duration, by: 0.01).map { GazeTiming.head($0, reduced: reduced) }
        #expect(values.allSatisfy { (0...1).contains($0) })
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(GazeTiming.head(0.5, reduced: reduced) < GazeTiming.eyes(0.5))
        #expect(GazeTiming.head(GazeTiming.duration, reduced: reduced) == 1)
    }
}
@Test func workAndReturnRecordingRetainsItsValue() {
    let steps = [ManualStep(action: .workState(.longDrift)), ManualStep(action: .returnBeat(.full))]
    #expect(steps.map(\.action) == [.workState(.longDrift), .returnBeat(.full)])
}

@MainActor @Test func gracePreservesLanternPhaseWhenReduceMotionChanges() {
    let lantern = LanternLayer()
    lantern.apply(.idle, reduced: false, instant: true)
    lantern.apply(.grace, reduced: false)
    #expect(lantern.phase.brightness == 0.15 && !lantern.phase.breath)
    lantern.apply(.grace, reduced: true)
    #expect(lantern.phase.brightness == 0.15 && !lantern.phase.breath)
}

@Test func oneSecondGraceReactsAtTheFirstTierDespiteAnOldCooldown() {
    var director = WorkDirection(); director.set(.focused, now: 0)
    director.pause(now: 0)
    director.set(.grace, now: 0)
    #expect(director.claim(now: 0.99, busy: false, reduced: false, choice: 0, jitter: 1) == nil)
    director.set(.noticing, now: 1)
    #expect(director.claim(now: 1, busy: false, reduced: false, choice: 0, jitter: 1) != nil)
    #expect(director.glanceCount == 1)
    #expect(director.claim(now: 1.01, busy: false, reduced: false, choice: 0, jitter: 1) == nil)
    director.set(.concerned, now: 2)
    #expect(director.claim(now: 2, busy: false, reduced: false, choice: 0, jitter: 1) == nil)
    #expect(director.claim(now: 61, busy: false, reduced: false, choice: 0, jitter: 1) != nil)
}

@Test func driftExpressionsNeverTakeTheEyesOffTheUser() {
    // Charles: when you drift it should "just look at me". The glances that move the gaze or head stay out.
    let lookAway: Set<MicroExpression> = [.gazePoint, .lookDown, .sideGlance]
    for state in [WorkState.noticing, .concerned, .drifting, .longDrift] {
        var director = WorkDirection()
        director.set(state, now: 0)
        #expect(Set(director.pool(reduced: false)).isDisjoint(with: lookAway), "\(state)")
        #expect(!director.pool(reduced: false).isEmpty)
    }
}
@Test func theSmileRisesHoldsAndFallsWithoutAStep() {
    // 60 fps through the whole gesture: every frame moves only a little, and it starts and ends at rest.
    var previous: Float = 0, biggest: Float = 0
    for frame in 0...Int(SmileTiming.length * 60) + 6 {
        let amount = SmileTiming.amount(age: Double(frame) / 60)
        biggest = max(biggest, abs(amount - previous)); previous = amount
    }
    #expect(biggest < 0.09)
    #expect(SmileTiming.amount(age: SmileTiming.rise + 0.5) == 1)
    #expect(SmileTiming.amount(age: SmileTiming.length + 0.01) == 0)
}
@Test func anEaseChangingItsMindMidWayNeverJumps() {
    var ease = Ease()
    ease.go(to: 1, at: 0, over: 0.6, after: 0.15)
    #expect(ease.value(at: 0.1) == 0)                   // still waiting out the delay
    let midway = ease.value(at: 0.45)
    ease.go(to: 0, at: 0.45, over: 0.6)                 // turned away before the smile finished
    #expect(abs(ease.value(at: 0.45) - midway) < 1e-6)  // picks up from where it was
    #expect(ease.value(at: 1.2) == 0)
}
@Test func anEarFlickIsSmallQuickAndLandsAtRest() {
    let frames = (0...Int(EarFlick.seconds * 60) + 3).map { EarFlick.angle(age: Double($0) / 60) }
    let peak = frames.map { abs($0) }.max()! * 180 / .pi
    #expect(peak > 5 && peak < 10)                                   // subtle: under 10°
    let steps = zip(frames, frames.dropFirst()).map { abs($1 - $0) * 180 / .pi }
    #expect(steps.max()! < 3)                                        // no frame jumps
    #expect(EarFlick.angle(age: EarFlick.seconds) == 0 && abs(frames[frames.count - 8]) < 0.002)
}

@Test func theCupGrowsIntoThePawsAndShrinksAwayButALoopedPropStaysFull() {
    #expect(PropAttachment.growScale(0.06, from: 0.06, to: 0.9) == 0)
    #expect(PropAttachment.growScale(0.0725, from: 0.06, to: 0.9) == 0.5)
    #expect(PropAttachment.growScale(0.5, from: 0.06, to: 0.9) == 1)
    #expect(PropAttachment.growScale(0.9, from: 0.06, to: 0.9) == 0)
    #expect(PropAttachment.growScale(0.0, from: 0, to: 1) == 1)   // the lantern, hammer and tea hold for their whole clip
    #expect(PropAttachment.growScale(1.0, from: 0, to: 1) == 1)
}

@Test func everyLittleMovementEasesOutAndBackWithoutAStep() {
    for kind in Fidget.Kind.allCases {
        let fidget = Fidget(kind: kind, side: 1)
        #expect(fidget.amount(at: 0) == 0 && fidget.amount(at: fidget.seconds) == 0)
        #expect(fidget.amount(at: fidget.seconds * 0.47) == 1)
        var previous: SIMD3<Float> = .zero, biggest: Float = 0, peak: Float = 0
        for frame in 0...Int(fidget.seconds * 60) + 1 {
            let t = Double(frame) / 60
            let total = ["arm_L", "arm_R", "hand_L", "foot_L", "head", "chest"].reduce(SIMD3<Float>.zero) { $0 + fidget.angles(for: $1, at: t) }
            let step = total - previous, largest = { (v: SIMD3<Float>) in max(abs(v.x), abs(v.y), abs(v.z)) }
            biggest = max(biggest, largest(step))
            peak = max(peak, largest(total))
            previous = total
        }
        #expect(biggest < 0.012)   // never more than about 0.7° from one frame to the next
        #expect(peak <= 0.13)      // a few degrees, never more than about 7°
        #expect(peak > 0.02)       // but enough to see
    }
}

/// A gaze change eases from the first frame drawn after it: an idle renderer's first frame, 125 ms later, carried a
/// quarter of the eyes' turn (12 to 15° in one frame in the motion audit's "settled" beat). With frames running, a change
/// keeps its own time.
@Test func aGazeChangeEasesFromTheFirstFrameDrawn() {
    let start = GazeTiming.easeStart(changedAt: 10, firstFrame: 10.125)
    #expect(GazeTiming.eyes(10.125 - start) < 0.02)
    #expect(GazeTiming.eyes(10.125 - 10) > 0.1)  // what the first frame carried before
    #expect(GazeTiming.easeStart(changedAt: 10, firstFrame: 10.016) == 10)
}
