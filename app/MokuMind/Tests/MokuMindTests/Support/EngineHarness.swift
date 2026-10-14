import CoreGraphics
import Foundation
import MokuKit
@testable import MokuMind

/// Drives a `BehaviorEngine` on simulated time: `t` is seconds since `base`, and every second that
/// passes is one tick, with a verdict every 3 s when a state is being judged (like the real sampler).
extension CompanionConfig {
    /// The timings most tests were written against: ten seconds of grace and a smile every 15 minutes, which
    /// keeps each rule's timing visible (sad at 10 s, angry at a minute). The shipped standard reacts at once (grace 1 s, a smile every
    /// 4 min); `StandardTimingsTests` covers it. Named, as after onboarding (the standard says "friend").
    static let charles: CompanionConfig = {
        var config = CompanionConfig.standard
        config.userName = "Charles"
        config.graceSec = 10
        config.smileEverySec = 900
        config.drinkEverySec = 1_000_000  // no drinks of its own unless a test asks for them
        return config
    }()
}

struct EngineHarness {
    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    var engine: BehaviorEngine
    private(set) var t: Double = 0
    private(set) var log: [(t: Double, effect: EngineEffect)] = []
    private var samples = 0

    init(config: CompanionConfig = .charles, tuning: EngineTuning = .standard, seed: UInt64 = 42) {
        engine = BehaviorEngine(config: config, tuning: tuning, random: MokuRandom(seed: seed))
    }

    var now: Date { Self.base.addingTimeInterval(t) }
    var status: BehaviorEngine.Status { engine.status }

    @discardableResult
    mutating func send(_ input: EngineInput) -> [EngineEffect] {
        record(engine.handle(input, now: now))
    }

    @discardableResult
    mutating func tick() -> [EngineEffect] {
        record(engine.tick(now: now))
    }

    /// Let `seconds` pass, one tick per second. While `judging` is set, a verdict of that state
    /// arrives on every third second; `cursor` moves the user's attention every second.
    @discardableResult
    mutating func pass(_ seconds: Double, judging state: Verdict.State? = nil, thread: ThreadRef? = Fixtures.thread,
                       context: WorkContext? = nil, cursor: CGPoint? = nil) -> [EngineEffect] {
        var collected: [EngineEffect] = []
        for _ in 0..<Int(seconds) {
            t += 1
            if let state, Int(t) % 3 == 0 {
                collected += send(.verdict(verdict(state, thread: thread), context: context))
            }
            if let cursor { collected += send(.attention(cursor)) }
            collected += tick()
        }
        return collected
    }

    /// Jump the clock without ticking (e.g. between two inputs within the same second).
    mutating func wait(_ seconds: Double) {
        t += seconds
    }

    /// Start working now (a working verdict right away), then keep working for `seconds`.
    @discardableResult
    mutating func work(_ seconds: Double, thread: ThreadRef? = Fixtures.thread, context: WorkContext? = nil) -> [EngineEffect] {
        send(.verdict(verdict(.working, thread: thread), context: context))
            + pass(seconds, judging: .working, thread: thread, context: context)
    }

    /// Start drifting now (a drifting verdict right away), then keep drifting for `seconds`.
    @discardableResult
    mutating func drift(_ seconds: Double, context: WorkContext? = nil, cursor: CGPoint? = nil) -> [EngineEffect] {
        send(.verdict(verdict(.drifting, thread: nil), context: context))
            + pass(seconds, judging: .drifting, thread: nil, context: context, cursor: cursor)
    }

    mutating func verdict(_ state: Verdict.State, thread: ThreadRef? = Fixtures.thread) -> Verdict {
        samples += 1
        return Verdict(sampleId: "s\(samples)", state: state, thread: state == .working ? thread : nil,
                       isNewThread: false, confidence: 0.9, source: .jev, reason: "test", latencyMs: 600)
    }

    /// Effects logged at times in [from, to].
    func effects(from start: Double, to end: Double) -> [EngineEffect] {
        log.filter { $0.t >= start && $0.t <= end }.map(\.effect)
    }

    /// When the first effect matching `predicate` was logged.
    func firstTime(where predicate: (EngineEffect) -> Bool) -> Double? {
        log.first { predicate($0.effect) }?.t
    }

    func times(where predicate: (EngineEffect) -> Bool) -> [Double] {
        log.filter { predicate($0.effect) }.map(\.t)
    }

    var allEffects: [EngineEffect] { log.map(\.effect) }

    private mutating func record(_ effects: [EngineEffect]) -> [EngineEffect] {
        log += effects.map { (t, $0) }
        return effects
    }
}

enum Fixtures {
    static let thread = ThreadRef(id: "t-auth", title: "Auth · Login flow")
    static let editorApp = AppInfo(bundleId: "com.apple.dt.Xcode", name: "Xcode")
    static let terminalApp = AppInfo(bundleId: "com.apple.Terminal", name: "Terminal")
    static let browserApp = AppInfo(bundleId: "com.apple.Safari", name: "Safari")
    static let editorWindow = WindowInfo(title: "LoginView.swift", url: nil)
    static let youtubeWindow = WindowInfo(title: "Lo-fi - YouTube", url: "https://www.youtube.com/watch?v=1")
    static let docsWindow = WindowInfo(title: "URLSession | Apple Developer", url: "https://developer.apple.com/documentation")
    static let editor = WorkContext(app: editorApp, window: editorWindow)
    static let youtube = WorkContext(app: browserApp, window: youtubeWindow)
    static let docs = WorkContext(app: browserApp, window: docsWindow)
    static let cursor = CGPoint(x: 640, y: 420)
    static let otherWindowCursor = CGPoint(x: 1200, y: 600)

    static let inCall = MeetingContext(inCall: true, sharingScreen: false, micInUse: true, cameraInUse: true)
    static let sharing = MeetingContext(inCall: false, sharingScreen: true, micInUse: false, cameraInUse: false)

    static func snapshot(points: Double) -> WorldSnapshot {
        WorldSnapshot(growthPoints: points, todayFocusMinutes: 0, todayReturns: 0, longestFocusMinutesToday: 0, threads: [])
    }

    /// Every timing shrunk, and all different from the standard ones, to prove they come from config.
    static let quickConfig = CompanionConfig(
        userName: "Ada", sampleIntervalSec: 3, awayAfterIdleSec: 60, shortDriftMaxSec: 20,
        annoyedAfterSec: 30, standUpAfterSec: 40, askAfterSec: 50,
        smileEverySec: 45, proudAfterSec: 100, breakAfterSec: 130,
        evidenceWindowSec: 60, longAwaySec: 600,
        ignoredNudgeAfterSec: 600, threadLabelGapSec: 1_800, teaBreakMaxSec: 1_200,
        graceSec: 60, drinkEverySec: 1_000_000  // no drinks unless a test asks for them
    )
}

extension Array where Element == EngineEffect {
    var commands: [CharacterCommand] {
        compactMap { if case let .character(command) = $0 { command } else { nil } }
    }

    var moods: [Mood] { commands.compactMap { if case let .setMood(mood) = $0 { mood } else { nil } } }
    var gestures: [Gesture] { commands.compactMap { if case let .perform(gesture) = $0 { gesture } else { nil } } }
    var lines: [SpeechLine] { commands.compactMap { if case let .say(line) = $0 { line } else { nil } } }
    var moves: [StageSpot] { commands.compactMap { if case let .move(spot) = $0 { spot } else { nil } } }
    var gazes: [AttentionTarget] { commands.compactMap { if case let .setAttention(target) = $0 { target } else { nil } } }
    var hiddenChanges: [Bool] { commands.compactMap { if case let .setHidden(hidden) = $0 { hidden } else { nil } } }
    var nods: Int { gestures.filter { $0 == .nod }.count }
    var workStates: [WorkState] { commands.compactMap { if case let .setWorkState(state) = $0 { state } else { nil } } }
    var returns: [ReturnSize] { commands.compactMap { if case let .celebrateReturn(size) = $0 { size } else { nil } } }
    /// Character commands other than the lantern's, which changes along with almost everything.
    var actions: [CharacterCommand] {
        commands.filter { if case .setWorkState = $0 { false } else { true } }
    }

    var events: [CompanionEvent] { compactMap { if case let .event(event) = $0 { event } else { nil } } }
    var eventTypes: [CompanionEventType] { events.map(\.type) }
    func events(_ type: CompanionEventType) -> [CompanionEvent] { events.filter { $0.type == type } }
    var feedback: [Feedback] { compactMap { if case let .feedback(feedback) = $0 { feedback } else { nil } } }
    var voiceRequests: [VoiceRequest] { compactMap { if case let .requestVoice(request) = $0 { request } else { nil } } }

    /// Events other than the per-minute growth that ticks along underneath everything.
    var notableEventTypes: [CompanionEventType] { eventTypes.filter { $0 != .focusGrowth } }
}

extension EngineEffect {
    func isSay(_ tone: SpeechLine.Tone? = nil) -> Bool {
        guard case let .character(.say(line)) = self else { return false }
        return tone.map { $0 == line.tone } ?? true
    }

    func isEvent(_ type: CompanionEventType) -> Bool {
        guard case let .event(event) = self else { return false }
        return event.type == type
    }

    func isMood(_ mood: Mood) -> Bool { self == .character(.setMood(mood)) }
    func isGesture(_ gesture: Gesture) -> Bool { self == .character(.perform(gesture)) }

    func isVoiceRequest(_ kind: VoiceKind) -> Bool {
        guard case let .requestVoice(request) = self else { return false }
        return request.kind == kind
    }

    func isFeedback(_ kind: FeedbackKind) -> Bool {
        guard case let .feedback(feedback) = self else { return false }
        return feedback.kind == kind
    }
}
