import Foundation
import MokuKit
import os

/// Where the runtime gets the time and how it waits. Injected so tests can drive time by hand.
public protocol RuntimeClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async throws
}

public struct SystemClock: RuntimeClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

/// Wires the senses, the brain, the character and the world around one `BehaviorEngine`.
/// The app shell constructs it and calls `start()`; everything else happens here.
///
/// - Samples go to `/v1/judge` with at most one request in flight. While one is out, only the newest
///   sample waits; older ones are dropped. Verdicts go to the engine tagged with where the sample was taken.
/// - Other sense events and the stage's pat and click callbacks go straight to the engine.
/// - Character commands run in order; a `move` is awaited before the commands queued after it. A new move
///   during a walk redirects it at once (after releasing what was queued behind the old walk).
/// - Voice requests go to `/v1/voice` and come back as `.voiceReady`. A failed request just means the
///   engine uses a built-in line when the time comes.
/// - Events and feedback are fire-and-forget, with a small retry queue for when the brain is down.
/// - `/v1/world` (and `/v1/config`) are refreshed every 60 s, and the world again after growth events.
/// - The engine ticks every second. If the brain is down there are no verdicts, so Moku stays calm.
/// - Manual control (`setManualControl(true)`) stops all of that: Charles drives Moku by hand and can
///   play scenes (`manualScenes()`). Nothing is judged, logged or sent until it's turned off.
@MainActor
public final class CompanionRuntime {
    public nonisolated static let tickIntervalSec: Double = 1
    public nonisolated static let refreshIntervalSec: Double = 60
    public nonisolated static let retryIntervalSec: Double = 15
    public nonisolated static let outboxLimit = 500

    private let senses: AsyncStream<SenseEvent>
    let brain: any BrainAPI
    let stage: any CharacterStage
    let presenter: any WorldPresenter
    let worldModel: WorldModel
    let clock: any RuntimeClock
    let tuning: EngineTuning
    private let log = Logger(subsystem: "ai.lightslips.moku", category: "mind")

    private(set) var engine: BehaviorEngine
    lazy var driver = StageDriver(stage: stage) { [weak self] work in
        guard let self else { return }
        self.track(work)
    }
    private var loops: [Task<Void, Never>] = []
    private var inFlight: [Int: Task<Void, Never>] = [:]
    private var nextTaskId = 0
    /// Judge and voice requests: cancelled when manual control starts.
    private var brainRequests: Set<Int> = []

    /// Manual control: Charles drives Moku by hand; nothing is watched, judged, logged or sent.
    public private(set) var isManualControl = false
    /// Bumped on every switch of manual control, so a brain reply started before it is ignored.
    private var epoch = 0
    /// Only the most recently started scene may drive the stage; bumped to stop a playing scene.
    var sceneTurn = 0
    /// Settings › Test the drift: the engine held at the last step shown, and what the stage shows.
    var rehearsal: DriftRehearsal?

    private var judging = false
    private var waitingSample: ActivitySample?
    /// Where the senses last said the user is. Without Accessibility, tab and window switches inside an
    /// app only show up in the next sample, so a sample from somewhere new counts as a focus change.
    private var knownFocus: WorkContext?

    private var outbox: [Outgoing] = []
    private var nextOutgoingId = 0
    private var nextRetryAt: Date?
    private var retrying = false

    /// The hand on the break button being handled, if any (`toggleBreak`).
    private var breakControl: BreakControl?
    /// The day of the last comeback, so `first_today` is true once a day.
    private var lastComebackDay: String?
    /// The world as last seen, so a new house piece or the first ten focused minutes are noticed once.
    private var lastWorld: (day: String, unitsToday: Int, focusMinutesAllTime: Int)?

    private var lastRefreshAt: Date?
    /// Whether a world has come back from the brain yet: until then (the brain still starting) it's asked every 2 s.
    private(set) var worldLoaded = false
    private var refreshingWorld = false
    private var worldRefreshWanted = false

    public init(senses: AsyncStream<SenseEvent>, brain: any BrainAPI, stage: any CharacterStage,
                world: any WorldPresenter, worldModel: WorldModel, clock: any RuntimeClock = SystemClock(),
                tuning: EngineTuning = .standard, randomSeed: UInt64? = nil) {
        self.senses = senses
        self.brain = brain
        self.stage = stage
        self.presenter = world
        self.worldModel = worldModel
        self.clock = clock
        self.tuning = tuning
        self.engine = BehaviorEngine(config: .standard, tuning: tuning,
                                     random: randomSeed.map(MokuRandom.init(seed:)) ?? MokuRandom())
    }

    /// Show Moku and start listening. Moku appears right away with the standard timings; the served
    /// config replaces them as soon as the brain answers.
    /// Set by the app: a break started (stop watching) or ended (start again).
    public var onBreakChanged: (@MainActor (Bool) -> Void)?
    /// Set by the app: records usage events (comebacks, breaks, corrections, house pieces, the first ten focused
    /// minutes). Code words and numbers only, never what the person was doing.
    public var usage: UsageTracker?
    /// Set by the app: adds to the day's counts (clicks, judgments and their timings, minutes at the Mac, water reminders).
    public var count: UsageCounter?
    /// What usage reporting remembers between effects (RuntimeUsage.swift).
    var usageState = RuntimeUsageState()
    /// Set by the app: when Moku was first opened on this Mac, for `first_focus`.
    public var installedAt: Date?
    /// Set by the app: "Today counted", the day's card (DayCounted.swift). Nil: no card.
    public var dayCounted: DayCountedSchedule?
    /// Set by the app: the version whose "What's new" is still to be said (WhatsNew.swift), once Moku has updated; nil when
    /// there's nothing new. It's said once, at the first calm moment, then cleared.
    public var whatsNew: String?
    /// Set by the app: "What's new" was said for this version, so it's never said again.
    public var onWhatsNewTold: (@MainActor (String) -> Void)?
    /// Set by the app: opens a link in the person's browser (a "What's new" bubble's changelog).
    public var openLink: (@MainActor (URL) -> Void)?
    /// When Moku started watching with news to tell: the launch, or the welcome's end.
    var watchingSince: Date?

    /// Where a break was started or ended by hand, for the `break` event.
    public enum BreakControl: String, Sendable {
        /// The popover's button.
        case popover
        /// Moku's right-click menu, or the ✕ on its break timer.
        case moku
        /// A moku://break link (Shortcuts, Raycast).
        case link
    }

    public func start() {
        guard loops.isEmpty else { return }
        stage.onPat = { [weak self] in self?.patted() }
        stage.onClick = { [weak self] in self?.clicked() }
        stage.onTakeBreak = { [weak self] in self?.toggleBreak(from: .moku) }
        stage.onWhatsNew = { [weak self] version, opened in self?.whatsNewAnswered(version, opened: opened) }
        stage.currentTask = { [weak self] in self?.taskNow() }
        stage.onCorrectNow = { [weak self] isWork in self?.correctNow(isWork: isWork) }
        watchingSince = clock.now()
        presenter.onTakeBreak = { [weak self] in self?.toggleBreak(from: .popover) }
        presenter.onOpen = { [weak self] in self?.refreshWorld() }
        presenter.todayProvider = { [weak self] date in await self?.today(date: date) }
        presenter.daysProvider = { [weak self] from, to in await self?.days(from: from, to: to) }
        presenter.onCorrection = { [weak self] segmentIds, isWork in self?.correct(segmentIds, isWork: isWork) }
        stage.show()
        refresh()
        loops.append(Task { await self.consumeSenses() })
        loops.append(Task { await self.tickLoop() })
    }

    public func stop() {
        loops.forEach { $0.cancel() }
        loops = []
        inFlight.values.forEach { $0.cancel() }
    }

    public var status: BehaviorEngine.Status { engine.status }

    // MARK: Manual control

    /// Home, seated, content, looking around, the lantern calm: how Moku looks when nothing is going on.
    /// (Sitting down is a no-op for a seated Moku; it stands down one a test or a real drift left standing.)
    static let calmCommands: [CharacterCommand] = [
        .dismissSpeech, .setHidden(false), .perform(.sitDown), .setWorkState(.idle), .setMood(.content), .setAttention(.wander), .move(.home),
    ]

    /// Turn manual control on or off (the world dropdown's switch, or the panel closing).
    ///
    /// **On:** in-flight judge and voice requests are cancelled and their replies ignored; queued
    /// character commands are dropped and speech dismissed; sense events are ignored and the engine stops
    /// ticking, so none of this time counts as focus, drift or away. No events or feedback are sent;
    /// ones that failed earlier wait in the retry queue until manual control ends. A click still opens
    /// the world; a pat only gets the stage's own reaction.
    ///
    /// **Off:** any scene still playing stops, Moku walks home calm (content, looking around), and
    /// behavior restarts as if Moku had just appeared: a fresh engine with the current config, so no drift,
    /// escalation or welcome-back carries over.
    public func setManualControl(_ on: Bool) {
        guard on != isManualControl else { return }
        isManualControl = on
        epoch += 1
        sceneTurn += 1
        rehearsal = nil
        presenter.setManualControl(on)
        driver.reset()
        judging = false
        waitingSample = nil
        if on {
            brainRequests.forEach { inFlight[$0]?.cancel() }
            driver.run(.dismissSpeech)
            // A break in progress is over: the fresh engine after this starts without one, so the timer and the
            // popover's "End break" must go now (the break usage event stays unsent: no word says "the welcome").
            execute(engine.endBreakForManualControl(now: clock.now()), reportingUsage: false)
        } else {
            let named = (threads: engine.labeledThreads, lastWorked: engine.threadLastWorkedAt)
            let calm = engine.forceCalm
            engine = BehaviorEngine(config: engine.config, tuning: tuning, random: engine.random)
            // Only what's been named carries over, so a test doesn't bring back the caption for the work at hand.
            engine.labeledThreads = named.threads; engine.threadLastWorkedAt = named.lastWorked
            engine.forceCalm = calm
            knownFocus = nil
            watchingSince = clock.now()  // the welcome (or a test) is over: watching starts again
            Self.calmCommands.forEach(driver.run)
            refresh()
            if !outbox.isEmpty { nextRetryAt = clock.now() }
        }
    }

    /// A pat on the stage. The stage plays the pat reaction where it's touched, at once; the engine says what the pat
    /// means ("this is fine"), and its own ask for the reaction isn't run again (a second one, after a walk when it was
    /// mid-move). Scripted pats (scenes) aren't touches: there the engine's ask is the only one.
    private func patted() {
        guard !isManualControl else { return }
        execute(engine.handle(.pat, now: clock.now()).filter { $0 != .character(.perform(.patReaction)) })
    }

    /// "Taking a break" starts a tea break; the same button ("Back to work") ends it.
    public func toggleBreak(from control: BreakControl) {
        guard !isManualControl else { return }
        breakControl = control
        defer { breakControl = nil }
        apply(engine.teaBreak == nil ? .startBreak : .endBreak)
    }

    /// A day for the Today window (nil: today). Nil when the brain can't answer.
    func today(date: Date? = nil) async -> TodaySummary? {
        do {
            return try await brain.today(date: date)
        } catch {
            log.debug("today failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Each day's totals for the Today window's strip. Nil when the brain can't answer.
    func days(from: Date, to: Date) async -> DaysResponse? {
        do {
            return try await brain.days(from: from, to: to)
        } catch {
            log.debug("days failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The task you're on and its minutes today, for the label a hover shows. Never a placeholder name, never in a drift.
    func taskNow() -> TaskNow? {
        guard engine.activity == .focused, let thread = engine.currentThread, !thread.provisional else { return nil }
        let minutes = worldModel.snapshot.threads.first { $0.id == thread.id }?.focusMinutesToday ?? 0
        return TaskNow(title: thread.title, minutesToday: minutes)
    }

    /// "This is work" / "This isn't work" from the companion's right-click.
    public func correctNow(isWork: Bool) {
        guard !isManualControl else { return }
        apply(.correct(isWork: isWork))
        usage?("correction", ["kind": .word(isWork ? "marked_work" : "marked_not_work")])
    }

    /// "This was work" / "This wasn't work" on a Today row. The world is refreshed once the brain has it.
    func correct(_ segmentIds: [String], isWork: Bool) {
        guard !isManualControl, !segmentIds.isEmpty else { return }
        deliver(.feedback(Feedback(ts: clock.now(), kind: isWork ? .markedWork : .markedNotWork, segmentIds: segmentIds)))
        usage?("correction", ["kind": .word(isWork ? "marked_work" : "marked_not_work")])
    }

    private func clicked() {
        count?(.companionClick)
        if isManualControl {
            presenter.openWorld()
        } else {
            apply(.click)
        }
    }

    // MARK: Loops

    private func consumeSenses() async {
        for await event in senses {
            handle(event)
        }
    }

    private func tickLoop() async {
        while !Task.isCancelled {
            do {
                try await clock.sleep(seconds: Self.tickIntervalSec)
            } catch {
                return
            }
            tick()
        }
    }

    func handle(_ event: SenseEvent) {
        guard !isManualControl else { return }
        switch event {
        case let .sample(sample):
            if WorkContext(app: sample.app, window: sample.window) != knownFocus {
                focusChanged(sample.app, sample.window)
            }
            judge(sample)
        case let .focusChanged(app, window): focusChanged(app, window)
        case let .attention(point): apply(.attention(point))
        case let .meeting(context): usageState.meeting = context; apply(.meeting(context))
        case .permissions: break  // onboarding is the app shell's job
        }
    }

    func tick() {
        guard !isManualControl else { return }
        let now = clock.now()
        execute(engine.tick(now: now))
        tickUsage(now: now)
        checkDayCounted(now: now)
        checkWhatsNew(now: now)
        if lastRefreshAt.map({ now.timeIntervalSince($0) >= (worldLoaded ? Self.refreshIntervalSec : 2) }) ?? true {
            refresh()
        }
        retryOutboxIfDue(now: now)
    }

    private func focusChanged(_ app: AppInfo, _ window: WindowInfo?) {
        knownFocus = WorkContext(app: app, window: window)
        apply(.focusChanged(app, window))
    }

    func apply(_ input: EngineInput) {
        guard !isManualControl else { return }
        execute(engine.handle(input, now: clock.now()))
    }

    /// A config the app just saved from Settings: used at once, even under manual control (drift tests
    /// then follow the new timings).
    public func useConfig(_ config: CompanionConfig) {
        let effects = engine.handle(.config(config), now: clock.now())
        if !isManualControl { execute(effects) }
    }

    /// "Delete my data": "Where was I?" forgets the window and task it was keeping for your return, and the world is asked
    /// for again, so the menu bar's house and the popover show the fresh start at once.
    public func forgetWork() {
        engine.forgetWork()
        refreshWorld()
    }

    /// The relay's forceCalm switch (RemoteFlags): Moku never reacts to a drift. Applied at once, even under manual
    /// control (which then carries it over), like a config.
    public func setForceCalm(_ on: Bool) {
        let effects = engine.setForceCalm(on, now: clock.now())
        if !isManualControl { execute(effects) }
    }

    // MARK: Judging

    private func judge(_ sample: ActivitySample) {
        guard !judging else {
            waitingSample = sample  // only the newest sample is worth judging next
            return
        }
        judging = true
        let epoch = self.epoch
        let asked = ContinuousClock.now
        track(brainRequest: true) {
            let verdict: Verdict?
            defer { self.countJudgment(verdict, ms: asked.millisecondsAgo) }
            do {
                verdict = try await self.brain.judge(sample)
            } catch {
                verdict = nil
                self.log.debug("judge failed: \(String(describing: error), privacy: .public)")
            }
            // Manual control started (and maybe ended) meanwhile: that reset the judging state.
            guard self.epoch == epoch else { return }
            if let verdict {
                self.apply(.verdict(verdict, context: WorkContext(app: sample.app, window: sample.window), window: sample.window))
            }
            self.judging = false
            if let next = self.waitingSample {
                self.waitingSample = nil
                self.judge(next)
            }
        }
    }

    // MARK: Effects

    private func execute(_ effects: [EngineEffect], reportingUsage: Bool = true) {
        for effect in effects {
            switch effect {
            case let .character(command): driver.run(command)
            case let .requestVoice(request): fetchVoice(request)
            case let .event(event): deliver(.event(event))
            case let .feedback(feedback): deliver(.feedback(feedback))
            case .openWorld: presenter.openWorld()
            case let .celebrateStage(stage): presenter.celebrate(stage)
            case let .setOnBreak(on): presenter.setOnBreak(on); onBreakChanged?(on)
            }
        }
        guard reportingUsage else { return }
        reportUsage(effects)
        reportEngineUsage(effects)
    }

    private func fetchVoice(_ request: VoiceRequest) {
        let epoch = self.epoch
        let asked = ContinuousClock.now
        track(brainRequest: true) {
            do {
                let line = try await self.brain.voice(request)
                if line.source == "luna" { self.count?(.lunaAnswer(ms: asked.millisecondsAgo)) }
                guard self.epoch == epoch else { return }
                self.apply(.voiceReady(request.kind, line))
            } catch {
                self.log.debug("voice \(request.kind.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Events and feedback

    private enum Payload: Sendable {
        case event(CompanionEvent)
        case feedback(Feedback)

        /// Growth changes the forest; a correction can change it too (a segment re-counted as work).
        var changesWorld: Bool {
            switch self {
            case let .event(event): event.type == .focusGrowth || event.type == .returnGrowth
            case let .feedback(feedback): feedback.kind == .markedWork || feedback.kind == .markedNotWork
            }
        }
    }

    private struct Outgoing: Sendable {
        var id: Int
        var payload: Payload
    }

    private func deliver(_ payload: Payload) {
        let item = Outgoing(id: nextOutgoingId, payload: payload)
        nextOutgoingId += 1
        track {
            do {
                try await self.send(payload)
                self.delivered(payload)
            } catch {
                self.queueForRetry(item)
            }
        }
    }

    private func send(_ payload: Payload) async throws {
        switch payload {
        case let .event(event): try await brain.sendEvent(event)
        case let .feedback(feedback): try await brain.sendFeedback(feedback)
        }
    }

    private func delivered(_ payload: Payload) {
        if payload.changesWorld { refreshWorld() }
    }

    private func queueForRetry(_ item: Outgoing) {
        outbox.append(item)
        if outbox.count > Self.outboxLimit { outbox.removeFirst(outbox.count - Self.outboxLimit) }
        if nextRetryAt == nil { nextRetryAt = clock.now().addingTimeInterval(Self.retryIntervalSec) }
    }

    /// Resend in order; stop at the first failure (the brain is still down) and try again later.
    private func retryOutboxIfDue(now: Date) {
        guard !retrying, !outbox.isEmpty, let due = nextRetryAt, now >= due else { return }
        retrying = true
        track {
            while let item = self.outbox.first {
                do {
                    try await self.send(item.payload)
                } catch {
                    break
                }
                self.outbox.removeAll { $0.id == item.id }
                self.delivered(item.payload)
            }
            self.retrying = false
            self.nextRetryAt = self.outbox.isEmpty ? nil : self.clock.now().addingTimeInterval(Self.retryIntervalSec)
        }
    }

    // MARK: World and config

    private func refresh() {
        lastRefreshAt = clock.now()
        refreshWorld()
        track {
            // The brain rereads its config file on every request, so tuned timings apply without a restart.
            if let config = try? await self.brain.config(), config != self.engine.config {
                self.apply(.config(config))
            }
        }
    }

    private func refreshWorld() {
        guard !refreshingWorld else {
            worldRefreshWanted = true
            return
        }
        refreshingWorld = true
        track {
            if let snapshot = try? await self.brain.world() {
                self.worldModel.snapshot = snapshot
                self.count?(.today(focusedMinutes: snapshot.todayFocusMinutes, returns: snapshot.todayReturns,
                                   longestMinutes: snapshot.longestFocusMinutesToday))
                self.noticeGrowth(snapshot)
                self.apply(.world(snapshot))
                self.worldLoaded = true
            }
            self.refreshingWorld = false
            if self.worldRefreshWanted {
                self.worldRefreshWanted = false
                self.refreshWorld()
            }
        }
    }

    // MARK: What's new (WhatsNew.swift)

    /// Every tick: says "What's new" at the first calm moment where the bubble can be seen (the same test as the day's card:
    /// the companion on show on this desktop, with the popover and the card out of the way). Not in the welcome or a test
    /// (manual control stops the ticks), nor while Settings rehearses a drift. Asked for once a launch: it's told when the
    /// bubble is over, so one the stage never put up (hidden by a call starting that moment) is said at the next launch.
    func checkWhatsNew(now: Date) {
        guard let version = whatsNew, rehearsal == nil, presenter.canShowDayCounted,
              engine.isCalmForNews(now: now, watchingSince: watchingSince ?? now) else { return }
        whatsNew = nil
        usageState.whatsNewShownAt = now
        execute(engine.sayWhatsNew(version, now: now))
    }

    /// The bubble that went up is over: clicked (its changelog opens in the browser), or closed. Only now is it told and
    /// counted as shown, and how long it stayed up (counted from when it went up) goes with the answer.
    func whatsNewAnswered(_ version: String, opened: Bool) {
        usage?("whats_new", ["what": .word("shown")])
        var facts: [String: UsageValue] = ["what": .word(opened ? "opened" : "closed")]
        if let shownAt = usageState.whatsNewShownAt {
            facts["seconds"] = .int(min(max(0, Int(clock.now().timeIntervalSince(shownAt).rounded())), 86_400))
        }
        usageState.whatsNewShownAt = nil
        usage?("whats_new", facts)
        onWhatsNewTold?(version)
        if opened { openLink?(WhatsNew.link(version: version)) }
    }

    // MARK: Usage events

    /// What the engine just did, as usage events: a comeback (a drift that ended in a return; a break's end isn't one),
    /// a break starting, ending by itself or cancelled by hand, and a pat.
    private func reportUsage(_ effects: [EngineEffect]) {
        guard let usage else { return }
        let events = effects.compactMap { if case let .event(event) = $0 { event.type } else { nil } }
        for case let .event(event) in effects {
            switch event.type {
            case .returned where !events.contains(.breakEnded):
                let today = BrainClient.localDay(clock.now())
                usage("comeback", ["drift_seconds": .int(UsageEvents.driftBucket(seconds: event.value ?? 0)),
                                   "first_today": .bool(lastComebackDay != today)])
                lastComebackDay = today
            case .breakStarted:
                var props: [String: UsageValue] = ["what": .word("started")]
                if let breakControl { props["from"] = .word(breakControl.rawValue) }
                usage("break", props.merging(breakFacts(.breakStarted, value: nil)) { a, _ in a })
            case .breakEnded:
                // Ended by hand, or by itself: back at work (it ends as a return) or its time is up.
                let from = breakControl?.rawValue ?? (events.contains(.returned) ? "work" : "timer")
                usage("break", ["what": .word(breakControl == nil ? "ended" : "cancelled"), "from": .word(from)]
                    .merging(breakFacts(.breakEnded, value: event.value)) { a, _ in a })
            default: break
            }
        }
        for case let .feedback(feedback) in effects where feedback.kind == .pat {
            usage("correction", ["kind": .word("pat")])
        }
    }

    /// A new house piece today, and the first ten focused minutes ever, from one world to the next. The first world
    /// after launch is only the baseline: what was built before isn't news.
    private func noticeGrowth(_ world: WorldSnapshot) {
        let today = BrainClient.localDay(clock.now())
        defer { lastWorld = (today, world.unitsToday, world.focusMinutesAllTime) }
        guard let usage, let last = lastWorld else { return }
        // The house has 24 pieces: focus past it builds nothing new (that's in day_summary).
        let before = last.day == today ? last.unitsToday : 0, built = min(world.unitsToday, DayHouse.pieces)
        if built > before {
            for pieces in (before + 1)...built {
                usage("house_piece", ["pieces_today": .int(pieces)])
            }
        }
        let activation = Int(DayHouse.minutesPerPiece)
        if last.focusMinutesAllTime < activation, world.focusMinutesAllTime >= activation {
            let minutes = installedAt.map { max(0, Int(clock.now().timeIntervalSince($0) / 60)) }
            usage("first_focus", minutes.map { ["minutes_since_install": .int($0)] } ?? [:])
        }
    }

    // MARK: Tasks

    func track(brainRequest: Bool = false, _ work: @escaping @MainActor () async -> Void) {
        let id = nextTaskId
        nextTaskId += 1
        if brainRequest { brainRequests.insert(id) }
        inFlight[id] = Task {
            await work()
            self.inFlight[id] = nil
            self.brainRequests.remove(id)
        }
    }

    /// Wait until every request and walk this runtime started has finished (tests use this).
    func drain() async {
        while let task = inFlight.values.first {
            await task.value
        }
    }
}
