import Foundation
import Testing
@testable import MokuVisual
import MokuKit

@Test func hoverRequiresBodyDwellAndResetsOnSuppression() {
    var dwell = HoverDwell()
    let result1 = (dwell.update(inside: true, allowed: true, now: 0) == nil)
    #expect(result1)
    let result2 = (dwell.update(inside: true, allowed: true, now: 0.29) == nil)
    #expect(result2)
    let result3 = (dwell.update(inside: true, allowed: true, now: 0.31) == true)
    #expect(result3)
    let result4 = (dwell.update(inside: true, allowed: true, now: 4) == nil)
    #expect(result4)
    let result5 = (dwell.update(inside: true, allowed: false, now: 4.1) == false)
    #expect(result5)
    let result6 = (dwell.update(inside: true, allowed: true, now: 4.2) == nil)
    #expect(result6)
    let result7 = (dwell.update(inside: false, allowed: true, now: 4.4) == nil)
    #expect(result7)
    let result8 = (dwell.update(inside: true, allowed: true, now: 4.5) == nil)
    #expect(result8)
    let result9 = (dwell.update(inside: true, allowed: true, now: 4.81) == true)
    #expect(result9)
}
@Test func microScheduleIsSparseNonoverlappingAndPaused() {
    var schedule = MicroSchedule(); schedule.reset(now: 0, delay: 3)
    let result10 = (!schedule.claim(now: 2.9, allowed: true, expression: .slowBlink, delay: 0))
    #expect(result10)
    let result11 = (!schedule.claim(now: 3, allowed: false, expression: .slowBlink, delay: 3))
    #expect(result11)
    let result12 = (schedule.claim(now: 3.1, allowed: true, expression: .slowBlink, delay: 3))
    #expect(result12)
    let result13 = (!schedule.claim(now: 3.4, allowed: true, expression: .smile, delay: 8))
    #expect(result13)
    let result14 = (!schedule.claim(now: 6, allowed: true, expression: .smile, delay: 8))
    #expect(result14)
    let result15 = (schedule.claim(now: 6.2, allowed: true, expression: .smile, delay: 80))
    #expect(result15)
    #expect(schedule.nextAt == 14.2)
    for expression in MicroExpression.allCases {
    let result16 = (0.2...1.2).contains(expression.duration)
    #expect(result16)
        #expect(expression.strength(at: 0) == 0)
        #expect(expression.strength(at: 1) == 0)
    }
    #expect(MicroExpression.vocabulary(for: .annoyed).contains(.sideGlance))
}
@MainActor @Test func manualCelebrationDoesNotQueueAFutureMoment() {
    let state = ForestPresentation(); state.manualControl = true
    state.queueCelebration(.tree)
    #expect(state.celebration == nil)
    #expect(state.points == 0)
    state.manualControl = false
    #expect(state.celebration == nil)
    state.queueCelebration(.grove)
    #expect(state.celebration == .grove)
}

@MainActor @Test func walkAndGestureWaitForOneSharedUnfold() async throws {
    let gate = ArmUnfoldGate(); gate.foldedPoseBegan()
    var events = [String]()
    let unfold: @MainActor @Sendable () async -> Void = {
        events.append("unfold")
        try? await Task.sleep(for: .milliseconds(40))
        events.append("unfolded")
    }
    let earlier = Task { await gate.unfold(using: unfold); if !Task.isCancelled { events.append("gesture") } }
    try await Task.sleep(for: .milliseconds(5))
    earlier.cancel()
    await gate.unfold(using: unfold); events.append("walk")
    await earlier.value
    #expect(events == ["unfold", "unfolded", "walk"])
    #expect(!gate.folded)
}

@Test func gazeKeepsDistinctDistantTargetsAcrossScreenSizes() {
    let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
    let origin = CGPoint(x: -100, y: 100)
    let near = StageGeometry.gaze(at: CGPoint(x: -500, y: 400), from: origin, in: screen)
    let far = StageGeometry.gaze(at: CGPoint(x: -900, y: 700), from: origin, in: screen)
    #expect(far.x < near.x && far.y > near.y)
    let scaled = StageGeometry.gaze(at: CGPoint(x: -1800, y: 1400), from: CGPoint(x: -200, y: 200), in: CGRect(x: -2880, y: 0, width: 2880, height: 1800))
    #expect(scaled == far)
}

@Test func curiousMicroRaisesTheOtherBrowWithinTheAssetRange() {
    let sample = MicroSample(.brow, progress: 0.5, shapes: ["brow_raise_L", "brow_raise_R"], baseline: ["brow_raise_L": 0.5])
    #expect(sample.weights["brow_raise_L"] == nil)
    #expect(sample.weights["brow_raise_R"] == 0.3)
}
