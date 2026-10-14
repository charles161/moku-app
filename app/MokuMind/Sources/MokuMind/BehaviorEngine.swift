import CoreGraphics
import Foundation
import MokuKit

/// What Moku does about what the user is doing. Pure and deterministic: no timers, no I/O, no clock.
/// The runtime feeds it inputs with `handle` and calls `tick` about once a second; both return effects.
///
/// Time model (the rules are also written up in lanes/mind.md):
/// - Every call first advances the engine's clocks to `now`. A `now` earlier than one already seen
///   counts as no time passing.
/// - The focus clock runs only while focused on fresh working evidence, and the drift clock only while
///   drifting on fresh drifting evidence. Evidence is fresh for `config.evidenceWindowSec` after a verdict,
///   a fast return or a pat. So unknown verdicts, silence and a dead brain freeze escalation, and a
///   laptop sleep can't mint focus minutes.
/// - Away and meetings freeze both clocks.
/// - Scheduled behavior (smiles, the drift ladder, breaks, growth, settling back after a gesture) fires only
///   in `tick`. Reactions to inputs happen in `handle`. The drift ladder itself is a table: `BehaviorLadder.swift`.
/// - `WorkState` (the lantern) is derived from all of the above after every call, and sent when it changes.
public struct BehaviorEngine: Sendable {
    public private(set) var config: CompanionConfig
    public let tuning: EngineTuning

    public init(config: CompanionConfig = .standard, tuning: EngineTuning = .standard, random: MokuRandom = MokuRandom()) {
        self.config = config
        self.tuning = tuning
        self.random = random
    }

    /// Chance, seeded: only the focus look-ups use it.
    var random: MokuRandom

    // MARK: What the user is doing

    enum Activity: Sendable { case unknown, focused, drifting }

    var activity = Activity.unknown
    var drift: Drift?
    var away: Away?
    var teaBreak: TeaBreak?
    var inMeeting = false
    /// When the last call or screen share ended: Moku stays hidden until it's been over `meetingHoldSec`.
    var meetingEndedAt: Date?
    /// A call app lets go of the mic for a moment mid-call; showing the companion then flashed it for 3 s (2026-10-07).
    static let meetingHoldSec: Double = 30
    /// The relay's forceCalm switch: Moku never reacts to a drift (`setForceCalm`, EngineCalm.swift).
    public internal(set) var forceCalm = false
    /// What the lantern shows, as last sent.
    var workState = WorkState.idle

    // MARK: Focus clocks (seconds of credited focus)

    /// Continuous focus: short drifts pause it, long drifts and long aways reset it.
    var focusStreakSec: Double = 0
    /// Focus since the last credited return; what return growth is scaled by.
    var focusSinceReturnSec: Double = 0
    /// Focus since Moku last looked up at the user, and how much focus the next look-up waits for.
    var focusSinceSmileSec: Double = 0
    /// Focused seconds since Moku last drank (its own drink or the water break's).
    var focusSinceDrinkSec: Double = 0
    var nextLookUpAfterSec: Double?
    /// The current hold is a look-up, which a due break may cut short.
    var holdIsLookUp = false
    /// Focus since the last break suggestion or long away.
    var workSinceBreakSec: Double = 0
    /// Focus not yet paid out as a whole-minute `focusGrowth` event.
    var growthCarrySec: Double = 0
    var isProud = false
    var breakPrefetched = false
    var breaksSuggested = 0

    // MARK: Evidence

    var workingEvidenceAt: Date?
    var driftingEvidenceAt: Date?
    /// When the neutral app now in front came to the front (see `holdThroughANeutralApp`).
    var neutralSince: Date?
    var currentThread: ThreadRef?
    /// Goal-aware judging: the goal of the last work. A drift remembers it, and the ask names it.
    var currentGoal: ThreadRef?
    var lastSampleId: String?
    /// Threads whose label has been shown, and when each thread last had a working verdict.
    var labeledThreads: Set<String> = []
    var threadLastWorkedAt: [String: Date] = [:]

    // MARK: Places (fast return detection)

    var focus: WorkContext?
    var focusApp: AppInfo?
    var focusAppName: String? { focusApp?.name }
    /// The window in front (its title and address), and when its place came to the front.
    var focusWindow: WindowInfo?
    var focusSince: Date?
    var judgments: [WorkContext: Judgment] = [:]
    var judgmentOrder: [WorkContext] = []
    /// Apps seen with a URL: a focus change in one of them without a URL is incomplete.
    var browsers: Set<String> = []
    /// When each place was last in front (a sniff is for a window new to Moku), and the last sniff.
    var placesSeenAt: [WorkContext: Date] = [:]
    var lastSniffAt: Date?

    // MARK: Work (EngineWork.swift)

    /// The last moment of work: where it was, its task, and when.
    var lastWork: WorkMoment?

    // MARK: What's new (WhatsNew.swift)

    /// When Moku last turned to the person on their way back (a celebrated comeback, or a break's end): a calm moment.
    var welcomedBackAt: Date?
    /// When the drift ladder last showed the sad move (EngineDrift.swift).
    var lastSadMoveAt: Date?
    /// The sad move shows at most once in this long (Charles, 2026-10-14, after quick drifts got one each).
    static let sadMoveCooldownSec: Double = 180
    /// When the bubble last put up goes by itself (nil: none up; distantFuture: until it's taken down).
    var speechUntil: Date?

    // MARK: Body, as last commanded

    var mood = Mood.content
    var atHome = true
    var standing = false
    var attentionTarget = AttentionTarget.wander
    /// Holding the gaze on the user: attention pass-through pauses until the hold settles.
    var lookingAtUser = false
    /// When the current gesture, blip or line is over and Moku settles back into its base mood and gaze.
    var settleAt: Date?

    // MARK: Attention pass-through

    var workPoint: CGPoint?
    /// Where the work was at the last working verdict: what Moku keeps looking at during a drift.
    var workPlace: CGPoint?
    var lastAttentionSentAt: Date?
    /// When the cursor or caret last moved (typing, scrolling, pointing).
    var lastAttentionAt: Date?
    var attentionPending = false

    // MARK: Voice

    var preparedLines: [VoiceKind: VoiceLine] = [:]
    var requestedKinds: Set<VoiceKind> = []
    var lastSpokenText: String?
    /// Where the welcome-back rotation is (starts before the first line).
    /// A line to say as soon as Luna delivers it, or with a built-in fallback at the deadline.
    var awaitedLine: AwaitedLine?

    // MARK: World

    var lastSeenStage: ForestStage?
    /// Growth points in the latest `/v1/world` snapshot, for next-piece nudges.
    var lastSnapshotPoints: Double?
    /// Today's focused minutes at the last world update (today's house milestones).
    var lastTodayMinutes: Int?
    /// Today's house (assets/src/house_kit.py): the focused minutes that finish each stage, and how Moku says so.
    static let houseMilestones: [(minutes: Int, label: String)] = [
        (40, "laid the floor of today’s house"), (80, "raised the frame of today’s house"), (140, "put up the walls of today’s house"),
        (180, "finished the roof of today’s house"), (240, "finished today’s house"),
    ]
    /// A new stage's cue for the menu bar, held back while a meeting hides everything.
    var pendingStageCue: ForestStage?
    /// Moku's own celebration of a new stage waits for the next return or break.
    var pendingMilestone: ForestStage?
    /// A finished piece of work, celebrated at the next calm moment.
    var pendingCompletion: Completion?
    /// The label of the completion being celebrated, until its line is said: it goes to Luna in the request.
    var celebratedLabel: String?
    var recentCompletions: [String: Date] = [:]

    var lastNow: Date?
    var effects: [EngineEffect] = []

    // MARK: API

    public mutating func handle(_ input: EngineInput, now requested: Date) -> [EngineEffect] {
        let now = advance(to: requested)
        switch input {
        case let .verdict(verdict, context, window): receive(verdict, context: context, window: window, now: now)
        case let .focusChanged(app, window): focusChanged(app: app, window: window, now: now)
        case let .attention(point): attention(at: point, now: now)
        case let .meeting(context): meetingChanged(context, now: now)
        case .pat: pat(now: now)
        case let .correct(isWork): correct(isWork: isWork, now: now)
        case .click: if !inMeeting { effects.append(.openWorld) }
        case let .voiceReady(kind, line): voiceReady(kind, line, now: now)
        case let .config(newConfig): config = newConfig
        case let .world(snapshot): worldChanged(snapshot, now: now)
        case .startBreak: startBreak(now: now)
        case .endBreak: if teaBreak != nil { becomeWorking(now: now, thread: nil, sampleId: nil, cause: .backToWork) }
        }
        syncWorkState(now: now)
        return takeEffects()
    }

    public mutating func tick(now requested: Date) -> [EngineEffect] {
        let now = advance(to: requested)
        payFocusGrowth()
        if let ended = meetingEndedAt, now.timeIntervalSince(ended) >= Self.meetingHoldSec { leaveMeeting(now: now) }
        guard !inMeeting else { return takeEffects() }
        if let stage = pendingStageCue {
            pendingStageCue = nil
            effects.append(.celebrateStage(stage))
        }
        flushAttention(now: now)
        if let settleAt, now >= settleAt { settle(now: now) }
        if let awaitedLine, now >= awaitedLine.deadline { sayAwaitedLine(now: now) }
        if teaBreak != nil {
            tickBreak(now: now)
        } else if away != nil {
            tickAway(now: now)
        } else {
            switch activity {
            case .focused: tickFocus(now: now)
            case .drifting: tickDrift(now: now)
            case .unknown: break
            }
            celebrateCompletionIfCalm(now: now)
        }
        syncWorkState(now: now)
        return takeEffects()
    }

    /// A read-only view of the engine for logs, the simulator and tests.
    public var status: Status {
        let phase: Status.Phase =
            if inMeeting { .meeting } else if teaBreak != nil { .onBreak } else if away != nil { .away } else {
                switch activity {
                case .unknown: .settling
                case .focused: .focused
                case .drifting: .drifting
                }
            }
        return Status(phase: phase, mood: mood, atHome: atHome, focusStreakSec: focusStreakSec,
                      driftSec: drift?.clockSec, escalation: drift?.lastStep?.id.rawValue, workState: workState)
    }

    public struct Status: Sendable, Equatable {
        public enum Phase: String, Sendable { case settling, focused, drifting, away, onBreak, meeting }
        public var phase: Phase
        public var mood: Mood
        public var atHome: Bool
        public var focusStreakSec: Double
        public var driftSec: Double?
        public var escalation: String?
        public var workState: WorkState
    }

    // MARK: Clocks

    mutating func advance(to requested: Date) -> Date {
        guard let last = lastNow else {
            lastNow = requested
            return requested
        }
        guard requested > last else { return last }
        lastNow = requested
        guard !inMeeting else { return requested }
        let gap = requested.timeIntervalSince(last)
        if teaBreak != nil {
            teaBreak?.elapsedSec += gap
            return requested
        }
        // No tick for as long as a long away: the Mac slept (Moku ticks every second while it's awake).
        // Nobody was here, so that time was away, and this tick plays the long away (tickAway).
        if away == nil && gap >= config.longAwaySec { becomeAway(idleBeforeSec: 0) }
        if away != nil {
            away?.elapsedSec += gap
            return requested
        }
        switch activity {
        case .focused: addFocus(credited(from: last, to: requested, evidenceAt: workingEvidenceAt))
        case .drifting:
            let seconds = credited(from: last, to: requested, evidenceAt: driftingEvidenceAt)
            drift?.clockSec += seconds
        case .unknown: break
        }
        return requested
    }

    /// The part of [start, end] covered by fresh evidence.
    func credited(from start: Date, to end: Date, evidenceAt: Date?) -> Double {
        guard let evidenceAt else { return 0 }
        let from = max(start, evidenceAt)
        let to = min(end, evidenceAt.addingTimeInterval(config.evidenceWindowSec))
        return max(0, to.timeIntervalSince(from))
    }

    mutating func addFocus(_ seconds: Double) {
        guard seconds > 0 else { return }
        focusStreakSec += seconds
        focusSinceReturnSec += seconds
        focusSinceSmileSec += seconds
        focusSinceDrinkSec += seconds
        workSinceBreakSec += seconds
        growthCarrySec += seconds
    }

    /// Continuity breaks on a long drift or a long away: no pride, no smile schedule, no return bonus carried.
    mutating func resetContinuity() {
        focusStreakSec = 0
        focusSinceReturnSec = 0
        focusSinceSmileSec = 0
        focusSinceDrinkSec = 0
        isProud = false
    }

    mutating func takeEffects() -> [EngineEffect] {
        defer { effects = [] }
        noteSpeech(effects)
        return effects
    }

    // MARK: Inputs

    mutating func receive(_ verdict: Verdict, context: WorkContext?, window: WindowInfo? = nil, now: Date) {
        let place = context ?? focus
        if let place, verdict.state == .working || verdict.state == .drifting {
            remember(verdict.state, thread: verdict.thread, at: place)
        }
        guard !inMeeting else { return }
        if let completion = verdict.completion { completed(completion, now: now) }
        // A verdict about a place the user has already left only teaches memory.
        if let context, let focus, !context.isSamePlace(as: focus) { return }
        lastSampleId = verdict.sampleId
        if verdict.state == .working, let goal = verdict.goal { currentGoal = goal }
        if teaBreak != nil {
            // On a break nothing is drift. Only work, with someone back at the desk, ends it.
            if verdict.state == .working && isBackAtDesk(now: now) {
                becomeWorking(now: now, thread: verdict.thread, sampleId: verdict.sampleId, cause: .verdict)
                noteWork(now: now, place: context, window: window, thread: verdict.thread, goal: verdict.goal)
            }
            return
        }
        if !(verdict.state == .unknown && verdict.source == .shortcut) { neutralSince = nil }
        switch verdict.state {
        case .working:
            becomeWorking(now: now, thread: verdict.thread, sampleId: verdict.sampleId, cause: .verdict)
            // After the return (or the wake) is played: what it names is the work before this.
            noteWork(now: now, place: context, window: window, thread: verdict.thread, goal: verdict.goal)
        case .drifting: becomeDrifting(now: now, sampleId: verdict.sampleId)
        case .away: becomeAway(idleBeforeSec: config.awayAfterIdleSec)
        // The sense stream is the authority on meetings; the verdict adds nothing.
        case .meeting: break
        case .unknown: if verdict.source == .shortcut { holdThroughANeutralApp(now: now) }
        }
    }

    /// Finder, Preview and the system screens are neither work nor drift: the brain's state before stands (its timeline carries
    /// it, so Your day counts the time). The engine's evidence for that state would go stale after a minute without a fresh
    /// verdict, and the house would stop growing under a PDF the day still calls focus; so while a neutral verdict keeps
    /// coming, focus goes on being credited, up to `neutralHoldSec`. A failed judgment (source `fallback`) is a different
    /// `unknown` and still freezes everything. A drift isn't held: it rests after a minute as before.
    mutating func holdThroughANeutralApp(now: Date) {
        guard activity == .focused, away == nil, teaBreak == nil else { return }
        let since = neutralSince ?? now
        neutralSince = since
        if now.timeIntervalSince(since) <= tuning.neutralHoldSec { workingEvidenceAt = now }
    }

    mutating func focusChanged(app: AppInfo, window: WindowInfo?, now: Date) {
        let place = WorkContext(app: app, window: window)
        if place.host != nil { browsers.insert(place.bundleId) }
        let previous = focus
        focus = place
        focusApp = app
        focusWindow = window
        if place != previous { focusSince = now }
        guard !inMeeting else { return }
        // A browser switch can arrive before its URL, with the URL following as a second focus change for
        // the same window. Wait for it instead of judging the app as a whole.
        let waitingForURL = place.host == nil && browsers.contains(place.bundleId)
        if !waitingForURL { sniffIfNew(place, after: previous, now: now) }
        let alreadyFocused = activity == .focused && away == nil && teaBreak == nil
        if !alreadyFocused, !waitingForURL, let judgment = judgments[place], judgment.state == .working {
            // Fast return: back somewhere last judged working. Quick to welcome, slow to judge:
            // a switch to a place last judged drifting waits for a fresh verdict.
            becomeWorking(now: now, thread: judgment.thread, sampleId: nil, cause: .fastReturn)
        } else if alreadyFocused, place.host == nil, place == lastWork?.place, let lastWork {
            // Another file in the editor while working: the work moved there before a verdict says so. (Not another page on
            // a site, nor a place remembered as work: youtube.com is a lecture one minute and a game the next.)
            noteWork(now: now, place: place, window: window, thread: lastWork.thread, goal: lastWork.goal)
        } else if activity == .drifting {
            let distraction = currentDistraction
            drift?.distraction = distraction
        }
    }

    /// A window new to Moku comes to the front while you work: it sniffs it (next-wave.md §2). Not one that was in front
    /// in the last `sniffNewAfterSec` (going back and forth between two windows isn't news), at most one sniff a
    /// `sniffGapSec`, and only while Moku is just watching your work (not in a drift, a break, a line or away).
    mutating func sniffIfNew(_ place: WorkContext, after previous: WorkContext?, now: Date) {
        let seen = placesSeenAt[place]
        placesSeenAt[place] = now
        if let previous { placesSeenAt[previous] = now }
        if placesSeenAt.count > tuning.contextMemoryLimit { placesSeenAt = placesSeenAt.filter { now.timeIntervalSince($0.value) < tuning.sniffNewAfterSec } }
        guard place != previous, activity == .focused, away == nil, teaBreak == nil, !lookingAtUser, settleAt == nil else { return }
        if let seen, now.timeIntervalSince(seen) < tuning.sniffNewAfterSec { return }
        if let lastSniffAt, now.timeIntervalSince(lastSniffAt) < tuning.sniffGapSec { return }
        lastSniffAt = now
        perform(.sniff)
    }

    mutating func pat(now: Date) {
        guard !inMeeting else { return }
        perform(.patReaction)
        effects.append(.feedback(Feedback(ts: now, kind: .pat, sampleId: lastSampleId, threadId: currentThread?.id)))
        effects.append(.event(CompanionEvent(ts: now, type: .patted, threadId: currentThread?.id)))
        if let focus { remember(.working, thread: currentThread, at: focus) }
        // A pat during a tea break is just a pat: the break goes on.
        guard teaBreak == nil else { return }
        becomeWorking(now: now, thread: nil, sampleId: lastSampleId, cause: .pat)
        noteWork(now: now, place: nil, window: nil, thread: nil, goal: nil)  // "this is fine": it's work
    }

    /// The companion's right-click (Charles, 2026-10-14). "This is work" in a drift: the brain relabels it work from where
    /// it began and learns the screen, and Moku settles as for a pat (no return, no bonus). "This isn't work" while
    /// working: relabeled from when that window came to the front, learned, a nod to say it's heard; the drift that
    /// follows counts, without a sad move (the person said so).
    mutating func correct(isWork: Bool, now: Date) {
        guard !inMeeting, teaBreak == nil else { return }
        if isWork {
            guard activity == .drifting, let drift else { return }
            effects.append(.feedback(Feedback(ts: now, kind: .markedWork, sampleId: lastSampleId, threadId: currentThread?.id,
                                              since: drift.startedAt)))
            if let focus { remember(.working, thread: currentThread, at: focus) }
            becomeWorking(now: now, thread: nil, sampleId: lastSampleId, cause: .pat)
            noteWork(now: now, place: nil, window: nil, thread: nil, goal: nil)
        } else {
            guard activity == .focused else { return }
            effects.append(.feedback(Feedback(ts: now, kind: .markedNotWork, sampleId: lastSampleId, since: focusSince ?? now)))
            if let focus { remember(.drifting, thread: nil, at: focus) }
            lastSadMoveAt = now
            perform(.nod)
        }
    }

    /// A new stage: the menu bar cue and the `milestone` event now (the cue waits out a meeting), Moku's own
    /// celebration at the next return or break. The first snapshot is the baseline: launching isn't a milestone.
    mutating func worldChanged(_ snapshot: WorldSnapshot, now: Date) {
        lastSnapshotPoints = snapshot.growthPoints
        // Today's house: each stage finished is celebrated at the next calm moment, like work finished on screen.
        // The first snapshot is the baseline, and a new day (fewer minutes than before) starts again.
        let minutes = snapshot.todayFocusMinutes
        if let before = lastTodayMinutes, minutes > before {
            for (mark, label) in Self.houseMilestones where before < mark && minutes >= mark { completed(Completion(kind: .other, label: label), now: now) }
        }
        lastTodayMinutes = minutes
        let stage = snapshot.stage
        guard let lastSeenStage else {
            self.lastSeenStage = stage
            return
        }
        guard stage > lastSeenStage else { return }
        self.lastSeenStage = stage
        emit(.milestone, now: now, threadId: currentThread?.id, value: Double(stage.rawValue))
        if inMeeting {
            pendingStageCue = stage
        } else {
            effects.append(.celebrateStage(stage))
        }
        pendingMilestone = max(pendingMilestone ?? stage, stage)
    }

    /// Something meaningful finished on screen. Logged now; celebrated at the next calm moment.
    mutating func completed(_ completion: Completion, now: Date) {
        let key = "\(completion.kind.rawValue)|\(completion.label)"
        if let last = recentCompletions[key], now.timeIntervalSince(last) < tuning.completionRepeatSec { return }
        recentCompletions = recentCompletions.filter { now.timeIntervalSince($0.value) < tuning.completionRepeatSec }
        recentCompletions[key] = now
        emit(.completed, now: now, threadId: currentThread?.id)
        pendingCompletion = completion
    }

    mutating func remember(_ state: Verdict.State, thread: ThreadRef?, at place: WorkContext) {
        if place.host != nil { browsers.insert(place.bundleId) }
        if judgments[place] == nil { judgmentOrder.append(place) }
        judgments[place] = Judgment(state: state, thread: thread)
        while judgmentOrder.count > tuning.contextMemoryLimit {
            judgments[judgmentOrder.removeFirst()] = nil
        }
    }

    var currentDistraction: String? { focus?.host ?? focusAppName }

    func isFresh(_ evidenceAt: Date?, now: Date) -> Bool {
        guard let evidenceAt else { return false }
        return now.timeIntervalSince(evidenceAt) <= config.evidenceWindowSec
    }

    /// The lantern, derived: a break or an away first, then what the user is doing on fresh evidence.
    /// Without fresh evidence (just launched, the brain unsure or down) it's idle: calm, no signal.
    mutating func syncWorkState(now: Date) {
        guard !inMeeting else { return }
        let state: WorkState
        if teaBreak != nil {
            state = .onBreak
        } else if away != nil {
            state = .away
        } else {
            switch activity {
            case .unknown: state = .idle
            case .focused: state = isFresh(workingEvidenceAt, now: now) ? .focused : .idle
            case .drifting: state = isFresh(driftingEvidenceAt, now: now) ? (drift?.tier ?? .grace) : .idle
            }
        }
        guard state != workState else { return }
        workState = state
        effects.append(.character(.setWorkState(state)))
    }
}

struct Judgment: Sendable {
    var state: Verdict.State
    var thread: ThreadRef?
}

extension WorkContext {
    /// Same app, and the same site unless one side doesn't know the site.
    func isSamePlace(as other: WorkContext) -> Bool {
        guard bundleId == other.bundleId else { return false }
        guard let host, let otherHost = other.host else { return true }
        return host == otherHost
    }
}
