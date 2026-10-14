import AppKit
import Foundation
import SwiftUI
import Testing
import MokuKit
@testable import MokuVisual

@MainActor @Test func forestNeverShrinksOrAcceptsInvalidGrowth() {
    let state = ForestPresentation(); state.ingest(700); state.ingest(10); state.ingest(.nan)
    #expect(state.points == 700)
    state.ingest(4200); #expect(ForestStage.at(points: state.points) == .forest)
}
@Test func placementClampsSideDockAndSmallDisplays() {
    let safe = CGRect(x: 82, y: -900, width: 1000, height: 760)
    let point = StageGeometry.clamped(CGPoint(x: -1000, y: 10000), to: safe, scale: 1)
    // As high as the head can go: `edgePadding` under the top (the empty panel above it may run past).
    #expect(point.x == StageGeometry.originsX(in: safe, scale: 1).lowerBound && point.y == safe.maxY - StageGeometry.edgePadding - StageGeometry.headTop)
    // Too narrow for the bunny: its body keeps the padding from the left side.
    let tiny = CGRect(x: 0, y: 0, width: 80, height: 80)
    let pinned = StageGeometry.clamped(CGPoint(x: 50, y: 50), to: tiny, scale: 1)
    #expect(pinned.x + StageGeometry.characterFrame.midX - StageGeometry.bodyLeft == tiny.minX + StageGeometry.edgePadding && pinned.y == 0)
}
/// The 2026-09-28 audit: at home Moku sat where a hidden Dock slides out. It keeps clear of the Dock as shown.
@Test func mokuKeepsClearOfAHiddenDock() {
    let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
    // A Dock that stays shown is already out of the visible frame, and no Dock on this display leaves nothing out.
    let shown = CGRect(x: 0, y: 73, width: 1470, height: 850), none = CGRect(x: 0, y: 0, width: 1470, height: 923)
    #expect(StageGeometry.clearOfHiddenDock(visible: shown, screen: screen, dockTile: 52) == shown)
    #expect(StageGeometry.clearOfHiddenDock(visible: none, screen: screen, dockTile: 52) == none)
    // Hidden at the bottom, the left or the right: only a sliver is out, so the shown Dock's room is kept clear.
    let bottom = StageGeometry.clearOfHiddenDock(visible: CGRect(x: 0, y: 4, width: 1470, height: 919), screen: screen, dockTile: 52)
    #expect(bottom == CGRect(x: 0, y: 73, width: 1470, height: 850))
    #expect(StageGeometry.home(in: bottom, scale: 1).y == 79)
    let left = StageGeometry.clearOfHiddenDock(visible: CGRect(x: 4, y: 0, width: 1466, height: 923), screen: screen, dockTile: 52)
    #expect(left == CGRect(x: 73, y: 0, width: 1397, height: 923))
    let right = StageGeometry.clearOfHiddenDock(visible: CGRect(x: 0, y: 0, width: 1466, height: 923), screen: screen, dockTile: 52)
    #expect(right == CGRect(x: 0, y: 0, width: 1397, height: 923))
}
/// The 2026-09-28 audit: Moku's wave took its ear past the screen's side at home. By a side it scoots in for it.
@Test func theWaveScootsInFromTheSidesJustEnough() {
    let visible = CGRect(x: 0, y: 40, width: 1470, height: 880), size = StageGeometry.panelSize(scale: 1)
    func panel(_ origin: CGPoint) -> CGRect { CGRect(origin: origin, size: size) }
    let home = panel(StageGeometry.home(in: visible, scale: 1))
    // Moku's ear reaches 81 pt right of its centre: 21 pt left keeps it `edgePadding` inside. Tetsu needs a point.
    #expect(StageGeometry.roomToWave(panel: home, visible: visible, reach: Companion.moku.waveReach) == -21)
    #expect(StageGeometry.roomToWave(panel: home, visible: visible, reach: Companion.tetsu.waveReach) == -1)
    // At the left side its raised paw needs 30 pt to the right; in the middle of the screen nothing moves.
    let left = panel(CGPoint(x: StageGeometry.originsX(in: visible, scale: 1).lowerBound, y: 46))
    #expect(StageGeometry.roomToWave(panel: left, visible: visible, reach: Companion.moku.waveReach) == 30)
    #expect(StageGeometry.roomToWave(panel: panel(CGPoint(x: 600, y: 46)), visible: visible, reach: Companion.moku.waveReach) == 0)
}
@MainActor @Test func silhouetteMatchesTransformedParts() {
    let puppet = PlushPuppet()
    #expect(puppet.contains(CGPoint(x: 80, y: 85)))
    #expect(!puppet.contains(CGPoint(x: 5, y: 5)))
    #expect(!puppet.contains(CGPoint(x: 80, y: 150))) // between ears
    puppet.head.setAffineTransform(CGAffineTransform(translationX: 15, y: 0))
    #expect(puppet.contains(CGPoint(x: 95, y: 85)))
}
@Test func aStoneSaysHowLongTheDriftReallyWas() {
    let glance = StoneMemory(id: "a", ts: Date(), driftSeconds: 4, from: "WhatsApp", followingFocusMinutes: 15)
    let wander = StoneMemory(id: "b", ts: Date(), driftSeconds: 130, from: "YouTube", followingFocusMinutes: 20)
    #expect(stoneText(glance).contains("back from WhatsApp after 4 s · then 15 min"))
    #expect(stoneText(wander).contains("back from YouTube after 2 min · then 20 min"))
}
@Test func theRehearsalPanelShowsWordsNotCodeNames() {
    #expect(ManualControls.words("longDrift") == "Long drift")
    #expect(ManualControls.words("patReaction") == "Pat reaction")
    #expect(ManualControls.words("idle") == "Idle")
}

@Test @MainActor func theDayPickerStaysBetweenTheFirstDayAndToday() {
    let model = TodayModel(), calendar = Calendar.current, today = calendar.startOfDay(for: Date())
    func days(_ n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: today)! }
    #expect(model.isToday && !model.canGoForward && model.canGoBack)
    #expect(model.clamped(days(3)) == today)                      // never after today
    model.firstDay = days(-5)
    #expect(model.clamped(days(-9)) == days(-5))                  // never before the first day with data
    model.day = days(-5); #expect(!model.canGoBack && model.canGoForward && !model.isToday)
    // The strip shows seven days, three past the chosen one where it can, never after today.
    #expect(model.stripRange(for: days(-10)) == (days(-13), days(-7)))
    #expect(model.stripRange(for: days(-1)) == (days(-6), today))
    #expect(TodayModel.key(TodayModel.date("2026-09-23")!) == "2026-09-23" && TodayModel.date("nope") == nil)
}

// Your day by task: the words under each card.
@Test func aTasksHoursStepsAndComebacksReadPlainly() {
    var calendar = Calendar(identifier: .gregorian); calendar.locale = Locale(identifier: "en_US"); calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    func at(_ h: Int, _ m: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: h, minute: m))! }
    var goal = GoalDay(id: "g", title: "building Moku’s settings", minutes: 96, firstAt: at(10, 12), lastAt: at(12, 40))
    #expect(TodayModel.hours(goal, calendar: calendar).replacingOccurrences(of: "\u{202F}", with: " ") == "10:12 AM–12:40 PM")
    goal.firstAt = at(14, 5); goal.lastAt = at(15, 10); goal.sittings = 3
    #expect(TodayModel.hours(goal, calendar: calendar).replacingOccurrences(of: "\u{202F}", with: " ") == "2:05–3:10 PM, on and off")
    #expect(TodayModel.stepsLine(["edited Today.swift", "ran swift test"]) == "Edited Today.swift · ran swift test")
    #expect(TodayModel.stepsLine(["iPhone notes in Notes"]) == "iPhone notes in Notes" && TodayModel.stepsLine(["lib.rs in Zed"]) == "lib.rs in Zed")
    #expect(TodayModel.stepsLine([]) == nil)
    #expect(TodayModel.cameBack(goal) == nil)
    goal.detours = 1; goal.detourMinutes = 3; #expect(TodayModel.cameBack(goal) == "Came back once, 3m away")
    goal.detours = 2; goal.detourMinutes = 71; #expect(TodayModel.cameBack(goal) == "Came back 2 times, 1h 11m away")
}

@Test @MainActor func theWorkflowRowFollowsTheBrainAndTheCorrections() {
    let cursor = GoalApp(app: "Cursor", bundleId: "c", minutes: 58), ghostty = GoalApp(app: "Ghostty", bundleId: "g", minutes: 22)
    let docs = GoalApp(app: "Chrome", bundleId: "b", host: "docs.stripe.com", name: "Stripe docs", minutes: 16)
    let goal = GoalDay(id: "g1", title: "settings", minutes: 96, apps: [cursor, ghostty, docs],
                       workflow: [.app("app:c", 58), .detour("YouTube", 8), .app("app:g", 22), .app("site:docs.stripe.com", 16)])
    func shape(_ row: WorkflowRow) -> [String] { row.links.map { $0.app?.name ?? "↩ \($0.step.place ?? "")" } }
    #expect(shape(WorkflowRow(goal: goal, apps: goal.apps)) == ["Cursor", "↩ YouTube", "Ghostty", "Stripe docs"])
    // "Cursor wasn't work": it leaves the row, and a detour with no app before it goes too.
    #expect(shape(WorkflowRow(goal: goal, apps: [ghostty, docs])) == ["Ghostty", "Stripe docs"])
    // A brain from before the workflow: the apps, longest first.
    var old = goal; old.workflow = []
    #expect(shape(WorkflowRow(goal: old, apps: old.apps)) == ["Cursor", "Ghostty", "Stripe docs"])
    let many = (0..<6).map { GoalApp(app: "App \($0)", bundleId: "b\($0)", minutes: 10 - $0) }
    var wide = goal; wide.apps = many; wide.workflow = many.prefix(4).map { .app($0.id, $0.minutes) }
    #expect(WorkflowRow(goal: wide, apps: many).more == 2)
}

/// One behaviour for everyone (Charles, 2026-10-04: "there should be no calm, etc behaviours, there should be just one
/// behaviour"). Someone who had saved Calm or Lively gets Normal's values and keeps everything else they set.
@Test func savedLivelinessIsClearedAndNothingElseIs() {
    let suite = "MokuVisualTests.retired.\(UUID().uuidString)"
    let store = UserDefaults(suiteName: suite)!
    defer { store.removePersistentDomain(forName: suite) }
    store.set(45.0, forKey: "MokuVisual.earFlickEvery"); store.set(60.0, forKey: "MokuVisual.fidgetEvery")  // Calm
    store.set(0.75, forKey: MokuPreferences.sizeKey); store.set("tetsu", forKey: CompanionChoice.key)
    store.set(true, forKey: MokuPreferences.hiddenKey); store.set(12.0, forKey: MokuPreferences.captionGapKey)
    store.set(true, forKey: "Moku.loginItemOffered"); store.set(true, forKey: "onboardingCompleted")
    MokuPreferences.retireBehaviourChoices(in: store)
    #expect(MokuPreferences.retiredKeys.allSatisfy { store.object(forKey: $0) == nil })
    #expect(MokuPreferences.setting(in: store) == 0.75 && store.string(forKey: CompanionChoice.key) == "tetsu")
    #expect(store.bool(forKey: MokuPreferences.hiddenKey) && store.double(forKey: MokuPreferences.captionGapKey) == 12)
    #expect(store.bool(forKey: "Moku.loginItemOffered") && store.bool(forKey: "onboardingCompleted"))
    MokuPreferences.retireBehaviourChoices(in: store)  // a second launch finds nothing, and changes nothing
    #expect(MokuPreferences.setting(in: store) == 0.75)
    // Lively (10 s, 12 s) is cleared too; what's left is the one behaviour, Normal's.
    store.set(10.0, forKey: "MokuVisual.earFlickEvery"); store.set(12.0, forKey: "MokuVisual.fidgetEvery")
    MokuPreferences.retireBehaviourChoices(in: store)
    #expect(MokuPreferences.earFlickEvery == 20 && MokuPreferences.fidgetEvery == 25)
}

/// Settings has no behaviour to choose: no liveliness picker, no drift pace, no custom minutes and no smile frequency,
/// and no paragraph about it either (Charles, 2026-10-04: "remove this part from settings").
@MainActor @Test func settingsHasNoBehaviourChoices() async throws {
    let model = SettingsModel()
    let shown = Mirror(reflecting: model).children.compactMap(\.label)
    #expect(!shown.contains { $0.lowercased().contains("drift") || $0.lowercased().contains("liveli") || $0.lowercased().contains("pace") }, "\(shown)")
    // A patch can carry the name, the companion and Breaks & Water, and no behaviour timing.
    let fields = Mirror(reflecting: CompanionConfigPatch()).children.compactMap(\.label).sorted()
    #expect(fields == ["breakAfterSec", "companion", "drinkEverySec", "teaBreakMaxSec", "userName"])
    // Settings' three tabs, and General builds.
    #expect(SettingsTab.allCases.map(\.title) == ["General", "Breaks & Water", "Privacy"])
    let general = NSHostingView(rootView: SettingsTab.general.view(model)); general.frame.size = general.fittingSize
    #expect(general.frame.width > 0 && general.frame.height > 0)
}

/// The menu bar icon opens the popover and nothing else (Charles, 2026-10-06: "make it very very predictable").
@MainActor @Test func theIconBringsForwardOnlyThePopover() {
    let settings = MokuWorldPresenter.WindowFacts(visible: true, companion: false, level: NSWindow.Level.normal.rawValue, excepted: false)
    let alert = MokuWorldPresenter.WindowFacts(visible: true, companion: false, level: NSWindow.Level.modalPanel.rawValue, excepted: false)
    // Behind another app: Settings and an alert would come forward with the activation, so they stay behind.
    #expect(MokuWorldPresenter.keepsBehind(settings, appActive: false))
    #expect(MokuWorldPresenter.keepsBehind(alert, appActive: false))
    // Moku already in front: nothing moves.
    #expect(!MokuWorldPresenter.keepsBehind(settings, appActive: true))
    // Never the companion, the icon, a closed window or anything above alerts (menus, the popover).
    #expect(!MokuWorldPresenter.keepsBehind(.init(visible: true, companion: true, level: NSWindow.Level.statusBar.rawValue, excepted: false), appActive: false))
    #expect(!MokuWorldPresenter.keepsBehind(.init(visible: true, companion: false, level: NSWindow.Level.statusBar.rawValue, excepted: true), appActive: false))
    #expect(!MokuWorldPresenter.keepsBehind(.init(visible: false, companion: false, level: 0, excepted: false), appActive: false))
    #expect(!MokuWorldPresenter.keepsBehind(.init(visible: true, companion: false, level: NSWindow.Level.popUpMenu.rawValue, excepted: false), appActive: false))
}


/// Delete my data: Your day forgets the days it was keeping, so going back to yesterday asks the brain again (it has
/// nothing now) instead of showing what was deleted. The window is never shown here.
@MainActor @Test func deletingTheDataForgetsTheDaysYourDayKept() async {
    final class Asked { var days: [Date?] = [] }
    let asked = Asked()
    let today = TodayPresenter(world: WorldModel(), provider: { date in
        asked.days.append(date)
        return TodaySummary(date: date.map(TodayModel.key) ?? TodayModel.key(Date()), note: "kept", focusedMinutes: 30, longestFocusMinutes: 30,
                            returns: 0, unitsToday: 3, segments: [], built: [], wandered: [], quickCheckMinutes: 0, comebacks: [],
                            bestComeback: nil, completions: [])
    }, correction: { _, _ in })
    let todayStart = Calendar.current.startOfDay(for: Date()), yesterday = todayStart.addingTimeInterval(-86_400)
    func settle() async { for _ in 0..<100 where today.model.loading { try? await Task.sleep(for: .milliseconds(10)) } }
    today.select(yesterday); await settle()
    today.select(todayStart); await settle()
    today.select(yesterday); await settle()
    #expect(asked.days.filter { $0 != nil }.count == 1)  // a finished day is asked for once while it's kept
    today.forgetShownDays()
    today.select(todayStart); await settle()
    today.select(yesterday); await settle()
    #expect(asked.days.filter { $0 != nil }.count == 2)  // forgotten: asked again
}

/// Your day says what the popover says (Charles, 2026-10-06: the popover 3h 30m and 9 returns, Your day 2h 51m and 6,
/// the day as it was when the window first opened). Opened again while it's open, it asks for today again; and while it
/// shows today, the world's minutes moving bring the day again. Neither shows "A moment with your day…" over the numbers.
/// The window is never shown here.
@MainActor @Test func yourDayKeepsUpWithTheDayWhileItsOpen() async {
    final class Day { var minutes = 171; var returns = 6; var asked = 0; var loadingSeen = false }
    let day = Day()
    let world = WorldModel()
    let today = TodayPresenter(world: world, provider: { date in
        day.asked += 1
        return TodaySummary(date: TodayModel.key(Date()), note: nil, focusedMinutes: day.minutes, longestFocusMinutes: 42,
                            returns: day.returns, unitsToday: day.minutes / 10, segments: [], built: [], wandered: [], quickCheckMinutes: 0,
                            comebacks: [], bestComeback: nil, completions: [])
    }, correction: { _, _ in })
    today.showing = { true }
    today.refreshGap = 0.2
    func shows(_ minutes: Int) async -> Bool {
        for _ in 0..<150 {
            if today.model.summary != nil && today.model.loading { day.loadingSeen = true }
            if today.model.summary?.focusedMinutes == minutes { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
    today.select(Calendar.current.startOfDay(for: Date()))
    #expect(await shows(171))
    // Later the popover says 3h 30m: Your day, opened again from it, says so too.
    day.minutes = 210; day.returns = 9
    today.openedAgain()
    #expect(await shows(210))
    #expect(today.model.summary?.returns == 9)
    // Left open while you work: the world's minutes move, and so does the day.
    day.minutes = 211
    world.snapshot.todayFocusMinutes = 211
    #expect(await shows(211))
    #expect(!day.loadingSeen)  // the numbers change in place, no spinner over them
}

/// The popover's "···" needed two clicks (Charles, 2026-10-08: "the first time it vanishes instantly"). It was a SwiftUI
/// Menu, which closes when Moku becomes active a moment after the popover opened, or when the popover redraws as its
/// fresh numbers arrive. It's an AppKit menu now, popped up under the button by the presenter, apart from the view's
/// redraws, with the same items as before.
@MainActor @Test func theMoreButtonsMenuHasTheRestOfTheControls() {
    var done: [HomeAction] = []
    let menu = MokuWorldPresenter.moreMenu(onBreak: false, name: "Moku") { done.append($0) }
    #expect(menu.items.map { $0.isSeparatorItem ? "—" : $0.title } == ["Say hi again", "Put Moku back in the corner", "—", "Send feedback…", "—", "Quit Moku"])
    // The item's own action, as AppKit sends it (performActionForItem goes through NSApp, which tests in parallel may not
    // have made yet: it passed and failed by turns).
    if let item = menu.items.first, let action = item.action { _ = (item.target as AnyObject?)?.perform(action, with: item) }
    #expect(done == [.hi])
}

/// The friends, 2026-10-14: "cuteness wins". What Settings calls 1× draws the companion at 87% of the old 1×; every saved
/// size keeps its number, so everyone's companion is 13% smaller.
@Test func settingsOneTimesIsEightySevenPercentOfTheOldSize() {
    let suite = "MokuVisualTests.size.\(UUID().uuidString)"
    let store = UserDefaults(suiteName: suite)!
    defer { store.removePersistentDomain(forName: suite) }
    #expect(MokuPreferences.setting(in: store) == 1)
    #expect(MokuPreferences.size(in: store) == 0.87)
    store.set(1.25, forKey: MokuPreferences.sizeKey)
    #expect(abs(MokuPreferences.size(in: store) - 1.0875) < 0.0001)
    store.set(0.1, forKey: MokuPreferences.sizeKey)  // below the slider's least: clamped first
    #expect(abs(MokuPreferences.size(in: store) - 0.2175) < 0.0001)
}
