import Foundation
import MokuKit

/// Real behaviors replayed on the live stage for manual control. Each scene is a `ScriptedDay` run through
/// a fresh `BehaviorEngine`: the lead-up plays instantly and silently, then the part worth watching (the
/// "act") plays at `speed`× on a virtual clock. Lines come from Luna when the brain answers within 2 s,
/// otherwise from the built-in ones. Nothing is sent to /v1/events or /v1/feedback, and `WorldModel`
/// is left alone.
enum ManualSceneKind: String, CaseIterable, Sendable {
    case shortDrift = "short-drift"
    case longDrift = "long-drift"
    case patDuringDrift = "pat-during-drift"
    case breakReminder = "break-reminder"
    case teaBreak = "tea-break"
    case completion
    case milestone
    case wholeDay = "whole-day"

    var title: String {
        switch self {
        case .shortDrift: "Short drift and return"
        case .longDrift: "Long drift: full escalation"
        case .patDuringDrift: "Pat during a drift"
        case .breakReminder: "Break reminder"
        case .teaBreak: "Tea break"
        case .completion: "Work finished"
        case .milestone: "Milestone"
        case .wholeDay: "Whole scripted day"
        }
    }

    /// Focus before any drift: 20 minutes, so reminders and return bonuses have something to say.
    static let leadIn: Double = 1_200
    /// A forest far from its next stage, so scenes other than "Milestone" never celebrate.
    static let quietForest: Double = 5_000

    /// The scene's script, with timings taken from the live config so it shows what Moku really does.
    func script(config: CompanionConfig, stage currentStage: ForestStage) -> SceneScript {
        let lead = Self.leadIn
        func day(_ moments: [ScriptedDay.Moment], until end: Double, points: Double = Self.quietForest) -> ScriptedDay {
            ScriptedDay(config: config, startPoints: points, moments: moments, endSec: end)
        }
        switch self {
        case .shortDrift:
            // Halfway between the end of grace and a long drift: a real (small) return.
            let drift = ((min(config.graceSec, config.shortDriftMaxSec) + config.shortDriftMaxSec) / 2).rounded()
            return SceneScript(day: day([
                .init(atSecond: 0, "Working in Xcode", .use(ScriptedDay.editor)),
                .init(atSecond: lead, "Checks X", .use(ScriptedDay.twitter)),
                .init(atSecond: lead + drift, "Back to Xcode", .use(ScriptedDay.editor)),
            ], until: lead + drift + 8), actStart: lead - 3)
        case .longDrift:
            // Past the ask to focus.
            let back = (config.askAfterSec + 20).rounded()
            return SceneScript(day: day([
                .init(atSecond: 0, "Working in Xcode", .use(ScriptedDay.editor)),
                .init(atSecond: lead, "Puts on a YouTube video", .use(ScriptedDay.youtube)),
                .init(atSecond: lead + back, "Back to Xcode", .use(ScriptedDay.editor)),
            ], until: lead + back + 10), actStart: lead - 3)
        case .patDuringDrift:
            let pat = (max(config.askAfterSec, config.shortDriftMaxSec) + 20).rounded()
            return SceneScript(day: day([
                .init(atSecond: 0, "Working in Xcode", .use(ScriptedDay.editor)),
                .init(atSecond: lead, "Opens r/swift", .use(ScriptedDay.reddit)),
                .init(atSecond: lead + pat, "Pats Moku: this is research", .pat),
            ], until: lead + pat + 10), actStart: lead - 3)
        case .breakReminder:
            let due = config.breakAfterSec.rounded()
            return SceneScript(day: day([
                .init(atSecond: 0, "Working in Xcode", .use(ScriptedDay.editor)),
            ], until: due + 10), actStart: max(0, due - 5))
        case .teaBreak:
            return SceneScript(day: day([
                .init(atSecond: 0, "Working in Xcode", .use(ScriptedDay.editor)),
                .init(atSecond: 600, "Takes a tea break", .takeBreak),
                .init(atSecond: 780, "Back from tea, into Xcode", .use(ScriptedDay.editor)),
            ], until: 790), actStart: 597)
        case .completion:
            return SceneScript(day: day([
                .init(atSecond: 0, "Working in Xcode", .use(ScriptedDay.editor)),
                .init(atSecond: 300, "Pushes the branch", .complete(Completion(kind: .codePushed, label: "pushed auth-flow"))),
            ], until: 320), actStart: 295)
        case .milestone:
            // Replays reaching the stage the forest is really at (sprout for a new forest), so the presenter
            // never celebrates a stage the user hasn't earned. The first focused minute crosses it at 1:01 (the
            // menu bar cue); Moku's own celebration waits for the tea break at 1:10.
            let stage = max(currentStage, .sprout)
            return SceneScript(day: day([
                .init(atSecond: 0, "Working in Xcode", .use(ScriptedDay.editor)),
                .init(atSecond: 70, "Takes a tea break", .takeBreak),
                .init(atSecond: 90, "Back to Xcode", .use(ScriptedDay.editor)),
            ], until: 95, points: stage.threshold - 0.5), actStart: 55)
        case .wholeDay:
            var whole = ScriptedDay.standard
            whole.config.userName = config.userName
            return SceneScript(day: whole, actStart: 0)
        }
    }
}

struct SceneScript: Sendable {
    var day: ScriptedDay
    /// Seconds before this play instantly with the stage untouched; the rest plays at speed.
    var actStart: Double
}

extension CompanionRuntime {
    /// The scenes for the manual control panel. They only play while manual control is on; a scene
    /// stops when its task is cancelled, when another scene starts, or when manual control ends.
    public func manualScenes() -> [ManualScene] {
        ManualSceneKind.allCases.map { kind in
            ManualScene(id: kind.rawValue, title: kind.title) { [weak self] speed in
                await self?.playScene(kind, speed: speed)
            }
        }
    }

    func playScene(_ kind: ManualSceneKind, speed: Double) async {
        guard isManualControl, speed > 0 else { return }
        sceneTurn += 1
        let turn = sceneTurn
        let player = ScenePlayer(script: kind.script(config: engine.config, stage: worldModel.snapshot.stage),
                                 tuning: tuning, stage: stage, presenter: presenter, brain: brain, clock: clock)
        await player.play(speed: speed) { [weak self] in
            guard let self else { return false }
            return self.isManualControl && self.sceneTurn == turn
        }
    }
}

/// Plays one scene on the live stage.
@MainActor
final class ScenePlayer {
    static let voiceTimeoutSec: Double = 2
    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    private var engine: BehaviorEngine
    private var inputs: ScriptedInputs
    private let actStart: Int
    private let presenter: any WorldPresenter
    private let brain: any BrainAPI
    private let clock: any RuntimeClock
    private let stage: any CharacterStage
    private lazy var driver = StageDriver(stage: stage) { [weak self] work in
        let walk = Task { await work() }
        self?.walks.append(walk)
    }
    private var walks: [Task<Void, Never>] = []
    private var voiceRequests: [Task<Void, Never>] = []
    private var replies: [(kind: VoiceKind, line: VoiceLine)] = []

    init(script: SceneScript, tuning: EngineTuning, stage: any CharacterStage, presenter: any WorldPresenter,
         brain: any BrainAPI, clock: any RuntimeClock) {
        // A fixed seed: a scene plays the same way every time.
        engine = BehaviorEngine(config: script.day.config, tuning: tuning, random: MokuRandom(seed: 7))
        inputs = ScriptedInputs(script.day)
        actStart = Int(script.actStart)
        self.stage = stage
        self.presenter = presenter
        self.brain = brain
        self.clock = clock
    }

    /// Returns when the scene has finished or stopped. `mayContinue` is checked every virtual second of the act.
    func play(speed: Double, mayContinue: @MainActor () -> Bool) async {
        var finished = true
        for second in 0...inputs.lastSecond {
            let live = second >= actStart
            if second == actStart { setTheStage() }
            if live && (Task.isCancelled || !mayContinue()) {
                finished = false
                break
            }
            step(second, live: live)
            guard live else { continue }
            do {
                try await clock.sleep(seconds: 1 / speed)
            } catch {
                finished = false
                break
            }
        }
        voiceRequests.forEach { $0.cancel() }
        // A scene that was replaced, or ended by leaving manual control, leaves the stage to its new owner.
        guard finished || mayContinue() else { return }
        CompanionRuntime.calmCommands.forEach(driver.run)
        if finished {
            for walk in walks { await walk.value }
        }
    }

    /// At the start of the act, the stage catches up with the engine: at home, in the engine's mood.
    private func setTheStage() {
        driver.reset()
        let commands: [CharacterCommand] = [
            .dismissSpeech, .setHidden(false), .perform(.sitDown), .setMood(engine.status.mood), .setAttention(.wander), .move(.home),
        ]
        commands.forEach(driver.run)
    }

    private func step(_ second: Int, live: Bool) {
        let now = Self.base.addingTimeInterval(Double(second))
        let ready = replies
        replies = []
        for reply in ready { perform(engine.handle(.voiceReady(reply.kind, reply.line), now: now), second, live) }
        for case let .input(input) in inputs.items(at: second) {
            perform(engine.handle(input, now: now), second, live)
        }
        perform(engine.tick(now: now), second, live)
    }

    private func perform(_ effects: [EngineEffect], _ second: Int, _ live: Bool) {
        inputs.observe(effects, at: second)
        for effect in effects {
            switch effect {
            case let .character(command): if live { driver.run(command) }
            case let .requestVoice(request): fetchVoice(request)
            case let .celebrateStage(stage): if live { presenter.celebrate(stage) }
            // A replay never reaches the brain's log or the break button, and nobody clicked.
            case .event, .feedback, .openWorld, .setOnBreak: break
            }
        }
    }

    private func fetchVoice(_ request: VoiceRequest) {
        let brain = self.brain
        voiceRequests.append(Task { [weak self] in
            guard let line = await Self.voice(request, from: brain) else { return }
            self?.replies.append((request.kind, line))
        })
    }

    /// Luna's line if the brain answers within `voiceTimeoutSec`; nil otherwise, and the engine falls back
    /// to its built-in line. Real time, not the scene's clock: this is a network timeout.
    private static func voice(_ request: VoiceRequest, from brain: any BrainAPI) async -> VoiceLine? {
        await withTaskGroup(of: VoiceLine?.self) { group in
            group.addTask { try? await brain.voice(request) }
            group.addTask {
                try? await Task.sleep(for: .seconds(voiceTimeoutSec))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
