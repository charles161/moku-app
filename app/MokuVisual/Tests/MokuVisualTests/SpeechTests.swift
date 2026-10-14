import AppKit
import Testing
import MokuKit
@testable import MokuVisual

/// Tetsu's dot-matrix lettering (DotFont, DotText) and the companions' bubbles (SpeechBubbleView).
@MainActor
@Suite("Speech: the dot font and the bubbles")
struct SpeechTests {
    @Test func everyPrintableLetterIsInTheFont() {
        for value in 32...126 {
            let character = Character(UnicodeScalar(UInt8(value)))
            #expect(DotFont.glyph(character) != nil, "\(character)")
        }
        for character in "’“”…—–•♥€£¿¡ßæøœł" { #expect(DotFont.glyph(character) != nil, "\(character)") }
    }

    @Test func accentsSitAboveTheirLetterWithADarkRowBetween() throws {
        // A small letter: the accent in rows -1…0, nothing in row 1, the letter from row 2.
        let e = try #require(DotFont.glyph("é")), plain = try #require(DotFont.glyph("e"))
        #expect(e.dots.count > plain.dots.count)
        #expect(e.dots.contains { $0.y < 1 } && !e.dots.contains { $0.y == 1 })
        // A capital: the accent above the cap height.
        let capital = try #require(DotFont.glyph("É"))
        #expect(capital.dots.contains { $0.y < 0 })
        // ï loses its own dot for the diaeresis; ç hangs its cedilla under the baseline.
        let i = try #require(DotFont.glyph("ï"))
        #expect(i.dots.filter { $0.y < 1 }.count == 2)
        #expect(try #require(DotFont.glyph("ç")).dots.contains { $0.y >= 7 })
    }

    @Test func textTheDotsCantSpellIsSetInTypeAndRightToLeftIsKnown() {
        #expect(DotFont.spells("Charles, can we focus? I want my rocket built."))
        #expect(DotFont.spells("Élodie, ça va? 💧🚀"))
        #expect(DotFont.spells("Привет, Ωμέγα"))  // drawn into the grid
        #expect(!DotFont.spells("مرحبا"))
        #expect(!DotFont.spells("你好"))
        #expect(DotFont.readsRightToLeft("مرحبا بك"))
        #expect(DotFont.readsRightToLeft("12 שלום"))
        #expect(!DotFont.readsRightToLeft("Hello مرحبا"))
    }

    @Test func linesWrapInsideTheirWidthAndKeepEveryLetterInOrder() {
        let text = "Charles, can we focus? I want my rocket built."
        let layout = DotText(text, width: 60)
        #expect(layout.lines > 1)
        #expect(layout.lineWidths.allSatisfy { $0 <= 60 })
        let letters = layout.glyphs.filter { !$0.isSpace }
        #expect(letters.count == text.filter { $0 != " " }.count)
        // Reading order: left to right on a line, then down.
        for (a, b) in zip(layout.glyphs, layout.glyphs.dropFirst()) { #expect(a.line < b.line || a.line == b.line && a.x < b.x) }
        // The cursor stands a dot after the last letter.
        let last = layout.glyphs[layout.glyphs.count - 1]
        #expect(layout.cursor(after: layout.glyphs.count) == (last.x + last.glyph.width + 1, last.line))
        #expect(layout.cursor(after: 0) == (0, 0))
    }

    @Test func aLongLineEndsInAnEllipsisAndAWordTooLongForALineBreaks() {
        let long = DotText(String(repeating: "focus again ", count: 30), width: 60, maxLines: 3)
        #expect(long.lines == 3)
        #expect(long.glyphs.last?.glyph == DotFont.glyph("…"))
        #expect(long.lineWidths.allSatisfy { $0 <= 60 })
        let word = DotText(String(repeating: "m", count: 40), width: 30)
        #expect(word.lines > 1 && word.lineWidths.allSatisfy { $0 <= 30 })
    }

    @Test func eachCompanionTalksInItsOwnStyle() {
        #expect(SpeechStyle(.moku) == .paper)
        #expect(SpeechStyle(.tetsu) == .led)
        #expect(SpeechInk.led(.calling) == SpeechInk.amber && SpeechInk.led(.warm) == SpeechInk.cyan)
    }

    @Test func bubblesAreSizedForTheirLineAndDrawnCrispAtEachScale() throws {
        let short = SpeechLine(text: "Welcome back!", tone: .warm), long = SpeechLine(text: "Charles, can we focus? I want my rocket built. The roof is still waiting.", tone: .warm)
        for style in [SpeechStyle.paper, .led] {
            let a = SpeechBubbleView(content: .line(short), style: style, name: "Tetsu", dark: false, scale: 2, reduced: false)
            let b = SpeechBubbleView(content: .line(long), style: style, name: "Tetsu", dark: true, scale: 2, reduced: false)
            let thinking = SpeechBubbleView(content: .thinking, style: style, name: "Tetsu", dark: false, scale: 2, reduced: false)
            #expect(b.frame.height > a.frame.height)
            #expect(thinking.frame.width < a.frame.width)
            // Inside the panel's limits (StageMovement: at most 260 points tall).
            #expect(b.frame.height <= 260 && b.frame.width <= 340)
            for scale in [1, 2] as [CGFloat] {
                let image = try #require(a.snapshot(scale: scale))
                #expect(image.width == Int((a.bounds.width * scale).rounded()) && image.height == Int((a.bounds.height * scale).rounded()))
            }
        }
        // The ask ends with Tetsu's prompt: a line taller than the same words said warmly.
        let ask = SpeechBubbleView(content: .line(SpeechLine(text: "Charles, can we focus?", tone: .calling)), style: .led, name: "Tetsu", dark: false, scale: 2, reduced: false)
        let warm = SpeechBubbleView(content: .line(SpeechLine(text: "Charles, can we focus?", tone: .warm)), style: .led, name: "Tetsu", dark: false, scale: 2, reduced: false)
        #expect(ask.frame.height == warm.frame.height + CGFloat(DotFont.lineRows) * 2)
    }

    @Test func tetsuTypesItsLinesOnUnlessMotionIsReduced() {
        let line = SpeechLine(text: "Charles, can we focus? I want my rocket built.", tone: .calling)
        let typing = SpeechBubbleView(content: .line(line), style: .led, name: "Tetsu", dark: false, scale: 2, reduced: false)
        typing.play()
        #expect(typing.typingSeconds > 0.5 && typing.typingSeconds <= 1.6)
        let still = SpeechBubbleView(content: .line(line), style: .led, name: "Tetsu", dark: false, scale: 2, reduced: true)
        still.play()
        #expect(still.typingSeconds == 0)
        // A very long line still types on in about the same time: the steps get quicker.
        let long = SpeechBubbleView(content: .line(SpeechLine(text: String(repeating: "focus ", count: 40), tone: .warm)), style: .led, name: "Tetsu", dark: false, scale: 2, reduced: false)
        long.play()
        #expect(long.typingSeconds <= 1.6 + 1e-9)
    }

    @Test func aBubbleOfAnyWidthLeansTheSameWayOverTheHead() {
        let visible = CGRect(x: 0, y: 70, width: 1470, height: 856)
        let panel = CGRect(origin: CGPoint(x: 700, y: 200), size: StageGeometry.size)
        for width in [96, 282, 320] as [CGFloat] {
            let origin = StageGeometry.speechOrigin(panel: panel, bubble: CGSize(width: width, height: 100), visible: visible, gap: 6, caption: nil)
            #expect(abs(origin.x - (panel.midX - width * StageGeometry.speechLean)) <= 0.5)
        }
    }
}

/// Settings › Breaks & Water: water and breaks can be turned off, and Settings says the companion's name.
@MainActor
@Suite("Settings: breaks, water and the companion")
struct SettingsBreaksTests {
    @MainActor final class Saved { var patches: [CompanionConfigPatch] = [] }

    @Test func offIsZeroInTheConfigAndTheMinutesComeBackWhenTurnedOn() async {
        let saved = Saved(), model = SettingsModel()
        var off = CompanionConfig.standard
        off.drinkEverySec = 0; off.breakAfterSec = 0
        model.loadConfig = { off }
        model.saveConfig = { [saved] patch in saved.patches.append(patch); return off }
        await model.load()
        #expect(!model.drinkOn && !model.breakOn)
        #expect(model.drinkMinutes == 30 && model.breakAfterMinutes == 50)  // kept for when they're turned back on
        model.setDrinkOn(true); model.setBreakOn(true)
        for _ in 0..<200 where saved.patches.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(saved.patches.last?.drinkEverySec == 1_800 && saved.patches.last?.breakAfterSec == 3_000)
        model.setDrinkOn(false); model.setBreakOn(false)
        for _ in 0..<200 where saved.patches.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(saved.patches.last?.drinkEverySec == 0 && saved.patches.last?.breakAfterSec == 0)
    }

    @Test func theRangesAreSensibleAndHoldTheDefaults() {
        #expect(SettingsModel.drinkRange.contains(30) && SettingsModel.drinkRange.lowerBound >= 10)
        #expect(SettingsModel.breakAfterRange.contains(25) && SettingsModel.breakAfterRange.contains(50) && SettingsModel.breakAfterRange.upperBound >= 120)
        #expect(SettingsModel.breakRange.contains(5) && SettingsModel.breakRange.contains(20))
    }

    @Test func breaksAndWaterHaveTheirOwnTabAndGeneralWearsTheCompanionsIcon() {
        #expect(SettingsTab.allCases.contains(.breaks))
        #expect(SettingsTab.breaks.title.contains("Water"))
        #expect(SettingsTab.general.symbol(for: .moku) == "hare" && SettingsTab.general.symbol(for: .tetsu) == "cpu")
        for tab in SettingsTab.allCases { for companion in Companion.allCases { #expect(NSImage(systemSymbolName: tab.symbol(for: companion), accessibilityDescription: nil) != nil) } }
        // Tetsu's words are a robot's: a battery cell, not a cup.
        #expect(Companion.tetsu.sipsWater.contains("battery") && Companion.moku.sipsWater.contains("water"))
    }
}
