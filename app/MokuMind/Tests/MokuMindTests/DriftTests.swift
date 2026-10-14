import CoreGraphics
import Foundation
import MokuKit
import Testing
@testable import MokuMind

@Suite("Short drift")
struct ShortDriftTests {
    /// The friends (2026-10-14) "dont like a sad face": a drift gets one short sad move (a sigh, the face sad while it looks
    /// at you), then the normal face again, eyes back on the work. Sad, never angry (2026-10-08).
    @Test func aDriftGetsOneSadMoveThenTheNormalFace() {
        var h = EngineHarness()
        h.send(.attention(Fixtures.cursor))
        h.work(1_200)
        let drifting = h.drift(90, cursor: Fixtures.otherWindowCursor)
        #expect(h.times { $0.isMood(.disappointed) } == [1_210])
        #expect(h.times { $0.isGesture(.sigh) } == [1_210])
        #expect(drifting.moods == [.disappointed, .content])
        // One pass: the face is back to normal as the 2.5 s sigh ends (Charles, 2026-10-14: "two pass sad display").
        #expect(h.times { $0.isMood(.content) }.filter { $0 > 1_210 }.first.map { $0 - 1_210 <= 3.5 } == true)
        let later = h.drift(900)
        #expect(!later.moods.contains(.annoyed) && !later.moods.contains(.disappointed))  // nor later, standing or past ten minutes
        #expect(drifting.gazes == [.user, .point(Fixtures.cursor)])
        #expect(drifting.gestures == [.sigh])
        #expect(drifting.lines.isEmpty)
        #expect(drifting.voiceRequests.isEmpty)
        #expect(drifting.moves.isEmpty)
        #expect(drifting.notableEventTypes.isEmpty)
        #expect(drifting.feedback.isEmpty)
        // It never watches the distracting window: after its look at you, it watches the work's place.
        #expect(!drifting.gazes.contains(.point(Fixtures.otherWindowCursor)))
        #expect(h.engine.attentionTarget == .point(Fixtures.cursor))
        #expect(h.status.phase == .drifting)
    }

    /// Charles, 2026-10-12: "the sad animation is too much, maybe moku can show its sadness once and then go back to
    /// watching my screen". One look at the person, a few seconds long; since 2026-10-14 the face goes back to normal too.
    @Test func mokuShowsItsSadnessOnceThenWatchesTheScreen() {
        var h = EngineHarness()
        h.send(.attention(Fixtures.cursor))
        h.work(1_200)
        h.drift(300, cursor: Fixtures.otherWindowCursor)
        let looksAtUser = h.times { $0 == .character(.setAttention(.user)) }.filter { $0 >= 1_200 }  // not the minute-by-minute look-up while working
        let looksAtWork = h.times { $0 == .character(.setAttention(.point(Fixtures.cursor))) }.filter { $0 >= 1_200 }
        #expect(looksAtUser == [1_210])  // the one look, as the face turns sad
        #expect(looksAtWork.count == 1)  // then the work, for the rest of the drift
        #expect(looksAtWork.first.map { $0 > 1_210 && $0 - 1_210 <= 8 } == true)
        #expect(h.engine.mood == .content)  // the normal face, not a sad one
        #expect(h.engine.attentionTarget == .point(Fixtures.cursor))
        // It's the work's place it watches, never the window it drifted to.
        #expect(!h.allEffects.gazes.contains(.point(Fixtures.otherWindowCursor)))
    }

    /// The sad move is shown once per drift: fresh evidence after a rest picks up neither the stare nor the sigh.
    @Test func aRestedDriftPicksUpNeitherTheSadMoveNorTheLookAtTheUser() {
        var h = EngineHarness()
        h.send(.attention(Fixtures.cursor))
        h.work(1_200)
        h.drift(30, cursor: Fixtures.otherWindowCursor)
        h.pass(120)  // no drifting evidence for the evidence window: Moku calms
        h.drift(30, cursor: Fixtures.otherWindowCursor)
        #expect(h.times { $0 == .character(.setAttention(.user)) }.filter { $0 >= 1_200 } == [1_210])
        #expect(h.times { $0.isGesture(.sigh) } == [1_210])
        #expect(h.engine.mood == .content)
        #expect(h.engine.attentionTarget == .point(Fixtures.cursor))
    }

    @Test func graceChangesNothingAndComingBackIsNotAReturn() {
        var h = EngineHarness()
        h.work(1_200)
        let grace = h.drift(9)
        #expect(grace.actions.isEmpty)
        #expect(grace.workStates == [.grace])
        let back = h.send(.verdict(h.verdict(.working)))
        #expect(back.notableEventTypes.isEmpty)
        #expect(back.returns.isEmpty)
        #expect(back.actions.isEmpty)
        #expect(back.workStates == [.focused])
    }

    @Test func comingBackEarnsAHappyBlipAndScaledReturnGrowth() {
        var h = EngineHarness()
        h.work(1_200)  // 20 focused minutes
        h.drift(60)
        let back = h.send(.verdict(h.verdict(.working)))
        #expect(back.moods == [.happy])
        #expect(back.returns == [.small])  // light and body, never words
        #expect(back.gestures.isEmpty)
        #expect(back.lines.isEmpty)
        #expect(back.notableEventTypes == [.shortDrift, .returned, .returnGrowth])
        #expect(back.events(.returnGrowth).first?.value == 2)
        #expect(back.events(.returnGrowth).first?.threadId == Fixtures.thread.id)
        #expect(back.events(.shortDrift).first?.value == 60)
        // The blip settles back into content focus.
        #expect(h.pass(3, judging: .working).moods == [.content])
        #expect(h.status.phase == .focused)
    }

    /// Charles, 2026-10-04: a stone only past 30 s. A glance is still noticed (the nod), but lays nothing.
    @Test(arguments: [(15.0, false), (29, false), (30, true), (90, true)])
    func aDriftLaysAStoneOnlyPastThirtySeconds(driftSec: Double, laysStone: Bool) {
        var h = EngineHarness()
        h.work(1_200)
        h.drift(driftSec)
        let back = h.send(.verdict(h.verdict(.working)))
        #expect(back.returns == [.small])
        #expect(back.moods == [.happy])
        #expect(back.notableEventTypes == (laysStone ? [.shortDrift, .returned, .returnGrowth] : [.shortDrift]))
        #expect(back.events(.shortDrift).first?.value == driftSec)
    }

    @Test func aGlanceKeepsTheBonusForTheNextRealReturn() {
        var h = EngineHarness()
        h.work(1_200)  // 20 focused minutes
        h.drift(20)
        h.work(60)
        h.drift(60)
        let back = h.send(.verdict(h.verdict(.working)))
        // The glance didn't spend the focus behind it: the real return is paid for all 21 minutes.
        #expect(back.events(.returnGrowth).first?.value == 2.1)
    }

    @Test func shortDriftsPauseTheStreakWithoutBreakingIt() {
        var h = EngineHarness()
        h.work(600)
        h.drift(60)
        h.work(600)
        #expect(h.status.focusStreakSec == 1_200)
    }

    @Test func drifterCannotFarmReturnGrowth() {
        var h = EngineHarness()
        h.work(360)  // 6 minutes
        var totalFocus = 360.0
        for _ in 0..<10 {
            h.drift(70)  // past grace: each one is a real return
            h.work(30)
            totalFocus += 30
        }
        let bonus = h.allEffects.events(.returnGrowth).compactMap(\.value).reduce(0, +)
        // Only the first return had 5+ focused minutes behind it.
        #expect(h.allEffects.events(.returnGrowth).count == 1)
        #expect(bonus <= totalFocus / 60 * 0.1)
        // Every return is still a return.
        #expect(h.allEffects.events(.returned).count == 10)
    }
}

@Suite("Standard timings")
struct StandardTimingsTests {
    @Test func mokuReactsAtOnceAndAGlanceAwayIsAReturn() {
        var h = EngineHarness(config: .standard)
        h.work(1_200)
        let glance = h.drift(30)
        // Within a couple of seconds: the one sad move (a sigh, the sad face, a look at the user), then the normal face
        // and the work again; no words.
        #expect(h.times { $0.isMood(.disappointed) }.first.map { $0 <= 1_202 } == true)
        #expect(glance.moods == [.disappointed, .content])
        #expect(glance.gazes.filter { $0 == .user }.count == 1)  // once
        #expect(glance.gazes.last != .user)
        #expect(glance.gestures == [.sigh])
        #expect(glance.lines.isEmpty)
        let back = h.send(.verdict(h.verdict(.working)))
        #expect(back.moods == [.happy])
        #expect(back.returns == [.small])
        #expect(back.lines.isEmpty)
    }

    /// Charles, 2026-10-14, on the new build: "the sad state and actions are kinda messy, its doing it twice". His log:
    /// a sad move at 06:11:10, a happy return at :36, another sad move at :44, happy at :54, sad at 06:12:24 and :48.
    /// The sad move shows once in `sadMoveCooldownSec`; a drift inside it is watched calmly (normal face, eyes on the
    /// work), and its return makes no happy face, so the face doesn't flip sad, normal, happy, sad.
    @Test func aQuickSecondDriftGetsNoSecondSadMove() {
        var h = EngineHarness(config: .standard)
        h.work(1_200)
        h.drift(30)
        #expect(h.times { $0.isGesture(.sigh) }.count == 1)
        h.send(.verdict(h.verdict(.working)))
        h.work(6)
        let start = h.now.timeIntervalSince(EngineHarness.base)
        let again = h.drift(30)
        #expect(!again.moods.contains(.disappointed) && !again.gestures.contains(.sigh))
        #expect(!again.gazes.contains(.user))
        let back = h.send(.verdict(h.verdict(.working)))
        #expect(!back.moods.contains(.happy))
        #expect(back.notableEventTypes.contains(.returned))  // still counted as a return, as usual
        // Once the cooldown is over, a drift gets its sad move again.
        h.work(BehaviorEngine.sadMoveCooldownSec)
        let later = h.drift(30)
        #expect(later.gestures == [.sigh] && later.moods.first == .disappointed, "after \(start)")
    }

    @Test func focusBringsALookUpEveryMinute() {
        var h = EngineHarness(config: .standard)
        h.work(900)
        // Once a minute of continuous focus: 15 in 15 minutes, the first a minute in.
        let lookUps = h.times { $0 == .character(.perform(.smile)) || $0 == .character(.setMood(.happy)) }
        #expect(lookUps.count == 15)
        #expect(lookUps.first.map { abs($0 - 60) <= 1 } == true)
    }
}

@Suite("Long drift")
struct LongDriftTests {
    /// 20 focused minutes, then a drift starting at t = 1200.
    static func driftingAfterFocus(for seconds: Double, config: CompanionConfig = .charles) -> EngineHarness {
        var h = EngineHarness(config: config)
        h.work(1_200)
        h.drift(seconds)
        return h
    }

    @Test func escalatesOnScheduleOncePerStep() {
        let h = Self.driftingAfterFocus(for: 1_100)
        let start = 1_200.0
        // After grace, one sad move: a sigh, the sad face and a look at the user. Three seconds later (the sigh is 2.5 s)
        // the normal face, for the rest of the drift. Never angry.
        #expect(h.times { $0.isMood(.disappointed) } == [start + 10])
        #expect(h.times { $0.isGesture(.sigh) } == [start + 10])
        #expect(h.times { $0 == .character(.setAttention(.user)) }.filter { $0 >= start } == [start + 10])
        #expect(h.times { $0.isMood(.content) }.filter { $0 >= start } == [start + 13])
        #expect(h.effects(from: start, to: start + 1_100).moods == [.disappointed, .content])
        #expect(h.times { $0.isEvent(.longDriftStarted) } == [start + 120])
        // Four minutes: stands up (and the stage shows it a little red from the .drifting tier).
        #expect(h.effects(from: start, to: start + 239).gestures == [.sigh])
        #expect(h.times { $0.isGesture(.standUp) } == [start + 240])
        #expect(h.times { $0 == .character(.setWorkState(.drifting)) } == [start + 240])
        // Ten minutes: the ask, standing where it is. No words over its head (the friends, 2026-10-14).
        #expect(h.allEffects.moves.isEmpty)  // no walking for now
        #expect(h.times { $0.isEvent(.nudged) } == [start + 600])
        #expect(h.times { $0 == .character(.setWorkState(.longDrift)) } == [start + 600])
        #expect(h.allEffects.lines.isEmpty)
        // No Luna lines, no name calls.
        #expect(h.allEffects.voiceRequests.isEmpty)
        #expect(!h.allEffects.eventTypes.contains(.calledName))
    }

    @Test func mokuWatchesTheWorkNotTheUserForTheRestOfTheDrift() {
        var h = EngineHarness()
        h.send(.attention(Fixtures.cursor))
        h.work(1_200)
        h.drift(1_000, cursor: Fixtures.otherWindowCursor)
        // The one look at the user comes with the sad face; the stand-up (4 min) and the ask (10 min) bring back neither
        // the look nor the sad face.
        #expect(h.effects(from: 1_210, to: 2_200).gazes == [.user, .point(Fixtures.cursor)])
        #expect(h.effects(from: 1_217, to: 2_200).moods.isEmpty)
        #expect(h.engine.attentionTarget == .point(Fixtures.cursor))
        #expect(h.engine.mood == .content)
    }

    @Test func afterTheAskMokuStaysQuietWithTheNormalFace() {
        let h = Self.driftingAfterFocus(for: 3_600)
        #expect(h.allEffects.lines.isEmpty)  // not even the ask has words now (the friends, 2026-10-14)
        #expect(h.allEffects.events(.nudged).count == 1)
        #expect(h.allEffects.moods.last == .content)  // the end state: the normal face since the look back (2026-10-14)
        #expect(h.allEffects.gestures.filter { $0 == .sigh }.count == 1)  // the one sad move, an hour in
    }

    /// Charles, 2026-10-04: the ask stays until you come back. Since the friends (2026-10-14) it's Moku standing tall,
    /// with no bubble over its head.
    @Test func theAskStaysUpUntilYouComeBack() {
        var h = Self.driftingAfterFocus(for: 1_800)
        #expect(h.engine.standing)
        #expect(h.effects(from: 1_200, to: 3_000).gestures == [.sigh, .standUp])
        #expect(h.allEffects.lines.isEmpty)
        #expect(!h.allEffects.commands.contains(.dismissSpeech))
        // Coming back sits it down, with no words.
        let back = h.send(.verdict(h.verdict(.working)))
        #expect(back.gestures == [.sitDown])
        #expect(back.lines.isEmpty)
    }

    @Test func aDriftThatNeverAskedTakesNothingDown() {
        var h = Self.driftingAfterFocus(for: 300)
        #expect(!h.send(.verdict(h.verdict(.working))).commands.contains(.dismissSpeech))
    }

    /// Goal-aware judging: a switch to another goal is just work.
    static let problems = ThreadRef(id: "g1", title: "practicing coding problems")
    static let potluck = ThreadRef(id: "g2", title: "Potluck side project")

    static func goalVerdict(_ h: inout EngineHarness, _ goal: ThreadRef, switch isSwitch: Bool = false) -> Verdict {
        var v = h.verdict(.working, thread: goal)
        v.goal = goal
        v.isSwitch = isSwitch
        return v
    }

    @Test func aSwitchToAnotherGoalIsJustWork() {
        var h = EngineHarness()
        h.send(.verdict(Self.goalVerdict(&h, Self.problems), context: nil))
        h.work(600, thread: Self.problems)
        // A switch to another goal: calm, focus keeps counting, no drift.
        h.send(.verdict(Self.goalVerdict(&h, Self.potluck, switch: true), context: nil))
        h.work(600, thread: Self.potluck)
        #expect(h.engine.activity == .focused)
        #expect(h.allEffects.lines.isEmpty)
        #expect(h.allEffects.events(.longDriftStarted).isEmpty)
        // A real drift off that goal still climbs to the ask (with no words since the friends, 2026-10-14).
        h.send(.verdict(Self.goalVerdict(&h, Self.potluck), context: nil))
        h.drift(700)
        #expect(h.allEffects.events(.nudged).count == 1)
        #expect(h.allEffects.lines.isEmpty)
    }
}

@Suite("Returning")
struct ReturnTests {
    @Test func afterALongDriftMokuSoftensAndWalksHome() {
        var h = LongDriftTests.driftingAfterFocus(for: 610)  // standing, asked to focus
        let back = h.send(.verdict(h.verdict(.working)))
        #expect(back.moods == [.happy])
        #expect(back.returns == [.full])
        #expect(back.gestures == [.sitDown])
        // Glad without words (the friends, 2026-10-14: no lines over its head).
        #expect(back.lines.isEmpty)
        #expect(back.moves.isEmpty)  // it never left home
        #expect(back.notableEventTypes == [.returned])
        #expect(back.events(.returnGrowth).isEmpty)
        #expect(back.feedback.map(\.kind) == [.returnedAfterNudge])
        #expect(h.status.atHome)
        // Settles into content focus, eyes back on the work.
        let settled = h.pass(6, judging: .working)
        #expect(settled.moods == [.content])
        #expect(h.status.phase == .focused)
    }

    @Test func noReturnedAfterNudgeFeedbackWithoutANudge() {
        var h = LongDriftTests.driftingAfterFocus(for: 200)
        let back = h.send(.verdict(h.verdict(.working)))
        #expect(back.notableEventTypes == [.returned])
        #expect(back.feedback.isEmpty)
        #expect(back.returns == [.small])  // before standing up: the small return
        #expect(back.lines.isEmpty)
    }

    @Test func growthResumesAfterALongReturnWithoutABonusAndTheStreakRestarts() {
        var h = LongDriftTests.driftingAfterFocus(for: 400)
        let back = h.work(300)
        #expect(back.events(.focusGrowth).count == 5)
        #expect(back.events(.returnGrowth).isEmpty)
        #expect(h.status.focusStreakSec == 300)
    }

    @Test func ignoredNudgeIsReportedOnceTenMinutesAfterTheNudge() {
        let h = LongDriftTests.driftingAfterFocus(for: 1_800)
        #expect(h.times { $0.isFeedback(.ignoredNudge) } == [1_200.0 + 600 + 600])
    }

    @Test func aLateReturnAfterAnIgnoredNudgeIsNotLabeledAsTheNudgeWorking() {
        var h = LongDriftTests.driftingAfterFocus(for: 1_300)
        let back = h.send(.verdict(h.verdict(.working)))
        #expect(back.feedback.isEmpty)
        #expect(back.notableEventTypes == [.returned])
    }

    @Test func fastReturnWhenFocusMovesToAPlaceJudgedWorking() {
        var h = EngineHarness()
        h.send(.focusChanged(Fixtures.editorApp, Fixtures.editorWindow))
        h.work(1_200, context: Fixtures.editor)
        h.send(.focusChanged(Fixtures.browserApp, Fixtures.youtubeWindow))
        h.drift(400, context: Fixtures.youtube)
        // No verdict needed: the editor was last judged working.
        let back = h.send(.focusChanged(Fixtures.editorApp, WindowInfo(title: "Other.swift", url: nil)))
        #expect(back.notableEventTypes == [.returned])
        #expect(back.returns == [.full])
        #expect(h.status.phase == .focused)
    }

    @Test func aURLArrivingJustAfterTheSwitchIsAnUpdateNotANewSwitch() {
        var h = EngineHarness()
        h.send(.focusChanged(Fixtures.browserApp, Fixtures.docsWindow))
        h.work(1_200, context: Fixtures.docs)
        h.send(.focusChanged(Fixtures.browserApp, Fixtures.youtubeWindow))
        h.drift(200, context: Fixtures.youtube)
        // Back to the docs tab: first without the URL (cache miss), then ~150 ms later with it.
        let urlless = h.send(.focusChanged(Fixtures.browserApp, WindowInfo(title: Fixtures.docsWindow.title, url: nil)))
        #expect(urlless.isEmpty)
        h.wait(0.15)
        let withURL = h.send(.focusChanged(Fixtures.browserApp, Fixtures.docsWindow))
        #expect(withURL.notableEventTypes == [.returned])
        #expect(withURL.returns == [.small])
        #expect(h.allEffects.gestures.filter { $0 == .glance }.isEmpty)
        #expect(h.allEffects.events(.returned).count == 1)
    }

    @Test func aBrowserSwitchWithoutAURLNeverFastReturnsOnTheAppAlone() {
        var h = EngineHarness()
        let blankTab = WindowInfo(title: "Start Page", url: nil)
        h.send(.focusChanged(Fixtures.browserApp, blankTab))
        h.work(600, context: WorkContext(bundleId: Fixtures.browserApp.bundleId))  // Safari with no URL: working
        h.send(.focusChanged(Fixtures.browserApp, Fixtures.youtubeWindow))
        h.drift(200, context: Fixtures.youtube)
        // Switching to a YouTube tab whose URL isn't known yet must not match "Safari, no URL: working".
        let urlless = h.send(.focusChanged(Fixtures.browserApp, WindowInfo(title: "Another video - YouTube", url: nil)))
        #expect(urlless.isEmpty)
        #expect(h.status.phase == .drifting)
    }

    @Test func switchingToAPlaceJudgedDriftingWaitsForAVerdict() {
        var h = EngineHarness()
        h.send(.focusChanged(Fixtures.browserApp, Fixtures.youtubeWindow))
        h.drift(30, context: Fixtures.youtube)
        h.send(.focusChanged(Fixtures.editorApp, Fixtures.editorWindow))
        h.work(60, context: Fixtures.editor)
        // Back to YouTube: Moku doesn't judge on memory alone.
        let switched = h.send(.focusChanged(Fixtures.browserApp, Fixtures.youtubeWindow))
        #expect(switched.isEmpty)
        #expect(h.status.phase == .focused)
    }

    @Test func aVerdictForAPlaceTheUserAlreadyLeftOnlyTeachesMemory() {
        var h = EngineHarness()
        h.send(.focusChanged(Fixtures.editorApp, Fixtures.editorWindow))
        h.work(1_200, context: Fixtures.editor)
        h.send(.focusChanged(Fixtures.browserApp, Fixtures.youtubeWindow))
        h.drift(400, context: Fixtures.youtube)
        h.send(.focusChanged(Fixtures.editorApp, Fixtures.editorWindow))
        // The YouTube sample taken just before the switch is judged after it.
        let stale = h.send(.verdict(h.verdict(.drifting), context: Fixtures.youtube))
        #expect(stale.isEmpty)
        #expect(h.status.phase == .focused)
    }
}
