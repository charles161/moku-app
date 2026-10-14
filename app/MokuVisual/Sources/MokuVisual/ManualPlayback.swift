import Foundation
import Observation
import MokuKit

/// Value snapshots keep a recording independent of later edits to text, tones or points.
enum ManualAction: Equatable, Sendable {
    case mood(Mood), gesture(Gesture), attention(AttentionTarget), watchCursor
    case move(StageSpot), speech(String, SpeechLine.Tone), dismissSpeech, label(String)
    case hidden(Bool), growth(Double), celebrate(ForestStage), openWorld
    case scene(String, Double)
    case workState(WorkState), returnBeat(ReturnSize)

    var title: String {
        switch self {
        case .workState(let state): "Work · \(state.rawValue)"
        case .returnBeat(let size): "Return · \(size.rawValue)"
        case .mood(let mood): "Mood · \(mood.rawValue)"
        case .gesture(let gesture): "Gesture · \(gesture.rawValue)"
        case .attention(.user): "Look at me"
        case .attention(.wander): "Wander"
        case .attention(.point(let point)): "Look at \(Int(point.x)), \(Int(point.y))"
        case .watchCursor: "Watch my work"
        case .move(.home): "Walk home"
        case .move(.center): "Walk to center"
        case .move(.near(let point)): "Walk near \(Int(point.x)), \(Int(point.y))"
        case .speech(let text, let tone): "Say (\(tone.rawValue)) · \(text)"
        case .dismissSpeech: "Dismiss speech"
        case .label(let title): "Thread · \(title)"
        case .hidden(let hidden): hidden ? "Hide" : "Show"
        case .growth(let points): "Forest · \(Int(points)) points"
        case .celebrate(let stage): "Celebrate · \(stage.title)"
        case .openWorld: "Open world"
        case .scene(let id, let speed): "Scene · \(id) · \(Int(speed))×"
        }
    }
}

struct ManualStep: Identifiable, Equatable, Sendable {
    let id = UUID()
    let action: ManualAction
    var wait: Double = 1
}

@MainActor @Observable
final class ManualPlayback {
    var isRecording = false
    var steps: [ManualStep] = []
    private(set) var isPlaying = false
    private(set) var status = "Ready"
    private var task: Task<Void, Never>?
    private var generation = 0

    func record(_ action: ManualAction) -> Bool {
        guard isRecording else { return false }
        steps.append(ManualStep(action: action)); status = "Recorded \(steps.count) steps"
        return true
    }
    func stop() {
        generation += 1; task?.cancel(); task = nil; isPlaying = false; status = "Stopped"
    }
    func play(loop: Bool, execute: @escaping @MainActor @Sendable (ManualAction) async -> Void) {
        let recording = steps
        guard !recording.isEmpty else { return }
        start(title: loop ? "Looping chain" : "Playing chain") {
            repeat {
                await Self.run(recording, execute: execute)
                guard loop, !Task.isCancelled else { return }
                // A zero-wait chain of immediate actions must never busy-spin.
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            } while !Task.isCancelled
        }
    }
    func play(scene: ManualScene, speed: Double) {
        start(title: "\(scene.title) · \(Int(speed))×") { await scene.play(speed) }
    }
    private func start(title: String, operation: @escaping @MainActor @Sendable () async -> Void) {
        stop(); isPlaying = true; status = title
        let token = generation
        task = Task { [weak self] in
            await operation()
            guard let self, generation == token else { return }
            isPlaying = false; status = Task.isCancelled ? "Stopped" : "Finished"; task = nil
        }
    }
    static func run(_ steps: [ManualStep], execute: @escaping @MainActor @Sendable (ManualAction) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            for step in steps {
                guard !Task.isCancelled else { group.cancelAll(); return }
                group.addTask { await execute(step.action) }
                let pause = step.wait.isFinite ? max(0, min(step.wait, 86_400)) : 0
                if pause > 0 {
                    await group.waitForAll()
                    do { try await Task.sleep(for: .seconds(pause)) } catch { group.cancelAll(); return }
                }
            }
            await group.waitForAll()
        }
    }
    isolated deinit { task?.cancel() }
}
