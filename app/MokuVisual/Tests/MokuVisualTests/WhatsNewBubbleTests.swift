import AppKit
import Foundation
import Testing
import MokuKit
import MokuMind
@testable import MokuVisual

/// "What's new" in the bubble: each companion's words, the link and its ✕, and one answer per bubble.
@MainActor
@Suite("Speech: What's new")
struct WhatsNewBubbleTests {
    static let line = SpeechLine(text: WhatsNew.words, tone: .cheerful, duration: WhatsNew.bubbleSec, whatsNew: "0.1.9")

    static func bubble(style: SpeechStyle, dark: Bool = false, reduced: Bool = false) -> SpeechBubbleView {
        SpeechBubbleView(content: .line(line), style: style, name: style == .led ? "Tetsu" : "Moku", dark: dark, scale: 2, reduced: reduced)
    }

    @Test func eachCompanionSaysItItsOwnWay() {
        #expect(WhatsNew.words == "I updated! See what’s new")
        #expect(WhatsNewLook.ledText == "> updated: see what’s new")
        // Tetsu's link starts at "see", and its words fit one line of the display.
        #expect(WhatsNewLook.ledText.dropFirst(WhatsNewLook.ledLinkFirstGlyph).hasPrefix("see what’s new"))
        #expect(DotText(WhatsNewLook.ledText, width: 124).lines == 1)
        #expect(Self.bubble(style: .paper).accessibilityLabel() == "Moku says: I updated! See what’s new")
        #expect(Self.bubble(style: .led).accessibilityLabel() == "Tetsu says: I updated! See what’s new")
    }

    @Test func theBubbleIsALinkWithAClose() throws {
        for style in [SpeechStyle.paper, .led] {
            let bubble = Self.bubble(style: style)
            #expect(bubble.whatsNew == "0.1.9")
            #expect(bubble.offersAction && bubble.accessibilityRole() == .button)
            #expect(bubble.accessibilityCustomActions()?.map(\.name) == ["Close"])
            // Within the panel's limits, and drawn at each scale, light and dark.
            #expect(bubble.frame.height <= 260 && bubble.frame.width <= 340)
            for dark in [false, true] { for scale in [1, 2] as [CGFloat] {
                _ = try #require(SpeechBubbleView(content: .line(Self.line), style: style, name: "Moku", dark: dark, scale: scale, reduced: false).snapshot(scale: scale))
            } }
        }
    }

    @Test func aClickOpensAndTheCloseCloses() {
        for style in [SpeechStyle.paper, .led] {
            let bubble = Self.bubble(style: style)
            var opened = 0, closed = 0
            bubble.onActivate = { opened += 1 }
            bubble.onClose = { closed += 1 }
            #expect(bubble.hitTest(CGPoint(x: bubble.card.midX, y: bubble.card.midY)) === bubble)
            #expect(bubble.accessibilityPerformPress())
            #expect(bubble.accessibilityCustomActions()?.first?.handler?() == true)
            #expect(opened == 1 && closed == 1)
        }
    }

    @Test func theLinkAndTheCloseLightUnderThePointer() throws {
        for style in [SpeechStyle.paper, .led] {
            let bubble = Self.bubble(style: style)
            let resting = try #require(bubble.snapshot(scale: 2))
            bubble.light(true)
            let linkLit = try #require(bubble.snapshot(scale: 2))
            bubble.light(false); bubble.lightClose(true)
            let closeLit = try #require(bubble.snapshot(scale: 2))
            #expect(bubble.closeHovered)
            let pictures = [resting, linkLit, closeLit].map { $0.dataProvider?.data as Data? }
            #expect(Set(pictures).count == 3, "\(style)")
        }
    }

    @Test func tetsuTypesItOnUnlessMotionIsReduced() {
        let typing = Self.bubble(style: .led)
        typing.play()
        #expect(typing.typingSeconds > 0)
        let still = Self.bubble(style: .led, reduced: true)
        still.play()
        #expect(still.typingSeconds == 0)
    }

    /// The stage answers once per bubble: a click opens; the ✕, the time running out or another line closes.
    @Test func theStageAnswersOncePerBubble() async throws {
        let stage = MokuCharacterStage(rendersOffscreen: true)
        var answers: [String] = []
        stage.onWhatsNew = { version, opened in answers.append("\(version) \(opened ? "opened" : "closed")") }
        stage.whatsNewUp = "0.1.9"
        stage.answerWhatsNew(opened: true)
        stage.answerWhatsNew(opened: false)  // already answered
        stage.whatsNewUp = "0.1.9"
        stage.dismissSpeech()
        #expect(answers == ["0.1.9 opened", "0.1.9 closed"])
    }

    /// A bubble you can click stays while the pointer is on it. "What's new" (and "Take me there") went from under the
    /// pointer when its 15 s ran out, as the person reached to click it.
    @Test func aClickableBubbleStaysWhileThePointerIsOnIt() async throws {
        let stage = MokuCharacterStage(rendersOffscreen: true)
        stage.setHidden(false)
        var answers: [String] = []
        stage.onWhatsNew = { _, opened in answers.append(opened ? "opened" : "closed") }
        stage.say(SpeechLine(text: WhatsNew.words, tone: .cheerful, duration: 0.3, whatsNew: "0.1.9"))
        let bubble = try #require(stage.speechPanel.contentView as? SpeechBubbleView)
        bubble.setHovered(true)
        try await Task.sleep(for: .seconds(1.2))
        #expect(answers.isEmpty)  // still up, under the pointer
        bubble.setHovered(false)
        try await Task.sleep(for: .seconds(1.2))
        #expect(answers == ["closed"])  // then its time is up
    }

    /// A bubble clicked (or replaced) under the pointer gives the pointer back. Its window goes, so the pointer never
    /// "leaves" it, and the pointing hand stayed pushed after the bubble had gone.
    @Test func aBubbleTakenDownUnderThePointerGivesThePointerBack() throws {
        let stage = MokuCharacterStage(rendersOffscreen: true)
        stage.setHidden(false)
        stage.say(SpeechLine(text: WhatsNew.words, tone: .cheerful, duration: 15, whatsNew: "0.1.9"))
        let clicked = try #require(stage.speechPanel.contentView as? SpeechBubbleView)
        clicked.setHovered(true)
        stage.dismissSpeech()  // as a click does
        #expect(!clicked.pointerInside)
        stage.say(SpeechLine(text: WhatsNew.words, tone: .cheerful, duration: 15, whatsNew: "0.1.9"))
        let replaced = try #require(stage.speechPanel.contentView as? SpeechBubbleView)
        replaced.setHovered(true)
        stage.say(SpeechLine(text: "Sip of water?", tone: .warm))  // another line takes its place
        #expect(!replaced.pointerInside)
    }

    /// The review sheets for Charles: MOKU_WHATS_NEW_LOOK_DIR=<dir> swift test --filter WhatsNewBubbleTests (drawn to pictures,
    /// no window).
    @Test func reviewSheets() async throws {
        guard let path = ProcessInfo.processInfo.environment["MOKU_WHATS_NEW_LOOK_DIR"] else { return }
        try await MokuVisualDiagnostics.whatsNewLook(directory: URL(fileURLWithPath: path))
    }
}

@MainActor
@Suite("The break timer's ✕")
struct BreakTimerEndTests {
    /// The ✕ ends the break and never starts one. It goes to the same toggle as the break button, and the pill stays on
    /// screen for its 0.3 s fade after the break ends: a double-click, or a click as the time runs out, started a new break.
    @Test func theCrossOnlyEndsABreak() {
        let stage = MokuCharacterStage(rendersOffscreen: true)
        var toggles = 0
        stage.onTakeBreak = { toggles += 1 }
        stage.endBreakFromTimer()  // no break: nothing to end
        #expect(toggles == 0)
        stage.setBreakTimer(until: Date().addingTimeInterval(600), total: 600)
        #expect(!stage.breakPanel.ignoresMouseEvents)
        stage.endBreakFromTimer()
        #expect(toggles == 1)
        stage.setBreakTimer(until: nil, total: 0)  // the engine ends it: the pill fades out
        #expect(stage.breakPanel.ignoresMouseEvents)
        stage.endBreakFromTimer()  // the second click of a double-click, on the fading pill
        #expect(toggles == 1)
    }
}
