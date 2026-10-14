import Foundation
import MokuKit
import Testing
@testable import MokuMind

// "Today counted" (docs/specs/next-three.md §3): when the day's card shows, on a fake clock. Days are in UTC here, so the
// hours read the same on any Mac.

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// 2026-10-`day` at `hour`:`minute`:`second`, UTC.
private func at(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
    utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
}

/// A plan on a day, ticked by hand: `idle` says how long the Mac has been idle at each tick, `calm` whether anything's in
/// the way.
private struct Day {
    var plan: DayCountedPlan
    init(memory: DayCountedPlan.Memory = .init()) { plan = DayCountedPlan(memory: memory, calendar: utc) }

    mutating func tick(_ now: Date, minutes: Int?, idle: TimeInterval = 0, calm: Bool = true) -> DayCountedPlan.Card? {
        plan.check(.init(now: now, focusedMinutes: minutes, idleSeconds: idle, calm: calm))
    }
    /// A tick a second from `from` up to `to`: the first card, and when.
    mutating func run(from: Date, to: Date, minutes: Int = 45, idle: (Date) -> TimeInterval = { _ in 0 },
                      calm: (Date) -> Bool = { _ in true }) -> (at: Date, card: DayCountedPlan.Card)? {
        var now = from
        while now <= to {
            if let card = tick(now, minutes: minutes, idle: idle(now), calm: calm(now)) { return (now, card) }
            now = now.addingTimeInterval(1)
        }
        return nil
    }
}

/// Idle since `since` (zero before).
private func idleSince(_ since: Date) -> (Date) -> TimeInterval { { max(0, $0.timeIntervalSince(since)) } }

@Suite("Today counted: when")
struct DayCountedPlanTests {
    @Test func awayThirtyMinutesAfterFourShowsIt() {
        var day = Day()
        let shown = day.run(from: at(4, 15, 30), to: at(4, 18), idle: idleSince(at(4, 16, 10)))
        #expect(shown?.at == at(4, 16, 40))
        #expect(shown?.card == DayCountedPlan.Card(day: "2026-10-04", yesterday: false, reason: .away))
    }

    @Test func anAwayThatBeganBeforeFourCountsFromFour() {
        var day = Day()
        let shown = day.run(from: at(4, 15, 30), to: at(4, 18), idle: idleSince(at(4, 15, 50)))
        #expect(shown?.at == at(4, 16, 30))
    }

    @Test func aMacAsleepHalfAnHourAfterFourShowsItOnWaking() {
        var day = Day()
        #expect(day.run(from: at(4, 16, 50), to: at(4, 17)) == nil)
        // Asleep from 17:00; woken at 17:45 by a key press (idle 0 again).
        #expect(day.tick(at(4, 17, 45), minutes: 45) == DayCountedPlan.Card(day: "2026-10-04", yesterday: false, reason: .away))

        // A short nap (20 minutes) isn't the day winding down.
        var napped = Day()
        #expect(napped.run(from: at(4, 16, 50), to: at(4, 17)) == nil)
        #expect(napped.tick(at(4, 17, 20), minutes: 45) == nil)
        #expect(napped.run(from: at(4, 17, 20, 1), to: at(4, 18, 59)) == nil)
    }

    @Test func sevenPMWhileYouReAtIt() {
        var day = Day()
        let shown = day.run(from: at(4, 18, 58), to: at(4, 19, 5))
        #expect(shown?.at == at(4, 19))
        #expect(shown?.card.reason == .evening)

        // Away at seven (idle since 18:55): not "while you're at it"; the away rule shows it at 19:25 instead.
        var away = Day()
        let later = away.run(from: at(4, 18, 50), to: at(4, 20), idle: idleSince(at(4, 18, 55)))
        #expect(later?.at == at(4, 19, 25))
        #expect(later?.card.reason == .away)
    }

    @Test func quittingAfterFour() {
        var day = Day()
        _ = day.tick(at(4, 15, 59), minutes: 25)
        #expect(day.plan.dueOnQuit(now: at(4, 15, 59)) == nil)
        _ = day.tick(at(4, 16, 1), minutes: 25)
        #expect(day.plan.dueOnQuit(now: at(4, 16, 1)) == DayCountedPlan.Card(day: "2026-10-04", yesterday: false, reason: .quit))
        _ = day.tick(at(4, 16, 2), minutes: 19)
        #expect(day.plan.dueOnQuit(now: at(4, 16, 2)) == nil)  // under 20 minutes
        _ = day.tick(at(4, 16, 3), minutes: 25)
        day.plan.settled("2026-10-04")
        #expect(day.plan.dueOnQuit(now: at(4, 16, 4)) == nil)  // already shown today
    }

    @Test func onlyADayWithTwentyFocusedMinutes() {
        var day = Day()
        // 19 minutes: no card for an evening at the Mac, nor an hour away.
        #expect(day.run(from: at(4, 16), to: at(4, 19, 10), minutes: 19, idle: { $0 < at(4, 17) ? 0 : $0 < at(4, 18) ? $0.timeIntervalSince(at(4, 17)) : 0 }) == nil)
        // The twentieth minute, while you're at it after seven: the card.
        let shown = day.run(from: at(4, 19, 10), to: at(4, 19, 20), minutes: 20)
        #expect(shown?.at == at(4, 19, 10))
    }

    @Test func onceADayAtMost() {
        var day = Day()
        let first = day.run(from: at(4, 16), to: at(4, 17), idle: idleSince(at(4, 16)))
        #expect(first?.at == at(4, 16, 30))
        day.plan.settled("2026-10-04")
        // The rest of the day: away, back, seven o'clock, quitting.
        #expect(day.run(from: at(4, 16, 30, 1), to: at(4, 23, 59, 59), idle: { $0 < at(4, 18) ? 0 : idleSince(at(4, 20))($0) }) == nil)
        #expect(day.plan.dueOnQuit(now: at(4, 23)) == nil)
        // The next day has its own.
        #expect(day.run(from: at(5, 18, 59), to: at(5, 19, 1))?.card.day == "2026-10-05")
    }

    @Test func aDayWithoutItsCardShowsTheNextMorning() {
        // Worked till three and quit (no ticks after): no card that day.
        var day = Day()
        #expect(day.run(from: at(4, 14, 30), to: at(4, 15), minutes: 40) == nil)
        // The next morning, Moku opens at 8:30 with the person at the Mac.
        let morning = day.tick(at(5, 8, 30), minutes: 0)
        #expect(morning == DayCountedPlan.Card(day: "2026-10-04", yesterday: true, reason: .morning))
        // Not while something's in the way; still there after.
        #expect(day.tick(at(5, 8, 31), minutes: 0, calm: false) == nil)
        #expect(day.tick(at(5, 8, 32), minutes: 0) == morning)
        // Shown: never again, and today's own card is still to come.
        day.plan.settled("2026-10-04")
        #expect(day.tick(at(5, 8, 33), minutes: 0) == nil)
        let today = day.run(from: at(5, 19), to: at(5, 19), minutes: 30)?.card
        #expect(today?.day == "2026-10-05" && today?.yesterday == false)
    }

    @Test func yesterdaysCardWaitsForThePersonAndOnlyTillNoon() {
        var day = Day()
        _ = day.run(from: at(4, 14), to: at(4, 14, 1), minutes: 40)
        // Woken at 9 but nobody's there (idle 10 minutes): wait.
        #expect(day.tick(at(5, 9), minutes: 0, idle: 600) == nil)
        #expect(day.tick(at(5, 9, 10), minutes: 0)?.yesterday == true)
        // Not shown by noon (always something in the way): let go.
        #expect(day.run(from: at(5, 9, 10, 1), to: at(5, 12), minutes: 0, calm: { _ in false }) == nil)
        #expect(day.tick(at(5, 12, 0, 1), minutes: 0) == nil)
        #expect(day.plan.memory.done.contains("2026-10-04"))
    }

    @Test func noMorningCardForASmallDayAShownOneOrAnOlderOne() {
        var small = Day()
        _ = small.run(from: at(4, 14), to: at(4, 14, 1), minutes: 15)
        #expect(small.tick(at(5, 8, 30), minutes: 0) == nil)

        var shown = Day()
        _ = shown.run(from: at(4, 19), to: at(4, 19), minutes: 40)
        shown.plan.settled("2026-10-04")
        #expect(shown.tick(at(5, 8, 30), minutes: 0) == nil)

        var older = Day()
        _ = older.run(from: at(3, 14), to: at(3, 14, 1), minutes: 90)
        #expect(older.tick(at(5, 8, 30), minutes: 0) == nil)  // two days on: only yesterday comes back
    }

    @Test func neverInAMeetingButAfterIt() {
        var day = Day()
        // A call from 18:30 to 19:30: seven o'clock comes during it.
        let shown = day.run(from: at(4, 18, 20), to: at(4, 20), calm: { $0 < at(4, 18, 30) || $0 >= at(4, 19, 30) })
        #expect(shown?.at == at(4, 19, 30))
        #expect(shown?.card.reason == .evening)
    }

    @Test func itsMomentStaysOnceItHasCome() {
        var day = Day()
        // Away from 16:10 with the display asleep (the companion out of sight, so not calm) until 17:15: the card's
        // moment came at 16:40, and it shows the moment the person is back and it can be seen.
        let shown = day.run(from: at(4, 16), to: at(4, 18), idle: { $0 < at(4, 17, 15) ? idleSince(at(4, 16, 10))($0) : 0 },
                            calm: { $0 < at(4, 16, 10) || $0 >= at(4, 17, 15) })
        #expect(shown?.at == at(4, 17, 15))
        #expect(shown?.card.reason == .away)
    }

    @Test func itsMemoryOutlivesALaunch() throws {
        var day = Day()
        _ = day.run(from: at(4, 14), to: at(4, 14, 1), minutes: 40)
        let defaults = try #require(UserDefaults(suiteName: "DayCountedTests.\(UUID().uuidString)"))
        day.plan.memory.save(to: defaults)
        var relaunched = Day(memory: DayCountedPlan.Memory.load(from: defaults))
        #expect(relaunched.tick(at(5, 8, 30), minutes: 0)?.day == "2026-10-04")
        #expect(DayCountedPlan.Memory.load(from: try #require(UserDefaults(suiteName: "DayCountedTests.empty.\(UUID().uuidString)"))) == .init())
    }
}

// MARK: The runtime

/// A brain for the card: the world and the day it's given, and which way the day was asked for.
private actor DayBrain: BrainAPI {
    var world = WorldSnapshot.empty
    var day: TodaySummary?
    var down = false
    private(set) var cachedAsks: [Date?] = []
    private(set) var plainAsks = 0

    func set(world: WorldSnapshot) { self.world = world }
    func set(day: TodaySummary?) { self.day = day }
    func set(down: Bool) { self.down = down }

    func judge(_ sample: ActivitySample) async throws -> Verdict {
        Verdict(sampleId: sample.id, state: .working, thread: nil, isNewThread: false, confidence: 0.9, source: .jev, reason: "", latencyMs: 1)
    }
    func voice(_ request: VoiceRequest) async throws -> VoiceLine { VoiceLine(text: "", source: "luna") }
    func sendFeedback(_ feedback: Feedback) async throws {}
    func sendEvent(_ event: CompanionEvent) async throws {}
    func world() async throws -> WorldSnapshot { world }
    func config() async throws -> CompanionConfig { .standard }
    func threads() async throws -> [ThreadSummary] { [] }
    func today(date: Date?) async throws -> TodaySummary {
        plainAsks += 1
        guard let day else { throw BrainError.unreachable(path: "/v1/today", reason: "none") }
        return day
    }
    func todayCached(date: Date?) async throws -> TodaySummary {
        cachedAsks.append(date)
        guard !down, let day else { throw BrainError.unreachable(path: "/v1/today", reason: "down") }
        return day
    }
    func days(from: Date, to: Date) async throws -> DaysResponse { DaysResponse(firstDay: nil, days: []) }
}

/// The menu bar side: records the cards it was asked to show.
@MainActor
private final class CardWorld: WorldPresenter {
    var onManualControl: (@MainActor (Bool) -> Void)?
    var onTakeBreak: (@MainActor () -> Void)?
    var onOpen: (@MainActor () -> Void)?
    var todayProvider: (@MainActor (Date?) async -> TodaySummary?)?
    var daysProvider: (@MainActor (_ from: Date, _ to: Date) async -> DaysResponse?)?
    var onCorrection: (@MainActor (_ segmentIds: [String], _ isWork: Bool) -> Void)?
    func openWorld() {}
    func closeWorld() {}
    func celebrate(_ stage: ForestStage) {}
    func setManualControl(_ on: Bool) {}
    func setOnBreak(_ on: Bool) {}

    var visible = true
    private(set) var shown: [(summary: TodaySummary, yesterday: Bool)] = []
    private(set) var goodbyes: [TodaySummary] = []
    private(set) var closed = 0
    var canShowDayCounted: Bool { visible }
    func showDayCounted(_ summary: TodaySummary, yesterday: Bool) async -> Bool {
        guard visible else { return false }
        shown.append((summary, yesterday)); return true
    }
    func sayGoodbyeWithDayCounted(_ summary: TodaySummary) async -> Bool {
        guard visible else { return false }
        goodbyes.append(summary); return true
    }
    func closeDayCounted() { closed += 1 }
}

private func summary(_ date: String, minutes: Int) -> TodaySummary {
    TodaySummary(date: date, note: nil, focusedMinutes: minutes, longestFocusMinutes: 31, returns: 4, unitsToday: minutes / 10, segments: [],
                 built: [], wandered: [], quickCheckMinutes: 0, comebacks: [], bestComeback: nil, completions: [])
}

/// The runtime with a card schedule on UTC days, starting at `start`.
@MainActor
private final class CardRig {
    let brain = DayBrain()
    let world = CardWorld()
    let clock = ManualClock()
    let runtime: CompanionRuntime
    let schedule: DayCountedSchedule
    /// The memory as last saved.
    @MainActor final class Saved { var memory: DayCountedPlan.Memory? }
    let box = Saved()
    var saved: DayCountedPlan.Memory? { box.memory }

    init(start: Date, worldMinutes: Int, dayMinutes: Int? = nil) async {
        let (senses, _) = AsyncStream.makeStream(of: SenseEvent.self)
        runtime = CompanionRuntime(senses: senses, brain: brain, stage: FakeStage(), world: world, worldModel: WorldModel(), clock: clock)
        let box = self.box
        schedule = DayCountedSchedule(memory: .init(), calendar: utc, idleSeconds: { 0 }, save: { box.memory = $0 })
        runtime.dayCounted = schedule
        var snapshot = WorldSnapshot.empty; snapshot.todayFocusMinutes = worldMinutes
        await brain.set(world: snapshot)
        let key = schedule.plan.key(start)
        await brain.set(day: summary(key, minutes: dayMinutes ?? worldMinutes))
        move(to: start)
        runtime.start()
        await runtime.drain()
    }
    func move(to date: Date) { clock.set(date.timeIntervalSince(EngineHarness.base)) }
    /// A tick a second from `from` to `to`.
    func run(from: Date, to: Date) async {
        var now = from
        while now <= to {
            move(to: now); runtime.tick(); await runtime.drain()
            now = now.addingTimeInterval(1)
        }
    }
    func finish() { runtime.stop(); clock.cancelSleepers() }
}

@MainActor
@Suite("Today counted: the runtime")
struct DayCountedRuntimeTests {
    @Test func sevenPMPutsUpTheCardOnceWithYourDaysNumbersAndNoModelCall() async {
        let rig = await CardRig(start: at(4, 18, 59, 50), worldMinutes: 94)
        await rig.run(from: at(4, 18, 59, 55), to: at(4, 19, 1))
        #expect(rig.world.shown.count == 1)
        #expect(rig.world.shown.first?.yesterday == false)
        #expect(rig.world.shown.first?.summary.focusedMinutes == 94)
        #expect(await rig.brain.cachedAsks.count == 1)
        #expect(await rig.brain.plainAsks == 0)
        #expect(rig.saved?.done == ["2026-10-04"])
        await rig.run(from: at(4, 19, 1, 1), to: at(4, 19, 5))
        #expect(rig.world.shown.count == 1)
        rig.finish()
    }

    @Test func aMeetingTakesTheCardAwayAndHoldsOneBack() async {
        let rig = await CardRig(start: at(4, 18, 59, 50), worldMinutes: 94)
        rig.runtime.handle(.meeting(MeetingContext(inCall: true, sharingScreen: false, micInUse: true, cameraInUse: true)))
        await rig.run(from: at(4, 18, 59, 55), to: at(4, 19, 2))
        #expect(rig.world.closed == 1)
        #expect(rig.world.shown.isEmpty)
        rig.runtime.handle(.meeting(.none))
        await rig.run(from: at(4, 19, 2, 1), to: at(4, 19, 2, 40))  // the call's over for half a minute first
        #expect(rig.world.shown.count == 1)
        rig.finish()
    }

    @Test func theBrainHasTheLastWordOnTwentyMinutes() async {
        // The world said 94 (stale); the day itself has 12: no card, and none later.
        let rig = await CardRig(start: at(4, 18, 59, 50), worldMinutes: 94, dayMinutes: 12)
        await rig.run(from: at(4, 18, 59, 55), to: at(4, 19, 3))
        #expect(rig.world.shown.isEmpty)
        #expect(rig.saved?.done == ["2026-10-04"])
        #expect(await rig.brain.cachedAsks.count == 1)
        rig.finish()
    }

    @Test func anUnseenCompanionOrABrainAwayTriesAgainLater() async {
        let rig = await CardRig(start: at(4, 18, 59, 50), worldMinutes: 94)
        await rig.brain.set(down: true)
        await rig.run(from: at(4, 19), to: at(4, 19, 1))
        #expect(rig.world.shown.isEmpty)
        await rig.brain.set(down: false)
        await rig.run(from: at(4, 19, 1, 1), to: at(4, 19, 1, 59))
        #expect(rig.world.shown.isEmpty)  // two minutes between tries
        await rig.run(from: at(4, 19, 2), to: at(4, 19, 2, 2))
        #expect(rig.world.shown.count == 1)
        rig.finish()
    }

    @Test func quittingAfterFourSaysGoodbyeWithTheCard() async {
        let rig = await CardRig(start: at(4, 16, 29, 58), worldMinutes: 94)
        await rig.run(from: at(4, 16, 29, 59), to: at(4, 16, 30))
        await rig.runtime.sayGoodbye()
        #expect(rig.world.goodbyes.count == 1)
        #expect(rig.saved?.done == ["2026-10-04"])
        await rig.runtime.sayGoodbye()
        #expect(rig.world.goodbyes.count == 1)  // once a day
        rig.finish()

        // Out of sight (hidden, behind a full-screen app): Moku just quits, and the day keeps its chance at a card.
        let hidden = await CardRig(start: at(4, 16, 29, 58), worldMinutes: 94)
        await hidden.run(from: at(4, 16, 29, 59), to: at(4, 16, 30))
        hidden.world.visible = false
        await hidden.runtime.sayGoodbye()
        #expect(hidden.world.goodbyes.isEmpty)
        #expect(hidden.saved?.done ?? [] == [])
        hidden.finish()

        let early = await CardRig(start: at(4, 15, 29, 58), worldMinutes: 94)
        await early.run(from: at(4, 15, 29, 59), to: at(4, 15, 30))
        await early.runtime.sayGoodbye()
        #expect(early.world.goodbyes.isEmpty)  // before four, Moku just quits
        early.finish()
    }
}
