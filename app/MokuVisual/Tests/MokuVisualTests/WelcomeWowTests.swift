import AppKit
import Foundation
import Testing
import MokuKit
@testable import MokuVisual

/// The welcome Charles picked ("A + C", docs/specs/welcome-wow.md): two pages, the companion's own exits, the plain
/// account word for word in both, where the icon is however it ends, and moves that never jump.

@MainActor private final class StubStage: CharacterStage {
    var onPat: (@MainActor ()->Void)?; var onClick: (@MainActor ()->Void)?
    var lines: [String] = []
    func show() {}; func setHidden(_ value: Bool) {}; func setMood(_ value: Mood) {}; func setAttention(_ value: AttentionTarget) {}; func perform(_ value: MokuKit.Gesture) {}; func move(to value: StageSpot) async {}
    func say(_ value: SpeechLine) { lines.append(value.text) }; func dismissSpeech() {}
}

/// What Moku reads, where it's kept and how it's processed: today's words, exactly, on both companions' pages.
@Test @MainActor func thePlainAccountIsWordForWordOnBothPages() {
    #expect(PlainAccount.accessibility.why == "Which app, window and web page you’re on, and your typing pace.")
    #expect(PlainAccount.accessibility.without == "Without it, I can’t see web addresses or your typing, so I’m less sure what’s work.")
    #expect(PlainAccount.screenRecording.why == "A few words from that window, read on this Mac.")
    #expect(PlainAccount.screenRecording.without == "Without it, I go by the app, the window’s name and the address.")
    #expect(PlainAccount.never == "Never the keys you press, never sound, never password managers.")
    #expect(PlainAccount.kept.text == "On this Mac: your days, your houses, your name. Pictures of your screen are read here, then let go: never saved, never sent.")
    #expect(PlainAccount.processed.text == "To tell work from a detour, a short excerpt, with the app, the window’s name and the address, goes to an AI that’s asked to keep nothing. We don’t keep it either.")
    // Tetsu's self-test says the same sentences (with Accessibility's "without" while it's off), in its dots.
    let model = OnboardingModel(); model.companion = .tetsu
    let lines = SelfTestLines.lines(model).map(\.text)
    for sentence in [PlainAccount.accessibility.why, PlainAccount.accessibility.without, PlainAccount.screenRecordingOptional,
                     PlainAccount.never, PlainAccount.kept.text, PlainAccount.processed.text] {
        #expect(lines.contains { $0.contains(sentence) }, "\(sentence)")
    }
    // Screen Recording is optional and isn't asked for in the welcome (the friends, 2026-10-14): no Allow on its line.
    #expect(SelfTestLines.lines(model).first { $0.label == "READER" }?.status == SelfTestLines.Status.none)
    #expect(!SelfTestLines.lines(model).contains { $0.status == .allow(.screenRecording) })
    model.permissions = PermissionStatus(accessibility: true, screenRecording: true)
    #expect(!SelfTestLines.lines(model).contains { $0.text.contains("Without it") })  // allowed: no "without"
    #expect(SelfTestLines.lines(model).first { $0.label == "READER" }?.text == PlainAccount.screenRecording.why)
    for line in SelfTestLines.lines(model).map(\.text) + [PlainAccount.reopen, "SELF-TEST · WHAT I READ, WHERE IT’S KEPT", "HELLO, CHARLES", OnboardingModel.whatItDoes] {
        #expect(DotFont.spells(line), "Tetsu can't spell in dots: \(line)")  // so it's never set in type by surprise
    }
}

/// Hello, then what it reads; the other companion leans in only while its name is hovered; picking it changes the
/// window (Tetsu's is a dark screen), its title and the greeting.
/// (In WelcomeWindowTests: every test that opens a welcome shares VisualSessionState.shared.onboarding, so one at a time.)
extension WelcomeWindowTests {
    private func flowContext() -> OnboardingContext {
        OnboardingContext(suggestedName: "Riley", permissions: { PermissionStatus(accessibility: false, screenRecording: false) }, requestPermission: { _ in },
                          launchAtLogin: { false }, setLaunchAtLogin: { _ in })
    }
    @Test func helloThenWhatItReadsThenStart() async {
        _ = NSApplication.shared
        CompanionChoice.keepInMemory(starting: .moku)
        let presenter = MokuOnboardingPresenter(stage: StubStage(), offscreen: true)
        presenter.pointSeconds = 0.05
        let icon = CGRect(x: 1200, y: 870, width: 26, height: 24)
        presenter.menuBarIcon = { icon }
        let run = Task { await presenter.run(flowContext()) }
        while presenter.panel == nil { await Task.yield() }
        #expect(presenter.state.page == .hello && presenter.state.hello == "Hi, Riley." && !presenter.state.machine)
        if Companion.available.contains(.tetsu) {
            presenter.state.hover(.moku); #expect(presenter.state.peeking == nil)  // the one on show doesn't lean in
            presenter.state.hover(.tetsu); #expect(presenter.state.peeking == .tetsu)
            presenter.state.hover(nil); #expect(presenter.state.peeking == nil)
            presenter.state.choose(.tetsu)
            #expect(presenter.state.machine && presenter.state.hello == "HELLO, RILEY" && presenter.panel?.title == "Hello, Tetsu")
            presenter.state.choose(.moku)
        }
        presenter.state.next()
        #expect(presenter.state.page == .read)
        presenter.state.next()  // twice does nothing
        #expect(presenter.state.page == .read)
        presenter.state.start()
        let result = await run.value
        #expect(result.completed && presenter.pointLine == "Your house lives up here." && presenter.pointedAt == icon)
        CompanionChoice.keepInMemory(starting: .moku)
    }
    /// Lens 1, call 2: Skip and the close button say where the icon is too, not only Start.
    @Test func skipAndCloseSayWhereTheIconIs() async {
        _ = NSApplication.shared
        for close in [false, true] {
            let stage = StubStage()
            let presenter = MokuOnboardingPresenter(stage: stage, offscreen: true)
            presenter.pointSeconds = 0.05
            let icon = CGRect(x: 1200, y: 870, width: 26, height: 24)
            presenter.menuBarIcon = { icon }
            let run = Task { await presenter.run(flowContext()) }
            while presenter.panel == nil { await Task.yield() }
            if close { presenter.windowWillClose(Notification(name: NSWindow.willCloseNotification)) } else { presenter.state.skip() }
            let result = await run.value
            #expect(!result.completed)
            #expect(presenter.pointedAt == icon && stage.lines.last == "Your house lives up here.", "close \(close)")
            #expect(presenter.spotlight == nil && presenter.spotlightOverlay == nil)  // nothing is left dimming or listening
        }
        // With the icon hidden (a full menu bar), it says to click it instead.
        let stage = StubStage(), presenter = MokuOnboardingPresenter(stage: stage, offscreen: true)
        presenter.pointSeconds = 0.05
        let run = Task { await presenter.run(flowContext()) }
        while presenter.panel == nil { await Task.yield() }
        presenter.state.skip(); _ = await run.value
        #expect(presenter.pointedAt == nil && stage.lines.last == "Click me to see your house.")
        #expect(presenter.spotlight == nil)  // the icon hidden behind the notch: no dim
    }
    /// Tetsu says it in its LED: HOME ↑.
    @Test func tetsuSaysHomeInItsLED() async {
        _ = NSApplication.shared
        guard Companion.available.contains(.tetsu) else { return }
        CompanionChoice.keepInMemory(starting: .tetsu); defer { CompanionChoice.keepInMemory(starting: .moku) }
        let stage = StubStage(), presenter = MokuOnboardingPresenter(stage: stage, offscreen: true)
        presenter.pointSeconds = 0.05; presenter.menuBarIcon = { CGRect(x: 1200, y: 870, width: 26, height: 24) }
        let run = Task { await presenter.run(flowContext()) }
        while presenter.panel == nil { await Task.yield() }
        presenter.state.next(); presenter.state.start(); _ = await run.value
        #expect(stage.lines.last == "HOME ↑")
    }
}

/// How the window goes: the companion's own way on Start, a fade for Skip, the close button and Reduce Motion.
@Test @MainActor func theWindowGoesTheCompanionsWayOnlyOnStartAndNeverWithReduceMotion() {
    let centre = CGPoint(x: 500, y: 400)
    #expect(MokuOnboardingPresenter.exit(for: .start, reduced: false, machine: false, centre: centre) == .letGo(center: centre))
    #expect(MokuOnboardingPresenter.exit(for: .start, reduced: false, machine: true, centre: centre) == .powerOff)
    for machine in [false, true] {
        #expect(MokuOnboardingPresenter.exit(for: .start, reduced: true, machine: machine, centre: centre) == .fade)
        #expect(MokuOnboardingPresenter.exit(for: .skip, reduced: false, machine: machine, centre: centre) == .fade)
        #expect(MokuOnboardingPresenter.exit(for: .closed, reduced: false, machine: machine, centre: centre) == .fade)
    }
}

/// Every exit starts as the window was and ends gone, with no jump between display frames.
@Test func theWindowsExitsAreSmoothFromWholeToGone() {
    for kind in [WindowExit.letGo(center: .zero), .powerOff, .fade] {
        let frames = stride(from: 0.0, through: kind.duration, by: 1.0 / 60).map { kind.state(at: $0) }
        let first = kind.state(at: 0), last = kind.state(at: kind.duration)
        #expect(first.opacity == 1 && first.scaleX == 1 && first.scaleY == 1 && first.hole == 0 && first.flash == 0, "\(kind)")
        switch kind {
        case .letGo: #expect(last.hole >= 1.1)
        case .powerOff: #expect(last.opacity <= 0.001 && last.scaleY < 0.02 && last.scaleX < 0.02)
        case .fade: #expect(last.opacity <= 0.001)
        }
        for (a, b) in zip(frames, frames.dropFirst()) {  // a 60 Hz frame never moves more than a fifth of the way
            #expect(abs(b.hole - a.hole) < 0.2 && abs(b.scaleY - a.scaleY) < 0.2 && abs(b.scaleX - a.scaleX) < 0.25 && abs(b.opacity - a.opacity) < 0.2, "\(kind)")
        }
    }
}

/// Moku's landing in its corner is a small squash and back about its feet, never more than 4%, ending exactly in its
/// shape; it never leaves its seat (no hop: Charles, "i hate the jumping animation").
@Test func theSeatedLandingSettlesWithoutAHop() {
    let frames = stride(from: 0.0, through: SeatedSettle.duration + 0.05, by: 1.0 / 60).map { SeatedSettle.squash(at: $0) }
    #expect(frames.first == CGSize(width: 1, height: 1) && frames.last == CGSize(width: 1, height: 1))
    #expect(frames.allSatisfy { $0.height >= 0.959 && $0.height <= 1 && $0.width >= 1 && $0.width <= 1.021 })
    for (a, b) in zip(frames, frames.dropFirst()) { #expect(abs(b.height - a.height) < 0.012) }
}

/// The welcome fits every screen: the companion stands in its stage under the title bar, the drawn window and its marks
/// fit the band, and the companion leaning in is out of the window until its name is hovered.
@Test @MainActor func theWelcomeLaysOutOnEveryScreen() {
    for visible in stride(from: 560.0, through: 1300, by: 37) {
        let size = MokuOnboardingPresenter.size(for: OnboardingModel(), visible: CGRect(x: 0, y: 0, width: 1440, height: visible))
        #expect(size.width == WelcomeLayout.width && size.height >= 480 && size.height <= max(480, visible - 24) && size.height <= 700)
        let layout = WelcomeLayout(size: size)
        #expect(layout.helloScale >= 0.9 && layout.helloScale <= 1.6)
        #expect(layout.helloFloor - 180 * layout.helloScale >= 26, "\(visible): the companion's ears under the title bar")
        #expect(layout.readFloor - 180 * layout.readScale >= 20 && layout.readScale <= layout.helloScale)
        #expect(layout.sample.minX > layout.readX + 70 && layout.sample.maxX <= size.width - 20 && layout.sample.maxY <= layout.readBand)
        for index in 1...4 {
            let mark = layout.mark(index)
            #expect(mark.minX >= 0 && mark.maxX <= layout.sample.width && mark.minY >= 0 && mark.maxY <= layout.sample.height + 0.5, "\(visible) mark \(index)")
        }
        #expect(layout.peek(in: false).minX >= size.width && layout.peek(in: true).minX < size.width - 60)
    }
}

/// Lens 1, call 5: nothing in the welcome is smaller than 11 points.
@Test func theWelcomesTextIsElevenPointsOrMore() throws {
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/MokuVisual")
    for file in ["WelcomeViews.swift", "Onboarding.swift"] {
        let source = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
        let sizes = try Regex(#"\.system\(size: ([0-9.]+)"#)
        for match in source.matches(of: sizes) {
            let value = Double(source[match.range].split(separator: ":").last!.trimmingCharacters(in: .whitespaces))!
            #expect(value >= 11, "\(file): a \(value) pt font")
        }
        // Dots: a pitch under 1.2 points makes capitals smaller than 11-point type's (seven dots tall).
        for match in source.matches(of: try Regex(#"pitch: ([0-9.]+)"#)) {
            let value = Double(source[match.range].split(separator: ":").last!.trimmingCharacters(in: .whitespaces))!
            #expect(value * 7 >= 8.3, "\(file): dots at \(value) points")
        }
    }
}
