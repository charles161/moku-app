import Foundation
import MokuKit
import Testing
@testable import MokuMind

@MainActor
@Suite("Test the drift (Settings)")
struct DriftRehearsalTests {
    static func rehearsing() -> Rig {
        let rig = Rig(clock: InstantClock())
        rig.runtime.setManualControl(true)
        return rig
    }

    static func calls(after count: Int, in rig: Rig) -> [FakeStage.Call] { Array(rig.stage.calls.dropFirst(count)) }

    @Test func eachJumpShowsMokuAsTheLadderHasItAtThatStep() async {
        let rig = Self.rehearsing()
        var seen = rig.stage.calls.count
        rig.runtime.testBehavior(.jump(.sad))
        #expect(Self.calls(after: seen, in: rig) == [
            .dismissSpeech, .hidden(false), .gesture(.sitDown), .workState(.noticing), .mood(.disappointed), .attention(.user),
        ])

        seen = rig.stage.calls.count
        // Past the one sad look at the user: its eyes are on the place the (scripted) work was, and its face the normal one.
        let workPlace = AttentionTarget.point(CGPoint(x: 636, y: 464))
        rig.runtime.testBehavior(.jump(.standUp))
        #expect(Self.calls(after: seen, in: rig) == [
            .dismissSpeech, .hidden(false), .workState(.drifting), .mood(.content), .attention(workPlace), .gesture(.standUp),
        ])

        seen = rig.stage.calls.count
        rig.runtime.testBehavior(.jump(.ask))
        await rig.runtime.drain()
        // Already standing (standing up again is a no-op on the stage): it asks where it is, standing tall with no words
        // over its head (the friends, 2026-10-14).
        #expect(Self.calls(after: seen, in: rig) == [
            .dismissSpeech, .hidden(false), .workState(.longDrift), .mood(.content), .attention(workPlace), .gesture(.standUp),
        ])

        seen = rig.stage.calls.count
        rig.runtime.testBehavior(.jump(.sad))
        await rig.runtime.drain()
        // Back to an earlier step: it sits down first.
        #expect(Self.calls(after: seen, in: rig) == [
            .dismissSpeech, .hidden(false), .gesture(.sitDown),
            .workState(.noticing), .mood(.disappointed), .attention(.user),
        ])
    }

    @Test func stoppingATestSitsMokuDownAtHome() async {
        let rig = Self.rehearsing()
        rig.runtime.testBehavior(.jump(.standUp))
        let seen = rig.stage.calls.count
        rig.runtime.setManualControl(false)  // "Stop testing", or closing Settings
        await rig.runtime.drain()
        let calm = Self.calls(after: seen, in: rig)
        #expect(calm.contains(.gesture(.sitDown)) && calm.contains(.workState(.idle)))
        #expect(calm.firstIndex(of: .gesture(.sitDown))! < calm.firstIndex(of: .move(.home))!)
        rig.finish()
    }

    @Test func comingBackPlaysTheEnginesOwnReturn() async {
        let rig = Self.rehearsing()
        rig.runtime.testBehavior(.jump(.ask))
        let seen = rig.stage.calls.count
        rig.runtime.testBehavior(.comeBack)
        await rig.runtime.drain()
        let back = Self.calls(after: seen, in: rig)
        #expect(back.contains(.celebrateReturn(.full)))
        // No words over its head (the friends, 2026-10-14): the return is the celebration alone.
        #expect(!back.contains { if case .say = $0 { true } else { false } })
        #expect(back.contains(.gesture(.sitDown)))
        #expect(back.contains(.workState(.focused)))
        #expect(back.last == .mood(.content))  // settled a few seconds later
    }

    @Test func itOnlyPlaysUnderManualControlAndNeverReachesTheBrain() async {
        let rig = Rig(clock: InstantClock())
        let before = rig.stage.calls
        rig.runtime.testBehavior(.jump(.standUp))
        #expect(rig.stage.calls == before)

        rig.runtime.setManualControl(true)
        for step in BehaviorTest.Step.allCases { rig.runtime.testBehavior(.jump(step)) }
        rig.runtime.testBehavior(.comeBack)
        await rig.runtime.drain()
        #expect(await rig.brain.events.isEmpty)
        #expect(await rig.brain.feedback.isEmpty)
        #expect(await rig.brain.voiceRequests.isEmpty)
    }

    @Test func smileAtMeSettlesIntoFocusThenPlaysTheLookUp() async {
        let rig = Self.rehearsing()
        rig.runtime.testBehavior(.jump(.standUp))
        let seen = rig.stage.calls.count
        rig.runtime.testBehavior(.lookUp)
        await rig.runtime.drain()
        let calls = Self.calls(after: seen, in: rig)
        // Standing from a drift test: it sits down, watches the work, then looks up at the user.
        #expect(Array(calls.prefix(6)) == [.dismissSpeech, .hidden(false), .gesture(.sitDown), .workState(.focused), .mood(.content), .attention(.wander)])
        #expect(calls.contains(.attention(.user)))
        #expect(calls.contains(.gesture(.smile)) || calls.contains(.mood(.happy)))
    }

    @Test func theJumpsFollowTheConfiguredTimings() {
        var config = CompanionConfig.standard
        config.userName = "Charles"
        config.standUpAfterSec = 100
        var rehearsal = DriftRehearsal(config: config, tuning: .standard)
        let standing = rehearsal.jump(to: .standUp)
        #expect(standing.standing && standing.tier == .drifting)
        rehearsal = DriftRehearsal(config: config, tuning: .standard)
        let asking = rehearsal.jump(to: .ask)
        #expect(asking.standing && asking.tier == .longDrift)
        #expect(asking.lines.isEmpty)  // the ask has no words any more (the friends, 2026-10-14)
    }
}
