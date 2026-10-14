import Foundation
import MokuKit
import Testing
@testable import MokuMind

@Suite("Take a break")
struct TakeABreakTests {
    /// The break timers the engine sent, in order: (seconds left, total), or nil when taken away.
    static func timers(_ effects: [EngineEffect], at start: Date) -> [Double?] {
        effects.compactMap { effect -> Double?? in
            guard case let .character(.breakTimer(until, _)) = effect else { return nil }
            return .some(until.map { $0.timeIntervalSince(start) })
        }
    }
    static func breakFlags(_ effects: [EngineEffect]) -> [Bool] {
        effects.compactMap { if case let .setOnBreak(on) = $0 { on } else { nil } }
    }

    @Test func aBreakRunsItsCountdownWithTeaThenADozeAndMokuWakesWhenItsOver() {
        var h = EngineHarness()
        h.work(60)
        let startedAt = h.now
        let start = h.send(.startBreak)
        #expect(Self.breakFlags(start) == [true])  // the app stops watching
        #expect(Self.timers(start, at: startedAt) == [1200])  // 20 minutes by default, over Moku's head
        #expect(start.gestures == [.drinkWater])
        let doze = h.pass(20)
        #expect(doze.moods.contains(.sleepy))
        let rest = h.pass(1_190)
        #expect(Self.breakFlags(rest) == [false])  // watching starts again
        #expect(Self.timers(rest, at: startedAt) == [nil])
        #expect(rest.gestures.contains(.stretch))
        #expect(rest.lines.contains { $0.text == "That’s your 20-minute break. Ready when you are." })
        #expect(h.status.phase == .settling)
    }

    @Test func endingItEarlyTakesTheTimerAway() {
        var h = EngineHarness()
        h.work(60)
        h.send(.startBreak)
        h.pass(120)
        let end = h.send(.endBreak)
        #expect(Self.breakFlags(end) == [false])
        #expect(Self.timers(end, at: h.now) == [nil])
        #expect(h.status.phase == .focused)
    }

    @Test func theLengthComesFromSettings() {
        var config = CompanionConfig.charles
        config.teaBreakMaxSec = 300
        var h = EngineHarness(config: config)
        h.work(60)
        let startedAt = h.now
        #expect(Self.timers(h.send(.startBreak), at: startedAt) == [300])
        #expect(Self.breakFlags(h.pass(301)) == [false])
    }

    @Test func eachStageOfTodaysHouseIsCelebratedAtACalmMoment() {
        var h = EngineHarness()
        h.work(30)
        func world(_ today: Int) -> WorldSnapshot { WorldSnapshot(growthPoints: 5000, todayFocusMinutes: today, todayReturns: 0, longestFocusMinutesToday: 0, threads: []) }
        h.send(.world(world(35)))  // the baseline: launching isn't a milestone
        let floor = h.send(.world(world(42)))
        #expect(floor.events(.completed).count == 1)
        let done = h.send(.world(world(175))) + h.send(.world(world(245)))
        #expect(done.events(.completed).count == 4)  // frame, walls, roof, and the house
        let calm = h.pass(60)
        #expect(calm.gestures.contains(.celebrate))
        // The body alone: no line, and Luna isn't asked for one (the friends, 2026-10-14).
        #expect(calm.voiceRequests.isEmpty)
        #expect(calm.lines.isEmpty)
        #expect(h.send(.world(world(5))).events(.completed).isEmpty)  // a new day starts over
    }
}
