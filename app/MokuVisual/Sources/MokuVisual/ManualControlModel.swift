import AppKit
import Observation
import MokuKit

@MainActor @Observable
final class ManualControlModel {
    let stage: any CharacterStage
    let world: WorldModel
    let presenter: any WorldPresenter
    let scenes: [ManualScene]
    var playback = ManualPlayback()
    var mood = Mood.content
    var workState = WorkState.idle
    var hidden = false
    var watchesCursor = false
    var speech = "A little focus. A little forest."
    var threadLabel = "DSA · Trees"
    var points: Double
    var speed = 1.0
    var cpu = 0.0
    var fps = 0.0
    var renderer = "Moku"
    private var monitor: Timer?
    private var moveTask: Task<Void, Never>?
    private var sampleTime = 0.0
    private var sampleCPU = 0.0
    private var nextSample = 0.0

    init(stage: any CharacterStage, world: WorldModel, presenter: any WorldPresenter, scenes: [ManualScene]) {
        self.stage = stage; self.world = world; self.presenter = presenter; self.scenes = scenes; points = world.snapshot.growthPoints
    }
    func submit(_ action: ManualAction) {
        guard !playback.record(action) else { return }
        switch action {
        case .scene(let id, let speed):
            if let scene = scenes.first(where: { $0.id == id }) { playback.play(scene: scene, speed: speed) }
        case .move:
            moveTask?.cancel(); moveTask = Task { [weak self] in await self?.execute(action) }
        default: Task { [weak self] in await self?.execute(action) }
        }
    }
    func play(loop: Bool) { playback.play(loop: loop) { [weak self] in await self?.execute($0) } }
    func stop() { playback.stop(); moveTask?.cancel(); moveTask = nil; stage.dismissSpeech() }
    func clear() { stop(); playback.steps.removeAll() }
    func execute(_ action: ManualAction) async {
        guard !Task.isCancelled else { return }
        switch action {
        case .workState(let state): workState = state; stage.setWorkState(state)
        case .returnBeat(let size): workState = .focused; stage.celebrateReturn(size)
        case .mood(let mood): self.mood = mood; stage.setMood(mood)
        case .gesture(let gesture): stage.perform(gesture)
        case .attention(let target): watchesCursor = false; stage.setAttention(target)
        case .watchCursor: watchesCursor = true; stage.setAttention(.point(NSEvent.mouseLocation))
        case .move(let spot): await stage.move(to: spot)
        case .speech(let text, let tone): stage.say(SpeechLine(text: text, tone: tone))
        case .dismissSpeech: stage.dismissSpeech()
        case .label(let title): stage.showThreadLabel(title)
        case .hidden(let hidden): self.hidden = hidden; stage.setHidden(hidden)
        case .growth(let points): self.points = points; world.snapshot.growthPoints = points
        case .celebrate(let stage): presenter.celebrate(stage)
        case .openWorld: presenter.openWorld()
        case .scene(let id, let speed): if let scene = scenes.first(where: { $0.id == id }) { await scene.play(speed) }
        }
    }
    func startMonitoring() {
        monitor?.invalidate(); sampleTime = 0; nextSample = 0
        monitor = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        monitor?.tolerance = 0.02
    }
    func stopMonitoring() { stop(); watchesCursor = false; monitor?.invalidate(); monitor = nil }
    private func tick() {
        if watchesCursor && !hidden { stage.setAttention(.point(NSEvent.mouseLocation)) }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= nextSample else { return }; nextSample = now + 1
        if let stage = stage as? MokuCharacterStage { fps = stage.framesPerSecond; renderer = stage.rendererDescription }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let used = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        if sampleTime > 0 { cpu = (used - sampleCPU) / (now - sampleTime) * 100 }
        sampleTime = now; sampleCPU = used
    }
    isolated deinit { monitor?.invalidate(); moveTask?.cancel() }
}
