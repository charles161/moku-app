import Testing
import AppKit
import Foundation
import MokuKit
@testable import MokuVisual

@Test func hopsHoldTheGroundAndFinishAtTheExactDestination() {
    let hop = HopTravel(duration: 13/24,strideLength: 0.26,travelPhase: [0.29,0.72])
    let stride = 24.0, distance = 113.0
    for cycle in 0..<4 {
        let base = Double(cycle)*hop.duration
        #expect(abs(hop.position(elapsed: base+0.1*hop.duration,distance: distance,stridePoints: stride)-Double(cycle)*stride) < 0.0001)
        #expect(abs(hop.position(elapsed: base+0.9*hop.duration,distance: distance,stridePoints: stride)-Double(cycle+1)*stride) < 0.0001)
    }
    #expect(hop.position(elapsed: hop.travelDuration(distance: distance,stridePoints: stride),distance: distance,stridePoints: stride) == distance)
}
@Test func earPopCrossesMiddleInFiveFramesAndSettlesExactly() {
    for rising in [true,false] {
        let values = (0...24).map { EarTiming.phase(Float($0)/60/0.38,rising: rising) }
        #expect(values.filter { $0 >= 0.3 && $0 <= 0.7 }.count <= 5)
        #expect(values.first == 0); #expect(values.last == 1)
        #expect(rising ? values.max()! > 1 : values.max()! <= 1)
    }
}
@Test @MainActor func onboardingUsesSuggestionEditedNameAndFriendFallback() {
    let model = OnboardingModel(); #expect(model.resultName == "friend")
    model.suggestedName = "  Riley  "; #expect(model.resultName == "Riley")
    model.name = "  Alex \n"; #expect(model.resultName == "Alex")
    model.name = String(repeating: "a",count: 100); #expect(model.resultName.utf16.count == PersonName.maxUTF16)  // the brain refuses more than 60
}
@Test @MainActor func correctionsMoveOnlyTheChosenActivityAndKeepExactSegmentIDs() {
    let model = TodayModel()
    let work = ActivityRow(id: "career",app: "LinkedIn",bundleId: "browser",activity: "researching roles",minutes: 20,segmentIds: ["a"])
    let feed = ActivityRow(id: "feed",app: "LinkedIn",bundleId: "browser",activity: "scrolling the feed",minutes: 8,segmentIds: ["b","c"])
    model.summary = TodaySummary(date: "2026-09-24",note: nil,focusedMinutes: 20,longestFocusMinutes: 20,returns: 1,unitsToday: 2,segments: [],built: [work],wandered: [feed],quickCheckMinutes: 0,comebacks: [],bestComeback: nil,completions: [])
    var sent = [String](); var isWork = false
    model.correct(feed,work: true) { sent = $0; isWork = $1 }
    #expect(sent == ["b","c"] && isWork); #expect(model.rows(work: true).map(\.id) == ["career","feed"]); #expect(model.rows(work: false).isEmpty)
    model.correct(feed,work: false) { _,_ in }; #expect(model.rows(work: false) == [feed]); #expect(model.rows(work: true) == [work])
}
@Test func bothHomesHaveEveryRoomsItemsAtTheStagesThresholds() throws {
    let layout = try HomeLayout.load()
    #expect(layout.thresholds == ForestStage.allCases.map(\.threshold))
    for kind in HomeKind.allCases {
        let home = try #require(layout.homes[kind.rawValue])
        #expect(home.stages.map(\.threshold) == layout.thresholds)
        // One item per 10 points in every room, exactly as the popover counts them; the observatory has its telescope.
        for (stage, room) in zip(home.stages, ForestStage.allCases) { #expect(stage.items.count == (room.unitCount ?? 1), "\(kind) \(room)") }
        #expect(home.bulbs.count == 200 && home.stars.count >= 1000)
    }
    #expect(layout.homes["burrow"]?.terrain?.count == 6)  // a hill for each number of rooms dug
}
@Test func todaysHouseIsTwentyFourPiecesAndDoneAtFourHours() throws {
    #expect(DayHouse.goalMinutes == 240 && DayHouse.pieceNames.count == DayHouse.pieces)
    #expect(DayHouse.percent(0) == 0 && DayHouse.percent(150) == 62 && DayHouse.percent(300) == 100)
    #expect(DayHouse.built(149) == 14 && DayHouse.stage(149) == 3)  // into the roof
    #expect(DayHouse.next(150)! == ("the right roof", 10))
    #expect(DayHouse.next(240) == nil)
    let layout = try HomeLayout.load("world/dayhouse/layout.json"), house = try #require(layout.homes["dayhouse"])
    #expect(house.stages.map(\.items.count) == [4, 4, 6, 4, 6, 0])
    #expect(house.stages.map(\.threshold) == [0, 40, 80, 140, 180, 240])
    #expect(house.bulbs.isEmpty && house.stars.isEmpty)
    #expect(house.terrain?.count == 6)  // the site changes as the house goes up
    // Every piece's first stage matches DayHouse's, so the popover names the piece being built.
    var first = 0
    for (stage, named) in zip(house.stages.dropLast(), DayHouse.stages) { #expect(named.first == first); first += stage.items.count }
}
@Test func theHomeShowsWhatsBeenMadeAndNoMore() throws {
    let layout = try HomeLayout.load(), home = try #require(layout.homes["burrow"])
    let day1 = HomeProgress(points: 180, returns: 6)
    let counts = home.stages.indices.map { day1.items(in: home.stages[$0], next: $0 + 1 < home.stages.count ? home.stages[$0 + 1].threshold : nil, perItem: 10) }
    #expect(counts == [3, 9, 6, 0, 0, 0, 0, 0])  // the door and entry done, six pieces into the study
    #expect(day1.roomsOpen(layout.thresholds) == 2 && day1.stars(layout.thresholds, perItem: 10) == 0)
    #expect(HomeProgress(points: 10_250, returns: 0).stars(layout.thresholds, perItem: 10) == 25)
}

@MainActor private final class WelcomeStage: CharacterStage {
    var onPat: (@MainActor ()->Void)?; var onClick: (@MainActor ()->Void)?
    func show() {}; func setHidden(_ value: Bool) {}; func setMood(_ value: Mood) {}; func setAttention(_ value: AttentionTarget) {}; func perform(_ value: MokuKit.Gesture) {}; func move(to value: StageSpot) async {}; func say(_ value: SpeechLine) {}; func dismissSpeech() {}
}
/// The welcome's window (they share VisualSessionState.shared.onboarding, so one at a time).
@MainActor @Suite(.serialized) struct WelcomeWindowTests {
    @Test func skippedAtAnyPointOrCancelled() async {
        _ = NSApplication.shared
        let context = OnboardingContext(suggestedName: "Riley",permissions: { PermissionStatus(accessibility: false,screenRecording: false) },requestPermission: { _ in },launchAtLogin: { false },setLaunchAtLogin: { _ in })
        for asked in [[], [PermissionKind.accessibility, .screenRecording]] {
            let presenter = MokuOnboardingPresenter(stage: WelcomeStage(),offscreen: true)
            presenter.pointSeconds = 0.05
            let run = Task { await presenter.run(context) }
            while presenter.panel == nil { await Task.yield() }
            asked.forEach { presenter.state.request($0) }; presenter.state.name = "Alex"; presenter.state.skip()
            let result = await run.value
            #expect(result == OnboardingResult(name: "Alex",completed: false)); #expect(presenter.panel == nil); #expect(!VisualSessionState.shared.onboarding)
        }
        let presenter = MokuOnboardingPresenter(stage: WelcomeStage(),offscreen: true)
        let run = Task { await presenter.run(context) }; while presenter.panel == nil { await Task.yield() }; run.cancel()
        let result = await run.value; #expect(!result.completed); #expect(presenter.panel == nil)
    }
    /// Allow saves where the welcome got to (macOS may quit Moku for Screen Recording): the next welcome picks up at the
    /// permissions, with the name and what was asked, and says so; Start clears it.
    @Test func aRelaunchPicksUpAtThePermissions() async {
        _ = NSApplication.shared
        OnboardingProgress.clear(); defer { OnboardingProgress.clear() }
        var steps: [UsageValue] = []
        let context = OnboardingContext(suggestedName: "Riley",permissions: { PermissionStatus(accessibility: true,screenRecording: false) },requestPermission: { _ in },
                                        launchAtLogin: { true },setLaunchAtLogin: { _ in },track: { name,props in if name == "welcome_step", let step = props["step"] { steps.append(step) } })
        let first = MokuOnboardingPresenter(stage: WelcomeStage(),offscreen: true,remembers: true)
        let quit = Task { await first.run(context) }
        while first.panel == nil { await Task.yield() }
        first.state.name = "Alex"; first.state.request(.screenRecording)
        first.finish(completed: false)  // macOS quits Moku: the window closes
        _ = await quit.value
        let again = MokuOnboardingPresenter(stage: WelcomeStage(),offscreen: true,remembers: true)
        again.pointSeconds = 0.05
        let run = Task { await again.run(context) }
        while again.panel == nil { await Task.yield() }
        #expect(again.state.resumed); #expect(again.state.name == "Alex"); #expect(again.state.asked == [.screenRecording]); #expect(again.state.waitingForReopen)
        #expect(again.state.page == .read)  // it opens at what it reads, where the Allow was
        again.state.start(); _ = await run.value
        // Each step it reached (the hello depends on timing here, so it's left out): the Allow, the pick-up, and Start.
        #expect(steps.filter { $0 != .word("hello") } == ["opened", "allow_screen", "resumed", "start"].map { UsageValue.word($0) })
        #expect(OnboardingProgress.resumable() == nil)
    }
    /// One window: Start applies starting with the Mac (on unless switched off), counts what happened, and finishes; the
    /// window's Quit & Reopen asks the app to relaunch. Nothing is remembered offscreen.
    @Test func startAppliesLoginAndQuitAndReopenRelaunches() async {
        _ = NSApplication.shared
        final class Log { var events: [String] = []; var steps: [UsageValue] = []; var answers: [[String: UsageValue]] = []; var login: [Bool] = []; var relaunches = 0; var requested: [PermissionKind] = [] }
        for switchedOff in [false, true] {
            let log = Log()
            var status = PermissionStatus(accessibility: false,screenRecording: false)
            let context = OnboardingContext(suggestedName: "Riley",permissions: { status },requestPermission: { log.requested.append($0); if $0 == .accessibility { status.accessibility = true } },
                                            launchAtLogin: { log.login.last ?? false },setLaunchAtLogin: { log.login.append($0) },
                                            track: { name,props in
                                                log.events.append(name)
                                                if name == "welcome_step", let step = props["step"] { log.steps.append(step) }
                                                if name == "permission_answered" { log.answers.append(props) }
                                            },
                                            relaunch: { log.relaunches += 1 })
            let presenter = MokuOnboardingPresenter(stage: WelcomeStage(),offscreen: true)
            presenter.pointSeconds = 0.05
            let run = Task { await presenter.run(context) }
            while presenter.panel == nil { await Task.yield() }
            #expect(!presenter.remembers); #expect(presenter.state.startWithMac)
            presenter.state.request(.accessibility); presenter.state.request(.screenRecording)
            #expect(presenter.state.waitingForReopen)
            presenter.state.relaunch(); #expect(log.relaunches == 1)
            if switchedOff { presenter.state.startWithMac = false }
            presenter.state.start(); presenter.state.start()  // a second press does nothing
            let result = await run.value
            #expect(result.completed); #expect(result.name == "Riley"); #expect(log.requested == [.accessibility, .screenRecording])
            #expect(log.login == (switchedOff ? [] : [true]))
            #expect(log.events.filter { $0 == "welcome_finished" }.count == 1)
            #expect(log.steps.filter { $0 != .word("hello") } == ["opened", "allow_accessibility", "allow_screen", "relaunch", "start"].map { UsageValue.word($0) })
            #expect(!log.events.contains("welcome_left"))
            // Left off at Start, with the seconds since its Allow.
            #expect(log.answers.contains { $0["kind"] == .word("screen") && $0["granted"] == .bool(false) && $0["where"] == .word("welcome") && $0["seconds"] != nil })
        }
    }
}

