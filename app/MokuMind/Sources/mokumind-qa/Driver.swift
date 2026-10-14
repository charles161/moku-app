import CoreGraphics
import Foundation
import MokuKit
import MokuMind

struct DriftRun {
    var start: Double
    var screens: [String] = []
    var firstSad: Double?
    var ask: Double?
    var reached: String?
}

/// What happened in one session, measured against what the person was really doing.
struct SessionReport: Codable {
    var name: String
    var date: String
    var seconds: Double
    /// Seconds of each truth.
    var truthSeconds: [String: Double] = [:]
    /// Truth × what the engine was showing (settling, focused, drifting, away, onBreak, meeting), in seconds.
    var phaseSeconds: [String: [String: Double]] = [:]
    /// Truth × the brain's verdict, in samples.
    var verdicts: [String: [String: Int]] = [:]
    /// Every ladder step that fired: when (seconds into the session), which, and the truth then.
    var steps: [StepMark] = []
    var drifts: [DriftOutcome] = []
    var eventCounts: [String: Int] = [:]
    /// What the engine asked the character to do, by kind (how busy Moku is on screen).
    var commandCounts: [String: Int] = [:]
    var focusCreditedMinutes: Double = 0
    var lines: [String] = []
    var brainErrors = 0
    /// Back-and-forth between working and drifting verdicts on one stretch of work: the same page judged both ways in turn.
    var verdictFlipsAtWork = 0
    var jevCalls = 0
    var maxVerdictSeconds = 0.0
    var yourDay: YourDay?
    /// Later days the session ran into (past midnight), each as Your day shows it.
    var laterDays: [YourDay] = []
    /// Verdicts that said away while the person was at work or drifting, by screen and rule: what the brain's quick check saw.
    var awayReasons: [String: Int] = [:]
    var notes: [String] = []
}

struct StepMark: Codable {
    var t: Double
    var step: String
    var truth: String
    var screen: String
}

/// A stretch of real drift (adjacent drift beats together) and how Moku met it.
struct DriftOutcome: Codable {
    var start: Double
    var seconds: Double
    var screens: [String]
    /// Seconds until the first ladder step that shows (sad), and until the ask; nil: never.
    var firstSadAfter: Double?
    var askAfter: Double?
    var reached: String?
}

struct YourDay: Codable {
    var date = ""
    var focusedMinutes: Int
    var longestFocusMinutes: Int
    var returns: Int
    var unitsToday: Int
    var goals: [String]
    var goalMinutes = 0
    var builtMinutes = 0
    var wanderedMinutes = 0
    var categoryMinutes = 0
    var builtRows: Int
    var wanderedRows: Int
    var quickCheckMinutes: Int
    var segments: Int
    var note: String?
}

/// Plays a session through the real engine and a real brain over HTTP, on simulated time: one tick a second, a sample every
/// `sampleIntervalSec`, the brain's verdict a moment later, events and feedback sent back to the brain as the runtime would.
@MainActor
final class Driver {
    let brain: BrainClient
    let controlBase: URL
    let catalog: [String: QAScreen]
    var config: CompanionConfig
    /// Seconds a Jev verdict takes (the tape's median) and a rules verdict.
    /// Where to write one line per verdict (--trace): when, the screen, the truth, the state and the brain's reason.
    var trace: FileHandle?
    var jevLatency = 0.45
    var ruleLatency = 0.05
    /// How long a failed model call takes before the brain answers `unknown` (a dead network: the 7 s budget).
    var failLatency = 1.0

    init(brain: BrainClient, control: URL, catalog: [String: QAScreen], config: CompanionConfig) {
        self.brain = brain
        self.controlBase = control
        self.catalog = catalog
        self.config = config
    }

    static func start(of session: Session) -> Date {
        let day = session.date.split(separator: "-").compactMap { Int($0) }
        let time = session.start.split(separator: ":").compactMap { Int($0) }
        let parts = DateComponents(calendar: .current, year: day[0], month: day[1], day: day[2], hour: time[0], minute: time[1])
        return Calendar.current.date(from: parts)!
    }

    // MARK: State of one run

    private var engine = BehaviorEngine()
    private var log: [(t: Double, effect: EngineEffect)] = []
    private var pending: [(due: Double, verdict: Verdict, context: WorkContext, window: WindowInfo?, truth: Truth)] = []
    private var sensing = true
    private var report = SessionReport(name: "", date: "", seconds: 0)
    private var sampleCount = 0
    private var random = MokuRandom(seed: 99)

    /// The senses' view, as the sense layer keeps it.
    private var lastMeeting = MeetingContext.none
    private var lastInputAt = 0.0
    private var nextInputAt = 0.0
    private var judgingUntil = 0.0
    private var waiting: (ActivitySample, Truth, WorkContext, String)?
    private var lastEscalation: String?
    private var lastJudged: (screen: String, state: Verdict.State)?
    private var lastTextVersion = -1
    private var lastScreenId: String?

    private func chance() -> Double { Double.random(in: 0..<1, using: &random) }

    func play(_ session: Session) async throws -> SessionReport {
        let start = Self.start(of: session)
        simStart = start
        var cfg = config
        cfg.userName = session.userName
        engine = BehaviorEngine(config: cfg, tuning: .standard, random: MokuRandom(seed: 7))
        log = []
        pending = []
        sensing = true
        report = SessionReport(name: session.name, date: session.date, seconds: session.beats.reduce(0) { $0 + $1.seconds })
        sampleCount = 0
        lastMeeting = .none
        lastInputAt = 0
        nextInputAt = 0
        judgingUntil = 0
        waiting = nil
        lastEscalation = nil
        lastJudged = nil
        lastTextVersion = -1
        lastScreenId = nil
        _ = try? await control("mode?m=up")

        var beatStart = 0.0
        var nextSampleAt = 0.0
        var nextWorldAt = 0.0
        var lastTick = -1.0
        var driftRun: DriftRun?
        var driftRuns: [DriftOutcome] = []

        func closeDrift(at end: Double) {
            guard let run = driftRun else { return }
            driftRuns.append(DriftOutcome(start: run.start, seconds: end - run.start, screens: run.screens,
                                          firstSadAfter: run.firstSad.map { $0 - run.start }, askAfter: run.ask.map { $0 - run.start },
                                          reached: run.reached))
            driftRun = nil
        }

        for beat in session.beats {
            guard let first = catalog[beat.screen] else { report.notes.append("no screen \(beat.screen)"); continue }
            var cur = Place(first, override: beat.truth)

            // The lid closes: the engine isn't running at all for this long.
            if beat.asleep {
                report.truthSeconds[cur.truth.rawValue, default: 0] += beat.seconds
                closeDrift(at: beatStart)
                beatStart += beat.seconds
                nextSampleAt = beatStart
                nextWorldAt = max(nextWorldAt, beatStart)
                lastScreenId = nil
                continue
            }

            var inputsDone = false
            let beatEnd = beatStart + beat.seconds
            var t = beatStart
            while t < beatEnd {
                let now = simDate(t)
                // Somewhere new: a switch (or, in a storm, many of them).
                var switched = false
                if let storm = beat.storm {
                    let before = Int((t - beatStart) * storm.perMinute / 60), after = Int((t - beatStart + 1) * storm.perMinute / 60)
                    for _ in before..<max(before, after) {
                        let id = storm.among[Int(chance() * Double(storm.among.count)) % storm.among.count]
                        if let screen = catalog[id] { cur = Place(screen, override: nil); switched = true
                            lastInputAt = t
                            if sensing { await handle(.focusChanged(cur.app, cur.window), at: t, truth: cur.truth, screen: id) } }
                    }
                }
                if !inputsDone {
                    inputsDone = true
                    // Switching somewhere is input (Cmd-Tab, a click); leaving the desk is the last of it.
                    lastInputAt = t
                    nextInputAt = t + (beat.profile.inputEverySec.map { $0 * (0.5 + chance()) } ?? .infinity)
                    if lastScreenId != cur.screen.id || beat.storm != nil, sensing, !switched {
                        await handle(.focusChanged(cur.app, cur.window), at: t, truth: cur.truth, screen: cur.screen.id)
                    }
                    lastScreenId = cur.screen.id
                    lastTextVersion = -1
                    if cur.truth == .drift {
                        if driftRun == nil { driftRun = DriftRun(start: t) }
                        driftRun?.screens.append(cur.screen.id)
                    } else {
                        closeDrift(at: t)
                    }
                    for input in beat.inputs { await apply(input, at: t, truth: cur.truth, screen: cur.screen.id) }
                }
                if switched { lastTextVersion = -1 }
                if beat.storm != nil {
                    if cur.truth == .drift, driftRun == nil { driftRun = DriftRun(start: t); driftRun?.screens.append(cur.screen.id) }
                    if cur.truth != .drift { closeDrift(at: t) }
                }

                // The model's answers that are due.
                while let next = pending.sorted(by: { $0.due < $1.due }).first, next.due <= t {
                    pending.removeAll { $0.due == next.due && $0.verdict.sampleId == next.verdict.sampleId }
                    let at = max(next.due, lastTick)
                    await handle(.verdict(next.verdict, context: next.context, window: next.window), at: at, truth: next.truth, screen: cur.screen.id)
                    if let waited = waiting, at >= judgingUntil {
                        waiting = nil
                        await judge(waited.0, truth: waited.1, context: waited.2, screen: waited.3, at: at)
                    }
                }
                if let waited = waiting, t >= judgingUntil {
                    waiting = nil
                    await judge(waited.0, truth: waited.1, context: waited.2, screen: waited.3, at: t)
                }

                // The hands.
                if sensing, let every = beat.profile.inputEverySec {
                    while nextInputAt <= t {
                        lastInputAt = nextInputAt
                        nextInputAt += every * (0.5 + chance())
                    }
                }
                if sensing, t - lastInputAt < 3, Int(t) % 2 == 0 {
                    let wobble = CGFloat(Int(t) % 40)
                    await handle(.attention(CGPoint(x: 600 + wobble * 6, y: 450 - wobble * 3)), at: t, truth: cur.truth, screen: cur.screen.id)
                }

                // The sensors: a sample every few seconds, and the meeting state they read with it.
                if sensing, t >= nextSampleAt {
                    nextSampleAt = t + config.sampleIntervalSec
                    let call = context(for: beat, at: t - beatStart)
                    if call != lastMeeting {
                        lastMeeting = call
                        await handle(.meeting(call), at: t, truth: cur.truth, screen: cur.screen.id)
                    }
                    let sample = makeSample(screen: cur.screen, beat: beat, at: t, beatStart: beatStart, now: now, call: call)
                    if t < judgingUntil {
                        waiting = (sample, cur.truth, cur.context, cur.screen.id)
                    } else {
                        await judge(sample, truth: cur.truth, context: cur.context, screen: cur.screen.id, at: t)
                    }
                }

                if t >= nextWorldAt {
                    nextWorldAt = t + CompanionRuntime.refreshIntervalSec
                    if let world = try? await brain.world() { await handle(.world(world), at: t, truth: cur.truth, screen: cur.screen.id) }
                }

                // The tick.
                let tickEffects = engine.tick(now: now)
                lastTick = t
                await consume(tickEffects, at: t, truth: cur.truth, screen: cur.screen.id)
                note(t: t, truth: cur.truth, screen: cur.screen.id, driftRun: &driftRun)

                report.truthSeconds[cur.truth.rawValue, default: 0] += 1
                report.phaseSeconds[cur.truth.rawValue, default: [:]][engine.status.phase.rawValue, default: 0] += 1
                t += 1
            }
            for input in beat.endInputs { await apply(input, at: beatEnd, truth: cur.truth, screen: cur.screen.id) }
            beatStart = beatEnd
        }
        closeDrift(at: beatStart)
        report.drifts = driftRuns
        report.focusCreditedMinutes = Double(report.eventCounts["focusGrowth", default: 0])
        report.yourDay = await yourDay(for: session.date)
        // A session that ran past midnight also made the next day.
        let startDay = Calendar.current.startOfDay(for: start)
        let endDay = Calendar.current.startOfDay(for: start.addingTimeInterval(report.seconds - 1))
        var day = startDay
        while let next = Calendar.current.date(byAdding: .day, value: 1, to: day), next <= endDay {
            if let later = await yourDay(on: next) { report.laterDays.append(later) }
            day = next
        }
        return report
    }

    // MARK: The sensors' side

    private func context(for beat: Beat, at offset: Double) -> MeetingContext {
        switch beat.call {
        case .none: return .none
        case let .on(camera): return MeetingContext(inCall: true, sharingScreen: false, micInUse: true, cameraInUse: camera)
        case .sharing: return MeetingContext(inCall: true, sharingScreen: true, micInUse: true, cameraInUse: false)
        case .dictating: return MeetingContext(inCall: false, sharingScreen: false, micInUse: true, cameraInUse: false)
        case let .flapping(period, off):
            let phase = offset.truncatingRemainder(dividingBy: period)
            let live = phase < period - off
            return MeetingContext(inCall: live, sharingScreen: false, micInUse: live, cameraInUse: false)
        }
    }

    private func makeSample(screen: QAScreen, beat: Beat, at t: Double, beatStart: Double, now: Date, call: MeetingContext) -> ActivitySample {
        sampleCount += 1
        // Absolute, not from the beat's start: a page's words never come round again (a restart would repeat texts exactly).
        let version = beat.profile.textChangesEverySec.map { Int(t / $0) } ?? 0
        var text: String?
        var hash: String?
        if !screen.text.isEmpty {
            let full = version == 0 ? screen.text : screen.text + " " + filler(version)
            hash = String(full.hashValue, radix: 16)
            if version != lastTextVersion { text = full }
            lastTextVersion = version
        }
        let idle = max(0, t - lastInputAt)
        return ActivitySample(
            id: "qa-\(sampleCount)", ts: now, app: AppInfo(bundleId: screen.bundle, name: screen.app),
            window: WindowInfo(title: screen.title, url: screen.url), text: text, textSource: text == nil ? nil : .accessibility,
            textHash: hash,
            activity: InputActivity(keysPerMinute: idle < 20 ? beat.profile.keysPerMinute : 0, clicksPerMinute: idle < 20 ? beat.profile.clicksPerMinute : 0,
                                    scrollsPerMinute: idle < 20 ? beat.profile.scrollsPerMinute : 0, idleSeconds: idle),
            context: call)
    }

    private func filler(_ version: Int) -> String {
        // The last dozen words typed or scrolled to: the text changes with every version, however long the session.
        (max(0, version - 12)..<version).map { "w\($0 * 7 + 3)" }.joined(separator: " ")
    }

    /// One /v1/judge call; the verdict is due a moment later (the runtime keeps one request in flight).
    private func judge(_ sample: ActivitySample, truth: Truth, context: WorkContext, screen: String, at t: Double) async {
        do {
            let verdict = try await brain.judge(sample)
            report.verdicts[truth.rawValue, default: [:]][verdict.state.rawValue, default: 0] += 1
            trace?.write(Data("\(clock(t)) \(screen) \(truth.rawValue) \(verdict.state.rawValue) \(verdict.reason.prefix(90))\n".utf8))
            if verdict.source == .jev { report.jevCalls += 1 }
            if verdict.state == .working || verdict.state == .drifting {
                // The same page judged both ways in turn (not a move from one page to another).
                if let before = lastJudged, before.screen == screen, before.state != verdict.state, truth == .work { report.verdictFlipsAtWork += 1 }
                lastJudged = (screen, verdict.state)
            }
            if verdict.state == .away, truth == .work || truth == .drift || truth == .dictation {
                report.awayReasons["\(truth.rawValue) \(sample.window?.title.prefix(28) ?? "") | \(verdict.reason.prefix(60))", default: 0] += 1
            }
            let failed = verdict.source == .fallback
            let latency = failed ? failLatency : (verdict.source == .jev ? jevLatency : ruleLatency)
            judgingUntil = t + latency
            report.maxVerdictSeconds = max(report.maxVerdictSeconds, latency)
            pending.append((t + latency, verdict, context, sample.window, truth))
        } catch {
            report.brainErrors += 1
            judgingUntil = t + 1
        }
    }

    // MARK: The engine's side

    private func handle(_ input: EngineInput, at t: Double, truth: Truth, screen: String) async {
        let effects = engine.handle(input, now: simDate(t))
        await consume(effects, at: t, truth: truth, screen: screen)
    }

    private var simStart = Date()

    private func simDate(_ t: Double) -> Date { simStart.addingTimeInterval(t) }

    private func apply(_ input: BeatInput, at t: Double, truth: Truth, screen: String) async {
        switch input {
        case .startBreak: await handle(.startBreak, at: t, truth: truth, screen: screen)
        case .endBreak: await handle(.endBreak, at: t, truth: truth, screen: screen)
        case .pat: await handle(.pat, at: t, truth: truth, screen: screen)
        case let .network(mode): _ = try? await control("mode?m=\(mode)")
        case let .forceCalm(on):
            let effects = engine.setForceCalm(on, now: simDate(t))
            await consume(effects, at: t, truth: truth, screen: screen)
        }
    }

    private func consume(_ effects: [EngineEffect], at t: Double, truth: Truth, screen: String) async {
        for effect in effects {
            log.append((t, effect))
            if case let .character(command) = effect { report.commandCounts[Self.name(of: command), default: 0] += 1 }
            switch effect {
            case let .event(event):
                report.eventCounts[event.type.rawValue, default: 0] += 1
                try? await brain.sendEvent(event)
            case let .feedback(feedback):
                report.eventCounts["feedback.\(feedback.kind.rawValue)", default: 0] += 1
                try? await brain.sendFeedback(feedback)
            case let .setOnBreak(on):
                sensing = !on
                if !on { lastMeeting = .none; lastScreenId = nil }
            case let .character(.say(line)):
                report.lines.append("\(clock(t)) [\(truth.rawValue)] \(line.text)")
            case .character(.setHidden(let hidden)):
                report.eventCounts[hidden ? "hidden" : "shown", default: 0] += 1
            default: break
            }
        }
    }

    /// A ladder step is a change of the engine's escalation: recorded with what the person was really doing.
    private func note(t: Double, truth: Truth, screen: String, driftRun: inout DriftRun?) {
        let escalation = engine.status.escalation
        defer { lastEscalation = escalation }
        guard escalation != lastEscalation, let step = escalation, step != "grace" else { return }
        report.steps.append(StepMark(t: t, step: step, truth: truth.rawValue, screen: screen))
        if driftRun != nil {
            if step == "sad", driftRun?.firstSad == nil { driftRun?.firstSad = t }
            if step == "ask", driftRun?.ask == nil { driftRun?.ask = t }
            driftRun?.reached = step
        }
    }

    private static func name(of command: CharacterCommand) -> String {
        switch command {
        case .setMood: "setMood"
        case .setAttention: "setAttention"
        case let .perform(gesture): "perform.\(gesture.rawValue)"
        case .move: "move"
        case .say: "say"
        case .dismissSpeech: "dismissSpeech"
        case .setHidden: "setHidden"
        case .setWorkState: "setWorkState"
        case let .celebrateReturn(size): "celebrateReturn.\(size)"
        case .breakTimer: "breakTimer"
        case .think: "think"
        }
    }

    /// The stage commands the engine gave in the last session, one a line: seconds into the session, the command, its
    /// arguments, separated by tabs. The visual demo's --soak plays them on the real stage (launch QA, lens 3: the
    /// stage under the engine's realistic stream). A line says everything the stage needs, in words.
    func exportCommands(to url: URL) throws {
        var lines: [String] = []
        for (t, effect) in log {
            guard case let .character(command) = effect else { continue }
            let head = String(format: "%.2f", t)
            switch command {
            case let .setMood(mood): lines.append("\(head)\tsetMood\t\(mood.rawValue)")
            case let .setAttention(target):
                switch target {
                case .user: lines.append("\(head)\tsetAttention\tuser")
                case .wander: lines.append("\(head)\tsetAttention\twander")
                case let .point(point): lines.append("\(head)\tsetAttention\tpoint\t\(Int(point.x))\t\(Int(point.y))")
                }
            case let .perform(gesture): lines.append("\(head)\tperform\t\(gesture.rawValue)")
            case let .move(spot):
                switch spot {
                case .home: lines.append("\(head)\tmove\thome")
                case .center: lines.append("\(head)\tmove\tcenter")
                case let .near(point): lines.append("\(head)\tmove\tnear\t\(Int(point.x))\t\(Int(point.y))")
                }
            case let .say(line): lines.append("\(head)\tsay\t\(line.tone.rawValue)\t\(line.duration.isFinite ? String(line.duration) : "forever")\t\(line.text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " "))")
            case .think: lines.append("\(head)\tthink")
            case .dismissSpeech: lines.append("\(head)\tdismissSpeech")
            case let .setHidden(hidden): lines.append("\(head)\tsetHidden\t\(hidden)")
            case let .setWorkState(state): lines.append("\(head)\tsetWorkState\t\(state.rawValue)")
            case let .celebrateReturn(size): lines.append("\(head)\tcelebrateReturn\t\(size.rawValue)")
            case let .breakTimer(until, total):
                lines.append("\(head)\tbreakTimer\t\(until.map { String(format: "%.1f", $0.timeIntervalSince(simStart) - t) } ?? "none")\t\(Int(total))")
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func clock(_ t: Double) -> String {
        let total = Int(t)
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    // MARK: The brain's side

    private func control(_ path: String) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "qa/" + path, relativeTo: controlBase)!)
        return data
    }

    private func yourDay(for date: String) async -> YourDay? {
        guard let day = Self.parse(date) else { return nil }
        return await yourDay(on: day)
    }

    private func yourDay(on day: Date) async -> YourDay? {
        guard let summary = try? await brain.today(date: day) else { return nil }
        return YourDay(date: summary.date, focusedMinutes: summary.focusedMinutes, longestFocusMinutes: summary.longestFocusMinutes, returns: summary.returns,
                       unitsToday: summary.unitsToday, goals: summary.goals.map(Self.describe),
                       goalMinutes: summary.goals.reduce(0) { $0 + $1.minutes }, builtMinutes: summary.built.reduce(0) { $0 + $1.minutes },
                       wanderedMinutes: summary.wandered.reduce(0) { $0 + $1.minutes }, categoryMinutes: summary.byCategory.filter { !["watching", "scrolling", "chatting", "reading", "shopping", "playing", "other"].contains($0.category.rawValue) }.reduce(0) { $0 + $1.minutes },
                       builtRows: summary.built.count, wanderedRows: summary.wandered.count, quickCheckMinutes: summary.quickCheckMinutes,
                       segments: summary.segments.count, note: summary.note)
    }

    private static func describe(_ goal: GoalDay) -> String {
        let names = Dictionary(uniqueKeysWithValues: goal.apps.map { ($0.id, $0.name) })
        let flow = goal.workflow.map { step in
            step.kind == .app ? "\(names[step.appId] ?? step.appId) \(step.minutes)m" : "↩ \(step.place ?? "a detour") \(step.minutes)m x\(step.count)"
        }.joined(separator: " → ")
        return "\(goal.title) \(goal.minutes)m, longest \(goal.longestMinutes), \(goal.sittings) sittings | \(flow) | steps: \(goal.steps.joined(separator: "; "))"
    }

    static func parse(_ date: String) -> Date? {
        let day = date.split(separator: "-").compactMap { Int($0) }
        guard day.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(calendar: .current, year: day[0], month: day[1], day: day[2], hour: 12))
    }
}

/// Where the person is right now: the screen, as the sensors name it, and what it really is to them.
struct Place {
    var screen: QAScreen
    var truth: Truth
    var app: AppInfo
    var window: WindowInfo
    var context: WorkContext { WorkContext(app: app, window: window) }

    init(_ screen: QAScreen, override: Truth?) {
        self.screen = screen
        truth = override ?? Truth(rawValue: screen.truth) ?? .work
        app = AppInfo(bundleId: screen.bundle, name: screen.app)
        window = WindowInfo(title: screen.title, url: screen.url)
    }
}
