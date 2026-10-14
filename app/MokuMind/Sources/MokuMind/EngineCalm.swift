import Foundation
import MokuKit

/// forceCalm, the relay's emergency brake (docs/launch-plan.md §4, proxy/api/_lib/flags.js): Moku never reacts to a
/// drift. The drift is still measured and recorded (the long-drift event, the focus streak ending), and coming back
/// is still celebrated, but while it lasts Moku shows nothing: no sad or angry face, no looking at you, no standing
/// up, no "can we focus?", and the lantern stays lit (the drift's first, calm tier). Off by default, and with it off
/// the ladder runs exactly as written. Turned off mid-drift, Moku picks up at the drift's next step.
extension BehaviorEngine {
    /// Turns forceCalm on or off. Turned on mid-drift, Moku settles at once: home, seated, content, eyes on the work.
    public mutating func setForceCalm(_ on: Bool, now requested: Date) -> [EngineEffect] {
        let now = advance(to: requested)
        guard on != forceCalm else { return takeEffects() }
        forceCalm = on
        if on, drift != nil { calmDown() }
        syncWorkState(now: now)
        return takeEffects()
    }

    /// A ladder step under forceCalm: only what isn't seen. Keeping the eyes where the work was (the first step's
    /// gaze) is how Moku looks when nothing is going on, so it stays. The events that record the drift stay; the
    /// nudge, never said, isn't recorded.
    mutating func runCalmly(_ step: LadderStep, drift current: inout Drift, now: Date) {
        if step.gaze == .holdPlace { holdPlace() }
        if step.nudges { current.nudgeHeldBack = true }
        for event in step.events where event != .nudged {
            emit(event, now: now, threadId: current.thread?.id, value: event == .longDriftStarted ? current.clockSec : nil)
        }
    }

    /// Takes back what this drift has shown so far.
    private mutating func calmDown() {
        guard var current = drift else { return }
        current.tier = .grace
        current.mood = nil
        current.holdsGazeOnUser = false
        drift = current
        goHome()
        setMood(baseMood)
        holdPlace()
    }
}
