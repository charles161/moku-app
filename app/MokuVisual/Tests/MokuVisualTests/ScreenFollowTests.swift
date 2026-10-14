import Foundation
import Testing
@testable import MokuVisual

/// Charles, 2026-10-14: with several screens, one Moku, which follows you to the screen you work on once you've stayed
/// there about 30 s; glances don't move it.
@Suite struct ScreenFollowTests {
    @Test func workThatStaysOnAnotherScreenForThirtySecondsBringsMokuThere() {
        var follow = ScreenFollow()
        #expect(follow.update(work: "B", own: "A", now: 0) == nil)
        #expect(follow.update(work: "B", own: "A", now: 29) == nil)
        #expect(follow.update(work: "B", own: "A", now: 30) == "B")
        #expect(follow.update(work: "B", own: "A", now: 31) == nil, "once")
    }

    @Test func aGlanceBackStartsTheWaitAgain() {
        var follow = ScreenFollow()
        _ = follow.update(work: "B", own: "A", now: 0)
        _ = follow.update(work: "A", own: "A", now: 20)   // back on Moku's screen
        #expect(follow.update(work: "B", own: "A", now: 35) == nil)
        #expect(follow.update(work: "B", own: "A", now: 65) == "B")
    }

    @Test func workOnMokusOwnScreenOrNowhereMovesNothing() {
        var follow = ScreenFollow()
        #expect(follow.update(work: "A", own: "A", now: 100) == nil)
        #expect(follow.update(work: nil, own: "A", now: 200) == nil)
    }
}
