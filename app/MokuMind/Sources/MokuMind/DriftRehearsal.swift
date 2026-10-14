import Foundation
import MokuKit

extension BehaviorTest.Step {
    /// The ladder row this step shows.
    var ladderStep: LadderStep.ID {
        switch self {
        case .sad: .sad
        case .standUp: .standUp
        case .ask: .ask
        }
    }
}

/// Settings › Test the drift. A jump runs a fresh engine, silently, through twenty minutes of work and a
/// drift until the chosen ladder step fires, then shows where Moku is at that moment: the tier (a little red
/// once standing), the mood, the gaze, standing, and that step's line. Moku holds there.
/// "Come back" goes on with the same engine: the user returns and the engine's own return plays live.
@MainActor
final class DriftRehearsal {
    private static let base = Date(timeIntervalSince1970: 1_790_000_000)
    private var engine: BehaviorEngine
    private var inputs: ScriptedInputs
    private var second = 0

    init(config: CompanionConfig, tuning: EngineTuning) {
        engine = BehaviorEngine(config: config, tuning: tuning, random: MokuRandom(seed: 7))
        let lead = ManualSceneKind.leadIn
        inputs = ScriptedInputs(ScriptedDay(config: config, startPoints: ManualSceneKind.quietForest, moments: [
            .init(atSecond: 0, "Working in Xcode", .use(ScriptedDay.editor)),
            .init(atSecond: lead, "Puts on a YouTube video", .use(ScriptedDay.youtube)),
        ], endSec: lead + config.askAfterSec + config.standUpAfterSec + 3_600))
    }

    /// Runs silently until `step` fires and returns the commands that show Moku as it is then.
    func jump(to step: BehaviorTest.Step) -> DriftSnapshot {
        var earlier: [CharacterCommand] = [], last: [CharacterCommand] = []
        while second <= inputs.lastSecond, engine.drift?.hasFired(step.ladderStep) != true {
            earlier += last
            last = advance()
        }
        return DriftSnapshot(earlier + last, lines: last.compactMap { if case let .say(line) = $0 { line } else { nil } })
    }

    /// The user comes back to work now; the engine's return, then the next few seconds as they happen.
    func comeBack(settling seconds: Int = 8) -> [[CharacterCommand]] {
        let now = Self.base.addingTimeInterval(Double(second))
        let back = Verdict(sampleId: "rehearsal-back", state: .working, thread: ScriptedDay.editor.thread, isNewThread: false,
                           confidence: 0.9, source: .jev, reason: "", latencyMs: 1)
        let context = WorkContext(app: ScriptedDay.editor.app, window: ScriptedDay.editor.window)
        var first = commands(engine.handle(.focusChanged(ScriptedDay.editor.app, ScriptedDay.editor.window), now: now))
        first += commands(engine.handle(.verdict(back, context: context), now: now))
        first += commands(engine.tick(now: now))
        second += 1
        return [first] + (0..<seconds).map { _ in
            let now = Self.base.addingTimeInterval(Double(second))
            second += 1
            return commands(engine.tick(now: now))
        }
    }

    private func advance() -> [CharacterCommand] {
        let now = Self.base.addingTimeInterval(Double(second))
        var effects: [EngineEffect] = []
        for case let .input(input) in inputs.items(at: second) { effects += engine.handle(input, now: now) }
        effects += engine.tick(now: now)
        inputs.observe(effects, at: second)
        second += 1
        return commands(effects)
    }

    private func commands(_ effects: [EngineEffect]) -> [CharacterCommand] {
        effects.compactMap { if case let .character(command) = $0 { command } else { nil } }
    }
}

/// Settings › "Smile at me": a fresh engine works, silently, until its first look-up; that second and the few
/// after it (holding, then back to watching the work) come back as per-second batches to play live.
@MainActor
enum LookUpRehearsal {
    private static let base = Date(timeIntervalSince1970: 1_790_000_000)
    static func run(config: CompanionConfig, tuning: EngineTuning, after seconds: Int = 4) -> [[CharacterCommand]] {
        var engine = BehaviorEngine(config: config, tuning: tuning, random: MokuRandom(seed: 7))
        var inputs = ScriptedInputs(ScriptedDay(config: config, startPoints: ManualSceneKind.quietForest, moments: [
            .init(atSecond: 0, "Working in Xcode", .use(ScriptedDay.editor)),
        ], endSec: config.smileEverySec + 120))
        var batches: [[CharacterCommand]] = []
        for second in 0...inputs.lastSecond {
            let now = base.addingTimeInterval(Double(second))
            var effects: [EngineEffect] = []
            for case let .input(input) in inputs.items(at: second) { effects += engine.handle(input, now: now) }
            effects += engine.tick(now: now)
            inputs.observe(effects, at: second)
            let commands = effects.compactMap { if case let .character(command) = $0 { command } else { nil } }
            if !batches.isEmpty || engine.holdIsLookUp { batches.append(commands) }
            if batches.count > seconds { break }
        }
        return batches
    }
}

/// Where the ladder has taken Moku by some moment, folded from the commands so far.
struct DriftSnapshot: Equatable {
    var tier: WorkState?
    var mood: Mood?
    var gaze: AttentionTarget?
    var standing = false
    /// Only the line said as the step fired.
    var lines: [SpeechLine] = []

    init(_ commands: [CharacterCommand], lines: [SpeechLine]) {
        for command in commands {
            switch command {
            case let .setWorkState(state): tier = state
            case let .setMood(value): mood = value
            case let .setAttention(target): gaze = target
            case .perform(.standUp): standing = true
            case .perform(.sitDown): standing = false
            default: break
            }
        }
        self.lines = lines
    }

    /// The commands that take the stage, however it was left (standing or not), to this moment. Sitting
    /// down and standing up are no-ops for a Moku already there.
    var commands: [CharacterCommand] {
        var list: [CharacterCommand] = [.dismissSpeech, .setHidden(false)]
        if !standing { list.append(.perform(.sitDown)) }
        if let tier { list.append(.setWorkState(tier)) }
        if let mood { list.append(.setMood(mood)) }
        if let gaze { list.append(.setAttention(gaze)) }
        if standing { list.append(.perform(.standUp)) }  // last, so it rises angry
        list += lines.map { .say($0) }
        return list
    }
}

extension CompanionRuntime {
    /// Settings › Test the drift. Plays only under manual control, like the scenes; the app turns it on.
    public func testBehavior(_ test: BehaviorTest) {
        guard isManualControl else { return }
        switch test {
        case let .jump(step):
            sceneTurn += 1  // stops a playing scene
            let rehearsal = DriftRehearsal(config: engine.config, tuning: tuning)
            let snapshot = rehearsal.jump(to: step)
            driver.reset()  // nothing queued behind an earlier jump's walk plays late
            snapshot.commands.forEach(driver.run)
            self.rehearsal = rehearsal
        case .comeBack:
            guard let rehearsal else { return }
            self.rehearsal = nil
            var seconds = rehearsal.comeBack()
            seconds.removeFirst().forEach(driver.run)
            let turn = sceneTurn
            track { [weak self] in
                for batch in seconds {
                    try? await self?.clock.sleep(seconds: 1)
                    guard let self, self.isManualControl, self.sceneTurn == turn else { return }
                    batch.forEach(self.driver.run)
                }
            }
        case .playAll:
            rehearsal = nil
            track { [weak self] in await self?.playScene(.longDrift, speed: 30) }
        case .lookUp:
            sceneTurn += 1
            let turn = sceneTurn
            let calm: [CharacterCommand] = [.dismissSpeech, .setHidden(false), .perform(.sitDown), .setWorkState(.focused), .setMood(.content), .setAttention(.wander)]
            rehearsal = nil
            driver.reset()
            calm.forEach(driver.run)  // watching the work first, so the look-up reads
            let batches = LookUpRehearsal.run(config: engine.config, tuning: tuning)
            track { [weak self] in
                try? await self?.clock.sleep(seconds: 1.5)
                for batch in batches {
                    guard let self, self.isManualControl, self.sceneTurn == turn else { return }
                    batch.forEach(self.driver.run)
                    try? await self.clock.sleep(seconds: 1)
                }
            }
        case .drink:
            sceneTurn += 1
            let turn = sceneTurn
            let calm: [CharacterCommand] = [.dismissSpeech, .setHidden(false), .perform(.sitDown), .setWorkState(.focused), .setMood(.content), .setAttention(.wander)]
            rehearsal = nil
            driver.reset()
            calm.forEach(driver.run)
            track { [weak self] in
                try? await self?.clock.sleep(seconds: 1.5)
                guard let self, self.isManualControl, self.sceneTurn == turn else { return }
                self.driver.run(.perform(.drinkWater))
            }
        case .stop:
            break
        }
    }
}
