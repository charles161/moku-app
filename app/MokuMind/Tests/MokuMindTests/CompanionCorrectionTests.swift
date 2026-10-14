import Foundation
import MokuKit
import Testing
@testable import MokuMind

/// Charles, 2026-10-14: right-click the companion to correct it. "This is work" in a drift, "This isn't work" while it
/// thinks you work. The brain relabels from a time (`since`) and learns the screen; Moku settles without a sad move.
@Suite("Corrections from the companion")
struct CompanionCorrectionTests {
    @Test func thisIsWorkInADriftRelabelsTheDriftAndSettlesLikeAPat() {
        var h = EngineHarness()
        h.work(600)
        h.drift(90)
        let corrected = h.send(.correct(isWork: true))
        #expect(corrected.feedback.map(\.kind) == [.markedWork])
        let since = corrected.feedback.first?.since?.timeIntervalSince(EngineHarness.base)
        #expect(since.map { abs($0 - 600) <= 10 } == true, "since \(String(describing: since)): the drift's start")
        #expect(h.status.phase == .focused)
        #expect(!corrected.notableEventTypes.contains(.returned))  // no return, no bonus
        h.pass(6, judging: .working)
        #expect(h.status.mood == .content)  // a happy blip, as for a pat ("got it"), then the normal face
    }

    @Test func thisIsntWorkRelabelsFromWhenTheWindowCameToTheFrontAndHoldsTheSadMove() {
        var h = EngineHarness()
        h.send(.focusChanged(Fixtures.browserApp, Fixtures.youtubeWindow))
        h.wait(5)
        h.work(300, context: Fixtures.youtube)
        let corrected = h.send(.correct(isWork: false))
        #expect(corrected.feedback.map(\.kind) == [.markedNotWork])
        #expect(corrected.feedback.first?.since == EngineHarness.base)  // when that window came to the front
        #expect(corrected.gestures == [.nod])  // heard
        // The person said so: the drift that follows is counted, without a sad move.
        let drift = h.drift(60, context: Fixtures.youtube)
        #expect(!drift.gestures.contains(.sigh) && !drift.moods.contains(.disappointed))
    }

    @Test func eachCorrectionOnlyInItsState() {
        var working = EngineHarness()
        working.work(300)
        #expect(working.send(.correct(isWork: true)).feedback.isEmpty)
        var drifting = EngineHarness()
        drifting.work(300)
        drifting.drift(60)
        #expect(drifting.send(.correct(isWork: false)).feedback.isEmpty)
    }
}
