import CoreGraphics
import Foundation
import MokuKit

/// How Moku's body and voice are commanded: mood, gaze, gestures, walking and lines.
extension BehaviorEngine {
    // MARK: Mood and body

    /// The mood Moku settles back into once a blip, gesture or line is over.
    var baseMood: Mood {
        if away?.isLong == true { return .sleepy }
        if teaBreak != nil { return .content }
        switch activity {
        case .focused: return isProud ? .proud : .content
        case .drifting: return forceCalm || drift?.resting == true ? .content : drift?.mood ?? .curious
        case .unknown: return .content
        }
    }

    mutating func setMood(_ newMood: Mood) {
        guard newMood != mood else { return }
        mood = newMood
        effects.append(.character(.setMood(newMood)))
    }

    mutating func perform(_ gesture: Gesture) {
        effects.append(.character(.perform(gesture)))
    }

    /// Walk home if away from it, then sit back down.
    mutating func goHome() {
        if !atHome {
            effects.append(.character(.move(.home)))
            atHome = true
        }
        if standing {
            perform(.sitDown)
            standing = false
        }
    }

    /// The end of a blip, gesture or line: back to the base mood and to following the work.
    mutating func settle(now: Date) {
        settleAt = nil
        holdIsLookUp = false
        let escalatedDrift = drift?.hasFired(.standUp) ?? false
        if drift?.looksAtUser != true {
            followWork(now: now)
        }
        setMood(baseMood)
        if standing && atHome && !escalatedDrift {
            perform(.sitDown)
            standing = false
        }
    }

    // MARK: Attention

    /// The cursor or caret moved. While working, the eyes follow it (throttled). During a drift they hold the
    /// work's place instead: Moku never watches the distracting window. On a break they wander.
    mutating func attention(at point: CGPoint, now: Date) {
        lastAttentionAt = now
        guard activity != .drifting, teaBreak == nil else { return }
        workPoint = point
        guard !inMeeting, !lookingAtUser, away?.isLong != true else { return }
        let interval = tuning.attentionIntervalSec
        if let last = lastAttentionSentAt, now.timeIntervalSince(last) < interval {
            attentionPending = true  // the newest point goes out on a later tick
            return
        }
        setAttention(.point(point), now: now)
    }

    mutating func flushAttention(now: Date) {
        guard attentionPending, let workPoint, !lookingAtUser, away?.isLong != true, activity != .drifting else { return }
        if let last = lastAttentionSentAt, now.timeIntervalSince(last) < tuning.attentionIntervalSec { return }
        setAttention(.point(workPoint), now: now)
    }

    /// Eyes back on the user's work (or wandering when there's no work point yet). During a drift that's
    /// the work's place, not wherever the cursor went.
    mutating func followWork(now: Date) {
        if activity == .drifting {
            holdPlace()
            return
        }
        if teaBreak != nil {
            lookingAtUser = false
            setAttention(.wander, now: now)
            return
        }
        lookingAtUser = false
        setAttention(workPoint.map { .point($0) } ?? .wander, now: now)
    }

    /// Keep looking where the work was when it was last judged working (looking around if that's not known).
    mutating func holdPlace() {
        lookingAtUser = false
        attentionPending = false
        setAttention((workPlace ?? workPoint).map { .point($0) } ?? .wander, now: nil)
    }

    mutating func lookAtUser() {
        lookingAtUser = true
        attentionPending = false
        setAttention(.user, now: nil)
    }

    mutating func setAttention(_ target: AttentionTarget, now: Date?) {
        attentionPending = false
        guard target != attentionTarget else { return }
        attentionTarget = target
        if let now { lastAttentionSentAt = now }
        effects.append(.character(.setAttention(target)))
    }

    // MARK: Voice

    static let driftLineKinds: Set<VoiceKind> = [.nudge, .callName, .remindFocus, .comeOn, .welcomeBack]

    /// Lines that name the next piece of today's house ("four minutes until the round door goes up").
    static let nextPieceKinds: Set<VoiceKind> = [.nudge, .remindFocus, .comeOn]

    func voiceRequest(_ kind: VoiceKind, drift current: Drift? = nil) -> VoiceRequest {
        let current = current ?? drift
        let nextPiece = Self.nextPieceKinds.contains(kind) ? lastTodayMinutes.flatMap { DayHouse.next(Double($0)) } : nil
        return VoiceRequest(kind: kind, userName: config.userName,
                            threadTitle: (current?.thread ?? currentThread)?.title,
                            focusMinutes: Int((current?.focusStreakBefore ?? focusStreakSec) / 60),
                            driftMinutes: current.map { Int($0.clockSec / 60) },
                            distraction: current?.distraction,
                            nextUnit: nextPiece?.name, minutesToNextUnit: nextPiece?.minutes,
                            completionLabel: kind == .celebrate ? celebratedLabel : nil)
    }

    /// Ask the brain for a line ahead of time, unless one is ready or already on its way.
    mutating func requestLine(_ kind: VoiceKind, drift current: Drift? = nil, force: Bool = false) {
        guard force || (preparedLines[kind] == nil && !requestedKinds.contains(kind)) else { return }
        requestedKinds.insert(kind)
        effects.append(.requestVoice(voiceRequest(kind, drift: current)))
    }

    mutating func voiceReady(_ kind: VoiceKind, _ line: VoiceLine, now: Date) {
        // Replies nobody is waiting for any more (the drift ended, a fallback was already said) are dropped,
        // so a stale "You were focused for 47 minutes" can't surface in a later drift.
        guard requestedKinds.contains(kind) else { return }
        requestedKinds.remove(kind)
        preparedLines[kind] = line
        if let awaitedLine, awaitedLine.kind == kind, !inMeeting {
            self.awaitedLine = nil
            say(kind, tone: awaitedLine.tone)
            settleAt = now.addingTimeInterval(tuning.speakingHoldSec)
        }
    }

    mutating func sayAwaitedLine(now: Date) {
        guard let awaitedLine else { return }
        self.awaitedLine = nil
        say(awaitedLine.kind, tone: awaitedLine.tone)
    }

    /// Say a line of this kind: Luna's if it's ready, otherwise a built-in one. Never the same text twice in a row.
    mutating func say(_ kind: VoiceKind, tone: SpeechLine.Tone, drift current: Drift? = nil) {
        say(text: lineText(kind, drift: current), tone: tone)
        if kind == .celebrate { celebratedLabel = nil }
    }

    /// `untilDismissed`: the line stays up until it's taken down (the ask, until the drift ends).
    mutating func say(text: String, tone: SpeechLine.Tone, untilDismissed: Bool = false) {
        lastSpokenText = text
        let line = untilDismissed ? SpeechLine(text: text, tone: tone, duration: SpeechLine.untilDismissed) : SpeechLine(text: text, tone: tone)
        effects.append(.character(.say(line)))
    }

    private mutating func lineText(_ kind: VoiceKind, drift current: Drift?) -> String {
        requestedKinds.remove(kind)
        if let line = preparedLines.removeValue(forKey: kind) {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && text != lastSpokenText { return text }
        }
        let variants = FallbackLines.variants(for: voiceRequest(kind, drift: current))
        return variants.first { $0 != lastSpokenText } ?? variants[0]
    }

    mutating func forgetDriftLines() {
        for kind in Self.driftLineKinds {
            preparedLines[kind] = nil
            requestedKinds.remove(kind)
        }
    }
}
