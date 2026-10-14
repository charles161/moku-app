import CoreGraphics
import Foundation
import MokuKit
import Testing
@testable import MokuMind

@Suite("v1: the lantern (WorkState)")
struct LanternTests {
    @Test func theLanternClimbsTheTiersAndRelightsOnReturn() {
        var h = EngineHarness()
        h.work(600)
        h.drift(1_000)
        let start = 600.0
        #expect(h.times { $0 == .character(.setWorkState(.focused)) } == [0])
        #expect(h.times { $0 == .character(.setWorkState(.grace)) } == [start])
        #expect(h.times { $0 == .character(.setWorkState(.noticing)) } == [start + 10])
        #expect(h.times { $0 == .character(.setWorkState(.concerned)) } == [start + 120])
        #expect(h.times { $0 == .character(.setWorkState(.drifting)) } == [start + 240])
        #expect(h.times { $0 == .character(.setWorkState(.longDrift)) } == [start + 600])
        let back = h.send(.verdict(h.verdict(.working)))
        #expect(back.workStates == [.focused])
    }

    @Test func awayAndTeaBreaksHaveTheirOwnLight() {
        var h = EngineHarness()
        h.work(60)
        #expect(h.send(.verdict(h.verdict(.away))).workStates == [.away])
        #expect(h.send(.verdict(h.verdict(.working))).workStates == [.focused])
        #expect(h.send(.startBreak).workStates == [.onBreak])
    }

    @Test func withoutFreshEvidenceTheLanternIsIdleNotLit() {
        var h = EngineHarness()
        h.send(.verdict(h.verdict(.working)))
        h.pass(120)  // the brain went quiet
        #expect(h.times { $0 == .character(.setWorkState(.idle)) } == [61])
        #expect(h.send(.verdict(h.verdict(.working))).workStates == [.focused])
    }

    @Test func aMeetingChangesNoLightAndAfterItTheLanternCatchesUp() {
        var h = EngineHarness()
        h.work(60)
        let meeting = h.send(.meeting(Fixtures.inCall)) + h.pass(600, judging: .drifting)
        #expect(meeting.workStates.isEmpty)
        #expect((h.send(.meeting(.none)) + h.pass(BehaviorEngine.meetingHoldSec, judging: .meeting)).workStates == [.idle])
    }
}

@Suite("v1: holding the place")
struct HoldPlaceTests {
    @Test func duringADriftTheEyesGoToTheWorkNeverTheDistraction() {
        var h = EngineHarness()
        h.work(600)
        h.send(.attention(Fixtures.cursor))
        h.work(30)
        h.drift(320, cursor: Fixtures.otherWindowCursor)
        // One look at the user as the face turns sad, then the place the work was.
        #expect(h.effects(from: 630, to: 630 + 320).gazes == [.user, .point(Fixtures.cursor)])
        #expect(!h.allEffects.gazes.contains(.point(Fixtures.otherWindowCursor)))
    }

    @Test func theEyesFollowTheWorkAgainAfterTheReturn() {
        var h = EngineHarness()
        h.send(.attention(Fixtures.cursor))
        h.work(600)
        h.drift(90, cursor: Fixtures.otherWindowCursor)
        h.send(.verdict(h.verdict(.working)))
        let work = h.pass(10, judging: .working, cursor: CGPoint(x: 700, y: 400))
        #expect(work.gazes.contains(.point(CGPoint(x: 700, y: 400))))
    }
}

@Suite("v1: returns are light and body")
struct ReturnSizeTests {
    @Test(arguments: [(5.0, nil), (30, .small), (200, .small), (250, .full), (800, .full)] as [(Double, ReturnSize?)])
    func theReturnIsSizedByHowFarTheDriftWent(driftSec: Double, size: ReturnSize?) {
        var h = EngineHarness()
        h.work(600)
        h.drift(driftSec)
        let back = h.send(.verdict(h.verdict(.working)))
        #expect(back.returns == (size.map { [$0] } ?? []))
        #expect(back.lines.isEmpty)  // light and body only, even after a long drift (the friends, 2026-10-14)
        #expect(back.events(.returned).count == (size == nil ? 0 : 1))
    }
}

@Suite("v1: tea break")
struct TeaBreakTests {
    @Test func aTeaBreakIsNotDriftAndNotGrowth() {
        var h = EngineHarness()
        h.work(600)
        let start = h.send(.startBreak)
        #expect(start.eventTypes == [.breakStarted])
        #expect(start.contains(.setOnBreak(true)))
        #expect(start.workStates == [.onBreak])
        let tea = h.pass(900, judging: .drifting)
        #expect(tea.events(.focusGrowth).isEmpty)
        #expect(tea.gestures.isEmpty)
        #expect(tea.lines.isEmpty)
        #expect(h.status.phase == .onBreak)
    }

    @Test func workOnAnUnattendedScreenDoesNotEndTheBreak() {
        var h = EngineHarness()
        h.work(600)
        h.send(.attention(Fixtures.cursor))  // the click on "Taking a break"
        h.send(.startBreak)
        h.pass(300, judging: .working)       // Xcode still on screen, nobody there
        #expect(h.status.phase == .onBreak)
    }

    @Test func comingBackToWorkEndsTheBreakAsAReturnWithoutABonus() {
        var h = EngineHarness()
        h.work(600)
        h.send(.startBreak)
        h.pass(300)
        h.send(.attention(Fixtures.cursor))  // back at the desk
        let back = h.send(.verdict(h.verdict(.working)))
        #expect(back.notableEventTypes == [.breakEnded, .returned])
        #expect(back.events(.breakEnded).first?.value == 300)
        #expect(back.events(.returnGrowth).isEmpty)
        #expect(back.contains(.setOnBreak(false)))
        #expect(back.returns == [.small])
        #expect(h.status.phase == .focused)
    }

    @Test func theBreakButtonTogglesBackToWork() {
        var h = EngineHarness()
        h.work(60)
        h.send(.startBreak)
        h.pass(120)
        let back = h.send(.endBreak)
        #expect(back.notableEventTypes == [.breakEnded, .returned])
        #expect(back.contains(.setOnBreak(false)))
        #expect(h.send(.endBreak).isEmpty)  // not on a break any more
    }

    @Test func afterTheLongestBreakTheLadderStartsFromZero() {
        var h = EngineHarness()
        h.work(600)
        h.send(.startBreak)
        let tea = h.pass(1_200, judging: .drifting)
        #expect(tea.notableEventTypes == [.breakEnded])
        #expect(tea.contains(.setOnBreak(false)))
        #expect(tea.events(.returned).isEmpty)  // nobody came back to work
        let after = h.pass(90, judging: .drifting)
        #expect(after.workStates.first == .grace)
        #expect(h.status.driftSec ?? 0 <= 90)
    }

    @Test func aBreakEndsAnEscalatedDriftWithoutJudgment() {
        var h = EngineHarness()
        h.work(600)
        h.drift(610)  // standing, asked to focus
        let tea = h.send(.startBreak)
        #expect(tea.moves.isEmpty)
        #expect(tea.gestures.contains(.sitDown))
        #expect(!tea.eventTypes.contains(.returned))
        #expect(tea.feedback.isEmpty)
    }

    @Test func aPatDuringABreakIsJustAPat() {
        var h = EngineHarness()
        h.work(60)
        h.send(.startBreak)
        let pat = h.send(.pat)
        #expect(pat.gestures == [.patReaction])
        #expect(h.status.phase == .onBreak)
    }
}

@Suite("v1: completions")
struct CompletionTests {
    static let push = Completion(kind: .codePushed, label: "pushed auth-flow")

    func verdict(_ h: inout EngineHarness, completion: Completion?) -> Verdict {
        var verdict = h.verdict(.working)
        verdict.completion = completion
        return verdict
    }

    @Test func aCompletionIsLoggedAtOnceAndCelebratedWhenTheTypingStops() {
        var h = EngineHarness()
        h.work(60)
        let finished = h.send(.verdict(verdict(&h, completion: Self.push)))
        #expect(finished.eventTypes == [.completed])
        // Still typing: no celebration.
        let typing = h.pass(30, judging: .working, cursor: Fixtures.cursor)
        #expect(!typing.gestures.contains(.celebrate))
        // Five still seconds, then the celebration: the body alone, no line, no thinking bubble, and Luna isn't asked
        // (the friends, 2026-10-14: no words over its head).
        let still = h.pass(6, judging: .working)
        #expect(h.times { $0.isGesture(.celebrate) } == [60.0 + 30 + 5])
        #expect(still.moods.contains(.happy))
        #expect(still.voiceRequests.isEmpty)
        #expect(!still.commands.contains(.think))
        #expect((still + h.pass(10, judging: .working)).lines.isEmpty)  // nor a built-in line later
    }

    @Test func theSameCompletionIsCelebratedOnce() {
        var h = EngineHarness()
        h.work(60)
        h.send(.verdict(verdict(&h, completion: Self.push)))
        h.pass(3)
        h.send(.verdict(verdict(&h, completion: Self.push)))
        h.pass(20)
        #expect(h.allEffects.events(.completed).count == 1)
        #expect(h.allEffects.gestures.filter { $0 == .celebrate }.count == 1)
    }

    @Test func aCompletionDuringADriftWaitsForTheReturn() {
        var h = EngineHarness()
        h.work(60)
        var drifting = h.verdict(.drifting)
        drifting.completion = Completion(kind: .messageSent, label: "offer sent")
        h.send(.verdict(drifting))
        let drift = h.pass(90, judging: .drifting)
        #expect(!drift.gestures.contains(.celebrate))
        let back = h.send(.verdict(h.verdict(.working)))
        #expect(back.gestures == [.celebrate])
        #expect(back.voiceRequests.isEmpty)  // no line to fetch (the friends, 2026-10-14)
        #expect((back + h.pass(10, judging: .working)).lines.isEmpty)
    }
}

@MainActor
@Suite("v1: Today, corrections and the break button in the runtime")
struct V1RuntimeTests {
    @Test func todayComesFromTheBrain() async {
        let rig = Rig()
        rig.runtime.start()
        let today = await rig.world.todayProvider?(nil)
        #expect(today?.returns == 6)
        let tuesday = Date(timeIntervalSince1970: 1_790_100_000)
        _ = await rig.world.todayProvider?(tuesday)
        #expect(await rig.brain.todayDates.last == tuesday)  // a chosen day goes to the brain
        #expect(await rig.world.daysProvider?(tuesday, tuesday)?.days.map(\.focusedMinutes) == [40, 94])
        await rig.brain.set(down: true)
        #expect(await rig.world.todayProvider?(nil) == nil)
        #expect(await rig.world.daysProvider?(tuesday, tuesday) == nil)
        rig.finish()
    }

    @Test func aCorrectionGoesToTheBrainAndTheWorldIsRefreshed() async {
        let rig = Rig()
        rig.runtime.start()
        await rig.runtime.drain()
        let fetches = await rig.brain.worldFetches
        rig.world.onCorrection?(["seg-1", "seg-2"], false)
        await rig.runtime.drain()
        let sent = await rig.brain.feedback
        #expect(sent.map(\.kind) == [.markedNotWork])
        #expect(sent.first?.segmentIds == ["seg-1", "seg-2"])
        #expect(await rig.brain.worldFetches == fetches + 1)
        rig.finish()
    }

    @Test func theBreakButtonStartsAndEndsATeaBreak() async {
        let rig = Rig()
        rig.runtime.start()
        await rig.runtime.drain()
        rig.world.onTakeBreak?()
        #expect(rig.runtime.status.phase == .onBreak)
        #expect(rig.world.onBreak == [true])
        #expect(rig.stage.workStates == [.onBreak])
        rig.manualClock.set(240)
        rig.world.onTakeBreak?()
        await rig.runtime.drain()
        #expect(rig.world.onBreak == [true, false])
        #expect(await rig.brain.events.map(\.type) == [.breakStarted, .breakEnded, .returned])
        #expect(rig.stage.calls.contains(.celebrateReturn(.small)))
        rig.finish()
    }

    @Test func underManualControlTheBreakAndCorrectionCallbacksDoNothing() async {
        let rig = Rig()
        rig.runtime.start()
        await rig.runtime.drain()
        rig.runtime.setManualControl(true)
        rig.world.onTakeBreak?()
        rig.world.onCorrection?(["seg-1"], true)
        await rig.runtime.drain()
        #expect(rig.world.onBreak.isEmpty)
        #expect(await rig.brain.feedback.isEmpty)
        #expect(await rig.brain.events.isEmpty)
        rig.finish()
    }
}
