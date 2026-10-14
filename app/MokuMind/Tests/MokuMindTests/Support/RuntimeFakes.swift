import CoreGraphics
import Foundation
import MokuKit
import Synchronization
@testable import MokuMind

/// A brain that answers from canned state and records every call. `isDown` makes every call throw.
actor FakeBrain: BrainAPI {
    var isDown = false
    var servedConfig = CompanionConfig.standard
    var servedWorld = WorldSnapshot.empty
    var judgedState = Verdict.State.working
    var lines: [VoiceKind: String] = [:]
    /// Hold every judge call until `releaseJudges()`.
    var holdJudges = false

    private(set) var judgedSampleIds: [String] = []
    private(set) var voiceRequests: [VoiceRequest] = []
    private(set) var events: [CompanionEvent] = []
    private(set) var feedback: [Feedback] = []
    private(set) var worldFetches = 0
    private(set) var configFetches = 0
    private var heldJudges: [CheckedContinuation<Void, Never>] = []

    func set(down: Bool) { isDown = down }
    func set(config: CompanionConfig) { servedConfig = config }
    func set(world: WorldSnapshot) { servedWorld = world }
    func set(judged state: Verdict.State) { judgedState = state }
    func set(holdJudges hold: Bool) { holdJudges = hold }
    func set(line: String, for kind: VoiceKind) { lines[kind] = line }

    func releaseJudges() {
        let held = heldJudges
        heldJudges = []
        held.forEach { $0.resume() }
    }

    var heldJudgeCount: Int { heldJudges.count }

    private func failIfDown(_ path: String) throws {
        if isDown { throw BrainError.unreachable(path: path, reason: "connection refused") }
    }

    func judge(_ sample: ActivitySample) async throws -> Verdict {
        judgedSampleIds.append(sample.id)
        if holdJudges { await withCheckedContinuation { heldJudges.append($0) } }
        try failIfDown("/v1/judge")
        return Verdict(sampleId: sample.id, state: judgedState, thread: ThreadRef(id: "t1", title: "Auth · Login flow"),
                       isNewThread: false, confidence: 0.9, source: .jev, reason: "fake", latencyMs: 5)
    }

    func voice(_ request: VoiceRequest) async throws -> VoiceLine {
        voiceRequests.append(request)
        try failIfDown("/v1/voice")
        return VoiceLine(text: lines[request.kind] ?? "Luna says \(request.kind.rawValue)", source: "luna")
    }

    func sendFeedback(_ feedback: Feedback) async throws {
        try failIfDown("/v1/feedback")
        self.feedback.append(feedback)
    }

    func sendEvent(_ event: CompanionEvent) async throws {
        try failIfDown("/v1/events")
        events.append(event)
    }

    func world() async throws -> WorldSnapshot {
        worldFetches += 1
        try failIfDown("/v1/world")
        return servedWorld
    }

    func config() async throws -> CompanionConfig {
        configFetches += 1
        try failIfDown("/v1/config")
        return servedConfig
    }

    func threads() async throws -> [ThreadSummary] {
        try failIfDown("/v1/threads")
        return []
    }

    private(set) var todayRequests = 0
    var servedToday = TodaySummary(date: "2026-09-23", note: "A steady day.", focusedMinutes: 94, longestFocusMinutes: 47,
                                   returns: 6, unitsToday: 9, segments: [], built: [], wandered: [], quickCheckMinutes: 3,
                                   comebacks: [], bestComeback: nil, completions: [])

    private(set) var todayDates: [Date?] = []
    func today(date: Date?) async throws -> TodaySummary {
        todayRequests += 1; todayDates.append(date)
        try failIfDown("/v1/today")
        return servedToday
    }
    var servedDays = DaysResponse(firstDay: "2026-09-21", days: [DayTotals(date: "2026-09-22", focusedMinutes: 40), DayTotals(date: "2026-09-23", focusedMinutes: 94, returns: 6, lanterns: 2)])
    func days(from: Date, to: Date) async throws -> DaysResponse {
        try failIfDown("/v1/days")
        return servedDays
    }
}

/// Records every call the runtime makes on the character. Moves can be held to test ordering.
@MainActor
final class FakeStage: CharacterStage {
    enum Call: Equatable {
        case show, hidden(Bool), mood(Mood), attention(AttentionTarget), gesture(Gesture), move(StageSpot), say(SpeechLine)
        case dismissSpeech, label(String), workState(WorkState), celebrateReturn(ReturnSize)
    }

    private(set) var calls: [Call] = []
    var onPat: (@MainActor () -> Void)?
    var onClick: (@MainActor () -> Void)?
    var onTakeBreak: (@MainActor () -> Void)?
    var onWhatsNew: (@MainActor (_ version: String, _ opened: Bool) -> Void)?
    var holdMoves = false
    private var heldMoves: [CheckedContinuation<Void, Never>] = []

    func show() { calls.append(.show) }
    func setHidden(_ hidden: Bool) { calls.append(.hidden(hidden)) }
    func setMood(_ mood: Mood) { calls.append(.mood(mood)) }
    func setAttention(_ target: AttentionTarget) { calls.append(.attention(target)) }
    func perform(_ gesture: Gesture) { calls.append(.gesture(gesture)) }
    func say(_ line: SpeechLine) { calls.append(.say(line)) }
    func dismissSpeech() { calls.append(.dismissSpeech) }
    func showThreadLabel(_ title: String) { calls.append(.label(title)) }
    func setWorkState(_ state: WorkState) { calls.append(.workState(state)) }
    func celebrateReturn(_ size: ReturnSize) { calls.append(.celebrateReturn(size)) }
    /// The break timer over the companion's head: when it ends, or nil when it's taken away.
    private(set) var breakTimers: [Date?] = []
    func setBreakTimer(until: Date?, total: TimeInterval) { breakTimers.append(until) }

    /// A new move redirects the walk in progress: the earlier call returns at once, as the contract says.
    func move(to spot: StageSpot) async {
        calls.append(.move(spot))
        releaseMoves()
        if holdMoves { await withCheckedContinuation { heldMoves.append($0) } }
    }

    func releaseMoves() {
        let held = heldMoves
        heldMoves = []
        held.forEach { $0.resume() }
    }

    var lines: [SpeechLine] { calls.compactMap { if case let .say(line) = $0 { line } else { nil } } }
    var moods: [Mood] { calls.compactMap { if case let .mood(mood) = $0 { mood } else { nil } } }
    var gestures: [Gesture] { calls.compactMap { if case let .gesture(gesture) = $0 { gesture } else { nil } } }
    var workStates: [WorkState] { calls.compactMap { if case let .workState(state) = $0 { state } else { nil } } }
}

@MainActor
final class FakeWorld: WorldPresenter {
    private(set) var opened = 0
    private(set) var closed = 0
    private(set) var celebrated: [ForestStage] = []
    private(set) var manualControl: [Bool] = []
    private(set) var onBreak: [Bool] = []
    var onManualControl: (@MainActor (Bool) -> Void)?
    var onTakeBreak: (@MainActor () -> Void)?
    var onOpen: (@MainActor () -> Void)?
    var todayProvider: (@MainActor (Date?) async -> TodaySummary?)?
    var daysProvider: (@MainActor (_ from: Date, _ to: Date) async -> DaysResponse?)?
    var onCorrection: (@MainActor (_ segmentIds: [String], _ isWork: Bool) -> Void)?
    /// Whether the companion is on show with nothing over it (the day's card and "What's new" wait for it).
    var visible = true
    var canShowDayCounted: Bool { visible }

    func openWorld() { opened += 1 }
    func closeWorld() { closed += 1 }
    func celebrate(_ stage: ForestStage) { celebrated.append(stage) }
    func setManualControl(_ on: Bool) { manualControl.append(on) }
    func setOnBreak(_ on: Bool) { onBreak.append(on) }
}

/// A clock moved by hand. `set` moves time without waking sleepers; `advance` wakes the ones due.
final class ManualClock: RuntimeClock {
    private struct State {
        var now: Date
        var sleepers: [(id: UUID, until: Date, continuation: CheckedContinuation<Void, any Error>)] = []
    }

    private let state: Mutex<State>

    init(start: Date = EngineHarness.base) {
        state = Mutex(State(now: start))
    }

    func now() -> Date { state.withLock { $0.now } }

    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    /// Sleeps until `advance` passes the deadline; cancelling the task wakes it with `CancellationError`.
    func sleep(seconds: Double) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let alreadyCancelled = state.withLock { state -> Bool in
                    guard !Task.isCancelled else { return true }
                    state.sleepers.append((id, state.now.addingTimeInterval(seconds), continuation))
                    return false
                }
                if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index).continuation
            }
            sleeper?.resume(throwing: CancellationError())
        }
    }

    func set(_ seconds: Double) {
        state.withLock { $0.now = EngineHarness.base.addingTimeInterval(seconds) }
    }

    func advance(by seconds: Double) {
        let due = state.withLock { state in
            state.now = state.now.addingTimeInterval(seconds)
            let now = state.now
            let due = state.sleepers.filter { $0.until <= now }.map(\.continuation)
            state.sleepers.removeAll { $0.until <= now }
            return due
        }
        due.forEach { $0.resume() }
    }

    /// Wake every sleeper with a cancellation so no continuation leaks when a test ends.
    func cancelSleepers() {
        let all = state.withLock { state in
            defer { state.sleepers = [] }
            return state.sleepers.map(\.continuation)
        }
        all.forEach { $0.resume(throwing: CancellationError()) }
    }
}

/// A clock whose sleeps return almost at once, moving its time forward and adding up what was asked for.
/// Scenes run on it at full speed while their pacing can still be checked.
final class InstantClock: RuntimeClock {
    private let state = Mutex((now: EngineHarness.base, slept: 0.0))

    func now() -> Date { state.withLock { $0.now } }
    var slept: Double { state.withLock { $0.slept } }

    func sleep(seconds: Double) async throws {
        try Task.checkCancellation()
        state.withLock {
            $0.now = $0.now.addingTimeInterval(seconds)
            $0.slept += seconds
        }
        try await Task.sleep(for: .microseconds(20))  // real, so other tasks (voice replies, walks) get to run
    }
}

/// Polls until `condition` holds (or about two seconds pass). For waiting on work in other tasks.
@MainActor
func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<400 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

enum Samples {
    static func sample(_ id: String, app: AppInfo = Fixtures.editorApp, window: WindowInfo? = Fixtures.editorWindow,
                       at time: Date = EngineHarness.base) -> ActivitySample {
        ActivitySample(id: id, ts: time, app: app, window: window, text: nil, textSource: nil, textHash: nil,
                       activity: InputActivity(keysPerMinute: 80, clicksPerMinute: 4, scrollsPerMinute: 2, idleSeconds: 0),
                       context: .none)
    }
}

/// What a callback was called with, in order (for the app's hooks on the runtime).
@MainActor
final class Recording<Value> {
    var values: [Value] = []
}
