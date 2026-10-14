import CoreGraphics
import Foundation
import MokuKit
import Testing
@testable import MokuMind

/// A runtime with fakes around it, on the clock a test chooses.
@MainActor
struct Rig {
    let brain = FakeBrain()
    let stage = FakeStage()
    let world = FakeWorld()
    let model = WorldModel(snapshot: Fixtures.snapshot(points: 700))
    let clock: any RuntimeClock
    let runtime: CompanionRuntime

    init(clock: any RuntimeClock = ManualClock()) {
        self.clock = clock
        let (senses, _) = AsyncStream.makeStream(of: SenseEvent.self)
        runtime = CompanionRuntime(senses: senses, brain: brain, stage: stage, world: world, worldModel: model, clock: clock)
    }

    var manualClock: ManualClock { clock as! ManualClock }

    /// A tick per simulated second, with `each` sending whatever the senses would.
    func run(_ seconds: Int, from start: Double, each: (Double) -> Void = { _ in }) async {
        for second in 1...seconds {
            let t = start + Double(second)
            manualClock.set(t)
            each(t)
            runtime.tick()
            await runtime.drain()
        }
    }

    func sample(_ id: String, _ window: WindowInfo, app: AppInfo = Fixtures.browserApp) {
        runtime.handle(.sample(Samples.sample(id, app: app, window: window)))
    }

    func scene(_ kind: ManualSceneKind) -> ManualScene {
        runtime.manualScenes().first { $0.id == kind.rawValue }!
    }

    func finish() {
        stage.releaseMoves()
        runtime.stop()
        (clock as? ManualClock)?.cancelSleepers()
    }
}

/// Is `steps` found in `calls`, in this order (other calls may come between)?
func inOrder(_ calls: [FakeStage.Call], _ steps: [(FakeStage.Call) -> Bool]) -> Bool {
    var remaining = steps[...]
    for call in calls where remaining.first?(call) == true {
        remaining = remaining.dropFirst()
    }
    return remaining.isEmpty
}

func call(_ expected: FakeStage.Call) -> (FakeStage.Call) -> Bool { { $0 == expected } }

func said(_ tone: SpeechLine.Tone) -> (FakeStage.Call) -> Bool {
    { if case let .say(line) = $0 { line.tone == tone } else { false } }
}

let calmCalls: [FakeStage.Call] = [
    .dismissSpeech, .hidden(false), .gesture(.sitDown), .workState(.idle), .mood(.content), .attention(.wander), .move(.home),
]

@MainActor
@Suite("Manual control")
struct ManualControlTests {
    @Test func manualControlIgnoresTheSensesAndFreezesTheEngine() async {
        let rig = Rig()
        rig.runtime.start()
        await rig.runtime.drain()
        await rig.run(30, from: 0) { t in
            if Int(t) % 3 == 0 { rig.sample("w\(Int(t))", Fixtures.editorWindow, app: Fixtures.editorApp) }
        }
        #expect(rig.runtime.status.phase == .focused)
        let streakBefore = rig.runtime.status.focusStreakSec

        rig.runtime.setManualControl(true)
        let judged = await rig.brain.judgedSampleIds.count
        let calls = rig.stage.calls.count
        await rig.run(600, from: 30) { t in
            rig.runtime.handle(.focusChanged(Fixtures.browserApp, Fixtures.youtubeWindow))
            rig.runtime.handle(.attention(CGPoint(x: t, y: 300)))
            if Int(t) % 3 == 0 { rig.sample("d\(Int(t))", Fixtures.youtubeWindow) }
        }
        #expect(await rig.brain.judgedSampleIds.count == judged)
        #expect(rig.stage.calls.count == calls)
        #expect(await rig.brain.events.isEmpty)
        #expect(rig.runtime.status.focusStreakSec == streakBefore)

        // Resuming counts none of the manual time: the first focused minute is a fresh one.
        rig.runtime.setManualControl(false)
        await rig.runtime.drain()
        #expect(rig.runtime.status.phase == .settling)
        #expect(rig.runtime.status.focusStreakSec == 0)
        await rig.run(70, from: 630) { t in
            if Int(t) % 3 == 0 { rig.sample("r\(Int(t))", Fixtures.editorWindow, app: Fixtures.editorApp) }
        }
        #expect(await rig.brain.events.map(\.type) == [.focusGrowth])
        rig.finish()
    }

    @Test func repliesToRequestsStartedBeforeManualControlAreIgnored() async {
        let rig = Rig()
        await rig.brain.set(judged: .drifting)
        await rig.brain.set(holdJudges: true)
        rig.runtime.start()
        rig.runtime.handle(.focusChanged(Fixtures.browserApp, Fixtures.youtubeWindow))
        rig.sample("s1", Fixtures.youtubeWindow)
        #expect(await eventually { await rig.brain.heldJudgeCount == 1 })
        rig.runtime.setManualControl(true)
        await rig.brain.releaseJudges()
        await rig.runtime.drain()
        #expect(rig.runtime.status.phase == .settling)
        #expect(!rig.stage.gestures.contains(.glance))
        rig.finish()
    }

    @Test func underManualControlAPatOnlyReactsAndAClickStillOpensTheWorld() async {
        let rig = Rig()
        rig.runtime.start()
        await rig.runtime.drain()
        rig.runtime.setManualControl(true)
        rig.stage.onPat?()
        rig.stage.onClick?()
        await rig.runtime.drain()
        #expect(rig.stage.gestures.isEmpty)  // the stage played its own pat reaction: nothing more
        #expect(rig.world.opened == 1)
        #expect(await rig.brain.feedback.isEmpty)
        #expect(await rig.brain.events.isEmpty)
        rig.finish()
    }

    @Test func leavingManualControlCalmsTheStageWithNothingCarriedOver() async {
        let rig = Rig()
        await rig.brain.set(judged: .drifting)
        rig.runtime.start()
        await rig.runtime.drain()
        rig.runtime.handle(.focusChanged(Fixtures.browserApp, Fixtures.youtubeWindow))
        await rig.run(400, from: 0) { t in
            if Int(t) % 3 == 0 { rig.sample("d\(Int(t))", Fixtures.youtubeWindow) }
        }
        #expect(rig.stage.gestures == [.sigh, .standUp])  // the sad step's sigh, then stood up: an escalated drift
        rig.runtime.setManualControl(true)
        rig.stage.perform(.cheer)  // Charles plays with Moku
        rig.runtime.setManualControl(false)
        await rig.runtime.drain()
        #expect(Array(rig.stage.calls.suffix(calmCalls.count)) == calmCalls)
        #expect(rig.runtime.status.phase == .settling)

        // Back to work: no welcome-back, no return.
        let resumedAt = rig.stage.calls.count
        await rig.brain.set(judged: .working)
        await rig.run(30, from: 400) { t in
            if Int(t) % 3 == 0 { rig.sample("w\(Int(t))", Fixtures.editorWindow, app: Fixtures.editorApp) }
        }
        #expect(!rig.stage.calls.dropFirst(resumedAt).contains { if case .say = $0 { true } else { false } })
        #expect(!(await rig.brain.events.map(\.type)).contains(.returned))
        #expect(rig.runtime.status.phase == .focused)
        rig.finish()
    }

    @Test func nothingIsSentUnderManualControlAndTheRetryQueueResumesAfter() async {
        let rig = Rig()
        await rig.brain.set(down: true)
        rig.runtime.start()
        await rig.runtime.drain()
        rig.stage.onPat?()  // before manual control: queued for retry while the brain is down
        await rig.runtime.drain()
        await rig.brain.set(down: false)
        rig.runtime.setManualControl(true)
        await rig.run(120, from: 0)
        #expect(await rig.brain.events.isEmpty)
        #expect(await rig.brain.feedback.isEmpty)
        rig.runtime.setManualControl(false)
        await rig.run(1, from: 120)
        #expect(await rig.brain.events.map(\.type) == [.patted])
        #expect(await rig.brain.feedback.map(\.kind) == [.pat])
        rig.finish()
    }

    /// "Say hi again" (the welcome) or a test started mid-break ends the break, and everything that showed it says so: the
    /// popover's button is "Break" again, the timer over the companion's head goes, Your day's break is closed, and watching
    /// can start again when it's over. Before, the fresh engine forgot the break while the popover still said "End break"
    /// and the timer counted on, so that button started a new break instead.
    @Test func aBreakEndsWhenTheWelcomeOrATestTakesOver() async {
        let rig = Rig()
        let watching = Recording<Bool>()
        rig.runtime.onBreakChanged = { watching.values.append($0) }
        rig.runtime.start()
        await rig.runtime.drain()
        rig.world.onTakeBreak?()
        #expect(rig.world.onBreak == [true])
        rig.runtime.setManualControl(true)
        await rig.runtime.drain()
        #expect(rig.world.onBreak == [true, false])
        #expect(watching.values == [true, false])
        #expect(rig.stage.breakTimers.count == 2 && rig.stage.breakTimers.last == .some(nil))
        #expect(await rig.brain.events.map(\.type).suffix(1) == [.breakEnded])
        rig.runtime.setManualControl(false)
        rig.world.onTakeBreak?()  // the button says "Break", and starts one
        #expect(rig.world.onBreak == [true, false, true])
        rig.finish()
    }

    @Test func theSwitchIsReflectedOnTheWorldPresenter() {
        let rig = Rig()
        rig.runtime.setManualControl(true)
        rig.runtime.setManualControl(true)
        rig.runtime.setManualControl(false)
        #expect(rig.world.manualControl == [true, false])
        #expect(rig.runtime.isManualControl == false)
    }
}

@MainActor
@Suite("Manual scenes")
struct ManualSceneTests {
    /// Plays a scene to the end on the instant clock under manual control.
    static func play(_ kind: ManualSceneKind, speed: Double = 10, brainDown: Bool = false,
                     line: (VoiceKind, String)? = nil) async -> Rig {
        let rig = Rig(clock: InstantClock())
        if brainDown { await rig.brain.set(down: true) }
        if let line { await rig.brain.set(line: line.1, for: line.0) }
        rig.runtime.setManualControl(true)
        await rig.scene(kind).play(speed)
        return rig
    }

    @Test func theScenesAreTheOnesThePanelLists() {
        let rig = Rig()
        #expect(rig.runtime.manualScenes().map(\.title) == [
            "Short drift and return", "Long drift: full escalation", "Pat during a drift", "Break reminder",
            "Tea break", "Work finished", "Milestone", "Whole scripted day",
        ])
    }

    @Test func shortDriftAndReturn() async {
        let rig = await Self.play(.shortDrift)
        #expect(inOrder(rig.stage.calls, [
            call(.workState(.grace)), call(.mood(.disappointed)), call(.attention(.user)), call(.workState(.noticing)),
            call(.mood(.happy)), call(.celebrateReturn(.small)), call(.workState(.focused)),
        ]))
        #expect(Array(rig.stage.calls.suffix(calmCalls.count)) == calmCalls)
        #expect(rig.stage.lines.isEmpty)
    }

    @Test func longDriftClimbsTheWholeLadder() async {
        let rig = await Self.play(.longDrift, speed: 30)
        // The lantern climbs its tiers as the ladder does.
        #expect(inOrder(rig.stage.calls, [
            call(.workState(.grace)), call(.mood(.disappointed)), call(.attention(.user)), call(.workState(.noticing)),
            call(.workState(.concerned)),
            call(.gesture(.standUp)), call(.workState(.drifting)),
            call(.workState(.longDrift)),
            call(.mood(.happy)), call(.celebrateReturn(.full)), call(.gesture(.sitDown)),
            call(.workState(.focused)),
        ]))
        #expect(!rig.stage.moods.contains(.curious) && !rig.stage.moods.contains(.concerned) && !rig.stage.moods.contains(.annoyed))
        // No words over its head, neither the ask nor the welcome back (the friends, 2026-10-14).
        #expect(rig.stage.lines.isEmpty)
        #expect(Array(rig.stage.calls.suffix(calmCalls.count)) == calmCalls)
    }

    @Test func patDuringADriftSoftensAndWalksHome() async {
        let rig = await Self.play(.patDuringDrift)
        #expect(inOrder(rig.stage.calls, [
            call(.mood(.disappointed)), call(.gesture(.standUp)), call(.workState(.longDrift)),
            call(.gesture(.patReaction)), call(.mood(.happy)), call(.gesture(.sitDown)),
        ]))
        #expect(rig.stage.lines.isEmpty)  // the ask has no words (the friends, 2026-10-14)
    }

    @Test func breakReminder() async {
        let rig = await Self.play(.breakReminder)
        #expect(inOrder(rig.stage.calls, [call(.attention(.user)), said(.warm), call(.gesture(.drinkWater))]))
        // The 50-minute lead-up plays instantly and silently: no smiles from it reach the stage.
        #expect(!rig.stage.gestures.contains(.smile))
    }

    @Test func milestoneCelebratesTheStageTheForestIsReallyAt() async {
        let rig = await Self.play(.milestone)
        #expect(rig.world.celebrated == [.tree])  // the model's 700 points
        // Moku's own celebration waits for the tea break: it arrives in the same batch as the break's lantern.
        let calls = rig.stage.calls
        let celebration = calls.firstIndex(of: .gesture(.celebrate))!
        #expect(Array(calls[celebration..<celebration + 4]) == [
            .gesture(.celebrate), .mood(.happy), .attention(.user), .workState(.onBreak),
        ])
        #expect(rig.stage.lines.isEmpty)  // the body alone, no line (the friends, 2026-10-14)
    }

    @Test func teaBreak() async {
        let rig = await Self.play(.teaBreak, speed: 30)
        #expect(inOrder(rig.stage.calls, [
            call(.workState(.onBreak)), call(.mood(.happy)), call(.celebrateReturn(.small)), call(.workState(.focused)),
        ]))
        #expect(rig.world.onBreak.isEmpty)  // a replay never touches the real break button
    }

    @Test func workFinished() async {
        let rig = await Self.play(.completion, line: (.celebrate, "Pushed! The auth flow is out."))
        #expect(inOrder(rig.stage.calls, [call(.gesture(.celebrate)), call(.mood(.happy)), call(.attention(.user))]))
        // The body alone (the friends, 2026-10-14): Luna isn't asked, so her ready line is never said.
        #expect(rig.stage.lines.isEmpty)
        #expect(await !rig.brain.voiceRequests.contains { $0.kind == .celebrate })
    }

    @Test func wholeScriptedDay() async {
        let rig = await Self.play(.wholeDay, speed: 30)
        #expect(inOrder(rig.stage.calls, [
            call(.gesture(.nod)), call(.gesture(.smile)), call(.mood(.disappointed)),
            call(.gesture(.standUp)), said(.warm), call(.gesture(.drinkWater)),  // the water prompt: its only words
            call(.hidden(true)), call(.hidden(false)),
            call(.gesture(.patReaction)), call(.gesture(.celebrate)),
        ]))
        #expect(rig.world.celebrated == [.youngTree])
    }

    @Test(arguments: [1.0, 5, 10, 30])
    func theActPlaysAtTheChosenSpeed(speed: Double) async {
        let rig = await Self.play(.shortDrift, speed: speed)
        let script = ManualSceneKind.shortDrift.script(config: .standard, stage: .tree)
        #expect(script.day.moments.map(\.at) == [0, 1_200, 1_261])  // 61 s: past grace, short of a long drift
        let actSeconds = script.day.endSec - script.actStart + 1
        let slept = (rig.clock as! InstantClock).slept
        #expect(abs(slept - actSeconds / speed) < 1e-6)
    }

    @Test func scenesNeverReachTheBrainsLogOrTheWorldModel() async {
        let rig = Rig(clock: InstantClock())
        rig.runtime.setManualControl(true)
        for scene in rig.runtime.manualScenes() {
            await scene.play(30)
        }
        #expect(await rig.brain.events.isEmpty)
        #expect(await rig.brain.feedback.isEmpty)
        #expect(await rig.brain.worldFetches == 0)
        #expect(rig.model.snapshot == Fixtures.snapshot(points: 700))
        #expect(!(await rig.brain.voiceRequests).isEmpty)  // Luna was asked for lines
    }

    @Test func scenesSpeakLunasLinesWhenTheBrainAnswers() async {
        let rig = await Self.play(.breakReminder, line: (.water, "Little sip of water?"))
        #expect(rig.stage.lines.first == SpeechLine(text: "Little sip of water?", tone: .warm))
    }

    @Test func scenesFallBackToBuiltInLinesWhenTheBrainIsDown() async {
        let rig = await Self.play(.breakReminder, brainDown: true)
        #expect(rig.stage.lines.first == SpeechLine(text: "Sip of water?", tone: .warm))
    }

    @Test func cancellingASceneStopsItAndCalmsTheStage() async {
        let rig = Rig()
        rig.runtime.setManualControl(true)
        let scene = rig.scene(.longDrift)
        let playing = Task { await scene.play(1) }
        // Let the act run for a few virtual seconds.
        for _ in 0..<5 {
            #expect(await eventually { rig.manualClock.sleeperCount == 1 })
            rig.manualClock.advance(by: 1)
        }
        #expect(await eventually { rig.manualClock.sleeperCount == 1 })
        playing.cancel()
        await playing.value
        #expect(await eventually { Array(rig.stage.calls.suffix(calmCalls.count)) == calmCalls })
        // Stopped for good: time passing changes nothing.
        let calls = rig.stage.calls.count
        rig.manualClock.advance(by: 600)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(rig.stage.calls.count == calls)
        rig.finish()
    }

    @Test func scenesOnlyPlayUnderManualControlAndStopWhenItEnds() async {
        let rig = Rig()
        await rig.scene(.shortDrift).play(10)
        #expect(rig.stage.calls.isEmpty)

        rig.runtime.setManualControl(true)
        let scene = rig.scene(.longDrift)
        let playing = Task { await scene.play(1) }
        #expect(await eventually { rig.manualClock.sleeperCount == 1 && rig.stage.calls.contains(.move(.home)) })
        rig.runtime.setManualControl(false)
        let offAt = rig.stage.calls.count - (calmCalls.count - 1)  // the runtime's calm, less the walk home still to come
        rig.manualClock.advance(by: 1)
        await playing.value
        await rig.runtime.drain()
        // Only the runtime's calm: the scene stepped aside without another command.
        #expect(Array(rig.stage.calls.dropFirst(offAt)) == calmCalls)
        rig.finish()
    }

    @Test func startingAnotherSceneStopsTheFirst() async {
        let rig = Rig()
        rig.runtime.setManualControl(true)
        let first = Task { await rig.scene(.longDrift).play(1) }
        #expect(await eventually { rig.manualClock.sleeperCount == 1 })
        let second = Task { await rig.scene(.breakReminder).play(1) }
        #expect(await eventually { rig.manualClock.sleeperCount == 2 })
        rig.manualClock.advance(by: 1)
        await first.value  // stepped aside at its next second
        second.cancel()
        await second.value
        rig.finish()
    }
}
