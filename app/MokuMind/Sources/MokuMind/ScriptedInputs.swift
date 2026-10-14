import CoreGraphics
import Foundation
import MokuKit

/// Turns a `ScriptedDay` into what the runtime would feed the engine, second by second:
/// - a focus change when the user moves somewhere
/// - a sample every `sampleIntervalSec`, judged by a scripted brain one second later (a thread's first
///   verdict carries a provisional title, and patted places are judged working from then on)
/// - the cursor every 2 s
/// - `/v1/world` every 60 s and one second after growth, with growth points summed from the engine's events
///
/// Voice is left to the caller: the simulator uses canned lines, manual scenes ask the real brain.
public struct ScriptedInputs: Sendable {
    public enum Item: Sendable {
        case note(String)
        case input(EngineInput)
    }

    public static let judgeLatencySec = 1
    /// After finishing something the user sits back: no cursor or caret movement for this long.
    public static let stillAfterCompletionSec = 10

    public let day: ScriptedDay
    /// Forest points so far: the day's start plus every growth event observed.
    public private(set) var points: Double

    private var place: ScriptedDay.Place?
    private var inMeeting = false
    /// Away from the desk (on a tea break): the cursor doesn't move.
    private var atDesk = true
    /// The cursor is still until this second (sitting back after finishing something).
    private var stillUntil = -1
    /// Carried by the next verdict for the current place.
    private var completion: Completion?
    private var patted: Set<WorkContext> = []
    private var namedThreads: Set<String> = []
    private var verdictsDue: [(due: Int, verdict: Verdict, context: WorkContext)] = []
    private var nextWorldRefresh = 0
    private var samples = 0
    private var currentSecond = 0

    public init(_ day: ScriptedDay) {
        self.day = day
        points = day.startPoints
    }

    public var lastSecond: Int { Int(day.endSec) }

    /// Everything that happens at `second` before the engine ticks, in order.
    public mutating func items(at second: Int) -> [Item] {
        currentSecond = second
        var items: [Item] = []
        for moment in day.moments where Int(moment.at) == second {
            items.append(.note(moment.note))
            items += play(moment.action)
        }
        for due in verdictsDue where due.due <= second {
            items.append(.input(.verdict(due.verdict, context: due.context)))
        }
        verdictsDue.removeAll { $0.due <= second }
        if second >= nextWorldRefresh {
            nextWorldRefresh = second + Int(CompanionRuntime.refreshIntervalSec)
            items.append(.input(.world(WorldSnapshot(growthPoints: points, todayFocusMinutes: 0, todayReturns: 0,
                                                     longestFocusMinutesToday: 0, threads: []))))
        }
        let sampleEvery = max(1, Int(day.config.sampleIntervalSec.rounded()))
        if let place, second % sampleEvery == 0 { sample(place, at: second) }
        if let place, !inMeeting, atDesk, second > stillUntil, second % 2 == 0 {
            let wobble = CGFloat(second % 20)
            items.append(.input(.attention(CGPoint(x: place.cursor.x + wobble, y: place.cursor.y - wobble))))
        }
        return items
    }

    /// Growth events move the forest; the next world refresh reports them.
    public mutating func observe(_ effects: [EngineEffect], at second: Int) {
        for case let .event(event) in effects where event.type == .focusGrowth || event.type == .returnGrowth {
            points += event.value ?? 0
            nextWorldRefresh = min(nextWorldRefresh, second + 1)
        }
    }

    private mutating func play(_ action: ScriptedDay.Action) -> [Item] {
        switch action {
        case let .use(next):
            atDesk = true
            return enter(next)
        case let .meetingStarts(meetingPlace):
            inMeeting = true
            return enter(meetingPlace)
                + [.input(.meeting(MeetingContext(inCall: true, sharingScreen: false, micInUse: true, cameraInUse: true)))]
        case let .meetingEnds(next):
            inMeeting = false
            return [.input(.meeting(.none))] + enter(next)
        case .pat:
            if let place { patted.insert(place.context) }
            return [.input(.pat)]
        case .click:
            return [.input(.click)]
        case .takeBreak:
            atDesk = false
            return [.input(.startBreak)]
        case let .complete(finished):
            completion = finished
            stillUntil = currentSecond + Self.stillAfterCompletionSec
            return []
        }
    }

    private mutating func enter(_ next: ScriptedDay.Place) -> [Item] {
        place = next
        return [.input(.focusChanged(next.app, next.window))]
    }

    private mutating func sample(_ place: ScriptedDay.Place, at second: Int) {
        samples += 1
        let isPatted = patted.contains(place.context)
        let state: Verdict.State = inMeeting ? .meeting : (isPatted ? .working : place.judged)
        var thread = state == .working ? place.thread : nil
        let isNewThread = thread.map { !namedThreads.contains($0.id) } ?? false
        if let named = thread {
            if isNewThread {
                thread = ThreadRef(id: named.id, title: "Code · \(place.window?.title ?? place.app.name)", provisional: true)
            }
            namedThreads.insert(named.id)
        }
        let verdict = Verdict(sampleId: "s\(samples)", state: state, thread: thread, isNewThread: isNewThread,
                              confidence: 0.9, source: isPatted ? .override : .jev,
                              reason: "scripted", latencyMs: Self.judgeLatencySec * 1000, completion: completion)
        completion = nil
        verdictsDue.append((second + Self.judgeLatencySec, verdict, place.context))
    }
}
