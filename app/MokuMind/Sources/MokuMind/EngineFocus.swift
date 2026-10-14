import Foundation
import MokuKit

extension BehaviorEngine {
    mutating func tickFocus(now: Date) {
        if !isProud && focusStreakSec >= config.proudAfterSec {
            isProud = true
            if settleAt == nil { setMood(FocusMoments.proudMood) }
        }

        let rotation = breakRotation
        let upcomingBreak = rotation[breaksSuggested % rotation.count]
        // Off (0) means no suggestion, so no line is fetched for one either.
        if config.breakAfterSec > 0 && !breakPrefetched && workSinceBreakSec >= config.breakAfterSec - tuning.breakPrefetchLeadSec {
            breakPrefetched = true
            requestLine(upcomingBreak.kind)
        }
        // One thing at a time: a due break waits for the current gesture or line to settle, except a look-up,
        // which it may cut short. A due look-up waits for everything.
        if config.breakAfterSec > 0 && workSinceBreakSec >= config.breakAfterSec && (settleAt == nil || holdIsLookUp) {
            suggestBreak(upcomingBreak.kind, gesture: upcomingBreak.gesture, now: now)
        } else if settleAt == nil && config.drinkEverySec > 0 && focusSinceDrinkSec >= config.drinkEverySec {
            drink(now: now)
        } else if settleAt == nil && config.smileEverySec > 0 {
            let due = nextLookUpAfterSec ?? drawLookUpInterval()
            nextLookUpAfterSec = due
            if focusSinceSmileSec >= due { lookUp(now: now) }
        }
    }

    /// The break suggestions on offer, in turn. With the water reminder off (`drinkEverySec` 0), water is left out.
    var breakRotation: [(kind: VoiceKind, gesture: Gesture)] {
        config.drinkEverySec > 0 ? FocusMoments.breaks : FocusMoments.breaks.filter { $0.gesture != .drinkWater }
    }

    /// Exactly `smileEverySec` of focus: once a minute means once a minute.
    mutating func drawLookUpInterval() -> Double { config.smileEverySec }

    /// Moku looks up at the user and smiles, its eyes open. Then back to watching the work.
    private mutating func lookUp(now: Date) {
        lookAtUser()
        perform(.smile)
        settleAt = now.addingTimeInterval(FocusMoments.holdSec)
        holdIsLookUp = true
        focusSinceSmileSec = 0
        nextLookUpAfterSec = drawLookUpInterval()
    }

    /// Every `drinkEverySec` of focus: a long, quiet drink of water, a reminder by example (no words). Nothing
    /// else starts until it's done.
    private mutating func drink(now: Date) {
        perform(.drinkWater)
        settleAt = now.addingTimeInterval(FocusMoments.drinkSeconds + 1)
        holdIsLookUp = false
        focusSinceDrinkSec = 0
    }

    private mutating func suggestBreak(_ kind: VoiceKind, gesture: Gesture, now: Date) {
        lookAtUser()
        say(kind, tone: .warm)
        perform(gesture)
        settleAt = now.addingTimeInterval(gesture == .drinkWater ? max(tuning.speakingHoldSec, FocusMoments.drinkSeconds + 1) : tuning.speakingHoldSec)
        if gesture == .drinkWater { focusSinceDrinkSec = 0 }
        holdIsLookUp = false
        emit(.breakSuggested, now: now, threadId: currentThread?.id)
        workSinceBreakSec = 0
        breakPrefetched = false
        breaksSuggested += 1
    }

    /// One `focusGrowth` event per whole focused minute, attributed to the current thread.
    mutating func payFocusGrowth() {
        let (minutes, carry) = WorldGrowth.creditableMinutes(focusedSeconds: growthCarrySec)
        growthCarrySec = carry
        guard minutes > 0, let now = lastNow else { return }
        for _ in 0..<minutes {
            emit(.focusGrowth, now: now, threadId: currentThread?.id, value: WorldGrowth.pointsPerFocusedMinute)
        }
    }

    // MARK: Celebrations (direction §4.4: they never interrupt focus)

    /// At a return or a break: Moku's celebration of a new stage if one is waiting, otherwise a finished piece of work.
    mutating func celebrateWhatWaited(now: Date) {
        if let stage = pendingMilestone {
            pendingMilestone = nil
            celebrateNewStage(stage, now: now)
        } else {
            celebrateCompletion(now: now)
        }
    }

    /// A finished piece of work also plays at a calm moment in the middle of focus: once the cursor and caret
    /// have been still for `calmAfterQuietSec`, so it never lands mid-typing.
    mutating func celebrateCompletionIfCalm(now: Date) {
        guard pendingCompletion != nil, activity != .drifting, settleAt == nil else { return }
        if let lastAttentionAt, now.timeIntervalSince(lastAttentionAt) < tuning.calmAfterQuietSec { return }
        celebrateCompletion(now: now)
    }

    /// Luna writes the line from the label (`completionLabel`); it's said as soon as it arrives, or a built-in
    /// one naming the label after `voiceWaitSec`.
    private mutating func celebrateCompletion(now: Date) {
        guard let completion = pendingCompletion else { return }
        pendingCompletion = nil
        perform(.celebrate)
        setMood(.happy)
        lookAtUser()
        settleAt = now.addingTimeInterval(tuning.speakingHoldSec)
    }

    /// Moku's own celebration of a new stage (the menu bar cue went out when it was reached). Luna's line is
    /// said as soon as it arrives, or a built-in one after `voiceWaitSec`.
    private mutating func celebrateNewStage(_ stage: ForestStage, now: Date) {
        perform(.celebrate)
        setMood(.happy)
        lookAtUser()
        settleAt = now.addingTimeInterval(tuning.speakingHoldSec)
    }

    /// Waits up to `voiceWaitSec` for Luna's line, thinking out loud meanwhile (the bubble's thinking dots); the line
    /// replaces them as soon as it's said.
    mutating func awaitLine(_ kind: VoiceKind, tone: SpeechLine.Tone, now: Date) {
        awaitedLine = AwaitedLine(kind: kind, tone: tone, deadline: now.addingTimeInterval(tuning.voiceWaitSec))
        effects.append(.character(.think))
    }

    /// Stops waiting for a line without saying it (a drift, away): the thinking bubble goes too.
    mutating func dropAwaitedLine() {
        guard awaitedLine != nil else { return }
        awaitedLine = nil
        effects.append(.character(.dismissSpeech))
    }

    // MARK: Tea break

    /// "Taking a break": Moku sits with tea. For up to `teaBreakMaxSec` nothing counts as drift and every clock
    /// but the break's own is frozen. Any drift in progress ends without judgment.
    mutating func startBreak(now: Date) {
        guard !inMeeting, teaBreak == nil else { return }
        if drift != nil { closeDriftSilently() }
        away = nil
        teaBreak = TeaBreak(startedAt: now)
        settleAt = nil
        awaitedLine = nil
        effects.append(.character(.dismissSpeech))
        goHome()
        setMood(.content)
        lookingAtUser = false
        setAttention(.wander, now: nil)
        emit(.breakStarted, now: now, threadId: currentThread?.id)
        effects.append(.setOnBreak(true))
        // The break: a countdown over Moku's head, a cup of tea, then a doze until it's over.
        effects.append(.character(.breakTimer(until: now.addingTimeInterval(config.teaBreakMaxSec), total: config.teaBreakMaxSec)))
        workSinceBreakSec = 0
        breakPrefetched = false
        // A celebration that waited for this calm moment plays first; otherwise the break opens with tea.
        let celebrating = pendingMilestone != nil || pendingCompletion != nil
        celebrateWhatWaited(now: now)
        if !celebrating { perform(.drinkWater) }
    }

    /// Back to work: the break ends as a return. It lays a stone (`returned`) but earns no return bonus.
    mutating func endBreak(now: Date) {
        guard let spell = teaBreak else { return }
        teaBreak = nil
        effects.append(.character(.breakTimer(until: nil, total: 0)))
        activity = .focused
        emit(.breakEnded, now: now, threadId: currentThread?.id, value: spell.elapsedSec)
        effects.append(.setOnBreak(false))
        emit(.returned, now: now, threadId: currentThread?.id, value: spell.elapsedSec)
        setMood(.happy)
        effects.append(.character(.celebrateReturn(.small)))
        settleAt = now.addingTimeInterval(tuning.blipSec)
        welcomedBackAt = now
        celebrateWhatWaited(now: now)
    }

    /// A break longer than `teaBreakMaxSec` is over. Nobody came back to work, so it isn't a return;
    /// whatever the next verdict says starts fresh (a drift from zero, work, or an away).
    mutating func tickBreak(now: Date) {
        guard let spell = teaBreak else { return }
        // The tea is done: Moku dozes for the rest of the break.
        if !spell.dozing, spell.elapsedSec >= FocusMoments.drinkSeconds + 1 {
            teaBreak?.dozing = true
            setMood(.sleepy)
        }
        guard spell.elapsedSec >= config.teaBreakMaxSec else { return }
        // Time's up: Moku wakes, stretches and says so; watching starts again.
        teaBreak = nil
        activity = .unknown
        emit(.breakEnded, now: now, threadId: currentThread?.id, value: spell.elapsedSec)
        effects.append(.setOnBreak(false))
        effects.append(.character(.breakTimer(until: nil, total: 0)))
        setMood(.happy)
        perform(.stretch)
        let minutes = Int((config.teaBreakMaxSec / 60).rounded())
        say(text: "That’s your \(minutes)-minute break. Ready when you are.", tone: .warm)
        settleAt = now.addingTimeInterval(tuning.speakingHoldSec)
        welcomedBackAt = now
    }

    /// The welcome ("Say hi again") or a test takes over mid-break: the break is over, quietly. Your day closes it, and the
    /// timer and the popover's "End break" go with it. It isn't a return (no stone, no celebration): what follows the welcome
    /// starts afresh.
    mutating func endBreakForManualControl(now requested: Date) -> [EngineEffect] {
        let now = advance(to: requested)
        guard let spell = teaBreak else { return takeEffects() }
        teaBreak = nil
        activity = .unknown
        emit(.breakEnded, now: now, threadId: currentThread?.id, value: spell.elapsedSec)
        effects.append(.setOnBreak(false))
        effects.append(.character(.breakTimer(until: nil, total: 0)))
        return takeEffects()
    }

    /// The cursor moved well after the break started: someone is back at the desk.
    func isBackAtDesk(now: Date) -> Bool {
        guard let spell = teaBreak, let lastAttentionAt else { return false }
        return lastAttentionAt.timeIntervalSince(spell.startedAt) >= tuning.backAtDeskAfterSec
            && now.timeIntervalSince(lastAttentionAt) <= tuning.backAtDeskAfterSec
    }

    // MARK: Away

    /// `idleBeforeSec`: how long the person had already been gone when the away was noticed (the brain says away after
    /// `awayAfterIdleSec` without input; a sleeping Mac is noticed at once).
    mutating func becomeAway(idleBeforeSec: Double) {
        guard away == nil else { return }
        away = Away(idleBeforeSec: idleBeforeSec)
        settleAt = nil
        dropAwaitedLine()
        lookingAtUser = false
        setAttention(.wander, now: nil)
    }

    /// A long away: Moku gives up waiting. It walks home, gets sleepy, and the break timer starts over.
    mutating func tickAway(now: Date) {
        guard var spell = away, !spell.isLong, spell.elapsedSec >= config.longAwaySec else { return }
        spell.isLong = true
        away = spell
        effects.append(.character(.dismissSpeech))
        if drift != nil { closeDriftSilently() } else { activity = .unknown }
        goHome()
        setMood(.sleepy)
        perform(.yawn)
        resetContinuity()
        workSinceBreakSec = 0
        breakPrefetched = false
    }

    mutating func wake(now: Date) {
        guard var spell = away else { return }
        // The long away plays in a tick. When the person is back before one (the Mac woke and the first thing heard was their
        // app, or an answer to an old sample), play it now: the sleepy sit-down, the open drift closed without judgment, the
        // continuous-work timers starting over, and the greeting after it.
        if !spell.isLong, spell.elapsedSec >= config.longAwaySec {
            tickAway(now: now)
            spell = away ?? spell
        }
        away = nil
        if spell.isLong {
            // A wave hello, no words over the head (the friends, 2026-10-14).
            setMood(.content)
            perform(.wave)
            lookAtUser()
            settleAt = now.addingTimeInterval(tuning.speakingHoldSec)
        } else if drift?.looksAtUser == true {
            lookAtUser()
        } else {
            followWork(now: now)
        }
    }

    // MARK: Meetings

    /// Calls and screen sharing hide Moku and freeze every clock. Afterwards (once the call has been over for
    /// `meetingHoldSec`, so a call that drops for a moment doesn't flash it back) it resumes calmly: an open drift is
    /// closed without judgment, because a meeting never counts as drift.
    mutating func meetingChanged(_ context: MeetingContext, now: Date) {
        let meetingNow = context.inCall || context.sharingScreen
        if meetingNow {
            meetingEndedAt = nil
            guard !inMeeting else { return }
            inMeeting = true
            settleAt = nil
            awaitedLine = nil
            attentionPending = false
            effects.append(.character(.dismissSpeech))
            effects.append(.character(.setHidden(true)))
        } else if inMeeting, meetingEndedAt == nil {
            meetingEndedAt = now
        }
    }

    /// The call's been over long enough: Moku comes back.
    mutating func leaveMeeting(now: Date) {
        meetingEndedAt = nil
        guard inMeeting else { return }
        inMeeting = false
        effects.append(.character(.setHidden(false)))
        away = nil
        if drift != nil { closeDriftSilently() }
        goHome()
        setMood(baseMood)
        if teaBreak == nil { followWork(now: now) } else { setAttention(.wander, now: now) }
    }
}

struct Away: Sendable {
    /// How long the person had been gone when the away began (see `becomeAway`).
    var idleBeforeSec: Double = 0
    var elapsedSec: Double = 0
    var isLong = false
}

struct TeaBreak: Sendable {
    var startedAt: Date
    /// Break time so far (a meeting pauses it).
    var elapsedSec: Double = 0
    /// The tea is finished and Moku is dozing.
    var dozing = false
}

struct AwaitedLine: Sendable {
    var kind: VoiceKind
    var tone: SpeechLine.Tone
    var deadline: Date
}
