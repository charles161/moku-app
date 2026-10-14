import Foundation
import MokuKit

/// When "Today counted" shows (docs/specs/next-three.md §3): a small card beside the companion, once a day at most, for a
/// day with 20 or more focused minutes, at the first of
/// - the person away from the Mac (idle, or the Mac asleep) for 30 minutes after 4 pm;
/// - 7 pm, while they're at the Mac;
/// - quitting Moku after 4 pm (`dueOnQuit`).
/// A day that ends without its card shows it the next morning, until noon, as "Yesterday counted".
///
/// Once its moment has come, the card waits for a calm one (`Moment.calm`: no meeting, call, break or drift, and the
/// companion on show on this desktop), so a card due during a call shows after it. The plan is a value with no clock of
/// its own: it reads the time from each `Moment`, so the rules are tested on a fake clock.
public struct DayCountedPlan: Sendable {
    public struct Rules: Sendable, Equatable {
        /// Work winds down from 4 pm.
        public var windDownHour = 16
        /// 7 pm while you're at the Mac.
        public var eveningHour = 19
        /// Away this long after 4 pm.
        public var awaySeconds: TimeInterval = 30 * 60
        /// Only a day with this many focused minutes.
        public var minimumMinutes = 20
        /// Yesterday's card, missed, shows the next morning until noon; then it's let go.
        public var morningEndsHour = 12
        /// Idle under this, the person is at the Mac (7 pm, and the morning's card).
        public var presentSeconds: TimeInterval = 120
        /// Idle this long, the person has stepped away (the time counts as away from the last input).
        public var stepAwaySeconds: TimeInterval = 60
        /// Moku ticks every second while the Mac is awake: ticks this far apart mean it slept in between.
        public var sleepGapSeconds: TimeInterval = 60
        public static let standard = Rules()
    }

    /// What's kept across launches (in the app's UserDefaults).
    public struct Memory: Codable, Sendable, Equatable {
        /// The day followed (YYYY-MM-DD) and its focused minutes as last seen.
        public var day: String?
        public var minutes: Int
        /// Days whose card has been shown, or let go (too small, or the morning over), the last few.
        public var done: [String]
        public init(day: String? = nil, minutes: Int = 0, done: [String] = []) {
            self.day = day; self.minutes = minutes; self.done = done
        }
        public static let defaultsKey = "MokuMind.dayCounted"
        public static func load(from defaults: UserDefaults) -> Memory {
            defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Memory.self, from: $0) } ?? Memory()
        }
        public func save(to defaults: UserDefaults) {
            if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
        }
    }

    /// Why a card came due, for app.log.
    public enum Reason: String, Sendable {
        case away, evening, quit, morning
    }

    public struct Card: Sendable, Equatable {
        /// The day it's for (YYYY-MM-DD).
        public var day: String
        /// The morning after: "Yesterday counted".
        public var yesterday: Bool
        public var reason: Reason
    }

    /// What's true at a tick.
    public struct Moment: Sendable {
        public var now: Date
        /// Today's focused minutes as the world last said; nil until it has.
        public var focusedMinutes: Int?
        /// Seconds since the last key, click or pointer move anywhere on the Mac.
        public var idleSeconds: TimeInterval
        /// Nothing in the way: no meeting, call, break or drift, and the companion on show on this desktop.
        public var calm: Bool
        public init(now: Date, focusedMinutes: Int?, idleSeconds: TimeInterval, calm: Bool) {
            self.now = now; self.focusedMinutes = focusedMinutes; self.idleSeconds = idleSeconds; self.calm = calm
        }
    }

    public private(set) var memory: Memory
    public let rules: Rules
    public let calendar: Calendar
    private var lastTick: Date?
    /// Since when the person has been away (the last input, or the last tick before the Mac slept); nil while they're here.
    private var awaySince: Date?
    /// Today's card, once its moment has come: it waits for a calm moment.
    private(set) var pending: Card?
    /// Yesterday's, when it ended without one: it waits for the person this morning.
    private(set) var missed: String?

    public init(memory: Memory = Memory(), rules: Rules = .standard, calendar: Calendar = .current) {
        self.memory = memory; self.rules = rules; self.calendar = calendar
    }

    /// The card to show now, if any. Call it every tick: it follows the day, the person's comings and goings and the
    /// Mac's sleep, and returns the same card on each calm tick until `settled` says it's shown or let go.
    public mutating func check(_ moment: Moment) -> Card? {
        let now = moment.now, today = key(now)
        let slept = lastTick.map { now.timeIntervalSince($0) >= rules.sleepGapSeconds } ?? false
        if slept, let lastTick { awaySince = min(awaySince ?? lastTick, lastTick) } else if moment.idleSeconds < rules.stepAwaySeconds { awaySince = nil }
        if moment.idleSeconds >= rules.stepAwaySeconds { awaySince = min(awaySince ?? .distantFuture, now.addingTimeInterval(-moment.idleSeconds)) }
        lastTick = now

        if memory.day != today { turn(to: today, now: now) }
        if let minutes = moment.focusedMinutes { memory.minutes = minutes }

        // Yesterday's, this morning, once the person's here; past noon it's let go.
        if let missed {
            if hour(now) >= rules.morningEndsHour { settled(missed) }
            else if moment.idleSeconds < rules.presentSeconds && moment.calm { return Card(day: missed, yesterday: true, reason: .morning) }
        }
        // Today's: its moment comes once, then waits for calm.
        if pending == nil, counts(today), let windDown = at(rules.windDownHour, on: now), now >= windDown {
            if let awaySince, now.timeIntervalSince(max(awaySince, windDown)) >= rules.awaySeconds {
                pending = Card(day: today, yesterday: false, reason: .away)
            } else if let evening = at(rules.eveningHour, on: now), now >= evening, moment.idleSeconds < rules.presentSeconds {
                pending = Card(day: today, yesterday: false, reason: .evening)
            }
        }
        return moment.calm ? pending : nil
    }

    /// Quitting Moku: today's card, when it's after 4 pm on a day that counted and the card hasn't been.
    public func dueOnQuit(now: Date) -> Card? {
        let today = key(now)
        guard memory.day == today, counts(today), let windDown = at(rules.windDownHour, on: now), now >= windDown else { return nil }
        return Card(day: today, yesterday: false, reason: .quit)
    }

    /// The day's card was shown, or let go (the brain said the day was too small): never again for that day.
    public mutating func settled(_ day: String) {
        if !memory.done.contains(day) { memory.done = Array((memory.done + [day]).suffix(7)) }
        if pending?.day == day { pending = nil }
        if missed == day { missed = nil }
    }

    // MARK: Days

    /// A new day: yesterday, if it counted and had no card, waits for the morning; anything older is let go.
    private mutating func turn(to today: String, now: Date) {
        if let day = memory.day, day == yesterday(of: now), memory.minutes >= rules.minimumMinutes, !memory.done.contains(day) {
            missed = day
        } else {
            missed = nil
        }
        pending = nil
        memory.day = today; memory.minutes = 0
    }

    private func counts(_ day: String) -> Bool { memory.minutes >= rules.minimumMinutes && !memory.done.contains(day) }
    func key(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    private func yesterday(of date: Date) -> String {
        calendar.date(byAdding: .day, value: -1, to: date).map(key) ?? ""
    }
    private func hour(_ date: Date) -> Int { calendar.component(.hour, from: date) }
    private func at(_ hour: Int, on date: Date) -> Date? { calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) }
}

/// The app's "Today counted": the plan, where its memory is kept, and how idle the Mac is. The runtime ticks it
/// (CompanionRuntime.checkDayCounted) and shows the card through the world presenter.
@MainActor
public final class DayCountedSchedule {
    public internal(set) var plan: DayCountedPlan
    let idleSeconds: @MainActor () -> TimeInterval
    let save: @MainActor (DayCountedPlan.Memory) -> Void
    /// Set by the app: a card went up (or said goodbye), for app.log.
    public var onShown: (@MainActor (DayCountedPlan.Card, TodaySummary) -> Void)?
    /// Asking the brain or putting the card up: nothing else starts meanwhile.
    var busy = false
    /// The card couldn't go up (the companion out of sight, the brain away): not before this.
    var notBefore: Date?
    /// The engine's phase at the last tick: a meeting starting takes the card away.
    var lastPhase: BehaviorEngine.Status.Phase?

    public init(memory: DayCountedPlan.Memory, rules: DayCountedPlan.Rules = .standard, calendar: Calendar = .current,
                idleSeconds: @escaping @MainActor () -> TimeInterval, save: @escaping @MainActor (DayCountedPlan.Memory) -> Void) {
        plan = DayCountedPlan(memory: memory, rules: rules, calendar: calendar)
        self.idleSeconds = idleSeconds; self.save = save
    }

    /// Runs `change` on the plan and saves its memory when that changed.
    func update<T>(_ change: (inout DayCountedPlan) -> T) -> T {
        let before = plan.memory
        let result = change(&plan)
        if plan.memory != before { save(plan.memory) }
        return result
    }
}

extension CompanionRuntime {
    /// The phases in which the card may go up: not a meeting, a break or a drift.
    static let dayCountedPhases: Set<BehaviorEngine.Status.Phase> = [.settling, .focused, .away]

    /// Every tick: a meeting starting takes the card away, and a card that's due goes up at a calm moment, with the
    /// day as Your day has it (the brain's cached day: no model call). A day the brain says is under 20 minutes is let go.
    func checkDayCounted(now: Date) {
        guard let schedule = dayCounted else { return }
        let phase = engine.status.phase
        if phase == .meeting && schedule.lastPhase != .meeting { presenter.closeDayCounted() }
        schedule.lastPhase = phase
        let calm = rehearsal == nil && Self.dayCountedPhases.contains(phase) && presenter.canShowDayCounted
        let moment = DayCountedPlan.Moment(now: now, focusedMinutes: worldLoaded ? worldModel.snapshot.todayFocusMinutes : nil,
                                           idleSeconds: schedule.idleSeconds(), calm: calm)
        let missedBefore = schedule.plan.missed
        let due = schedule.update { $0.check(moment) }
        // Yesterday's card, never shown, let go at noon: `day_card` missed.
        if missedBefore != nil, schedule.plan.missed == nil, due == nil {
            usage?("day_card", ["what": .word("missed"), "yesterday": .bool(true), "farewell": .bool(false)])
        }
        guard let card = due, !schedule.busy, schedule.notBefore.map({ now >= $0 }) ?? true else { return }
        schedule.busy = true
        track {
            defer { schedule.busy = false }
            let date = card.yesterday ? schedule.plan.calendar.date(byAdding: .day, value: -1, to: now) : nil
            guard let summary = try? await self.brain.todayCached(date: date), summary.date == card.day else {
                schedule.notBefore = self.clock.now().addingTimeInterval(120)
                return
            }
            guard summary.focusedMinutes >= schedule.plan.rules.minimumMinutes else { schedule.update { $0.settled(card.day) }; return }
            // The brain took a moment: still nothing in the way?
            guard !self.isManualControl, Self.dayCountedPhases.contains(self.engine.status.phase),
                  await self.presenter.showDayCounted(summary, yesterday: card.yesterday) else {
                schedule.notBefore = self.clock.now().addingTimeInterval(60)
                return
            }
            schedule.update { $0.settled(card.day) }
            schedule.onShown?(card, summary)
        }
    }

    /// Moku is quitting from its own menu: the day's card says goodbye first when it's due (after 4 pm, on a day that
    /// counted and has had no card, not in a meeting), and this returns once it's gone. The brain gets 1.5 s to answer.
    /// (Whether the companion is in view is the presenter's to say: quitting from the popover closes it first.)
    public func sayGoodbye() async {
        guard let schedule = dayCounted, !isManualControl, engine.status.phase != .meeting,
              let card = schedule.plan.dueOnQuit(now: clock.now()) else { return }
        let brain = self.brain
        let summary = await withTaskGroup(of: TodaySummary?.self) { group in
            group.addTask { try? await brain.todayCached(date: nil) }
            group.addTask { try? await Task.sleep(for: .seconds(1.5)); return nil }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
        guard let summary, summary.date == card.day, summary.focusedMinutes >= schedule.plan.rules.minimumMinutes,
              await presenter.sayGoodbyeWithDayCounted(summary) else { return }
        schedule.update { $0.settled(card.day) }
        schedule.onShown?(card, summary)
    }
}
