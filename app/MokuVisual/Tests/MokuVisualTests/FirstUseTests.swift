import AppKit
import SwiftUI
import Testing
import MokuKit
@testable import MokuVisual

/// Launch QA, lens 1 (first use and usability): the welcome's names, its keeping place, its skip, and the contrast of
/// quiet text. (The welcome's ending under Reduce Motion: WelcomeWowTests.)

@MainActor private final class QuietStage: CharacterStage {
    var onPat: (@MainActor ()->Void)?; var onClick: (@MainActor ()->Void)?
    func show() {}; func setHidden(_ value: Bool) {}; func setMood(_ value: Mood) {}; func setAttention(_ value: AttentionTarget) {}; func perform(_ value: MokuKit.Gesture) {}; func move(to value: StageSpot) async {}; func say(_ value: SpeechLine) {}; func dismissSpeech() {}
}

/// A name from the Mac, as given: the greeting says it once and ends its sentence once, and never goes past what the brain takes.
@Test @MainActor func theGreetingSaysAnyNameOnceAndEndsItsSentence() {
    CompanionChoice.keepInMemory(starting: .moku)
    let model = OnboardingModel(); model.companion = .moku
    func greet(_ name: String) -> String { model.suggestedName = name; return model.greeting }
    #expect(greet("Charles") == "Hi, Charles. I’m Moku.")
    #expect(greet("") == "Hi! I’m Moku.")
    #expect(greet("   \n") == "Hi! I’m Moku.")
    #expect(greet("Dr.") == "Hi, Dr. I’m Moku.")  // one full stop, not two
    model.companion = .tetsu
    #expect(greet("مريم") == "Hi, مريم. I’m Tetsu.")
    #expect(greet("🦊 Ana") == "Hi, 🦊 Ana. I’m Tetsu.")
    for stress in [String(repeating: "a", count: 200), String(repeating: "🦊", count: 90), "Mary\tAnn\nLou"] {
        model.suggestedName = stress
        #expect(model.resultName.utf16.count <= PersonName.maxUTF16 && !model.resultName.contains(where: \.isNewline) && model.resultName != "friend")
    }
}

/// The window is tall enough for a long name and never taller than a short screen, whatever the name.
@Test @MainActor func theWelcomeFitsEveryNameOnEveryScreen() {
    let screens = [CGRect(x: 0, y: 0, width: 1470, height: 850), CGRect(x: 0, y: 0, width: 1280, height: 640), CGRect(x: 0, y: 0, width: 1024, height: 600)]
    for name in ["", "Charles", String(repeating: "Wolfeschlegelsteinhausenbergerdorff ", count: 3), String(repeating: "🦊", count: 80), "مرحبا بالعالم الجميل", "山田太郎"] {
        for choosing in [false, true] {
            let model = OnboardingModel(); model.suggestedName = name; model.choosing = choosing
            for screen in screens {
                let size = MokuOnboardingPresenter.size(for: model, visible: screen)
                #expect(size.width == OnboardingView.width(choosing: choosing))
                #expect(size.height <= max(480, screen.height - 24) && size.height >= 480, "\(name.prefix(12)) \(screen.height): \(size.height)")
            }
        }
    }
}

/// Where the welcome got to survives macOS's Quit & Reopen, for half an hour and no more, and a damaged note is no note.
@Test func theWelcomeKeepsItsPlaceForHalfAnHourOnly() {
    let suite = "MokuVisualTests.progress.\(UUID().uuidString)"
    let store = UserDefaults(suiteName: suite)!; defer { store.removePersistentDomain(forName: suite) }
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(OnboardingProgress.resumable(in: store, now: at) == nil)
    OnboardingProgress.save(name: "Alex", asked: [.screenRecording, .accessibility], in: store, now: at)
    let kept = OnboardingProgress.resumable(in: store, now: at.addingTimeInterval(29 * 60))
    #expect(kept?.name == "Alex" && kept?.asked == [.accessibility, .screenRecording])
    #expect(OnboardingProgress.resumable(in: store, now: at.addingTimeInterval(31 * 60)) == nil)
    #expect(OnboardingProgress.resumable(in: store, now: at.addingTimeInterval(-60)) == nil)  // a clock set back
    OnboardingProgress.clear(in: store)
    #expect(OnboardingProgress.resumable(in: store, now: at) == nil)
    store.set(["name": 5, "at": "yesterday"], forKey: OnboardingProgress.key)
    #expect(OnboardingProgress.resumable(in: store, now: at) == nil)
    store.set(["asked": ["nonsense"], "at": at.timeIntervalSince1970], forKey: OnboardingProgress.key)
    #expect(OnboardingProgress.resumable(in: store, now: at)?.asked == [])
}

/// Skip and the close button end the welcome, and "Start with your Mac" is still the person's: a switch they flipped is
/// kept, and one they never touched changes nothing (a development build isn't added to the login items).
/// (In WelcomeWindowTests: every test that opens a welcome shares VisualSessionState.shared.onboarding, so one at a time.)
extension WelcomeWindowTests {
    final class FirstUseLog { var login: [Bool] = []; var enabled = true }
    private func context(_ log: FirstUseLog) -> OnboardingContext {
        OnboardingContext(suggestedName: "Riley", permissions: { PermissionStatus(accessibility: false, screenRecording: false) }, requestPermission: { _ in },
                          launchAtLogin: { log.enabled }, setLaunchAtLogin: { log.login.append($0); log.enabled = $0 })
    }
    @Test func skipAndCloseKeepTheLoginSwitchThePersonSet() async {
        _ = NSApplication.shared
        for (flip, close) in [(false, false), (true, false), (false, true), (true, true)] {
            let log = FirstUseLog()
            let presenter = MokuOnboardingPresenter(stage: QuietStage(), offscreen: true)
            presenter.pointSeconds = 0.05
            let run = Task { await presenter.run(context(log)) }
            while presenter.panel == nil { await Task.yield() }
            if flip { presenter.state.startWithMac = false }
            if close { presenter.windowWillClose(Notification(name: NSWindow.willCloseNotification)) } else { presenter.state.skip() }
            let result = await run.value
            #expect(!result.completed && result.name == "Riley")
            #expect(log.login == (flip ? [false] : []), "flip \(flip), close \(close): \(log.login)")
        }
    }
    @Test func theWindowIsNamedForTheCompanionOnShow() async {
        _ = NSApplication.shared
        CompanionChoice.keepInMemory(starting: .moku)
        let presenter = MokuOnboardingPresenter(stage: QuietStage(), offscreen: true)
        presenter.pointSeconds = 0.05
        let run = Task { await presenter.run(context(FirstUseLog())) }
        while presenter.panel == nil { await Task.yield() }
        #expect(presenter.panel?.title == "Hello, Moku")
        if Companion.available.contains(.tetsu) {
            presenter.state.choose(.tetsu)
            #expect(presenter.panel?.title == "Hello, Tetsu" && presenter.state.greeting.hasSuffix("I’m Tetsu."))
            presenter.state.choose(.moku)  // and back, before the first has finished arriving
            #expect(presenter.panel?.title == "Hello, Moku" && presenter.state.companion == .moku)
        }
        presenter.state.skip(); _ = await run.value
        CompanionChoice.keepInMemory(starting: .moku)
    }
}

/// Quiet text over the paper: SwiftUI's .secondary measured 2.5:1 there. Normal quiet text now meets WCAG AA for small
/// text, and Increase Contrast reaches AAA.
@Test func quietTextReadsOnThePaper() {
    #expect(Quiet.contrast(.secondary) >= 4.5)
    #expect(Quiet.contrast(.dimmed) >= 3)
    #expect(Quiet.contrast(.secondary, increased: true) >= 7)
    #expect(Quiet.contrast(.dimmed, increased: true) >= 4.5)
    #expect(Quiet.contrast(.secondary) > Quiet.contrast(.dimmed))  // the dimmed one still recedes
}

/// The companion's own words for a first day.
@Test func theEmptyDaySaysTheRightCompanion() {
    #expect(Companion.moku.emptyDayLine.contains("Moku") && !Companion.moku.emptyDayLine.contains("Tetsu"))
    #expect(Companion.tetsu.emptyDayLine.contains("Tetsu") && !Companion.tetsu.emptyDayLine.contains("Moku") && !Companion.tetsu.emptyDayLine.contains("kettle"))
}

/// Settings' name field: made safe for the brain, an empty field is no name, and what was kept is what the field shows.
@Test @MainActor func settingsKeepsAnyNameTheBrainWillTake() async {
    final class Saved { var names: [String] = [] }
    let saved = Saved(), model = SettingsModel()
    var config = CompanionConfig.standard; config.userName = "Charles"
    model.loadConfig = { config }
    model.saveConfig = { patch in if let name = patch.userName { saved.names.append(name); config.userName = name }; return config }
    await model.load()
    func commit(_ text: String) async { model.name = text; model.commitName(); for _ in 0..<150 where saved.names.isEmpty { try? await Task.sleep(for: .milliseconds(10)) } }
    await commit("  Riley \n"); #expect(saved.names == ["Riley"] && model.name == "Riley")
    saved.names = []
    await commit(String(repeating: "🦊", count: 40)); #expect(saved.names == [String(repeating: "🦊", count: 30)] && model.name.utf16.count == 60)
    saved.names = []
    await commit(""); #expect(saved.names == ["friend"])  // cleared: no name
    saved.names = []
    model.name = "friend"; model.commitName(); try? await Task.sleep(for: .milliseconds(600)); #expect(saved.names.isEmpty)  // already so
}

/// VoiceOver (#15): a control drawn as an icon, or a text field with no title, says nothing unless it's named. Read from the
/// source (a SwiftUI view's accessibility tree can't be read reliably offscreen): every `label: { Image(systemName:` control
/// and every `TextField("",` in the views a person uses names itself within the next few lines.
@Test func everyIconControlAndFieldNamesItself() throws {
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/MokuVisual")
    var unnamed: [String] = [], checked = 0
    for file in ["Onboarding", "WorldPresenter", "Today", "SettingsWindow", "BreakTimer", "Postcard", "CharacterOverlay"] {
        let lines = try String(contentsOf: sources.appendingPathComponent("\(file).swift"), encoding: .utf8).components(separatedBy: "\n")
        for (index, line) in lines.enumerated() where line.contains("label: { Image(systemName:") || line.contains("TextField(\"\"") {
            checked += 1
            let near = lines[index...min(lines.count - 1, index + 3)].joined(separator: " ")
            if !near.contains("accessibilityLabel") { unnamed.append("\(file).swift:\(index + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(90))") }
        }
    }
    #expect(checked >= 7, "the lint should find the icon buttons and fields it guards (found \(checked))")
    #expect(unnamed.isEmpty, "\(unnamed)")
}

/// The companion's body and the menu bar icon name the companion on show, and "press" does what a click does.
@Test @MainActor func theCompanionAndTheIconSpeakForVoiceOver() {
    CompanionChoice.keepInMemory(starting: .moku)
    let view = CharacterView(frame: CGRect(origin: .zero, size: StageGeometry.size))
    #expect(view.accessibilityLabel() == "Moku, your companion" && view.accessibilityRole() == .button)
    #expect(!view.accessibilityPerformPress())  // nothing to open yet
    var opened = 0; view.clicked = { opened += 1 }
    #expect(view.accessibilityPerformPress() && opened == 1)
    CompanionChoice.keepInMemory(starting: .tetsu)
    #expect(Companion.current != .tetsu || view.accessibilityLabel() == "Tetsu, your companion")
    CompanionChoice.keepInMemory(starting: .moku)
}
