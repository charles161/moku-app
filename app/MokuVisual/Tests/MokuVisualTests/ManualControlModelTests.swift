import Foundation
import Testing
import MokuKit
@testable import MokuVisual

@MainActor private final class RecordingStage: CharacterStage {
    var onPat: (@MainActor () -> Void)?
    var onClick: (@MainActor () -> Void)?
    var speech = [SpeechLine]()
    var moves = [StageSpot]()
    var workStates = [WorkState]()
    var returns = [ReturnSize]()
    func setWorkState(_ state: WorkState) { workStates.append(state) }
    func celebrateReturn(_ size: ReturnSize) { returns.append(size) }
    func show() {}
    func setHidden(_ hidden: Bool) {}
    func setMood(_ mood: Mood) {}
    func setAttention(_ target: AttentionTarget) {}
    func perform(_ gesture: Gesture) {}
    func move(to spot: StageSpot) async { moves.append(spot) }
    func say(_ line: SpeechLine) { speech.append(line) }
    func dismissSpeech() {}
}
@MainActor private final class RecordingWorld: WorldPresenter {
    func openWorld() {}
    func closeWorld() {}
    func celebrate(_ stage: ForestStage) {}
}
@MainActor @Test func recordingPanelButtonsCaptureValuesWithoutDrivingTheStage() async throws {
    let stage = RecordingStage()
    let model = ManualControlModel(stage: stage, world: WorldModel(), presenter: RecordingWorld(), scenes: [])
    model.playback.isRecording = true
    model.speech = "Keep this exact line."
    model.submit(.speech(model.speech, .firm))
    model.submit(.move(.near(CGPoint(x: -300, y: 420))))
    model.speech = "A later edit."
    await Task.yield()
    #expect(stage.speech.isEmpty && stage.moves.isEmpty)
    #expect(model.playback.steps.map(\.action) == [.speech("Keep this exact line.", .firm), .move(.near(CGPoint(x: -300, y: 420)))])
    for index in model.playback.steps.indices { model.playback.steps[index].wait = 0 }
    model.playback.isRecording = false; model.play(loop: false)
    while model.playback.isPlaying { try await Task.sleep(for: .milliseconds(5)) }
    #expect(stage.speech.first?.text == "Keep this exact line.")
    #expect(stage.speech.first?.tone == .firm)
    #expect(stage.moves == [.near(CGPoint(x: -300, y: 420))])
}

@MainActor @Test func manualWorkAndReturnButtonsRecordThenReachTheStage() async {
    let stage = RecordingStage(), world = RecordingWorld()
    let model = ManualControlModel(stage: stage, world: WorldModel(), presenter: world, scenes: [])
    model.playback.isRecording = true
    model.submit(.workState(.longDrift)); model.submit(.returnBeat(.full))
    #expect(stage.workStates.isEmpty && stage.returns.isEmpty)
    for step in model.playback.steps { await model.execute(step.action) }
    #expect(stage.workStates == [.longDrift] && stage.returns == [.full])
    #expect(model.workState == .focused)
}
