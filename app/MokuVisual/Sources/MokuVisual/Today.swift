import AppKit
import SwiftUI
import Observation
import MokuKit

@MainActor @Observable final class TodayModel {
    var summary: TodaySummary?
    /// Folded parts opened since the window opened (an app's lines, the small things, every app): `day_closed`.
    @ObservationIgnored var expanded = 0
    var loading = false
    var unavailable = false
    var corrections: [String:Bool] = [:]
    var correctionNote: String?
    /// The day on show (local midnight), today by default.
    var day = Calendar.current.startOfDay(for: Date())
    /// The strip of days: each day's totals, oldest first, and the first day with any data.
    var strip: [DayTotals] = []
    /// The week strip as shown: the day on show carries its header's numbers, so the two can't disagree (a strip loaded
    /// earlier said "Tue 2h 51m" under a header of 4h 3m, 2026-10-06).
    var shownStrip: [DayTotals] {
        guard let summary else { return strip }
        return strip.map { day in
            guard day.date == summary.date else { return day }
            var day = day
            day.focusedMinutes = summary.focusedMinutes; day.longestFocusMinutes = summary.longestFocusMinutes
            day.returns = summary.returns; day.pieces = summary.unitsToday
            return day
        }
    }
    var firstDay: Date?
    var isToday: Bool { Calendar.current.isDateInToday(day) }
    var dayKey: String { Self.key(day) }
    var canGoBack: Bool { firstDay.map { day > $0 } ?? true }
    var canGoForward: Bool { !isToday }
    /// A day moved into range: never after today, never before the first day with data.
    func clamped(_ date: Date) -> Date {
        let calendar = Calendar.current, today = calendar.startOfDay(for: Date())
        var chosen = min(calendar.startOfDay(for: date), today)
        if let firstDay { chosen = max(chosen, firstDay) }
        return chosen
    }
    /// The seven days the strip shows: ending three days after the chosen one, but never after today.
    func stripRange(for date: Date) -> (from: Date, to: Date) {
        let calendar = Calendar.current, today = calendar.startOfDay(for: Date())
        let end = min(today, calendar.date(byAdding: .day, value: 3, to: date) ?? date)
        return (calendar.date(byAdding: .day, value: -6, to: end) ?? end, end)
    }
    nonisolated static func key(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    nonisolated static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
    /// The rows by app, or by website for pages in a browser (never under the browser): each with its total, the
    /// apps longest first and what was done in each longest first. Built from `rows`, so corrections move lines.
    func groups(work: Bool) -> [ActivityGroup] {
        var order: [String] = [], groups: [String: ActivityGroup] = [:]
        for row in rows(work: work) {
            let id = row.host.map { "site:\($0)" } ?? "app:\(row.bundleId)"
            if groups[id] == nil { order.append(id); groups[id] = ActivityGroup(id: id, name: row.host ?? row.app, bundleId: row.bundleId, host: row.host, browser: row.host == nil ? nil : row.app, rows: []) }
            groups[id]?.rows.append(row)
        }
        return order.compactMap { groups[$0] }.sorted { $0.minutes > $1.minutes }
    }
    func rows(work: Bool) -> [ActivityRow] {
        guard let summary else { return [] }
        return (summary.built.map { ($0,true) }+summary.wandered.map { ($0,false) }).filter { row,original in (corrections[row.id] ?? original) == work }.map(\.0).sorted { $0.minutes > $1.minutes }
    }
    /// Goals with a card of their own: at least 10 minutes, at most six, then "Other work" when it's as big. The rest
    /// fold into one "smaller things" card, so a day of many little threads doesn't become a wall.
    static let goalCardMinutes = 10, goalCards = 6
    var goalCards: [GoalDay] {
        guard let summary else { return [] }
        let real = summary.goals.filter { !$0.isOther && $0.minutes >= Self.goalCardMinutes }.prefix(Self.goalCards)
        let other = summary.goals.filter { $0.isOther && $0.minutes >= Self.goalCardMinutes }
        return Array(real) + other
    }
    var smallerGoals: [GoalDay] {
        let shown = Set(goalCards.map(\.id))
        return (summary?.goals ?? []).filter { !shown.contains($0.id) }
    }
    /// A task's hours, "10:12–12:40 PM" (the first time drops its AM or PM when both share it), and "on and off" when it
    /// was picked up in more than one sitting.
    nonisolated static func hours(_ goal: GoalDay,calendar: Calendar = .current) -> String {
        let style = Date.FormatStyle(date: .omitted,time: .shortened,locale: calendar.locale ?? .current,calendar: calendar,timeZone: calendar.timeZone)
        var from = goal.firstAt.formatted(style)
        let to = goal.lastAt.formatted(style)
        for symbol in [calendar.amSymbol,calendar.pmSymbol] where from.hasSuffix(symbol) && to.hasSuffix(symbol) {
            from = String(from.dropLast(symbol.count)).trimmingCharacters(in: .whitespaces)
        }
        return (from == to ? to : "\(from)–\(to)") + (goal.sittings > 1 ? ", on and off" : "")
    }
    /// The steps as one line: "Edited Today.swift · ran swift test". Only a first word in plain lowercase letters is
    /// capitalized (a verb Moku wrote), so "iPhone notes" and "lib.rs" stay as they are.
    nonisolated static func stepsLine(_ steps: [String]) -> String? {
        guard var line = steps.first else { return nil }
        if let word = line.split(separator: " ").first, word.allSatisfy({ $0.isLowercase && $0.isLetter }) { line = line.prefix(1).uppercased() + line.dropFirst() }
        return ([line] + steps.dropFirst()).joined(separator: " · ")
    }
    /// How you came back to a task: "Came back once, 3m away" or "Came back 2 times, 11m away"; nothing when it had
    /// no detours.
    nonisolated static func cameBack(_ goal: GoalDay) -> String? {
        switch goal.detours {
        case 0: return nil
        case 1: return "Came back once, \(minutesText(goal.detourMinutes)) away"
        default: return "Came back \(goal.detours) times, \(minutesText(goal.detourMinutes)) away"
        }
    }
    /// Apps marked "this wasn't work" from a goal card: hidden until the day is read again.
    var correctedApps: Set<String> = []
    func correct(goal: GoalDay,app: GoalApp,callback: ([String],Bool)->Void) {
        guard !app.segmentIds.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.3)) { _ = correctedApps.insert(goal.id+"|"+app.id) }
        callback(app.segmentIds,false); correctionNote = "Thanks. I’ll remember that."
    }
    func correct(_ row: ActivityRow,work: Bool,callback: ([String],Bool)->Void) { guard !row.segmentIds.isEmpty else { return }; withAnimation(.easeInOut(duration: 0.3)) { corrections[row.id] = work }; callback(row.segmentIds,work); correctionNote = "Thanks. I’ll remember that." }
}
@MainActor final class TodayPresenter: NSObject, NSWindowDelegate {
    let world: WorldModel
    let model = TodayModel()
    let scene = HomeScene()
    let window: NSWindow
    let provider: @MainActor (Date?) async -> TodaySummary?
    let daysProvider: @MainActor (Date, Date) async -> DaysResponse?
    let correction: @MainActor ([String],Bool)->Void
    var task: Task<Void,Never>?
    var stripTask: Task<Void,Never>?
    var screenObserver: NSObjectProtocol?
    /// Finished days don't change: each is loaded once while the window's open.
    private var pastDays: [String: TodaySummary] = [:]
    /// Usage: `day_closed` (how long it was open, and how much of it was unfolded).
    var track: UsageTracker?
    private var openedAt: Date?
    /// Your day was opened then and hasn't shown its day yet: `day_loaded` (how long, and whether it did).
    private var loadAsked: ContinuousClock.Instant?
    /// Whether the window is on screen (tests say so without showing it).
    var showing: () -> Bool = { false }
    /// Today's day asked for again: when, and the ask on its way. At most one every `refreshGap` seconds while the world
    /// moves; the last one waits its turn rather than being dropped.
    private var refreshedAt: Date?
    private var refreshTask: Task<Void, Never>?
    private var refreshQueued = false
    var refreshGap: TimeInterval = 10
    init(world: WorldModel,provider: @escaping @MainActor (Date?) async -> TodaySummary?,days: @escaping @MainActor (Date, Date) async -> DaysResponse? = { _,_ in nil },correction: @escaping @MainActor ([String],Bool)->Void) {
        self.world = world; self.provider = provider; self.daysProvider = days; self.correction = correction
        window = MokuWindow(contentRect: CGRect(x: 140,y: 100,width: 1120,height: 760),styleMask: [.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing: .buffered,defer: false)
        super.init(); window.title = "Your day with Moku"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false; window.minSize = CGSize(width: 820,height: 620); window.delegate = self
        window.contentView = NSHostingView(rootView: TodayView(model: model,scene: scene,world: world,onRetry: { [weak self] in self?.reload() },onCorrect: { [weak self] row,work in guard let self else { return }; self.model.correct(row,work: work,callback: self.correction) },onCorrectGoalApp: { [weak self] goal,app in guard let self else { return }; self.model.correct(goal: goal,app: app,callback: self.correction); self.refreshSoon() },onPostcard: { [weak self] in self?.postcard() },onSelect: { [weak self] in self?.select($0) }))
        screenObserver = DisplayRecovery.observe(window)
        showing = { [weak self] in self?.window.isVisible ?? false }
        watchWorld()
    }
    func open() {
        // Already open: it comes forward where it is, at today. Opening it again re-centred the window you'd placed,
        // faded it in again and replayed the house from the empty plot.
        if window.isVisible && !window.isMiniaturized {
            openedAgain()
            ActivateOnly.activate(keeping: [window]) { window.makeKeyAndOrderFront(nil) }
            return
        }
        openedAt = Date(); model.expanded = 0; loadAsked = .now
        model.day = Calendar.current.startOfDay(for: Date()); pastDays = [:]
        scene.step = 0.07  // days change quickly here: the pieces cascade
        scene.open(points: Double(world.snapshot.todayFocusMinutes),from: 0); reload(); loadStrip(); window.center()
        window.title = "Your day with \(Companion.current.name)"  // what VoiceOver and Mission Control call it
        let target = window.frame
        // Reduce Motion: it appears where it is, with no easing in from a smaller size.
        if MotionPreference.reduced { window.alphaValue = 1; ActivateOnly.activate(keeping: [window]) { window.makeKeyAndOrderFront(nil) }; return }
        window.setFrame(target.insetBy(dx: target.width*0.02,dy: target.height*0.02),display: false)
        window.alphaValue = 0; ActivateOnly.activate(keeping: [window]) { window.makeKeyAndOrderFront(nil) }
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.25; context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); window.animator().alphaValue = 1; window.animator().setFrame(target,display: true) }
    }
    /// Opened while it's open: today's day, asked for again. It showed the day as it was when the window first opened
    /// (Charles, 2026-10-06: Your day 2h 51m and 6 returns beside the popover's 3h 30m and 9).
    func openedAgain() {
        let todayStart = Calendar.current.startOfDay(for: Date())
        if model.day == todayStart, model.summary != nil { refreshToday() } else { select(todayStart) }
    }
    /// Today's day asked for again and swapped in place: the numbers move and the house adds its pieces, with no
    /// "A moment with your day…" over them.
    func refreshToday() {
        guard model.isToday else { return }
        let key = model.dayKey
        refreshedAt = Date(); refreshQueued = false
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self, let value = await provider(nil), !Task.isCancelled, key == model.dayKey else { return }
            withAnimation(.easeInOut(duration: 0.35)) { model.summary = value; model.corrections = [:]; model.correctedApps = [] }
            showHouse(value)
        }
        loadStrip()
    }
    /// While it shows today on screen, the world's minutes moving (what the popover says) bring the day again.
    private func watchWorld() {
        withObservationTracking { _ = world.snapshot.todayFocusMinutes } onChange: { [weak self] in
            Task { @MainActor in self?.worldMoved(); self?.watchWorld() }
        }
    }
    private func worldMoved() {
        guard showing(), model.isToday, !model.loading, let shown = model.summary, shown.focusedMinutes != world.snapshot.todayFocusMinutes,
              !refreshQueued else { return }
        let wait = refreshedAt.map { refreshGap - Date().timeIntervalSince($0) } ?? 0
        guard wait > 0 else { refreshToday(); return }
        refreshQueued = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, refreshQueued else { return }
            refreshToday()
        }
    }
    /// Back to the window (a click, ⌘-Tab): today's day again, if it's been a while.
    func windowDidBecomeKey(_ notification: Notification) {
        guard model.isToday, model.summary != nil, !model.loading else { return }
        if let refreshedAt, Date().timeIntervalSince(refreshedAt) < refreshGap { return }
        refreshToday()
    }
    /// Delete my data: the finished days kept while the window is open are gone, and an open window shows the fresh start
    /// (it went on showing what had just been deleted).
    func forgetShownDays() {
        pastDays = [:]
        guard window.isVisible else { return }
        model.day = Calendar.current.startOfDay(for: Date())
        reload(); loadStrip()
    }
    /// Show another day: its summary (a finished day from the cache when it's been seen), and the strip around it.
    func select(_ date: Date) {
        let day = model.clamped(date)
        guard day != model.day || model.summary == nil else { return }
        model.day = day; model.correctionNote = nil
        if !model.strip.contains(where: { $0.date == model.dayKey }) { loadStrip() }  // the strip moves to show it
        reload()
    }
    func reload() {
        task?.cancel(); model.unavailable = false
        let day = model.day, key = model.dayKey, isToday = model.isToday
        if !isToday, let cached = pastDays[key] { model.summary = cached; model.corrections = [:]; model.correctedApps = []; model.loading = false; showHouse(cached); return }
        model.loading = true
        task = Task { [weak self] in
            guard let self else { return }
            let value = await provider(isToday ? nil : day)
            guard !Task.isCancelled, key == model.dayKey else { return }
            model.summary = value; model.loading = false; model.unavailable = value == nil
            if let asked = loadAsked {
                loadAsked = nil
                let elapsed = asked.duration(to: .now).components
                track?("day_loaded", ["ms": .int(Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)), "ok": .bool(value != nil)])
            }
            if let value { showHouse(value) }
            if let value { model.corrections = [:]; model.correctedApps = []; if !isToday { pastDays[key] = value } }
            // Today answers at once with the note and goal lines it has; fresher ones may be on their way (Luna takes
            // a few seconds): ask once more for them.
            if let value, isToday, !value.segments.isEmpty {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, key == model.dayKey, let fresh = await provider(nil) else { return }
                let lines = Dictionary(fresh.goals.map { ($0.id, $0.summary) }, uniquingKeysWith: { a, _ in a })
                withAnimation(.easeInOut(duration: 0.4)) {
                    if let note = fresh.note { model.summary?.note = note }
                    for i in model.summary?.goals.indices ?? 0..<0 { if let line = lines[model.summary!.goals[i].id] ?? nil { model.summary?.goals[i].summary = line } }
                }
                return
            }
            // A finished day answers at once and Moku's note is written meanwhile (Luna takes a few seconds):
            // ask again for it, a few times, until it's there.
            guard let value, !isToday, value.note == nil, !value.segments.isEmpty else { return }
            for wait in [2.5, 4.0, 6.0] {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, key == model.dayKey else { return }
                if let note = await provider(day)?.note { model.summary?.note = note; pastDays[key]?.note = note; return }
            }
        }
    }
    /// After a correction from a goal card: the day again, once the brain has it, so the minutes move.
    func refreshSoon() {
        let key = model.dayKey
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, key == model.dayKey, let value = await provider(model.isToday ? nil : model.day), key == model.dayKey else { return }
            withAnimation(.easeInOut(duration: 0.35)) { model.summary = value; model.correctedApps = [] }
            if !model.isToday { pastDays[key] = value }
        }
    }
    /// The picked day's house: from the house on show, the missing pieces land or the extra ones leave. Today's numbers
    /// are checked against each other as they arrive.
    func showHouse(_ summary: TodaySummary) {
        scene.setPoints(Double(summary.focusedMinutes))
        checkNumbers(summary)
    }
    /// `numbers_disagree`, once per pair of views a day: what the brain's audit should have made impossible.
    private var reportedDisagreements: Set<String> = []
    private func checkNumbers(_ summary: TodaySummary) {
        guard summary.date == TodayModel.key(Date()) else { return }  // days saved before the audit kept their old sums
        // Before the brain's first world (just after launch) the popover has nothing to say yet.
        let popover = world.snapshot == .empty ? nil : world.snapshot.todayFocusMinutes
        for disagreement in NumbersCheck.disagreements(summary, popover: popover)
        where reportedDisagreements.insert(summary.date + disagreement.views).inserted {
            track?("numbers_disagree", ["views": .word(disagreement.views), "gap_minutes": .int(min(disagreement.gap, 1440))])
        }
    }
    func loadStrip() {
        stripTask?.cancel()
        let range = model.stripRange(for: model.day)
        stripTask = Task { [weak self] in
            guard let self, let response = await daysProvider(range.from, range.to), !Task.isCancelled else { return }
            model.strip = response.days; model.firstDay = response.firstDay.flatMap(TodayModel.date)
        }
    }
    func windowWillClose(_ notification: Notification) {
        task?.cancel(); stripTask?.cancel(); scene.close()
        if let openedAt { track?("day_closed", ["seconds_open": .int(max(0, Int(Date().timeIntervalSince(openedAt)))), "expanded": .int(model.expanded)]) }
        openedAt = nil
    }
    func postcard() { guard let summary = model.summary else { return }; Task { await Postcard.present(summary: summary,scene: scene,from: window) } }
    isolated deinit { task?.cancel(); scene.close(); if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; window.delegate = nil; window.close() }
}

struct TodayView: View {
    let model: TodayModel; let scene: HomeScene; let world: WorldModel
    var onRetry: ()->Void = {}; var onCorrect: (ActivityRow,Bool)->Void = { _,_ in }; var onCorrectGoalApp: (GoalDay,GoalApp)->Void = { _,_ in }; var onPostcard: ()->Void = {}; var onSelect: (Date)->Void = { _ in }
    @State private var picking = false
    /// For the demo's captures: the smaller things already open.
    var previewSmallerGoalsOpen = false
    @State private var showSmallerGoals = false
    @State private var showAllWandered = false
    /// Apps showing all their lines, and the line the pointer is on (its "…" shows then).
    @State private var openGroups: Set<String> = []
    @State private var hoveredRow: String?
    var body: some View {
        VStack(alignment: .leading,spacing: 0) {
            VStack(alignment: .leading,spacing: 10) {
                HStack(spacing: 10) {
                    Button { onSelect(Calendar.current.date(byAdding: .day,value: -1,to: model.day) ?? model.day) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.plain).disabled(!model.canGoBack).keyboardShortcut(.leftArrow,modifiers: .command).help("The day before (⌘←)").accessibilityLabel("The day before")
                    Button { picking = true } label: { Text(dayTitle).font(.system(size: 28,weight: .medium,design: .serif)) }.buttonStyle(.plain).help("Pick a day")
                        .popover(isPresented: $picking,arrowEdge: .bottom) {
                            DatePicker("Day",selection: Binding(get: { model.day },set: { picking = false; onSelect($0) }),in: (model.firstDay ?? .distantPast)...Date(),displayedComponents: .date)
                                .datePickerStyle(.graphical).labelsHidden().padding(12)
                        }
                    Button { onSelect(Calendar.current.date(byAdding: .day,value: 1,to: model.day) ?? model.day) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.plain).disabled(!model.canGoForward).keyboardShortcut(.rightArrow,modifiers: .command).help("The day after (⌘→)").accessibilityLabel("The day after")
                    if !model.isToday { Button("Today") { onSelect(Date()) }.font(.system(size: 12)).buttonStyle(.plain).padding(.horizontal,9).padding(.vertical,3).background(sage.opacity(0.18),in: Capsule()) }
                    Spacer(); Button("Evening postcard",action: onPostcard).buttonStyle(.plain).font(.system(size: 12)).disabled(model.summary == nil || !scene.hasFrame)
                }.font(.system(size: 15,weight: .medium)).foregroundStyle(ink)
                Text(model.summary?.note ?? (model.summary?.segments.isEmpty == true ? (model.isToday ? Companion.current.emptyDayLine : "A quiet day: nothing to show.") : "A little of what we made, together.")).font(.system(size: 16,design: .serif)).lineSpacing(4).quiet()
                if !model.strip.isEmpty { DayStrip(days: model.shownStrip,selected: model.dayKey,onSelect: onSelect).frame(height: 62).padding(.top,6) }
            }.padding(.horizontal,32).padding(.top,40).padding(.bottom,22)
            Divider().opacity(0.4)
            HStack(alignment: .top,spacing: 0) {
                VStack(alignment: .leading,spacing: 16) {
                    HomeSceneView(scene: scene).frame(minHeight: 300,maxHeight: 420).clipShape(RoundedRectangle(cornerRadius: 12))
                    HouseProgress(minutes: scene.displayedPoints,focusedMinutes: model.summary?.focusedMinutes)
                    Spacer(minLength: 0)
                }.padding(24).frame(minWidth: 300,idealWidth: 430,maxWidth: 460)
                Divider().opacity(0.4)
                ScrollView {
                    VStack(alignment: .leading,spacing: 22) {
                        if model.loading { ProgressView("A moment with your day…").padding(30) }
                        else if model.unavailable { VStack(alignment: .leading,spacing: 12) { Text("Your day is resting offline.").font(.title3); Text("Moku couldn’t reach your day just now. Your home is still here.").quiet(); Button("Try again",action: onRetry) }.padding(.vertical,30) }
                        else if let summary = model.summary {
                            HStack { metric(minutesText(summary.focusedMinutes),"focused"); metric("\(summary.returns)","returns"); metric(minutesText(summary.longestFocusMinutes),"longest") }
                            DayRibbon(summary: summary,live: model.isToday).frame(height: 62)
                            goalsSection(summary)
                            activitySection("WANDERED · and came back \(summary.returns) times",rows: model.rows(work: false),work: false)
                            if summary.quickCheckMinutes > 0 { HStack { Text("A few quick checks"); Spacer(); Text(minutesText(summary.quickCheckMinutes)) }.font(.system(size: 12)).quiet() }
                            if let note = model.correctionNote { Text(note).font(.system(size: 12,design: .serif)).quiet() }
                            if let best = summary.bestComeback {
                                VStack(alignment: .leading,spacing: 10) {
                                    Text("BEST COMEBACK").font(.system(size: 10,weight: .semibold)).tracking(1.5)
                                    Text("At \(best.ts.formatted(date: .omitted,time: .shortened)), you came back from \(best.from) after \(max(1,best.driftSeconds/60)) min, then stayed with \(best.threadTitle ?? "your work") for \(best.followingFocusMinutes) min.").font(.system(size: 14,design: .serif)).lineSpacing(3)
                                }.padding(18).frame(maxWidth: .infinity,alignment: .leading).background(sage.opacity(0.12),in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }.padding(24)
                }.frame(maxWidth: .infinity,maxHeight: .infinity)
            }
            HStack { Text("Every 10 focused minutes adds a piece to the day’s house; four hours builds all of it."); Spacer(); Text("Only you see this.") }.font(.system(size: 11)).quiet().padding(.horizontal,32).padding(.vertical,16)
        }.background(paper).foregroundStyle(ink).preferredColorScheme(.light)
    }
    var dayTitle: String { model.day.formatted(.dateTime.weekday(.wide).day().month(.wide)) }
    /// The day by task: what you worked on, a card per task, and the small ones folded into one line.
    func goalsSection(_ summary: TodaySummary) -> some View {
        let cards = model.goalCards, smaller = model.smallerGoals
        return VStack(alignment: .leading,spacing: 14) {
            Text(Self.tasksHeading(summary)).font(.system(size: 10,weight: .semibold)).tracking(1.2)
            if summary.goals.isEmpty { Text(model.isToday ? "Nothing yet. Start whenever you like." : "A quiet day.").font(.system(size: 13,design: .serif)).quiet() }
            ForEach(cards) { goal in goalCard(goal).transition(.opacity) }
            if !smaller.isEmpty { smallerTasks(smaller,alone: cards.isEmpty) }
        }
    }
    /// "8 tasks and other work, 4h 3m": every task's minutes, Other work too, so it's the header's focused time. It left
    /// Other work out ("8 tasks, 2h 59m" under 4h 3m, 2026-10-06).
    static func tasksHeading(_ summary: TodaySummary) -> String {
        let tasks = summary.goals.filter { !$0.isOther }.count, other = summary.goals.contains { $0.isOther }
        guard tasks > 0 else { return "WHAT YOU WORKED ON" }
        return "WHAT YOU WORKED ON · \(tasks) \(tasks == 1 ? "task" : "tasks")\(other ? " and other work" : ""), \(minutesText(summary.goals.reduce(0) { $0 + $1.minutes }))"
    }
    /// The small tasks, folded into one line ("Also: getting app feedback 8m · planning the week 5m"); it opens to a row each.
    func smallerTasks(_ smaller: [GoalDay],alone: Bool) -> some View {
        let open = showSmallerGoals || previewSmallerGoalsOpen
        return VStack(alignment: .leading,spacing: 6) {
            Button { withAnimation(.easeInOut(duration: 0.25)) { showSmallerGoals.toggle() }; if showSmallerGoals { model.expanded += 1 } } label: {
                HStack(spacing: 6) {
                    Text(alone ? "Small things" : "Also").font(.system(size: 12,weight: .medium))
                    if !open { Text(smaller.map { "\($0.title) \(minutesText($0.minutes))" }.joined(separator: " · ")).font(.system(size: 12)).quiet().lineLimit(1).truncationMode(.tail) }
                    Spacer(minLength: 6)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9,weight: .semibold)).quiet()
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(open ? "Fewer small tasks" : "\(smaller.count) small tasks, \(minutesText(smaller.reduce(0) { $0 + $1.minutes }))")
            if open {
                ForEach(smaller) { goal in HStack { Text(goal.title).font(.system(size: 12)).lineLimit(1); Spacer(); Text(minutesText(goal.minutes)).font(.system(size: 12)).quiet().monospacedDigit() }.padding(.leading,12) }
            }
        }.padding(.horizontal,16)
    }
    /// One task: what it was, its hours and time, Luna's line about it, its workflow (the apps in the order the work
    /// reached them, with the detours where they happened), the steps in plain words, and how it went.
    func goalCard(_ goal: GoalDay) -> some View {
        let apps = goal.apps.filter { !model.correctedApps.contains(goal.id+"|"+$0.id) }
        let key = "task|"+goal.id
        return VStack(alignment: .leading,spacing: 10) {
            // The hours sit beside the time when the title leaves room, else on a line of their own under the title.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline,spacing: 10) {
                    Text(goal.title).font(.system(size: 17,weight: .medium,design: .serif)).fixedSize()
                    Spacer(minLength: 8)
                    Text(TodayModel.hours(goal)).font(.system(size: 11)).quiet().fixedSize()
                    Text(minutesText(goal.minutes)).font(.system(size: 17,weight: .medium,design: .serif)).monospacedDigit().fixedSize()
                }
                VStack(alignment: .leading,spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(goal.title).font(.system(size: 17,weight: .medium,design: .serif)).lineLimit(2)
                        Spacer(minLength: 8)
                        Text(minutesText(goal.minutes)).font(.system(size: 17,weight: .medium,design: .serif)).monospacedDigit().fixedSize()
                    }
                    Text(TodayModel.hours(goal)).font(.system(size: 11)).quiet().lineLimit(1)
                }
            }
            if let line = goal.summary { Text(line).font(.system(size: 13,design: .serif)).italic().quiet().lineSpacing(2).fixedSize(horizontal: false,vertical: true) }
            WorkflowRow(goal: goal,apps: apps,onCorrect: { app in withAnimation(.easeInOut(duration: 0.3)) { onCorrectGoalApp(goal,app) } })
            if let steps = TodayModel.stepsLine(goal.steps) { Text(steps).font(.system(size: 12)).quiet().lineSpacing(2).lineLimit(2).fixedSize(horizontal: false,vertical: true) }
            HStack(alignment: .top,spacing: 8) {
                let longest = Label("Longest stretch \(minutesText(goal.longestMinutes))",systemImage: "timer"), cameBack = TodayModel.cameBack(goal)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { longest.fixedSize(); if let cameBack { Label(cameBack,systemImage: "arrow.uturn.left").fixedSize() } }
                    VStack(alignment: .leading,spacing: 4) { longest; if let cameBack { Label(cameBack,systemImage: "arrow.uturn.left") } }
                }
                Spacer(minLength: 0)
                Menu {
                    ForEach(apps.filter { !$0.segmentIds.isEmpty }) { app in Button("\(app.name) wasn’t work") { withAnimation(.easeInOut(duration: 0.3)) { onCorrectGoalApp(goal,app) } } }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .opacity(apps.allSatisfy { $0.segmentIds.isEmpty } ? 0 : hoveredRow == key ? 1 : 0.3).disabled(apps.allSatisfy { $0.segmentIds.isEmpty })
                    .accessibilityLabel("Correct an app in \(goal.title)").help("Correct an app that wasn’t work")
            }.font(.system(size: 11)).quiet().labelStyle(.titleAndIcon)
        }.padding(16).frame(maxWidth: .infinity,alignment: .leading).background(sage.opacity(goal.isOther ? 0.05 : 0.1),in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onHover { inside in hoveredRow = inside ? key : (hoveredRow == key ? nil : hoveredRow) }
        .accessibilityElement(children: .contain).accessibilityLabel("\(goal.title), \(minutesText(goal.minutes)), \(TodayModel.hours(goal))")
    }
    func metric(_ value: String,_ label: String) -> some View { VStack(alignment: .leading,spacing: 4) { Text(value).font(.system(size: 29,weight: .medium,design: .serif)); Text(label).font(.system(size: 11)).quiet() }.frame(maxWidth: .infinity,alignment: .leading) }
    /// BUILT or WANDERED: one line per app (icon, name, total, one bar), what was done there under it, and the "…" to
    /// correct a line on hover. Wandering shows less, so drift reads quieter than work.
    func activitySection(_ title: String,rows: [ActivityRow],work: Bool) -> some View {
        let groups = model.groups(work: work)
        let expanded = showAllWandered
        let (appsShown, linesShown) = work ? (4, 3) : (3, 2)
        let shown = expanded ? groups : Array(groups.prefix(appsShown))
        let top = max(1, groups.first?.minutes ?? 1), tint = work ? sage : oat
        return VStack(alignment: .leading,spacing: 16) {
            Text(title).font(.system(size: 10,weight: .semibold)).tracking(1.2)
            if groups.isEmpty { Text(work ? "Nothing yet. Start whenever you like." : "A quiet stretch.").font(.system(size: 13,design: .serif)).quiet() }
            ForEach(shown) { group in
                let open = openGroups.contains(group.id)
                VStack(alignment: .leading,spacing: 6) {
                    HStack(spacing: 10) {
                        GroupIcon(group: group,tint: tint).frame(width: 22,height: 22)
                        Text(group.name).font(.system(size: 13,weight: .medium)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(minutesText(group.minutes)).font(.system(size: 13,weight: .medium)).monospacedDigit()
                    }
                    .help(group.browser.map { "In \($0)" } ?? "")
                    GeometryReader { geometry in Capsule().fill(tint.opacity(0.7)).frame(width: max(3,geometry.size.width*CGFloat(group.minutes)/CGFloat(top))) }
                        .frame(height: 3).padding(.leading,32)
                    VStack(alignment: .leading,spacing: 4) {
                        ForEach(open ? group.rows : Array(group.rows.prefix(linesShown))) { row in activityLine(row,work: work) }
                        if group.rows.count > linesShown {
                            Button { withAnimation(.easeInOut(duration: 0.2)) { if open { openGroups.remove(group.id) } else { openGroups.insert(group.id); model.expanded += 1 } } } label: {
                                Text(open ? "Fewer" : "\(group.rows.count - linesShown) more").font(.system(size: 11,weight: .medium)).quiet()
                            }.buttonStyle(.plain)
                        }
                    }.padding(.leading,32)
                }
                .transition(.opacity)
            }
            if groups.count > appsShown {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { showAllWandered.toggle() }
                    if showAllWandered { model.expanded += 1 }
                } label: {
                    Label(expanded ? "Show fewer" : "Show all \(groups.count) apps",systemImage: expanded ? "chevron.up" : "chevron.down").font(.system(size: 12,weight: .medium))
                }.buttonStyle(.plain).quiet()
            }
        }
    }
    /// One thing done in an app: the phrase and its minutes, and on hover the "…" with the correction.
    func activityLine(_ row: ActivityRow,work: Bool) -> some View {
        let correction = work ? "This wasn’t work" : "This was work"
        let correct = { withAnimation(.easeInOut(duration: 0.3)) { onCorrect(row,!work) } }
        return HStack(spacing: 8) {
            Text(row.activity).font(.system(size: 12)).quiet().lineLimit(1)
            Spacer(minLength: 6)
            // Faint at rest, so a correction is found without hunting for it (Charles, 2026-10-14); full on hover.
            Menu { Button(correction,action: correct) } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .opacity(row.segmentIds.isEmpty ? 0 : hoveredRow == row.id ? 1 : 0.3).disabled(row.segmentIds.isEmpty)
                .accessibilityLabel("Correct \(row.app), \(row.activity)").help(correction)
            Text(minutesText(row.minutes)).font(.system(size: 12)).quiet().monospacedDigit()
        }
        .frame(minHeight: 20).contentShape(Rectangle())
        .onHover { inside in hoveredRow = inside ? row.id : (hoveredRow == row.id ? nil : hoveredRow) }
        .contextMenu { if !row.segmentIds.isEmpty { Button(correction,action: correct) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.activity), \(minutesText(row.minutes))")
        .accessibilityAction(named: Text(correction)) { if !row.segmentIds.isEmpty { correct() } }
    }
}
/// One app on Your day (or one website, when it was in a browser) with what was done there.
struct ActivityGroup: Identifiable {
    let id: String
    /// The app's name, or the site's host.
    let name: String
    let bundleId: String
    let host: String?
    /// The browser a site was in (for the tooltip).
    let browser: String?
    var rows: [ActivityRow]
    var minutes: Int { rows.reduce(0) { $0 + $1.minutes } }
}
/// An app's own icon; a site (or an app without one) gets a letter tile of the same size.
struct GroupIcon: View {
    let group: ActivityGroup
    let tint: Color
    var body: some View {
        if group.host == nil, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: group.bundleId) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.22))
                .overlay(Text(String(group.name.prefix(1)).uppercased()).font(.system(size: 12,weight: .semibold,design: .serif)).foregroundStyle(ink))
        }
    }
}
/// A task's workflow in one row: each app with its icon and minutes in the order the work reached it, joined by arrows,
/// and the detours as small oat pills where they happened ("Cursor 58m → Ghostty 22m → ↩ YouTube 4m → Stripe docs 16m").
/// When the row is too narrow, the detours' places go first, then the apps' names (the icons stay).
struct WorkflowRow: View {
    let goal: GoalDay
    /// The goal's apps still counted as work (an app corrected from this card leaves the row).
    let apps: [GoalApp]
    var onCorrect: (GoalApp)->Void = { _ in }
    var links: [(id: String,step: WorkflowStep,app: GoalApp?)] {
        let byID = Dictionary(apps.map { ($0.id,$0) },uniquingKeysWith: { a,_ in a })
        var out: [(id: String,step: WorkflowStep,app: GoalApp?)] = []
        // A brain from before the workflow sends none: the apps, longest first, stand in.
        let steps = goal.workflow.isEmpty ? apps.prefix(4).map { WorkflowStep.app($0.id,$0.minutes) } : goal.workflow
        for (index,step) in steps.enumerated() {
            if step.kind == .app { if let app = byID[step.appId] { out.append((step.appId,step,app)) } }
            else if !out.isEmpty { out.append(("detour-\(index)",step,nil)) }
        }
        return out
    }
    var more: Int { max(0,apps.count - links.filter { $0.app != nil }.count) }
    var body: some View {
        ViewThatFits(in: .horizontal) { row(named: true,placed: true); row(named: true,placed: false); row(named: false,placed: false) }
            .accessibilityElement(children: .contain)
    }
    func row(named: Bool,placed: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(links.enumerated()),id: \.element.id) { index,link in
                if index > 0 { Text("→").font(.system(size: 11)).foregroundStyle(ink.opacity(0.35)).accessibilityHidden(true) }
                if let app = link.app { appLink(app,named: named) } else { detourLink(link.step,named: placed) }
            }
            if more > 0 { Text("+\(more) more").font(.system(size: 11)).quiet().fixedSize() }
        }
    }
    func appLink(_ app: GoalApp,named: Bool) -> some View {
        let group = ActivityGroup(id: app.id,name: app.name,bundleId: app.bundleId,host: app.host,browser: app.host == nil ? nil : app.app,rows: [])
        return HStack(spacing: 5) {
            GroupIcon(group: group,tint: sage.opacity(0.8)).frame(width: 16,height: 16)
            if named { Text(app.name).font(.system(size: 12,weight: .medium)).lineLimit(1) }
            Text(minutesText(app.minutes)).font(.system(size: 12)).quiet().monospacedDigit()
        }
        .fixedSize()
        .help(([app.name] + app.titles).joined(separator: " · "))
        .contextMenu { if !app.segmentIds.isEmpty { Button("This wasn’t work") { onCorrect(app) } } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(app.name), \(minutesText(app.minutes))")
        .accessibilityAction(named: Text("This wasn’t work")) { if !app.segmentIds.isEmpty { onCorrect(app) } }
    }
    func detourLink(_ step: WorkflowStep,named: Bool) -> some View {
        let place = step.place ?? "somewhere else"
        return HStack(spacing: 3) {
            Image(systemName: "arrow.uturn.left").font(.system(size: 8,weight: .semibold))
            Text(named ? "\(place) \(minutesText(step.minutes))" : minutesText(step.minutes)).font(.system(size: 11)).lineLimit(1)
        }
        .foregroundStyle(ink.opacity(0.6)).padding(.horizontal,7).padding(.vertical,2).background(oat.opacity(0.45),in: Capsule()).fixedSize()
        .help(step.count == 1 ? "A detour to \(place), then back" : "\(step.count) detours, mostly \(place), then back")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.count == 1 ? "A detour to \(place), \(minutesText(step.minutes))" : "\(step.count) detours, mostly \(place), \(minutesText(step.minutes))")
    }
}
struct DayRibbon: View {
    let summary: TodaySummary
    /// Today's ribbon runs to now; a finished day's ends at its last activity.
    var live = true
    /// Work, drift and meetings: away time at either end (a Mac left awake overnight) doesn't stretch the day.
    var active: [DaySegment] { let real = summary.segments.filter { $0.state == .working || $0.state == .drifting || $0.state == .meeting }; return real.isEmpty ? summary.segments : real }
    var start: Date { active.map(\.start).min() ?? Date() }
    var end: Date { let last = active.map(\.end).max() ?? start; return live ? max(last,Date()) : last }
    func x(_ date: Date,_ width: Double) -> Double { min(width,max(0,date.timeIntervalSince(start)/max(1,end.timeIntervalSince(start))*width)) }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5).fill(Color(red: 0.933,green: 0.906,blue: 0.863)).frame(height: 20).offset(y: 16)
                ForEach(summary.segments) { segment in
                    let left = x(segment.start,geometry.size.width), width = max(1,x(segment.end,geometry.size.width)-left)
                    ZStack { Rectangle().fill(segment.state == .working ? sage : segment.state == .drifting ? oat : Color.clear)
                        if segment.state == .meeting { Canvas { context,size in for i in stride(from: -20.0,to: size.width+20,by: 6) { var path = Path(); path.move(to: CGPoint(x: i,y: 20)); path.addLine(to: CGPoint(x: i+20,y: 0)); context.stroke(path,with: .color(.gray.opacity(0.5)),lineWidth: 1) } }.clipped() }
                    }.frame(width: width,height: 20).offset(x: left,y: 16).help("\(segment.start.formatted(date: .omitted,time: .shortened))–\(segment.end.formatted(date: .omitted,time: .shortened)) · \(segment.app) · \(segment.activity ?? segment.state.rawValue) · \(max(1,Int(segment.end.timeIntervalSince(segment.start)/60)))m")
                }
                HStack { Text(start.formatted(date: .omitted,time: .shortened)); Spacer(); Text(live ? "now" : end.formatted(date: .omitted,time: .shortened)) }.font(.system(size: 10)).quiet().offset(y: 44)
            }
        }.accessibilityLabel("Your day: sage for focus, oat for wandering, hatched meetings, amber returns")
    }
}

/// Seven days of focus at a glance: a bar per day, the chosen one darker. Hovering one lights it; clicking shows that day.
struct DayStrip: View {
    let days: [DayTotals]; let selected: String; var onSelect: (Date)->Void = { _ in }
    @State private var hovered: String?
    var body: some View {
        let most = max(60,days.map(\.focusedMinutes).max() ?? 60)
        HStack(alignment: .bottom,spacing: 10) {
            Spacer(minLength: 0)
            ForEach(days) { day in
                let date = TodayModel.date(day.date) ?? Date(), chosen = day.date == selected
                Button { onSelect(date) } label: {
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3).fill(chosen ? ink.opacity(0.75) : sage.opacity(day.focusedMinutes == 0 ? 0.18 : hovered == day.date ? 1 : 0.75))
                            .frame(width: 30,height: max(3,34*CGFloat(day.focusedMinutes)/CGFloat(most)))
                        Text(date.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 10,weight: chosen ? .semibold : .regular))
                        Text(minutesText(day.focusedMinutes)).font(.system(size: 9)).quiet().monospacedDigit()
                    }.frame(width: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
                .onHover { inside in hovered = inside ? day.date : (hovered == day.date ? nil : hovered) }
                .animation(.easeOut(duration: 0.12), value: hovered)
                .help("\(date.formatted(.dateTime.weekday(.wide).day().month(.wide))) · \(minutesText(day.focusedMinutes)) focused · \(DayHouse.percent(Double(day.focusedMinutes)))% of a house")
                .accessibilityLabel("\(date.formatted(.dateTime.weekday(.wide).day().month(.wide))): \(minutesText(day.focusedMinutes)) focused")
            }
            Spacer(minLength: 0)
        }.frame(maxHeight: .infinity,alignment: .bottom)
    }
}

extension MokuVisualDiagnostics {
    /// Your day by task, on a sample day shaped like a real one (a few tasks with cards, many small ones folded):
    /// goal-day.png, goal-day-open.png with the small ones open, goal-day-full(-open).png tall enough for every card,
    /// and goal-day-narrow.png at the window's smallest width.
    public static func goalDayLook(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let now = Date(), start = Calendar.current.startOfDay(for: now).addingTimeInterval(9*3600)
        func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes*60) }
        let cursor = "com.todesktop.230313mzl4w4u92", ghostty = "com.mitchellh.ghostty", chrome = "com.google.Chrome"
        let settingsApps: [GoalApp] = [GoalApp(app: "Cursor",bundleId: cursor,minutes: 58,activities: ["building Moku"],titles: ["SettingsWindow.swift","Onboarding.swift"],segmentIds: ["s1"],firstAt: at(72)),
                           GoalApp(app: "Ghostty",bundleId: ghostty,minutes: 22,activities: ["running tests"],titles: ["swift test — MokuVisual"],segmentIds: ["s2"],firstAt: at(140)),
                           GoalApp(app: "Chrome",bundleId: chrome,host: "docs.stripe.com",name: "Stripe docs",minutes: 16,activities: ["reading the Stripe docs"],titles: ["Subscriptions overview"],segmentIds: ["s3"],firstAt: at(190))]
        let designApps: [GoalApp] = [GoalApp(app: "Claude",bundleId: "com.anthropic.claudefordesktop",minutes: 29,activities: ["studying consistent hashing"],segmentIds: ["s4"],firstAt: at(305)),
                           GoalApp(app: "Chrome",bundleId: chrome,host: "youtube.com",name: "YouTube",minutes: 12,activities: ["watching a talk"],titles: ["Designing a rate limiter"],segmentIds: ["s5"],firstAt: at(342))]
        let ideaApps: [GoalApp] = [GoalApp(app: "Chrome",bundleId: chrome,host: "chatgpt.com",name: "ChatGPT",minutes: 10,activities: ["researching the market"],titles: ["Focus app landscape"],segmentIds: ["s6"],firstAt: at(122)),
                           GoalApp(app: "Telegram",bundleId: "ru.keepcoder.Telegram",minutes: 5,activities: ["researching the market"],titles: ["Product team"],segmentIds: ["s7"],firstAt: at(400))]
        let mailApps: [GoalApp] = [GoalApp(app: "Mail",bundleId: "com.apple.mail",minutes: 12,activities: ["answering email"],segmentIds: ["s8"],firstAt: at(5))]
        var goals: [GoalDay] = []
        goals.append(GoalDay(id: "g1",title: "building Moku’s settings",summary: "The privacy pane and the permission rows, then the Stripe docs",minutes: 96,longestMinutes: 52,apps: settingsApps,detours: 2,detourMinutes: 11,detourPlace: "youtube.com",firstAt: at(72),lastAt: at(220),
                             workflow: [.app("app:"+cursor,58),.detour("YouTube",8),.app("app:"+ghostty,22),.app("site:docs.stripe.com",16),.detour("X",3)],
                             steps: ["edited SettingsWindow.swift and Onboarding.swift","ran swift test","read Subscriptions overview in the Stripe docs"]))
        goals.append(GoalDay(id: "g2",title: "learning system design",summary: "Consistent hashing, then a talk on rate limiters",minutes: 41,longestMinutes: 25,apps: designApps,detours: 1,detourMinutes: 3,detourPlace: "x.com",firstAt: at(305),lastAt: at(370),
                             workflow: [.app("app:com.anthropic.claudefordesktop",29),.detour("X",3),.app("site:youtube.com",12)],
                             steps: ["studied consistent hashing","watched Designing a rate limiter"]))
        goals.append(GoalDay(id: "g3",title: "researching the market",minutes: 15,longestMinutes: 6,apps: ideaApps,firstAt: at(122),lastAt: at(460),
                             workflow: [.app("site:chatgpt.com",10),.app("app:ru.keepcoder.Telegram",5)],sittings: 3,
                             steps: ["asked ChatGPT about Focus app landscape","messaged Product team"]))
        for (id,title,minutes) in [("g4","getting app feedback",8),("g5","exploring agent frameworks",7),("g6","planning the week",5),("g7","reading about RealityKit",4)] { goals.append(GoalDay(id: id,title: title,minutes: minutes)) }
        goals.append(GoalDay(id: "other",title: "Other work",summary: "Email and the calendar",minutes: 12,longestMinutes: 5,apps: mailApps,firstAt: at(5),lastAt: at(480),
                             workflow: [.app("app:com.apple.mail",12)],sittings: 2,steps: ["answered email"]))
        var segments: [DaySegment] = []
        for i in 0..<16 {
            let state: Verdict.State = i == 3 || i == 8 || i == 12 ? .drifting : .working
            segments.append(DaySegment(id: "seg-\(i)",start: at(Double(i)*30),end: at(Double(i+1)*30),state: state,app: "Cursor",bundleId: cursor))
        }
        let wandered = [ActivityRow(id: "w1",app: "Chrome",bundleId: "com.google.Chrome",host: "youtube.com",activity: "watching videos",minutes: 14,segmentIds: ["w1"],category: .watching)]
        let model = TodayModel()
        model.summary = TodaySummary(date: TodayModel.key(now),note: "A long stretch on the settings screen, and you came back every time. I put up the round door.",focusedMinutes: 188,longestFocusMinutes: 52,returns: 5,unitsToday: 18,segments: segments,built: [],wandered: wandered,quickCheckMinutes: 4,comebacks: [],bestComeback: nil,completions: [],goals: goals)
        let scene = HomeScene(); scene.open(points: 188)
        while scene.image == nil && scene.error == nil { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(500))
        for (name,open,width,height) in [("goal-day",false,1120.0,900.0),("goal-day-open",true,1120,900),("goal-day-full",false,1120,1500),("goal-day-full-open",true,1120,1500),("goal-day-narrow",false,820,1500)] {
            let view = NSHostingView(rootView: TodayView(model: model,scene: scene,world: WorldModel(snapshot: .empty),previewSmallerGoalsOpen: open)); view.frame = CGRect(x: 0,y: 0,width: width,height: height)
            try NSBitmapImageRep(cgImage: ReviewCapture.view(view)).representation(using: .png,properties: [:])!.write(to: directory.appendingPathComponent("\(name).png"))
        }
        scene.close()
    }
}

/// Today's numbers against each other where the app shows them together. The brain's audit (numbers_agree_test.go)
/// makes them add up; this is the same check on real days. The popover may be a refresh (a minute) behind.
enum NumbersCheck {
    struct Disagreement: Equatable { let views: String; let gap: Int }
    static func disagreements(_ summary: TodaySummary, popover: Int?) -> [Disagreement] {
        var out: [Disagreement] = []
        func check(_ views: String, _ shown: Int, allowed: Int = 1) {
            let gap = abs(shown - summary.focusedMinutes)
            if gap > allowed { out.append(Disagreement(views: views, gap: gap)) }
        }
        check("tasks_header", summary.goals.reduce(0) { $0 + $1.minutes })
        check("rows_header", summary.built.reduce(0) { $0 + $1.minutes })
        let pieces = summary.focusedMinutes / 10
        if summary.unitsToday != pieces { out.append(Disagreement(views: "house_header", gap: abs(summary.unitsToday - pieces))) }
        if let popover { check("popover_header", popover, allowed: 2) }
        return out
    }
}
