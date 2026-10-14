import Foundation
import MokuKit
import Testing
@testable import MokuMind

@Suite("Pat and click")
struct PatAndClickTests {
    @Test func aPatIsFeedbackAndAnEvent() {
        var h = EngineHarness()
        h.work(60)
        let lastSample = h.verdict(.working)
        h.send(.verdict(lastSample))
        let pat = h.send(.pat)
        #expect(pat.gestures == [.patReaction])
        #expect(pat.feedback == [Feedback(ts: h.now, kind: .pat, sampleId: lastSample.sampleId, threadId: Fixtures.thread.id)])
        #expect(pat.notableEventTypes == [.patted])
        #expect(pat.moods.isEmpty)
    }

    @Test func aPatDuringAnEscalatedDriftMeansWorkingRightAway() {
        var h = EngineHarness()
        h.send(.focusChanged(Fixtures.browserApp, Fixtures.docsWindow))
        h.work(600, context: Fixtures.docs)
        h.drift(610, context: Fixtures.docs)  // the brain thought the docs were a drift; Moku is standing
        let pat = h.send(.pat)
        #expect(pat.gestures == [.patReaction, .sitDown])
        #expect(pat.moods == [.happy])
        #expect(pat.moves.isEmpty)  // it never left home
        #expect(pat.notableEventTypes == [.patted])
        #expect(pat.feedback.map(\.kind) == [.pat])
        #expect(h.status.phase == .focused)
        // Growth resumes straight away, and nothing more is said about the drift.
        let after = h.pass(120)
        #expect(after.events(.focusGrowth).count == 1)
        #expect(after.lines.isEmpty)
        #expect(after.moods == [.content])
    }

    @Test func aPattedPlaceCountsAsWorkForFastReturns() {
        var h = EngineHarness()
        h.send(.focusChanged(Fixtures.browserApp, Fixtures.docsWindow))
        h.drift(30, context: Fixtures.docs)
        h.send(.pat)
        h.send(.focusChanged(Fixtures.browserApp, Fixtures.youtubeWindow))
        h.drift(90, context: Fixtures.youtube)
        let back = h.send(.focusChanged(Fixtures.browserApp, Fixtures.docsWindow))
        #expect(back.notableEventTypes == [.shortDrift, .returned])
    }

    @Test func aClickOpensTheWorld() {
        var h = EngineHarness()
        #expect(h.send(.click) == [.openWorld])
        h.work(600)
        h.drift(400)
        #expect(h.send(.click) == [.openWorld])
    }
}

@Suite("Breaks")
struct BreakTests {
    @Test func breaksRotateAfterContinuousFocus() {
        var h = EngineHarness()
        h.work(4 * 3_000 + 10)
        #expect(h.times { $0.isEvent(.breakSuggested) } == [3_000, 6_000, 9_000, 12_000])
        #expect(h.times { $0.isVoiceRequest(.water) } == [2_940])
        let lines = h.allEffects.lines
        #expect(lines.map(\.tone) == [.warm, .warm, .warm, .warm])
        #expect(lines.map(\.text) == [
            "Sip of water?", "Time for a little stretch.", "Rest your eyes. Look far away for a bit.", "How about a short walk?",
        ])
        let gestures = h.allEffects.gestures.filter { $0 != .smile && $0 != .nod }  // the look-ups, and the task's nod
        // The walk gets a wave: standing up means an angry drift now.
        #expect(gestures == [.drinkWater, .stretch, .glance, .wave])
    }

    @Test func mokuDrinksQuietlyEveryDrinkIntervalOfFocus() {
        var config = CompanionConfig.charles
        config.drinkEverySec = 1_200
        var h = EngineHarness(config: config)
        h.work(1_199)
        #expect(h.allEffects.gestures.filter { $0 == .drinkWater }.isEmpty)
        let due = h.pass(3, judging: .working)
        #expect(due.gestures == [.drinkWater])
        #expect(due.lines.isEmpty)  // no words: a reminder by example
        // Nothing else starts until the drink is done, and the next one is another 20 focused minutes away.
        let during = h.pass(12, judging: .working)
        #expect(during.gestures.isEmpty)
        h.work(1_150)
        #expect(h.allEffects.gestures.filter { $0 == .drinkWater }.count == 1)
        h.work(60)
        #expect(h.allEffects.gestures.filter { $0 == .drinkWater }.count == 2)
    }

    /// Settings › Breaks & Water › Remind me to drink water, off: no drinks, and no water among the break suggestions.
    @Test func waterOffMeansNoDrinkAndNoWaterBreak() {
        var config = CompanionConfig.charles
        config.drinkEverySec = 0
        var h = EngineHarness(config: config)
        h.work(4 * 3_000 + 10)
        #expect(!h.allEffects.gestures.contains(.drinkWater))
        #expect(h.times { $0.isVoiceRequest(.water) }.isEmpty)
        #expect(h.times { $0.isEvent(.breakSuggested) } == [3_000, 6_000, 9_000, 12_000])
        #expect(h.allEffects.lines.map(\.text) == [
            "Time for a little stretch.", "Rest your eyes. Look far away for a bit.", "How about a short walk?", "Time for a little stretch.",
        ])
    }

    /// Settings › Breaks & Water › Suggest a break, off: none is suggested, and no line is fetched for one.
    @Test func breaksOffMeansNoSuggestionAndNoLineFetched() {
        var config = CompanionConfig.charles
        config.breakAfterSec = 0
        var h = EngineHarness(config: config)
        h.work(4 * 3_000 + 10)
        #expect(h.times { $0.isEvent(.breakSuggested) }.isEmpty)
        for kind in [VoiceKind.water, .stretch, .lookAway, .walk] { #expect(h.times { $0.isVoiceRequest(kind) }.isEmpty) }
        #expect(h.allEffects.lines.isEmpty)
        // A break can still be taken.
        #expect(h.send(.startBreak).commands.contains(.setWorkState(.onBreak)))
    }

    /// Both off: hours of focus with neither a drink nor a break, while the look-ups go on.
    @Test func waterAndBreaksOffLeaveOnlyTheLookUps() {
        var config = CompanionConfig.charles
        config.drinkEverySec = 0; config.breakAfterSec = 0
        var h = EngineHarness(config: config)
        h.work(3 * 3_600)
        #expect(!h.allEffects.gestures.contains(.drinkWater))
        #expect(h.times { $0.isEvent(.breakSuggested) }.isEmpty)
        #expect(h.allEffects.gestures.contains(.smile))
    }

    @Test func driftTimeDoesNotCountTowardADrink() {
        var config = CompanionConfig.charles
        config.drinkEverySec = 1_200
        var h = EngineHarness(config: config)
        h.work(1_000)
        h.drift(90)  // a short drift: focus pauses, the count doesn't reset
        h.work(150)
        #expect(h.allEffects.gestures.filter { $0 == .drinkWater }.isEmpty)
        h.work(60)
        #expect(h.allEffects.gestures.filter { $0 == .drinkWater }.count == 1)
    }

    @Test func aBreakLineFromLunaIsUsedWhenReady() {
        var h = EngineHarness()
        h.work(2_950)
        h.send(.voiceReady(.water, VoiceLine(text: "Sip of water? You've been at it a while.", source: "luna")))
        let due = h.pass(60, judging: .working)
        #expect(due.lines == [SpeechLine(text: "Sip of water? You've been at it a while.", tone: .warm)])
        #expect(due.gestures.contains(.drinkWater))
    }

    @Test func driftTimeDoesNotCountTowardABreak() {
        var h = EngineHarness()
        h.work(2_400)
        h.drift(1_000)
        h.work(500)
        #expect(h.allEffects.events(.breakSuggested).isEmpty)
    }
}

@Suite("Milestones")
struct MilestoneTests {
    @Test func theFirstSnapshotIsABaseline() {
        var h = EngineHarness()
        h.send(.world(Fixtures.snapshot(points: 700)))
        #expect(h.pass(5).isEmpty)
    }

    @Test func aNewStageIsCuedAtOnceButMokuNeverInterruptsFocus() {
        var h = EngineHarness()
        h.work(10)
        h.send(.world(Fixtures.snapshot(points: 100)))
        let reached = h.send(.world(Fixtures.snapshot(points: 125)))
        // The menu bar cue and the log right away...
        #expect(reached.contains(.celebrateStage(.sapling)))
        #expect(reached.events(.milestone).map(\.value) == [Double(ForestStage.sapling.rawValue)])
        // ...but Moku itself keeps quiet while the work goes on.
        let focus = h.pass(1_200, judging: .working)
        #expect(!focus.gestures.contains(.celebrate))
        #expect(!focus.contains(.celebrateStage(.sapling)))
    }

    @Test func mokuCelebratesANewStageAtTheNextReturn() {
        var h = EngineHarness()
        h.work(10)
        h.send(.world(Fixtures.snapshot(points: 100)))
        h.send(.world(Fixtures.snapshot(points: 125)))
        h.drift(90)
        let back = h.send(.verdict(h.verdict(.working)))
        #expect(back.returns == [.small])
        #expect(back.gestures == [.celebrate])
        #expect(back.moods == [.happy])
        // The body alone: no line, and Luna isn't asked for one (the friends, 2026-10-14).
        #expect(back.voiceRequests.isEmpty)
        #expect(back.lines.isEmpty)
        #expect(h.pass(10).lines.isEmpty)  // nor a built-in one later
    }

    @Test func mokuCelebratesANewStageAtTheNextBreak() {
        var h = EngineHarness()
        h.work(10)
        h.send(.world(Fixtures.snapshot(points: 100)))
        h.send(.world(Fixtures.snapshot(points: 125)))
        let tea = h.send(.startBreak)
        #expect(tea.gestures == [.celebrate])
        #expect(tea.moods.contains(.happy))
        // No words over its head, from Luna or built in (the friends, 2026-10-14).
        #expect(tea.voiceRequests.isEmpty)
        #expect((tea + h.pass(10)).lines.isEmpty)
    }

    @Test func stagesNeverGoBackwards() {
        var h = EngineHarness()
        h.send(.world(Fixtures.snapshot(points: 700)))
        h.send(.world(Fixtures.snapshot(points: 10)))
        h.send(.world(Fixtures.snapshot(points: 700)))
        #expect(h.pass(3).isEmpty)
    }
}

@Suite("Config")
struct ConfigTests {
    @Test func everyTimingComesFromTheConfig() {
        var h = EngineHarness(config: Fixtures.quickConfig)
        h.work(135)
        // Every 45 s of focus, exactly.
        #expect(h.times { $0.isGesture(.smile) || $0.isMood(.happy) } == [45, 90])
        #expect(h.times { $0.isMood(.proud) } == [100])
        #expect(h.times { $0.isEvent(.breakSuggested) } == [130])
        h.drift(100)
        let start = 135.0
        #expect(h.times { $0.isMood(.disappointed) } == [start + 20])  // grace ends at shortDriftMaxSec here
        #expect(!h.allEffects.moods.contains(.annoyed))  // sad only
        #expect(h.times { $0.isEvent(.longDriftStarted) } == [start + 20])
        #expect(h.times { $0.isGesture(.standUp) } == [start + 40])
        #expect(h.times { $0.isEvent(.nudged) } == [start + 50])
        #expect(h.times { $0 == .character(.setWorkState(.longDrift)) } == [start + 50])
        #expect(h.effects(from: start, to: start + 100).lines.isEmpty)  // the ask has no words (the friends, 2026-10-14)
    }

    @Test func theServedLadderAndAwayTimingsComeFromTheConfigToo() {
        var config = Fixtures.quickConfig
        config.ignoredNudgeAfterSec = 15
        var drifting = EngineHarness(config: config)
        drifting.work(10)
        drifting.drift(200)
        // The ask at +50 (no words since the friends, 2026-10-14), then the ignored nudge.
        #expect(drifting.times { $0.isEvent(.nudged) } == [10.0 + 50])
        #expect(drifting.allEffects.lines.isEmpty)
        #expect(drifting.times { $0.isFeedback(.ignoredNudge) } == [10.0 + 50 + 15])

        config.evidenceWindowSec = 5
        var silent = EngineHarness(config: config)
        silent.send(.verdict(silent.verdict(.working)))
        silent.pass(60)
        #expect(silent.status.focusStreakSec == 5)

        config.longAwaySec = 30
        var away = EngineHarness(config: config)
        away.work(10)
        away.send(.verdict(away.verdict(.away)))
        away.pass(40, judging: .away)
        #expect(away.times { $0.isMood(.sleepy) } == [40])

        config.threadLabelGapSec = 100
        var labels = EngineHarness(config: config)
        let other = ThreadRef(id: "t-other", title: "Docs · Onboarding")
        labels.work(10)
        labels.work(100, thread: other)
        labels.work(3)
        #expect(labels.allEffects.nods == 3)
    }

    @Test func theEndOfGraceComesFromTheConfig() {
        var config = CompanionConfig.standard
        config.graceSec = 30
        var h = EngineHarness(config: config)
        h.work(600)
        h.drift(40)
        #expect(h.times { $0.isMood(.disappointed) } == [630])
        #expect(h.send(.verdict(h.verdict(.working))).returns == [.small])  // 40 s is past this grace
    }

    @Test func aNewConfigAppliesImmediately() {
        var h = EngineHarness()
        h.send(.config(Fixtures.quickConfig))
        h.work(10)
        h.drift(55)
        #expect(h.allEffects.eventTypes.contains(.nudged))
    }

    @Test func ladderStepsNeverFireOutOfOrder() {
        var config = Fixtures.quickConfig
        config.standUpAfterSec = 5  // misconfigured: earlier than the long drift
        var h = EngineHarness(config: config)
        h.work(10)
        h.drift(35)
        #expect(h.times { $0.isGesture(.standUp) } == [10.0 + config.shortDriftMaxSec])  // right after the long drift, never before
    }
}
