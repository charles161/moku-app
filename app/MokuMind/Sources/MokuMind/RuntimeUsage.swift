import Foundation
import MokuKit

/// What the runtime remembers to report usage (docs/specs/deeper-analytics.md): the drift's ladder so far, the ask
/// waiting for its outcome, the last break suggestion, a call's hiding. Nothing here is polled: it's read off what the
/// engine just did.
struct RuntimeUsageState {
    /// The drift the ladder steps were counted for (by when it started), and how many of its steps were.
    var driftStartedAt: Date?
    var stepsReported = 0
    /// The ask went up then, and its outcome isn't known yet; the day it was asked ends at `askDayEnds`.
    var askedAt: Date?
    var askDayEnds: Date?
    var breakSuggestedAt: Date?
    var breakStartedAt: Date?
    /// When the "What's new" bubble went up, until it's answered: how long it stayed up is counted from here.
    var whatsNewShownAt: Date?
    /// The meeting as last heard (a call, or screen sharing), and when Moku hid for it.
    var meeting: MeetingContext?
    var hiddenAt: Date?
    /// Seconds at the Mac not yet counted as a whole minute.
    var activeSeconds: Double = 0
}

extension CompanionRuntime {
    /// A break started within this long of a suggestion was taken because of it.
    static let suggestionTakenWithinSec: Double = 600
    /// Back within this long of the ask: it worked at once.
    static let askWorkedWithinSec: Double = 120

    /// The ladder's steps as `drift_step` words (grace isn't a step anyone sees).
    static func usageWord(_ step: LadderStep.ID) -> String? {
        switch step {
        case .grace: nil
        case .sad: "sad"
        case .lookBack: nil  // the same sadness, no longer looking at the person: nothing new to count
        case .longDrift: "long"
        case .standUp: "tall"
        case .ask: "ask"
        }
    }

    /// A break suggestion's kind, from the gesture that goes with it.
    static func breakKind(_ gesture: Gesture) -> String? {
        switch gesture {
        case .drinkWater: "water"
        case .stretch: "stretch"
        case .glance: "look_away"
        case .wave: "walk"
        default: nil
        }
    }

    /// What the engine just did, as usage: the ladder's new steps, the ask's outcome, break suggestions and breaks, the
    /// water reminder, "Where was I?" offered, and the companion hidden for a call or screen sharing.
    func reportEngineUsage(_ effects: [EngineEffect]) {
        guard usage != nil || count != nil else { return }
        let now = clock.now()
        reportLadder(now: now)
        let events = effects.compactMap { if case let .event(event) = $0 { event.type } else { nil } }
        let gestures = effects.compactMap { if case let .character(.perform(gesture)) = $0 { gesture } else { nil } }
        if events.contains(.breakSuggested) {
            usageState.breakSuggestedAt = now
            if let kind = gestures.lazy.compactMap(Self.breakKind).first { usage?("break_suggested", ["kind": .word(kind)]) }
        } else if gestures.contains(.drinkWater) && !events.contains(.breakStarted) {
            count?(.waterReminder)
        }
        for case let .character(command) in effects {
            switch command {
            case let .setHidden(hidden):
                noteHidden(hidden, now: now)
            default: break
            }
        }
    }

    /// The breaks' extra facts: whether a start followed a suggestion, and how long a break lasted.
    func breakFacts(_ type: CompanionEventType, value: Double?) -> [String: UsageValue] {
        let now = clock.now()
        switch type {
        case .breakStarted:
            usageState.breakStartedAt = now
            let suggested = usageState.breakSuggestedAt.map { now.timeIntervalSince($0) <= Self.suggestionTakenWithinSec } ?? false
            return ["after_suggestion": .bool(suggested)]
        case .breakEnded:
            defer { usageState.breakStartedAt = nil }
            let seconds = value ?? usageState.breakStartedAt.map { now.timeIntervalSince($0) }
            return seconds.map { ["seconds": .int(max(0, Int($0.rounded())))] } ?? [:]
        default:
            return [:]
        }
    }

    /// Each ladder step the drift reached since the last look, once; the ask starts the wait for its outcome. The outcome:
    /// back at work within 2 minutes of the ask, later that day, or not that day.
    private func reportLadder(now: Date) {
        if let drift = engine.drift {
            if drift.startedAt != usageState.driftStartedAt { usageState.driftStartedAt = drift.startedAt; usageState.stepsReported = 0 }
            while usageState.stepsReported < drift.stepsFired {
                let step = LadderStep.ladder[usageState.stepsReported].id
                usageState.stepsReported += 1
                guard let word = Self.usageWord(step) else { continue }
                usage?("drift_step", ["step": .word(word)])
                if step == .ask {
                    usageState.askedAt = now
                    usageState.askDayEnds = Calendar.current.dateInterval(of: .day, for: now)?.end
                }
            }
        } else {
            usageState.driftStartedAt = nil; usageState.stepsReported = 0
        }
        if let askedAt = usageState.askedAt, engine.status.phase == .focused {
            let seconds = now.timeIntervalSince(askedAt)
            usage?("ask_outcome", ["outcome": .word(seconds <= Self.askWorkedWithinSec ? "within_2_min" : "later"), "seconds": .int(Int(seconds.rounded()))])
            usageState.askedAt = nil
        }
    }

    /// Every tick: a minute at the Mac (not away, not on a break) is counted, and an ask still waiting when its day ends
    /// didn't work that day.
    func tickUsage(now: Date) {
        let phase = engine.status.phase
        if phase != .away && phase != .onBreak {
            usageState.activeSeconds += Self.tickIntervalSec
            if usageState.activeSeconds >= 60 { usageState.activeSeconds -= 60; count?(.activeMinute) }
        }
        if usageState.askedAt != nil, let ends = usageState.askDayEnds, now >= ends {
            usage?("ask_outcome", ["outcome": .word("not_that_day")])
            usageState.askedAt = nil
        }
    }

    /// Moku hid for a call or screen sharing, or came back after it.
    private func noteHidden(_ hidden: Bool, now: Date) {
        if hidden, usageState.hiddenAt == nil {
            usageState.hiddenAt = now
            usage?("hidden", ["by": .word(usageState.meeting?.inCall == false && usageState.meeting?.sharingScreen == true ? "screen_share" : "call")])
        } else if !hidden, let since = usageState.hiddenAt {
            usageState.hiddenAt = nil
            usage?("shown", ["by": .word("automatic"), "after_seconds": .int(max(0, Int(now.timeIntervalSince(since).rounded())))])
        }
    }

    /// A judgment's answer: what it said, how long the brain took, and how long Jev took when it was asked.
    func countJudgment(_ verdict: Verdict?, ms: Int) {
        guard let count else { return }
        count(.brainAnswer(ms: ms))
        guard let verdict else { return }
        if verdict.source == .jev { count(.jevAnswer(ms: verdict.latencyMs)) }
        switch verdict.state {
        case .working: count(.verdict(verdict.isSwitch ? .switched : .work))
        case .drifting: count(.verdict(.drift))
        default: count(.verdict(.unknown))
        }
    }
}

extension ContinuousClock.Instant {
    /// Milliseconds from this instant until now.
    var millisecondsAgo: Int {
        let elapsed = duration(to: .now)
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
