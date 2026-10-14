import CoreGraphics
import Foundation
import MokuKit
import Testing
@testable import MokuMind

@MainActor
@Suite("Companion runtime")
struct RuntimeTests {
    let brain = FakeBrain()
    let stage = FakeStage()
    let world = FakeWorld()
    let model = WorldModel()
    let clock = ManualClock()
    let senses: AsyncStream<SenseEvent>
    let feed: AsyncStream<SenseEvent>.Continuation
    let runtime: CompanionRuntime

    init() {
        (senses, feed) = AsyncStream.makeStream(of: SenseEvent.self)
        runtime = CompanionRuntime(senses: senses, brain: brain, stage: stage, world: world, worldModel: model, clock: clock)
    }

    /// Run `seconds` of simulated time: a tick per second, and whatever `each` sends before it.
    func run(_ seconds: Int, from start: Double, each: (Double) -> Void = { _ in }) async {
        for second in 1...seconds {
            let t = start + Double(second)
            clock.set(t)
            each(t)
            runtime.tick()
            await runtime.drain()
        }
    }

    func finish() {
        stage.releaseMoves()
        runtime.stop()
        clock.cancelSleepers()
        feed.finish()
    }

    @Test func startShowsMokuAndAppliesTheServedConfig() async {
        await brain.set(config: Fixtures.quickConfig)
        runtime.start()
        #expect(stage.calls.first == .show)
        await runtime.drain()
        #expect(runtime.engine.config == Fixtures.quickConfig)
        #expect(stage.onPat != nil && stage.onClick != nil)
        finish()
    }

    @Test func senseEventsReachTheEngineAndVerdictsReachTheStage() async {
        await brain.set(judged: .drifting)
        runtime.start()
        feed.yield(.focusChanged(Fixtures.browserApp, Fixtures.youtubeWindow))
        feed.yield(.sample(Samples.sample("s1", app: Fixtures.browserApp, window: Fixtures.youtubeWindow)))
        // The first minute of a drift is grace: only the lantern knows.
        #expect(await eventually { self.stage.workStates == [.grace] })
        #expect(stage.moods.isEmpty)
        #expect(runtime.status.phase == .drifting)
        finish()
    }

    @Test func atMostOneJudgeInFlightAndStaleSamplesAreDropped() async {
        await brain.set(holdJudges: true)
        runtime.start()
        runtime.handle(.sample(Samples.sample("s1")))
        #expect(await eventually { await self.brain.heldJudgeCount == 1 })
        runtime.handle(.sample(Samples.sample("s2")))
        runtime.handle(.sample(Samples.sample("s3")))
        #expect(await brain.judgedSampleIds == ["s1"])
        await brain.releaseJudges()
        #expect(await eventually { await self.brain.heldJudgeCount == 1 })
        // s2 went stale while s1 was out; only the newest sample is judged next.
        #expect(await brain.judgedSampleIds == ["s1", "s3"])
        await brain.set(holdJudges: false)
        await brain.releaseJudges()
        await runtime.drain()
        #expect(runtime.status.phase == .focused)
        #expect(stage.calls.contains(.gesture(.nod)))
        finish()
    }

    @Test func aTestInSettingsDoesNotNameTheWorkAgain() async {
        runtime.start()
        runtime.handle(.sample(Samples.sample("s1")))
        await runtime.drain()
        #expect(stage.calls.filter { $0 == .gesture(.nod) }.count == 1)
        runtime.setManualControl(true)   // a test starts…
        runtime.setManualControl(false)  // …and stops
        runtime.handle(.sample(Samples.sample("s2")))
        await runtime.drain()
        #expect(runtime.status.phase == .focused)
        #expect(stage.calls.filter { $0 == .gesture(.nod) }.count == 1)
        finish()
    }

    @Test func voiceIsFetchedAheadAndSpokenWhenItsMomentComes() async {
        var config = CompanionConfig.standard
        config.breakAfterSec = 120  // the break line is fetched a minute ahead
        await brain.set(config: config)
        await brain.set(line: "Little sip of water?", for: .water)
        runtime.start()
        await runtime.drain()
        runtime.apply(.verdict(Verdict(sampleId: "w0", state: .working, thread: nil, isNewThread: false,
                                       confidence: 0.9, source: .jev, reason: "", latencyMs: 1)))
        await run(130, from: 0) { t in
            if Int(t) % 3 == 0 {
                self.runtime.apply(.verdict(Verdict(sampleId: "w\(Int(t))", state: .working, thread: nil, isNewThread: false,
                                                    confidence: 0.9, source: .jev, reason: "", latencyMs: 1)))
            }
        }
        #expect(await brain.voiceRequests.map(\.kind).contains(.water))
        #expect(stage.lines == [SpeechLine(text: "Little sip of water?", tone: .warm)])
        finish()
    }

    @Test func aTabSwitchSeenOnlyInASampleIsStillJudged() async {
        await brain.set(judged: .drifting)
        runtime.start()
        runtime.handle(.focusChanged(Fixtures.browserApp, Fixtures.youtubeWindow))
        runtime.handle(.sample(Samples.sample("s1", app: Fixtures.browserApp, window: Fixtures.youtubeWindow)))
        await runtime.drain()
        #expect(runtime.status.phase == .drifting)
        // A minute and a half on YouTube, past grace.
        for second in stride(from: 3, through: 90, by: 3) {
            clock.set(Double(second))
            runtime.handle(.sample(Samples.sample("s1-\(second)", app: Fixtures.browserApp, window: Fixtures.youtubeWindow)))
            await runtime.drain()
            runtime.tick()
        }
        // Without Accessibility there is no focus change for a tab switch; the next sample is the first news of it.
        await brain.set(judged: .working)
        runtime.handle(.sample(Samples.sample("s2", app: Fixtures.browserApp, window: Fixtures.docsWindow)))
        await runtime.drain()
        #expect(runtime.status.phase == .focused)
        #expect(stage.calls.contains(.celebrateReturn(.small)))
        finish()
    }

    @Test func patAndClickFromTheStage() async {
        runtime.start()
        await runtime.drain()
        stage.onClick?()
        #expect(world.opened == 1)
        stage.onPat?()
        // The stage plays the pat reaction where it's touched: the runtime doesn't ask for it again (a second one, after
        // a walk when it was mid-move).
        #expect(!stage.gestures.contains(.patReaction))
        await runtime.drain()
        #expect(await brain.feedback.map(\.kind) == [.pat])
        #expect(await brain.events.map(\.type) == [.patted])
        finish()
    }

    @Test func eventsWaitInARetryQueueWhileTheBrainIsDown() async {
        await brain.set(down: true)
        runtime.start()
        await runtime.drain()
        stage.onPat?()
        await runtime.drain()
        #expect(await brain.events.isEmpty)
        await brain.set(down: false)
        await run(Int(CompanionRuntime.retryIntervalSec), from: 0)
        #expect(await brain.events.map(\.type) == [.patted])
        #expect(await brain.feedback.map(\.kind) == [.pat])
        finish()
    }

    @Test func theWorldRefreshesEveryMinuteAndMilestonesReachThePresenter() async {
        await brain.set(world: Fixtures.snapshot(points: 100))
        runtime.start()
        await runtime.drain()
        #expect(model.snapshot.growthPoints == 100)
        let fetchesAtStart = await brain.worldFetches
        await brain.set(world: Fixtures.snapshot(points: 125))
        await run(61, from: 0)
        #expect(await brain.worldFetches == fetchesAtStart + 1)
        #expect(model.snapshot.growthPoints == 125)
        #expect(world.celebrated == [.sapling])
        #expect(!stage.gestures.contains(.celebrate))  // Moku's own celebration waits for a return or a break
        finish()
    }

    /// Settings › Delete my data: "Moku starts fresh from here". The menu bar's house and the popover's numbers show the
    /// empty day at once. Before, they kept today's house until the next minute's refresh.
    @Test func deletingTheDataShowsTheEmptyWorldAtOnce() async {
        var built = Fixtures.snapshot(points: 300)
        built.todayFocusMinutes = 120
        await brain.set(world: built)
        runtime.start()
        await runtime.drain()
        #expect(model.snapshot.todayFocusMinutes == 120)
        await brain.set(world: .empty)  // the brain has deleted everything
        runtime.forgetWork()
        await runtime.drain()
        #expect(model.snapshot.todayFocusMinutes == 0)
        #expect(model.snapshot.growthPoints == 0)
        finish()
    }

    @Test func growthEventsTriggerAWorldRefresh() async {
        runtime.start()
        await runtime.drain()
        let fetchesAtStart = await brain.worldFetches
        // Work from t = 5, so the first focused minute (t = 65) doesn't coincide with the periodic refresh (t = 60).
        let sampleEveryThreeSeconds: (Double) -> Void = { t in
            if t >= 5 && Int(t) % 3 == 2 { self.runtime.handle(.sample(Samples.sample("w\(Int(t))"))) }
        }
        await run(64, from: 0, each: sampleEveryThreeSeconds)
        #expect(await brain.events.isEmpty)
        #expect(await brain.worldFetches == fetchesAtStart + 1)
        await run(1, from: 64, each: sampleEveryThreeSeconds)
        #expect(await brain.events.map(\.type) == [.focusGrowth])
        #expect(await brain.worldFetches == fetchesAtStart + 2)
        finish()
    }

    @Test func theEngineTicksEverySecondOnTheClock() async {
        runtime.start()
        await runtime.drain()
        runtime.apply(.verdict(Verdict(sampleId: "w", state: .working, thread: nil, isNewThread: false,
                                       confidence: 0.9, source: .jev, reason: "", latencyMs: 1)))
        for _ in 0..<60 {
            // Wait for the tick loop to go to sleep, then wake it one second later.
            #expect(await eventually { self.clock.sleeperCount == 1 })
            clock.advance(by: 1)
        }
        #expect(await eventually { await self.brain.events.map(\.type) == [.focusGrowth] })
        finish()
    }

    @Test func withTheBrainDownMokuStaysCalm() async {
        await brain.set(down: true)
        runtime.start()
        await runtime.drain()
        #expect(runtime.engine.config == .standard)
        runtime.handle(.focusChanged(Fixtures.browserApp, Fixtures.youtubeWindow))
        await run(1_800, from: 0) { t in
            if Int(t) % 3 == 0 {
                self.runtime.handle(.sample(Samples.sample("s\(Int(t))", app: Fixtures.browserApp, window: Fixtures.youtubeWindow)))
            }
            self.runtime.handle(.attention(CGPoint(x: t, y: 300)))
        }
        #expect(stage.calls.first == .show)
        #expect(stage.lines.isEmpty)
        #expect(stage.moods.isEmpty)
        #expect(stage.gestures.isEmpty)
        #expect(!stage.calls.contains { if case .move = $0 { true } else { false } })
        #expect(runtime.status.phase == .settling)
        finish()
    }
}

/// The drift ladder doesn't walk any more, but the driver's contract still holds for any move.
@MainActor
@Suite("Stage driver: walks")
struct StageDriverWalkTests {
    final class Walks { var tasks: [Task<Void, Never>] = [] }
    let stage = FakeStage()
    let walks = Walks()
    var driver: StageDriver { StageDriver(stage: stage) { [walks] work in walks.tasks.append(Task { await work() }) } }
    let ask = SpeechLine(text: "Charles, can we focus? I want my house built.", tone: .calling, duration: SpeechLine.untilDismissed)

    @Test func commandsAfterAMoveWaitUntilMokuArrives() async {
        stage.holdMoves = true
        let driver = self.driver
        driver.run(.move(.center)); driver.run(.say(ask)); driver.run(.setWorkState(.longDrift))
        #expect(await eventually { self.stage.calls.last == .move(.center) })
        stage.releaseMoves()
        for walk in walks.tasks { await walk.value }
        #expect(Array(stage.calls.drop { $0 != .move(.center) }.dropFirst()) == [.say(ask), .workState(.longDrift)])
    }

    @Test func aNewMoveRedirectsTheWalkAndWhatWaitedPlaysFirst() async {
        stage.holdMoves = true
        let driver = self.driver
        let welcome = SpeechLine(text: "Welcome back! Let's do it.", tone: .warm)
        driver.run(.move(.center)); driver.run(.say(welcome))
        #expect(await eventually { self.stage.calls.last == .move(.center) })
        driver.run(.move(.home)); driver.run(.perform(.sitDown))
        #expect(await eventually { self.stage.calls.last == .move(.home) })
        #expect(stage.calls.contains(.say(welcome)))
        #expect(!stage.gestures.contains(.sitDown))  // sitting down waits for the walk home
        stage.releaseMoves()
        for walk in walks.tasks { await walk.value }
        #expect(stage.calls.last == .gesture(.sitDown))
    }

    @Test func hidingDropsWhatWaitsBehindAWalk() async {
        stage.holdMoves = true
        let driver = self.driver
        driver.run(.move(.center)); driver.run(.say(ask))
        #expect(await eventually { self.stage.calls.last == .move(.center) })
        driver.run(.setHidden(true))
        stage.releaseMoves()
        for walk in walks.tasks { await walk.value }
        #expect(!stage.calls.drop { $0 != .hidden(true) }.contains { if case .say = $0 { true } else { false } })
    }
}
