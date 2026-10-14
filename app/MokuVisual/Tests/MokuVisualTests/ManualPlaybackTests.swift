import Foundation
import Testing
import MokuKit
@testable import MokuVisual

@MainActor private final class PlaybackProbe {
    var events: [String] = []
    var cancelled = false
    var loops = 0
    var moveLasts: Duration = .milliseconds(60)
    func execute(_ action: ManualAction) async {
        switch action {
        case .move:
            events.append("move starts")
            do { try await Task.sleep(for: moveLasts) } catch { cancelled = true; return }
            events.append("move ends")
        default: events.append("other")
        }
    }
}

/// Waits for a condition rather than a fixed time, so a busy machine can't fail the test (gives up after a second).
@MainActor private func eventually(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(1)
    while !condition() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
}

@MainActor @Test func zeroWaitStartsNextStepAlongsideRealMove() async {
    let probe = PlaybackProbe()
    await ManualPlayback.run([ManualStep(action: .move(.center), wait: 0), ManualStep(action: .mood(.happy), wait: 0)]) { await probe.execute($0) }
    #expect(probe.events.firstIndex(of: "other")! < probe.events.firstIndex(of: "move ends")!)
    #expect(probe.events.contains("move ends"))
}

@MainActor @Test func positiveWaitFinishesGroupThenPauses() async {
    let probe = PlaybackProbe(); let began = ContinuousClock.now
    await ManualPlayback.run([ManualStep(action: .move(.center), wait: 0.03), ManualStep(action: .mood(.happy), wait: 0)]) { await probe.execute($0) }
    #expect(probe.events == ["move starts", "move ends", "other"])
    #expect(ContinuousClock.now - began >= .milliseconds(90))
}

@MainActor @Test func stopCancelsChainIncludingItsInFlightMove() async throws {
    let player = ManualPlayback(), probe = PlaybackProbe()
    probe.moveLasts = .seconds(10)  // still in flight when stop() lands, however busy the machine is
    player.steps = [ManualStep(action: .move(.center), wait: 1), ManualStep(action: .mood(.happy), wait: 0)]
    player.play(loop: false) { await probe.execute($0) }
    while probe.events.isEmpty { await Task.yield() }
    player.stop()
    await eventually { probe.cancelled }
    #expect(probe.cancelled)
    #expect(!probe.events.contains("other"))
    #expect(!player.isPlaying)
}

@MainActor @Test func recordingCapturesExactParametersWithoutExecuting() {
    let player = ManualPlayback(); player.isRecording = true
    var text = "Hello Charles"
    #expect(player.record(.speech(text, .warm)))
    text = "Changed later"
    #expect(player.steps[0].action == .speech("Hello Charles", .warm))
    #expect(player.record(.move(.near(CGPoint(x: 17, y: -200)))))
    #expect(player.steps[1].action == .move(.near(CGPoint(x: 17, y: -200))))
    player.isRecording = false
    #expect(!player.record(.label(text)))
    #expect(player.steps.count == 2)
}

@MainActor @Test func stopCancelsSceneAndPreservesItsSpeed() async throws {
    let player = ManualPlayback(), probe = PlaybackProbe()
    let scene = ManualScene(id: "test", title: "Test") { speed in
        probe.events.append("speed \(speed)")
        do { try await Task.sleep(for: .seconds(10)) } catch { probe.cancelled = true }
    }
    player.play(scene: scene, speed: 30)
    while probe.events.isEmpty { await Task.yield() }
    player.stop(); await eventually { probe.cancelled }
    #expect(probe.events == ["speed 30.0"])
    #expect(probe.cancelled)
}

@MainActor @Test func loopRepeatsAndStopsWithoutMoreSteps() async throws {
    let player = ManualPlayback(), probe = PlaybackProbe()
    player.steps = [ManualStep(action: .mood(.happy), wait: 0)]
    player.play(loop: true) { _ in probe.loops += 1 }
    let deadline = ContinuousClock.now + .seconds(10)  // it leaves at the third loop; a busy Mac took over 1 s
    while probe.loops < 3 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    player.stop(); let count = probe.loops
    try await Task.sleep(for: .milliseconds(70))
    #expect(count >= 3)
    #expect(probe.loops == count)
}
