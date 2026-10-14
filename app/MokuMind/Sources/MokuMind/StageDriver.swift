import MokuKit

/// Runs character commands on a stage in order. A `move` starts a walk; commands after it wait until
/// the character arrives. A new move during a walk redirects it (the stage returns the earlier call at
/// once): whatever was queued behind the old walk happens first, in order. Hiding and dismissing speech
/// never wait, and hiding drops the lines, gestures and labels still queued.
@MainActor
final class StageDriver {
    private let stage: any CharacterStage
    /// Starts a walk's task; the owner tracks it (so tests and scenes can wait for walks).
    private let spawn: (@escaping @MainActor () async -> Void) -> Void
    private var currentWalk: Int?
    private var nextWalkId = 0
    private var backlog: [CharacterCommand] = []

    init(stage: any CharacterStage, spawn: @escaping (@escaping @MainActor () async -> Void) -> Void) {
        self.stage = stage
        self.spawn = spawn
    }

    func run(_ command: CharacterCommand) {
        switch command {
        case .setHidden(true):
            backlog.removeAll {
                switch $0 {
                case .say, .think, .perform, .celebrateReturn: true
                default: false
                }
            }
            apply(command)
        case .setHidden(false), .dismissSpeech:
            apply(command)
        case let .move(spot):
            walk(to: spot)
        default:
            guard currentWalk == nil else {
                // Keep order behind the walk, but only the newest gaze target matters.
                if case .setAttention = command, case .setAttention? = backlog.last {
                    backlog[backlog.count - 1] = command
                } else {
                    backlog.append(command)
                }
                return
            }
            apply(command)
        }
    }

    /// Forget everything queued and the walk in progress (its arrival releases nothing).
    func reset() {
        backlog = []
        currentWalk = nil
    }

    private func walk(to spot: StageSpot) {
        if currentWalk != nil { releaseBacklog() }
        nextWalkId += 1
        let walkId = nextWalkId
        currentWalk = walkId
        // The walk keeps its driver alive until it arrives: a finished scene still has to get Moku home.
        spawn {
            await self.stage.move(to: spot)
            // A redirected or reset walk returns early; the newer owner decides what happens next.
            guard self.currentWalk == walkId else { return }
            self.currentWalk = nil
            self.releaseBacklog()
        }
    }

    private func releaseBacklog() {
        let released = backlog
        backlog = []
        released.forEach(apply)
    }

    private func apply(_ command: CharacterCommand) {
        switch command {
        case let .setMood(mood): stage.setMood(mood)
        case let .setAttention(target): stage.setAttention(target)
        case let .perform(gesture): stage.perform(gesture)
        case let .say(line): stage.say(line)
        case .think: stage.think()
        case .dismissSpeech: stage.dismissSpeech()
        case let .setHidden(hidden): stage.setHidden(hidden)
        case let .setWorkState(state): stage.setWorkState(state)
        case let .celebrateReturn(size): stage.celebrateReturn(size)
        case let .breakTimer(until, total): stage.setBreakTimer(until: until, total: total)
        case let .move(spot): walk(to: spot)
        }
    }
}
