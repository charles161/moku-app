import Foundation
import MokuKit
import Testing
@testable import MokuMind

/// The usage events the runtime records: comebacks, breaks, corrections, house pieces and the first focus.
@MainActor
@Suite("Companion runtime: usage events")
struct RuntimeUsageTests {
    @MainActor final class Recorded {
        var events: [(name: String, props: [String: UsageValue])] = []
        var counts: [UsageCount] = []
        func named(_ name: String) -> [[String: UsageValue]] { events.filter { $0.name == name }.map(\.props) }
    }

    let brain = FakeBrain()
    let stage = FakeStage()
    let world = FakeWorld()
    let clock = ManualClock()
    let recorded = Recorded()
    let senses: AsyncStream<SenseEvent>
    let feed: AsyncStream<SenseEvent>.Continuation
    let runtime: CompanionRuntime

    init() {
        (senses, feed) = AsyncStream.makeStream(of: SenseEvent.self)
        runtime = CompanionRuntime(senses: senses, brain: brain, stage: stage, world: world, worldModel: WorldModel(), clock: clock)
        runtime.usage = { [recorded] name, props in recorded.events.append((name, props)) }
        runtime.count = { [recorded] count in recorded.counts.append(count) }
    }

    func finish() {
        stage.releaseMoves()
        runtime.stop()
        clock.cancelSleepers()
        feed.finish()
    }

    /// `seconds` on YouTube from `start`, then a sample of work: a drift and its return.
    func driftAndReturn(from start: Double, seconds: Int) async {
        await brain.set(judged: .drifting)
        clock.set(start)
        runtime.handle(.sample(Samples.sample("d\(start)", app: Fixtures.browserApp, window: Fixtures.youtubeWindow)))
        await runtime.drain()
        for second in stride(from: 3, through: seconds, by: 3) {
            clock.set(start + Double(second))
            runtime.handle(.sample(Samples.sample("d\(start)-\(second)", app: Fixtures.browserApp, window: Fixtures.youtubeWindow)))
            await runtime.drain()
            runtime.tick()
        }
        await brain.set(judged: .working)
        clock.set(start + Double(seconds) + 1)
        runtime.handle(.sample(Samples.sample("w\(start)", app: Fixtures.browserApp, window: Fixtures.docsWindow)))
        await runtime.drain()
    }

    @Test func aReturnFromADriftIsAComebackTheFirstOfTheDayOnce() async {
        runtime.start()
        await runtime.drain()
        await driftAndReturn(from: 0, seconds: 90)
        #expect(recorded.named("comeback") == [["drift_seconds": .int(60), "first_today": .bool(true)]])
        await driftAndReturn(from: 200, seconds: 330)
        #expect(recorded.named("comeback").last == ["drift_seconds": .int(300), "first_today": .bool(false)])
        finish()
    }

    @Test func breaksSayWhereTheyStartedAndHowTheyEndedAndAreNotComebacks() async {
        var config = CompanionConfig.standard
        config.teaBreakMaxSec = 30
        await brain.set(config: config)
        runtime.start()
        await runtime.drain()
        world.onTakeBreak?()       // the popover's button
        stage.onTakeBreak?()       // the ✕ on Moku's timer
        runtime.toggleBreak(from: .link)
        for second in 1...31 {
            clock.set(Double(second))
            runtime.tick()
        }
        await runtime.drain()
        #expect(recorded.named("break") == [
            ["what": .word("started"), "from": .word("popover"), "after_suggestion": .bool(false)],
            ["what": .word("cancelled"), "from": .word("moku"), "seconds": .int(0)],
            ["what": .word("started"), "from": .word("link"), "after_suggestion": .bool(false)],
            ["what": .word("ended"), "from": .word("timer"), "seconds": .int(30)],
        ])
        #expect(recorded.named("comeback").isEmpty)  // ending a break by hand lays a stone, but isn't a comeback
        finish()
    }

    @Test func patsAndTodaysCorrectionsAreCorrections() async {
        runtime.start()
        await runtime.drain()
        stage.onPat?()
        world.onCorrection?(["s1"], true)
        world.onCorrection?(["s2"], false)
        world.onCorrection?([], false)  // nothing to correct
        #expect(recorded.named("correction") == [["kind": .word("pat")], ["kind": .word("marked_work")], ["kind": .word("marked_not_work")]])
        finish()
    }

    @Test func newHousePiecesAndTheFirstTenMinutesAreCountedOnceButNotAtLaunch() async {
        await brain.set(world: WorldSnapshot(growthPoints: 30, todayFocusMinutes: 9, todayReturns: 0, longestFocusMinutesToday: 9,
                                             threads: [], unitsToday: 3, focusMinutesAllTime: 9))
        runtime.installedAt = clock.now().addingTimeInterval(-3 * 3600)
        runtime.start()
        await runtime.drain()
        #expect(recorded.events.isEmpty)  // the first world is the baseline
        await brain.set(world: WorldSnapshot(growthPoints: 50, todayFocusMinutes: 21, todayReturns: 0, longestFocusMinutesToday: 21,
                                             threads: [], unitsToday: 5, focusMinutesAllTime: 21))
        world.onOpen?()
        await runtime.drain()
        #expect(recorded.named("house_piece") == [["pieces_today": .int(4)], ["pieces_today": .int(5)]])
        #expect(recorded.named("first_focus") == [["minutes_since_install": .int(180)]])
        world.onOpen?()
        await runtime.drain()
        #expect(recorded.events.count == 3)  // nothing new
        // The house has 24 pieces: focus past it is no new piece (0a62 sent pieces_today 40 on 2026-10-07).
        await brain.set(world: WorldSnapshot(growthPoints: 230, todayFocusMinutes: 230, todayReturns: 0, longestFocusMinutesToday: 60,
                                             threads: [], unitsToday: 23, focusMinutesAllTime: 230))
        world.onOpen?()
        await runtime.drain()
        await brain.set(world: WorldSnapshot(growthPoints: 400, todayFocusMinutes: 400, todayReturns: 0, longestFocusMinutesToday: 60,
                                             threads: [], unitsToday: 40, focusMinutesAllTime: 400))
        world.onOpen?()
        await runtime.drain()
        #expect(recorded.named("house_piece").last == ["pieces_today": .int(24)])
        #expect(!recorded.named("house_piece").contains { ($0["pieces_today"]).map { $0 == .int(25) || $0 == .int(40) } ?? false })
        finish()
    }

    @Test func aDriftSaysEachStepItReachedAndWhetherTheAskWorked() async throws {
        var config = CompanionConfig.standard
        config.graceSec = 1; config.annoyedAfterSec = 6; config.shortDriftMaxSec = 9; config.standUpAfterSec = 12; config.askAfterSec = 15
        await brain.set(config: config)
        runtime.start()
        await runtime.drain()
        await driftAndReturn(from: 0, seconds: 30)
        #expect(recorded.named("drift_step").map { $0["step"] } == ["sad", "long", "tall", "ask"].map { UsageValue.word($0) })
        let outcome = try #require(recorded.named("ask_outcome").first)
        #expect(outcome["outcome"] == .word("within_2_min"))
        guard case let .int(seconds)? = outcome["seconds"] else { Issue.record("no seconds"); return }
        #expect((5...25).contains(seconds))
        // A second drift starts the ladder again; one that never reaches the ask has no outcome.
        await driftAndReturn(from: 100, seconds: 6)
        #expect(recorded.named("drift_step").dropFirst(4).first == ["step": .word("sad")])
        #expect(!recorded.named("drift_step").dropFirst(4).contains(["step": .word("ask")]) && recorded.named("ask_outcome").count == 1)
        finish()
    }

    @Test func anAskStillWaitingAtMidnightDidntWorkThatDay() {
        runtime.usageState.askedAt = clock.now()
        runtime.usageState.askDayEnds = clock.now().addingTimeInterval(60)
        runtime.tickUsage(now: clock.now().addingTimeInterval(30))
        #expect(recorded.named("ask_outcome").isEmpty)
        runtime.tickUsage(now: clock.now().addingTimeInterval(61))
        #expect(recorded.named("ask_outcome") == [["outcome": .word("not_that_day")]])
    }

    @Test func suggestionsWaterAndHidingForACallAreReadOffWhatTheEngineDid() {
        let now = clock.now()
        runtime.reportEngineUsage([.event(CompanionEvent(ts: now, type: .breakSuggested)), .character(.say(SpeechLine(text: "Stretch?", tone: .warm))),
                                   .character(.perform(.stretch))])
        #expect(recorded.named("break_suggested") == [["kind": .word("stretch")]])
        #expect(runtime.breakFacts(.breakStarted, value: nil) == ["after_suggestion": .bool(true)])
        runtime.reportEngineUsage([.character(.perform(.drinkWater))])
        runtime.reportEngineUsage([.event(CompanionEvent(ts: now, type: .breakStarted)), .character(.perform(.drinkWater))])  // tea, not a reminder
        #expect(recorded.counts == [.waterReminder])
        runtime.handle(.meeting(MeetingContext(inCall: false, sharingScreen: true, micInUse: false, cameraInUse: false)))
        runtime.reportEngineUsage([.character(.setHidden(true))])
        clock.set(clock.now().addingTimeInterval(125).timeIntervalSince(EngineHarness.base))
        runtime.reportEngineUsage([.character(.setHidden(false))])
        runtime.reportEngineUsage([.character(.setHidden(false))])  // already showing: nothing more
        #expect(recorded.named("hidden").contains(["by": .word("screen_share")]))
        #expect(recorded.named("shown") == [["by": .word("automatic"), "after_seconds": .int(125)]])
    }

    @Test func clicksJudgmentsAndMinutesAtTheMacGoIntoTheDaysCounts() async {
        runtime.start()
        await runtime.drain()
        stage.onClick?()
        await brain.set(judged: .working)
        runtime.handle(.sample(Samples.sample("w1", app: Fixtures.browserApp, window: Fixtures.docsWindow)))
        await runtime.drain()
        for second in 1...60 { clock.set(Double(second)); runtime.tick() }
        #expect(recorded.counts.contains(.companionClick))
        #expect(recorded.counts.contains(.verdict(.work)) && recorded.counts.contains(.jevAnswer(ms: 5)))
        #expect(recorded.counts.contains { if case .brainAnswer = $0 { true } else { false } })
        #expect(recorded.counts.filter { $0 == .activeMinute }.count == 1)
        #expect(recorded.counts.contains { if case .today = $0 { true } else { false } })
        finish()
    }
}
