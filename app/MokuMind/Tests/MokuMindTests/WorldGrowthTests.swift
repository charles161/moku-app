import Testing
@testable import MokuMind

@Suite("World growth")
struct WorldGrowthTests {
    @Test(arguments: [
        (4.99, nil),
        (5.0, 0.5),
        (8.0, 0.8),
        (20.0, 2.0),
        (47.0, 4.7),
        (50.0, 5.0),
        (240.0, 5.0),
    ] as [(Double, Double?)])
    func returnGrowthScalesWithTheFocusBeforeTheDrift(minutes: Double, points: Double?) {
        #expect(WorldGrowth.returnPoints(focusMinutesBefore: minutes) == points)
    }

    @Test func returnGrowthNeverExceedsTenPercentOfTheFocusThatEarnedIt() {
        for tenths in 0...3_000 {
            let minutes = Double(tenths) / 10
            if let points = WorldGrowth.returnPoints(focusMinutesBefore: minutes) {
                #expect(points <= minutes * 0.1 + 1e-9)
            }
        }
    }

    @Test func focusedSecondsBecomeWholeMinutesWithACarry() {
        #expect(WorldGrowth.creditableMinutes(focusedSeconds: 59.5) == (0, 59.5))
        #expect(WorldGrowth.creditableMinutes(focusedSeconds: 60) == (1, 0))
        #expect(WorldGrowth.creditableMinutes(focusedSeconds: 185) == (3, 5))
        #expect(WorldGrowth.creditableMinutes(focusedSeconds: -1) == (0, 0))
    }
}
