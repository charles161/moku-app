import Foundation
import Testing
import MokuKit
@testable import MokuVisual

/// Your day's numbers agree wherever it shows them (Charles, 2026-10-06: "completely wrong metrics bruh"): the header said
/// 4h 3m, the week strip "Tue 2h 51m" and the tasks "8 tasks, 2h 59m". The brain's audit (numbers_agree_test.go) makes
/// its views add up; here, what the window does with them, and the check it sends when they still don't.
@MainActor @Suite("Your day's numbers agree")
struct NumbersAgreeTests {
    func day(_ minutes: Int, goals: [GoalDay] = [], built: [ActivityRow] = [], units: Int? = nil) -> TodaySummary {
        TodaySummary(date: TodayModel.key(Date()), note: nil, focusedMinutes: minutes, longestFocusMinutes: 48, returns: 9, unitsToday: units ?? minutes / 10,
                     segments: [], built: built, wandered: [], quickCheckMinutes: 0, comebacks: [], bestComeback: nil, completions: [], goals: goals)
    }
    func row(_ id: String, _ minutes: Int) -> ActivityRow { ActivityRow(id: id, app: "Cursor", bundleId: "c", activity: id, minutes: minutes, segmentIds: [id]) }

    @Test func theStripShowsTheDayOnShowAsItsHeaderDoes() {
        let model = TodayModel()
        model.strip = [DayTotals(date: "2026-10-05", focusedMinutes: 100), DayTotals(date: TodayModel.key(Date()), focusedMinutes: 171, longestFocusMinutes: 30, returns: 6, pieces: 17)]
        model.summary = day(243)
        let today = model.shownStrip.last
        #expect(today?.focusedMinutes == 243 && today?.longestFocusMinutes == 48 && today?.returns == 9 && today?.pieces == 24)
        #expect(model.shownStrip.first?.focusedMinutes == 100)  // other days as loaded
    }

    @Test func theTasksLineCountsOtherWorkToo() {
        let goals = [GoalDay(id: "g1", title: "settings", minutes: 120), GoalDay(id: "g2", title: "design", minutes: 59), GoalDay(id: "other", title: "Other work", minutes: 64)]
        #expect(TodayView.tasksHeading(day(243, goals: goals)) == "WHAT YOU WORKED ON · 2 tasks and other work, 4h 3m")
        #expect(TodayView.tasksHeading(day(179, goals: Array(goals.prefix(2)))) == "WHAT YOU WORKED ON · 2 tasks, 2h 59m")
        #expect(TodayView.tasksHeading(day(0)) == "WHAT YOU WORKED ON")
    }

    @Test func theCheckNamesEachPairThatDisagrees() {
        let goals = [GoalDay(id: "g1", title: "settings", minutes: 179)]
        let agreeing = day(179, goals: goals, built: [row("a", 120), row("b", 59)])
        #expect(NumbersCheck.disagreements(agreeing, popover: 178).isEmpty)  // the popover may be a minute behind
        #expect(NumbersCheck.disagreements(agreeing, popover: nil).isEmpty)  // no world yet: nothing to compare
        let wrong = day(243, goals: goals, built: [row("a", 120)], units: 30)
        #expect(NumbersCheck.disagreements(wrong, popover: 210) == [
            .init(views: "tasks_header", gap: 64), .init(views: "rows_header", gap: 123), .init(views: "house_header", gap: 6), .init(views: "popover_header", gap: 33)])
    }

    @Test func yourDaySendsADisagreementOncePerDay() async {
        let world = WorldModel()
        world.snapshot.todayFocusMinutes = 210
        var sent: [(String, [String: UsageValue])] = []
        let shown = day(243, goals: [GoalDay(id: "g1", title: "settings", minutes: 243)], built: [row("a", 243)])
        let today = TodayPresenter(world: world, provider: { _ in shown }, correction: { _, _ in })
        today.track = { name, props in sent.append((name, props)) }
        today.select(Calendar.current.startOfDay(for: Date()))
        for _ in 0..<100 where today.model.summary == nil { try? await Task.sleep(for: .milliseconds(10)) }
        today.refreshToday()
        try? await Task.sleep(for: .milliseconds(100))
        let disagreements = sent.filter { $0.0 == "numbers_disagree" }
        #expect(disagreements.count == 1)
        #expect(disagreements.first?.1 == ["views": .word("popover_header"), "gap_minutes": .int(33)])
    }

    @Test func yourDayOpenedBeforeTheFirstWorldSendsNothing() async {
        let world = WorldModel()  // just after launch: the brain hasn't answered yet
        var sent: [String] = []
        let shown = day(243, goals: [GoalDay(id: "g1", title: "settings", minutes: 243)], built: [row("a", 243)])
        let today = TodayPresenter(world: world, provider: { _ in shown }, correction: { _, _ in })
        today.track = { name, _ in sent.append(name) }
        today.select(Calendar.current.startOfDay(for: Date()))
        for _ in 0..<100 where today.model.summary == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(today.model.summary != nil && !sent.contains("numbers_disagree"))
    }
}
