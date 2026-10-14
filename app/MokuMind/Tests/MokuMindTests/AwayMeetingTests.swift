import Foundation
import MokuKit
import Testing
@testable import MokuMind

@Suite("Away")
struct AwayTests {
    @Test func awayIsNeitherDriftNorGrowth() {
        var h = EngineHarness()
        h.send(.attention(Fixtures.cursor))
        h.work(600)
        let away = h.send(.verdict(h.verdict(.away))) + h.pass(500, judging: .away)
        #expect(away.events(.focusGrowth).isEmpty)
        #expect(away.lines.isEmpty)
        #expect(!away.moods.contains(.concerned))
        #expect(away.gazes == [.wander])
        #expect(h.status.phase == .away)
        #expect(h.status.focusStreakSec == 600)
    }

    @Test func awayFreezesAnOpenDriftWhereItWas() {
        var h = EngineHarness()
        h.work(600)
        h.drift(200)  // past the one sad move (its sigh), 40 s before standing up
        h.send(.verdict(h.verdict(.away)))
        h.pass(400, judging: .away)  // shorter than a long away
        #expect(h.allEffects.gestures == [.nod, .sigh])  // the task's nod as work began, then the sad move
        #expect(h.status.driftSec == 200)
        // Back on the distraction: escalation picks up where it stopped.
        let resumed = h.drift(40)
        #expect(resumed.gestures == [.standUp])
        #expect(h.times { $0.isGesture(.standUp) } == [600.0 + 200 + 400 + 40])
    }

    @Test func aLongAwayMakesMokuSleepyAndComingBackEarnsAWave() {
        var h = EngineHarness()
        h.work(600)
        h.send(.verdict(h.verdict(.away)))
        let longAway = h.pass(600, judging: .away)
        #expect(longAway.moods == [.sleepy])
        #expect(longAway.gestures == [.yawn])
        #expect(longAway.voiceRequests.isEmpty)  // no greeting to fetch: no words over its head (the friends, 2026-10-14)
        #expect(h.times { $0.isMood(.sleepy) } == [1_200])

        let back = h.send(.verdict(h.verdict(.working)))
        #expect(back.moods == [.content])
        #expect(back.gestures == [.wave])
        #expect(back.lines.isEmpty)  // the wave says hello on its own
        #expect(back.notableEventTypes.isEmpty)
        #expect(h.status.phase == .focused)
    }

    @Test func aLongAwayClosesAnOpenDriftWithoutJudgment() {
        var h = EngineHarness()
        h.work(600)
        h.drift(610)  // standing, asked to focus
        h.send(.verdict(h.verdict(.away)))
        let longAway = h.pass(600, judging: .away)
        #expect(longAway.moves.isEmpty)
        #expect(longAway.gestures.contains(.sitDown))
        let back = h.send(.verdict(h.verdict(.working)))
        #expect(back.notableEventTypes.isEmpty)
        #expect(back.feedback.isEmpty)
        #expect(back.gestures == [.wave])  // the long away's hello, not a return
        #expect(back.lines.isEmpty)
    }

    @Test func aNightAsleepMidDriftIsALongAwayNotAReturn() {
        var h = EngineHarness()
        h.work(600)
        h.drift(610)  // standing, red, asked to focus; then the lid closes
        h.wait(8 * 3_600)
        let waking = h.tick()
        #expect(waking.moods == [.sleepy])
        #expect(waking.gestures.contains(.sitDown) && waking.gestures.contains(.yawn))
        #expect(h.status.phase == .away)
        let back = h.send(.verdict(h.verdict(.working)))
        #expect(back.notableEventTypes.isEmpty)  // no return, no stone
        #expect(back.gestures == [.wave])  // a long away's hello, not a return's celebration
        #expect(back.returns.isEmpty)
        #expect(back.lines.isEmpty)
    }

    @Test func aShortSleepIsNotAnAway() {
        var h = EngineHarness()
        h.work(600)
        h.wait(120)
        h.tick()
        #expect(h.status.phase == .focused)
    }

    @Test func aLongAwayResetsTheContinuousWorkTimerForBreaks() {
        var h = EngineHarness()
        h.work(2_400)  // 40 minutes
        h.send(.verdict(h.verdict(.away)))
        h.pass(700, judging: .away)
        h.work(2_400)  // 40 more: 80 in total, but not continuous
        #expect(h.allEffects.events(.breakSuggested).isEmpty)
        h.pass(600, judging: .working)
        #expect(h.allEffects.events(.breakSuggested).count == 1)
    }
}

@Suite("Meetings")
struct MeetingTests {
    @Test func aMeetingHidesMokuAndFreezesEverything() {
        var h = EngineHarness()
        h.work(600)
        h.drift(200)
        let start = h.send(.meeting(Fixtures.inCall))
        #expect(start.commands == [.dismissSpeech, .setHidden(true)])
        // Even drifting verdicts during the call change nothing.
        let during = h.pass(1_800, judging: .drifting)
        #expect(during.isEmpty)
        #expect(h.status.phase == .meeting)
        #expect(h.status.driftSec == 200)
    }

    /// A friend's companion came back for 3 s between two "in a call" states, twice in a call (2ba8, 2026-10-07: hidden
    /// 16:02:13, shown 16:02:16, hidden 16:02:55): the call app let go of the mic for a moment. It stays hidden until the
    /// call has been over for half a minute.
    @Test func aCallThatDropsForAMomentKeepsTheCompanionHidden() {
        var h = EngineHarness()
        h.work(600)
        #expect(h.send(.meeting(Fixtures.inCall)).hiddenChanges == [true])
        h.pass(120, judging: .meeting)
        var shown = h.send(.meeting(.none)).hiddenChanges
        shown += h.pass(3, judging: .meeting).hiddenChanges
        let back = h.send(.meeting(Fixtures.inCall))
        #expect(shown.isEmpty && back.commands.isEmpty)  // no show, and no second hide
        #expect(h.status.phase == .meeting)
        h.pass(39, judging: .meeting)
        h.send(.meeting(.none))
        #expect(h.pass(BehaviorEngine.meetingHoldSec - 1, judging: .meeting).hiddenChanges.isEmpty)
        #expect(h.pass(2, judging: .meeting).hiddenChanges == [false])
        #expect(h.status.phase != .meeting)
    }

    @Test func afterAMeetingMokuResumesCalmlyAndTheDriftIsForgotten() {
        var h = EngineHarness()
        h.work(600)
        h.drift(610)  // standing, past the ten-minute step, the normal face since the look back
        h.send(.meeting(Fixtures.sharing))
        h.pass(600, judging: .meeting)
        #expect(h.send(.meeting(.none)).hiddenChanges.isEmpty)  // it waits out a call that only dropped for a moment
        let end = h.pass(BehaviorEngine.meetingHoldSec + 1, judging: .meeting)
        #expect(end.hiddenChanges == [false])
        #expect(end.moves.isEmpty)
        #expect(end.gestures == [.sitDown])
        #expect(end.moods.isEmpty)  // the face was normal already, since the look back
        #expect(h.engine.mood == .content)
        #expect(end.notableEventTypes.isEmpty)
        #expect(end.feedback.isEmpty)
        #expect(h.status.phase == .settling)
        // Drifting again starts a fresh drift, from a glance: its own one sad move, then the normal face.
        let again = h.drift(30)
        #expect(again.moods == [.disappointed, .content])
        #expect(again.gestures == [.sigh])
        #expect(again.lines.isEmpty)
    }

    @Test func focusTimeIsFrozenNotLostDuringAMeeting() {
        var h = EngineHarness()
        h.work(600)
        h.send(.meeting(Fixtures.inCall))
        let during = h.pass(1_200, judging: .working)
        #expect(during.events(.focusGrowth).isEmpty)
        h.send(.meeting(.none))
        h.pass(BehaviorEngine.meetingHoldSec, judging: .meeting)  // the call's half minute after it ends is still the call
        h.work(300)
        #expect(h.status.focusStreakSec == 900)
    }

    @Test func micOrCameraAloneIsNotAMeeting() {
        var h = EngineHarness()
        h.work(60)
        let effects = h.send(.meeting(MeetingContext(inCall: false, sharingScreen: false, micInUse: true, cameraInUse: true)))
        #expect(effects.isEmpty)
    }

    @Test func aMeetingVerdictAloneDoesNotHideMoku() {
        var h = EngineHarness()
        h.work(60)
        let effects = h.send(.verdict(h.verdict(.meeting)))
        #expect(effects.isEmpty)
        #expect(h.status.phase == .focused)
    }
}

@Suite("Unknown verdicts and missing evidence")
struct EvidenceTests {
    @Test func unknownVerdictsChangeNothing() {
        var h = EngineHarness()
        h.work(600)
        let unknown = h.pass(1_800, judging: .unknown)
        #expect(unknown.notableEventTypes.isEmpty)
        #expect(unknown.lines.isEmpty)
        #expect(unknown.moods.isEmpty)
        #expect(h.status.phase == .focused)
        // No growth either once the last working verdict is more than a minute old.
        #expect(unknown.events(.focusGrowth).count <= 1)
    }

    @Test func unknownVerdictsNeverStartEscalation() {
        var h = EngineHarness()
        h.pass(3_600, judging: .unknown)
        #expect(h.allEffects.isEmpty)
        #expect(h.status.phase == .settling)
    }

    @Test func escalationPausesWithoutFreshDriftingEvidenceAndResumesWithIt() {
        var h = EngineHarness()
        h.work(600)
        h.drift(120)
        // The brain can't decide for 10 minutes. Evidence stays fresh for 60 s, so the clock stops at 3:00.
        h.pass(600, judging: .unknown)
        #expect(h.status.driftSec == 180)
        #expect(h.allEffects.gestures == [.nod, .sigh])  // the task's nod as work began, then only the sad step's
        // Fresh drifting evidence: Moku stands up one drifting minute later, with no second sigh.
        h.drift(60)
        #expect(h.allEffects.gestures == [.nod, .sigh, .standUp])
        #expect(h.times { $0.isGesture(.standUp) } == [600.0 + 120 + 600 + 60])
    }

    /// Charles, 2026-10-04: a drift with no verdict for a minute calms Moku fully, instead of standing red and still.
    @Test func staleEvidenceCalmsMokuFullyAndFreshEvidencePicksTheDriftBackUp() {
        var h = EngineHarness()
        h.work(600)
        h.drift(660)  // standing, red, past the ten-minute step; the last drifting verdict comes at 1260
        #expect(h.engine.standing)
        let stale = h.pass(120)  // the brain is down
        #expect(h.firstTime { $0.isGesture(.sitDown) } == 1_321)
        // (Its eyes were on the work already, and its face the normal one, since the look back.)
        #expect(stale.commands == [.perform(.sitDown), .setWorkState(.idle)])
        #expect(stale.notableEventTypes.isEmpty)
        #expect(h.status.phase == .drifting && h.status.driftSec == 720)

        // Fresh drifting evidence: the drift as the ladder left it, the ask back up (standing, no words since the friends,
        // 2026-10-14) with the normal face: no sad face again, no second sigh. Nothing is logged again.
        let again = h.drift(3)
        #expect(again.moods.isEmpty)
        #expect(h.engine.mood == .content)
        #expect(again.gestures == [.standUp])
        #expect(again.gazes.isEmpty)  // the look at you was shown once; the eyes stay on the work
        #expect(again.lines.isEmpty)
        #expect(again.workStates == [.longDrift])
        #expect(again.notableEventTypes.isEmpty)
    }

    @Test func comingBackAfterARestIsStillAReturn() {
        var h = EngineHarness()
        h.work(600)
        h.drift(300)  // standing
        h.pass(120)
        let back = h.send(.verdict(h.verdict(.working)))
        #expect(back.returns == [.full])
        #expect(back.notableEventTypes == [.returned])
        #expect(!back.gestures.contains(.sitDown))  // already seated
        #expect(back.lines.isEmpty)  // glad without words (the friends, 2026-10-14)
    }

    @Test func underForceCalmARestAndThePickUpShowNothing() {
        var h = EngineHarness()
        h.send(.verdict(h.verdict(.working)))
        _ = h.engine.setForceCalm(true, now: h.now)
        h.work(600)
        h.drift(660)
        h.pass(120)
        let again = h.drift(3)
        #expect(again.actions.isEmpty)
        #expect(again.lines.isEmpty)
    }

    @Test func silenceIsTheSameAsUnknown() {
        var h = EngineHarness()
        h.work(600)
        h.drift(30)
        h.pass(3_600)  // the brain is down: no verdicts at all
        #expect(h.allEffects.lines.isEmpty)
        #expect(!h.allEffects.moods.contains(.concerned))
        #expect(h.status.driftSec == 90)
    }
}
