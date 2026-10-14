import AppKit
import MokuKit
import Testing
@testable import MokuVisual

// "Today counted" (DayCounted.swift): what the card says, how it's drawn, and where it goes.

@MainActor
@Suite("Today counted: the card")
struct DayCountedCardTests {
    let samples = MokuVisualDiagnostics.dayCountedSamples()

    @Test func itsNumbersAndTasksAreYourDays() {
        let day = samples.full
        let card = DayCountedContent(summary: day, companion: .moku)
        // Your day's three numbers (TodayView.metric) and its first task cards (TodayModel.goalCards), from the same summary.
        #expect(card.figures.map(\.value) == [minutesText(day.focusedMinutes), "\(day.returns)", minutesText(day.longestFocusMinutes)])
        #expect(card.figures.map(\.value) == ["3h 41m", "5", "52m"])
        let model = TodayModel(); model.summary = day
        let yourDay = model.goalCards.filter { !$0.isOther }.prefix(2)
        #expect(card.tasks == yourDay.map { DayCountedContent.Task(title: $0.title, minutes: minutesText($0.minutes)) })
        #expect(card.tasks.map(\.title) == ["building Moku’s settings", "learning system design"])
        // A task under 10 minutes, or "Other work", never makes the card.
        #expect(DayCountedContent(summary: samples.light, companion: .moku).tasks.map(\.title) == ["reading the onboarding doc"])
    }

    @Test func theLineIsLunasNoteWhenThereIsOneElseTheCompanionsOwn() {
        #expect(DayCountedContent(summary: samples.note, companion: .moku).line == samples.note.note)
        #expect(DayCountedContent(summary: samples.full, companion: .moku).line == "It feels like home now. Thank you for today.")
        #expect(DayCountedContent(summary: samples.full, companion: .tetsu).line == "Launch-ready. Good shift.")
        #expect(DayCountedContent(summary: samples.full, companion: .moku, yesterday: true).header == "YESTERDAY COUNTED")
        #expect(DayCountedContent(summary: samples.full, companion: .tetsu, yesterday: true).line == "Launch-ready yesterday. Ready for today.")
    }

    @Test func aLightDayIsToldItCountedToo() {
        for companion in Companion.allCases {
            for yesterday in [false, true] {
                #expect(DayCountedContent(summary: samples.light, companion: companion, yesterday: yesterday).line.contains("Small days count too."))
                #expect(!DayCountedContent(summary: samples.full, companion: companion, yesterday: yesterday).line.contains("Small days"))
            }
        }
    }

    @Test func everyLineIsKindAndEachCompanionsOwn() {
        for minutes in [20, 35, 45, 70, 95, 150, 200, 240, 600] {
            for yesterday in [false, true] {
                let moku = DayCountedContent.line(minutes: minutes, companion: .moku, yesterday: yesterday)
                let tetsu = DayCountedContent.line(minutes: minutes, companion: .tetsu, yesterday: yesterday)
                #expect(moku != tetsu)
                for line in [moku, tetsu] {
                    let lower = line.lowercased()
                    for word in ["streak", "in a row", "%", "only", "wasted", "distracted", "should", "lost"] { #expect(!lower.contains(word), "\(line)") }
                }
            }
        }
    }

    @Test func itsDrawnForBothCompanionsLightAndDarkAtOneAndTwoTimes() throws {
        for companion in Companion.allCases {
            for summary in [samples.full, samples.light, samples.note, samples.scripts] {
                for dark in [false, true] {
                    for scale in [1, 2] as [CGFloat] {
                        let view = DayCountedCardView(content: DayCountedContent(summary: summary, companion: companion), house: nil,
                                                      style: SpeechStyle(companion), dark: dark, scale: scale, reduced: false)
                        #expect(view.card.width == (companion == .tetsu ? DayCountedDrawing.displayWidth : DayCountedDrawing.paperWidth))
                        #expect((300...520).contains(view.card.height), "\(companion) \(summary.focusedMinutes) min: \(view.card.height) pt tall")
                        let image = try #require(view.snapshot(scale: scale))
                        #expect(image.width == Int((view.bounds.width * scale).rounded()))
                    }
                }
            }
        }
    }

    @Test func everyHomeHasAStillForEveryPieceCount() throws {
        for companion in Companion.available {
            for pieces in 0...DayHouse.pieces {
                let still = try #require(DayCountedStills.load(minutes: pieces * 10 + 3, companion: companion), "\(companion) \(pieces)")
                #expect(still.width == DayCountedStills.pixels.width && still.height == DayCountedStills.pixels.height)
            }
        }
        // Past four hours, the finished home.
        #expect(DayCountedStills.load(minutes: 600, companion: .moku) != nil)
    }

    @Test func itSitsBesideTheCompanionOnScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875), size = CGSize(width: 292, height: 420), inset = DayCountedCardView.inset
        // At home, bottom right: the card is to its left, its bottom at the companion's feet.
        let home = CGRect(origin: StageGeometry.home(in: visible, scale: 1), size: StageGeometry.size)
        let placed = DayCountedGeometry.place(window: size, inset: inset, companion: home, visible: visible)
        let card = CGRect(x: placed.origin.x + inset, y: placed.origin.y + inset, width: size.width - 2 * inset, height: size.height - 2 * inset)
        let bodyLeft = home.minX + StageGeometry.characterFrame.midX - StageGeometry.bodyLeft
        #expect(placed.companionOnRight)
        #expect(card.maxX <= bodyLeft - DayCountedGeometry.gap + 1)
        #expect(abs(card.minY - (home.minY + StageGeometry.feet.y)) <= 1)
        #expect(visible.contains(card))
        // Put at the left edge: the card goes to its right.
        let left = CGRect(x: -100, y: 300, width: StageGeometry.size.width, height: StageGeometry.size.height)
        let right = DayCountedGeometry.place(window: size, inset: inset, companion: left, visible: visible)
        #expect(!right.companionOnRight)
        #expect(right.origin.x + inset >= left.minX + StageGeometry.characterFrame.midX + StageGeometry.bodyRight)
        // Near the top: it stays on screen.
        let high = CGRect(x: 700, y: 800, width: StageGeometry.size.width, height: StageGeometry.size.height)
        let top = DayCountedGeometry.place(window: size, inset: inset, companion: high, visible: visible)
        #expect(top.origin.y + size.height - inset <= visible.maxY)
    }

    @Test func reduceMotionOnlyFades() throws {
        for companion in Companion.allCases {
            let calm = DayCountedCardView(content: DayCountedContent(summary: samples.full, companion: companion), house: nil,
                                          style: SpeechStyle(companion), dark: false, scale: 2, reduced: true)
            calm.playEntrance(fromRight: true)
            let layer = try #require(calm.layer?.sublayers?.first)
            #expect(layer.animationKeys() == ["in"])
            let lively = DayCountedCardView(content: DayCountedContent(summary: samples.full, companion: companion), house: nil,
                                            style: SpeechStyle(companion), dark: false, scale: 2, reduced: false)
            lively.playEntrance(fromRight: true)
            #expect((lively.layer?.sublayers?.first?.animationKeys()?.count ?? 0) >= 2)
        }
    }

    @Test func aClickOpensYourDayAndTheCrossCloses() throws {
        let view = DayCountedCardView(content: DayCountedContent(summary: samples.full, companion: .moku), house: nil,
                                      style: .paper, dark: false, scale: 2, reduced: true)
        var opened = 0, closed = 0
        view.onOpen = { opened += 1 }; view.onClose = { closed += 1 }
        #expect(view.accessibilityPerformPress())
        #expect(opened == 1)
        let close = try #require(view.accessibilityCustomActions()?.first { $0.name == "Close" })
        _ = close.handler?()
        #expect(closed == 1)
        #expect(view.accessibilityLabel()?.hasPrefix("Today counted. 3h 41m focused, 5 returns, 52m longest.") == true)
    }
}
