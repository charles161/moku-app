import CoreGraphics
import Testing
@testable import MokuVisual

/// The menu bar's house fills as much as the popover says (a friend's screenshot, 2026-10-06: the popover said 69% built,
/// the icon looked about 90% full).
@MainActor
@Suite("Menu bar house")
struct MenuBarHouseTests {
    @Test func theSymbolsInkIsMeasured() {
        #expect(MenuBarHouse.ink.count == 72)
        #expect(MenuBarHouse.ink.reduce(0, +) > 100)  // drawn, not an empty bitmap
    }

    @Test func theHouseFillsAsMuchOfItsShapeAsThePopoversPercent() {
        for percent in [10, 25, 50, 69, 75, 90] {
            let filled = MenuBarHouse.inkFraction(below: MenuBarHouse.fillLine(Double(percent) / 100))
            #expect(abs(filled - Double(percent) / 100) <= 0.02, "at \(percent)% the icon shows \(Int((filled * 100).rounded()))% of the house")
        }
    }

    @Test func emptyAtNothingFullAtTheWholeHouseAndNeverGoingBack() {
        #expect(MenuBarHouse.fillLine(0) == 0)
        #expect(MenuBarHouse.fillLine(1) == MenuBarHouse.size.height)
        let lines = (0...100).map { MenuBarHouse.fillLine(Double($0) / 100) }
        #expect(zip(lines, lines.dropFirst()).allSatisfy { $0 <= $1 })
    }
}
