import Foundation
import MokuKit

/// One drift, from the first drifting verdict to the return (or until a meeting, a break or a long away closes it).
struct Drift: Sendable {
    /// When the person left their work for it: when the drifting place came to the front, but not before the last
    /// working evidence. "Where was I?" measures the drift's length from here, in wall time.
    var startedAt: Date
    /// The last moment of work before it: what "Where was I?" names on the way back.
    var leftWork: WorkMoment?
    /// Seconds of drifting on fresh evidence. Every ladder step compares against this.
    var clockSec: Double = 0
    /// The continuous focus before the drift: "You were focused for N minutes."
    var focusStreakBefore: Double
    var thread: ThreadRef?
    /// The goal left (goal-aware judging only), for the ask.
    var goal: ThreadRef?
    var distraction: String?
    var sampleId: String?
    /// How many ladder steps have fired, and when (drift clock).
    var stepsFired = 0
    var firedAt: [LadderStep.ID: Double] = [:]
    /// The lantern tier the ladder last set.
    var tier = WorkState.grace
    /// How a return now would be celebrated (the ladder's last `returns`).
    var returns = LadderStep.Return.ignored
    /// The mood the ladder last set: what Moku settles back into during this drift (nil: unchanged).
    var mood: Mood?
    /// Looking at the user until the drift ends.
    var holdsGazeOnUser = false
    /// This drift showed the sad move (a drift inside `sadMoveCooldownSec` of the last one is watched calmly).
    var showedSadness = false
    var isLong = false
    var ignoredNudgeSent = false
    /// forceCalm kept the nudge unsaid, so there's no nudge for its follow-ups to report on.
    var nudgeHeldBack = false
    /// No drifting verdict for `evidenceWindowSec`: the clock stands still and Moku has calmed (`rest`) until fresh
    /// drifting evidence picks the drift back up.
    var resting = false

    func hasFired(_ step: LadderStep.ID) -> Bool { firedAt[step] != nil }
    /// Looking at the user right now: from the sad step on, unless Moku is resting.
    var looksAtUser: Bool { holdsGazeOnUser && !resting }
    var lastStep: LadderStep? { stepsFired > 0 ? LadderStep.ladder[stepsFired - 1] : nil }
}

enum WorkCause { case verdict, fastReturn, pat, backToWork }

extension BehaviorEngine {
    // MARK: Transitions

    mutating func becomeWorking(now: Date, thread: ThreadRef?, sampleId: String?, cause: WorkCause) {
        if let thread {
            currentThread = thread
            // Coming back from a drift, an away or a break has its own move (the return, the wave): no nod on top.
            labelIfNew(thread, now: now, nods: activity != .drifting && away == nil && teaBreak == nil)
        }
        workingEvidenceAt = now
        workPlace = workPoint ?? workPlace
        if away != nil { wake(now: now) }
        if teaBreak != nil {
            endBreak(now: now)
            return
        }
        switch activity {
        case .focused:
            break
        case .unknown:
            activity = .focused
            if settleAt == nil { setMood(baseMood) }
        case .drifting:
            if cause == .pat { acceptDrift(now: now) } else { returnFromDrift(now: now, sampleId: sampleId) }
        }
    }

    /// A nod for a line of work: the first time it arrives with a real (not provisional) title, and again when the user
    /// comes back to it after `threadLabelGapSec` without it. It used to name it in a label; Charles, 2026-10-14: those
    /// aren't needed, Moku shows it knows with its body (hovering it shows the task).
    private mutating func labelIfNew(_ thread: ThreadRef, now: Date, nods: Bool) {
        let lastWorked = threadLastWorkedAt[thread.id]
        threadLastWorkedAt[thread.id] = now
        guard !thread.provisional else { return }
        let backAfterAGap = lastWorked.map { now.timeIntervalSince($0) >= config.threadLabelGapSec } ?? true
        guard !labeledThreads.contains(thread.id) || backAfterAGap else { return }
        labeledThreads.insert(thread.id)
        if nods { perform(.nod) }
    }

    mutating func becomeDrifting(now: Date, sampleId: String) {
        driftingEvidenceAt = now
        if away != nil { wake(now: now) }
        switch activity {
        case .drifting:
            let distraction = currentDistraction
            drift?.sampleId = sampleId
            drift?.distraction = distraction
            if drift?.resting == true { pickUpDrift() }
        case .focused, .unknown:
            startDrift(now: now, sampleId: sampleId)
        }
    }

    mutating func startDrift(now: Date, sampleId: String) {
        activity = .drifting
        focusSinceSmileSec = 0  // the look-up comes after a minute of continuous focus, counted afresh
        let left = min(now, max(focusSince ?? now, workingEvidenceAt ?? .distantPast))
        drift = Drift(startedAt: left, leftWork: lastWork, focusStreakBefore: focusStreakSec, thread: currentThread, goal: currentGoal,
                      distraction: currentDistraction, sampleId: sampleId)
        forgetDriftLines()
        dropAwaitedLine()
        settleAt = nil
        attentionPending = false
        runLadder(now: now)
    }

    /// Coming back. Light and body, no words (the friends, 2026-10-14: no lines over the head): the lantern flares
    /// (`celebrateReturn`), Moku walks home if it had left, and the return is logged. A drift still in grace isn't a
    /// return at all, and one shorter than `Stones.afterDriftSec` is a glance: celebrated, but it lays no stone and earns
    /// no bonus.
    mutating func returnFromDrift(now: Date, sampleId: String?) {
        guard let finished = drift else { return }
        endDrift()
        activity = .focused
        guard finished.returns != .ignored else {
            if settleAt == nil { setMood(baseMood) }
            return
        }
        let threadId = (currentThread ?? finished.thread)?.id
        welcomedBackAt = now
        // Glad you're back only after a drift that showed its sadness: after a calm one the face doesn't flip. Under
        // forceCalm nothing shows sadness, and Moku is still glad when you come back (the kill switch's promise).
        if finished.showedSadness || forceCalm { setMood(.happy) }
        effects.append(.character(.celebrateReturn(finished.returns == .full ? .full : .small)))
        settleAt = now.addingTimeInterval(finished.returns == .full ? tuning.speakingHoldSec : tuning.blipSec)
        goHome()
        let laysStone = finished.clockSec >= Stones.afterDriftSec
        if !finished.isLong { emit(.shortDrift, now: now, threadId: threadId, value: finished.clockSec) }
        if laysStone { emit(.returned, now: now, threadId: threadId, value: finished.clockSec) }
        if finished.isLong {
            // "Within a short time after a nudge": once ignoredNudge went out, a late return isn't a label for the nudge.
            if finished.hasFired(LadderFollowUps.nudge) && !finished.ignoredNudgeSent && !finished.nudgeHeldBack {
                effects.append(.feedback(Feedback(ts: now, kind: .returnedAfterNudge, sampleId: sampleId, threadId: threadId)))
            }
        } else if laysStone, let points = WorldGrowth.returnPoints(focusMinutesBefore: focusSinceReturnSec / 60) {
            emit(.returnGrowth, now: now, threadId: threadId, value: points)
            focusSinceReturnSec = 0
        }
        celebrateWhatWaited(now: now)
    }

    /// A pat during a drift: the user says this is fine. Resume focus now, without return events or bonus.
    mutating func acceptDrift(now: Date) {
        endDrift()
        activity = .focused
        setMood(.happy)
        goHome()
        settleAt = now.addingTimeInterval(tuning.blipSec)
    }

    /// A meeting, a break or a long away ends the drift without judgment: no events, no lines.
    mutating func closeDriftSilently() {
        endDrift()
        activity = .unknown
    }

    private mutating func endDrift() {
        drift = nil
        driftingEvidenceAt = nil
        forgetDriftLines()
    }

    // MARK: The ladder

    mutating func tickDrift(now: Date) {
        guard isFresh(driftingEvidenceAt, now: now) else { rest(); return }
        runLadder(now: now)
        guard var current = drift else { return }
        defer { drift = current }

        if let nudgedAt = current.firedAt[LadderFollowUps.nudge], !current.ignoredNudgeSent, !current.nudgeHeldBack,
           current.clockSec >= nudgedAt + config.ignoredNudgeAfterSec {
            current.ignoredNudgeSent = true
            effects.append(.feedback(Feedback(ts: now, kind: .ignoredNudge, sampleId: current.sampleId,
                                              threadId: current.thread?.id)))
        }
    }

    /// No drifting verdict for `evidenceWindowSec` (the brain unsure or down, a neutral app like Finder): the drift
    /// clock already stands still, and Moku calms fully, seated and content with its eyes on the work and the ask
    /// down, instead of standing red and still (the red goes with the lantern, idle). It's not a return: the drift
    /// goes on, and fresh drifting evidence picks it back up (docs/specs/next-wave.md §6).
    private mutating func rest() {
        guard var current = drift, !current.resting else { return }
        current.resting = true
        drift = current
        settleAt = nil
        goHome()
        setMood(baseMood)
        holdPlace()
    }

    /// Fresh drifting evidence after a rest: Moku shows the drift again where the ladder left it (the mood, standing,
    /// eyes on you). Nothing is logged again; the ladder goes on from its next step.
    private mutating func pickUpDrift() {
        guard var current = drift else { return }
        current.resting = false
        if !forceCalm {
            if let mood = current.mood { setMood(mood) }
            if current.hasFired(.standUp) { standUp() }
            if current.holdsGazeOnUser { lookAtUser() }
        }
        drift = current
    }

    /// Fire every ladder step that's due, in order. Returns whether any fired.
    @discardableResult
    mutating func runLadder(now: Date) -> Bool {
        guard var current = drift else { return false }
        var stepped = false
        while current.stepsFired < LadderStep.ladder.count {
            let step = LadderStep.ladder[current.stepsFired]
            guard current.clockSec >= step.at.seconds(in: config) else { break }
            current.stepsFired += 1
            current.firedAt[step.id] = current.clockSec
            run(step, drift: &current, now: now)
            stepped = true
        }
        drift = current
        return stepped
    }

    /// One row of the ladder, column by column.
    private mutating func run(_ step: LadderStep, drift current: inout Drift, now: Date) {
        let threadId = current.thread?.id
        if step.makesDriftLong {
            current.isLong = true
            resetContinuity()
        }
        if let returns = step.returns { current.returns = returns }
        guard !forceCalm else {
            runCalmly(step, drift: &current, now: now)
            return
        }
        if let tier = step.tier { current.tier = tier }
        // The sad move shows once in `sadMoveCooldownSec`: a drift soon after another is watched with the normal face,
        // eyes on the work (Charles, 2026-10-14: "its doing it twice").
        var step = step
        if step.id == .sad {
            if let last = lastSadMoveAt, now.timeIntervalSince(last) < Self.sadMoveCooldownSec {
                step.mood = nil; step.gesture = nil; step.gaze = .holdPlace
            } else {
                lastSadMoveAt = now
                current.showedSadness = true
            }
        }
        if let mood = step.mood {
            current.mood = mood
            setMood(mood)
        }
        if let gesture = step.gesture {
            if gesture == .standUp { standUp() } else { perform(gesture) }
        }
        switch step.gaze {
        case .holdPlace:
            current.holdsGazeOnUser = false
            holdPlace()
        case .atUser:
            settleAt = nil
            current.holdsGazeOnUser = true
            lookAtUser()
        case nil:
            break
        }
        if let spot = step.move {
            effects.append(.character(.move(spot)))
            atHome = spot == .home
        }
        for event in step.events {
            emit(event, now: now, threadId: threadId, value: event == .longDriftStarted ? current.clockSec : nil)
        }
    }

    mutating func standUp() {
        guard !standing else { return }
        perform(.standUp)
        standing = true
    }

    mutating func emit(_ type: CompanionEventType, now: Date, threadId: String?, value: Double? = nil) {
        effects.append(.event(CompanionEvent(ts: now, type: type, threadId: threadId, value: value)))
    }
}
