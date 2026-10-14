import CoreGraphics
import Foundation
import MokuKit
import MokuMind

/// Everything that happened in a replayed day, in order.
public struct DayRecord: Sendable {
    public struct Entry: Sendable {
        public var t: Double
        public var kind: Kind
    }

    public enum Kind: Sendable {
        case note(String)
        case input(EngineInput)
        case effect(EngineEffect)
    }

    public var entries: [Entry] = []
    public var startPoints: Double
    public var endPoints: Double
    public var finalStatus: BehaviorEngine.Status?

    /// Every effect with its time, in order.
    public var effects: [(t: Double, effect: EngineEffect)] {
        entries.compactMap { entry in
            if case let .effect(effect) = entry.kind { return (entry.t, effect) }
            return nil
        }
    }

    public func effects(from start: Double, to end: Double) -> [EngineEffect] {
        effects.filter { $0.t >= start && $0.t <= end }.map(\.effect)
    }

    public func events(_ type: CompanionEventType) -> [(t: Double, event: CompanionEvent)] {
        effects.compactMap { item in
            if case let .event(event) = item.effect, event.type == type { return (item.t, event) }
            return nil
        }
    }

    /// When the first effect matching `predicate` happened.
    public func firstTime(where predicate: (EngineEffect) -> Bool) -> Double? {
        effects.first { predicate($0.effect) }?.t
    }
}

/// Runs a `ScriptedDay` through a `BehaviorEngine` second by second, standing in for the runtime:
/// `ScriptedInputs` supplies focus changes, judged samples, the cursor and world refreshes, and a
/// stand-in Luna answers voice requests after 2 s.
public enum DayReplay {
    public static let lunaLatencySec = 2
    public static let base = Date(timeIntervalSince1970: 1_790_000_000)

    public static func run(_ script: ScriptedDay = .standard, tuning: EngineTuning = .standard, seed: UInt64 = 1) -> DayRecord {
        var engine = BehaviorEngine(config: script.config, tuning: tuning, random: MokuRandom(seed: seed))
        var inputs = ScriptedInputs(script)
        var record = DayRecord(startPoints: script.startPoints, endPoints: script.startPoints)
        var linesDue: [(due: Int, kind: VoiceKind, line: VoiceLine)] = []

        func apply(_ effects: [EngineEffect], at second: Int) {
            inputs.observe(effects, at: second)
            for effect in effects {
                record.entries.append(.init(t: Double(second), kind: .effect(effect)))
                if case let .requestVoice(request) = effect {
                    linesDue.append((second + lunaLatencySec, request.kind, ScriptedLuna.line(for: request)))
                }
            }
        }

        func feed(_ input: EngineInput, at second: Int) {
            record.entries.append(.init(t: Double(second), kind: .input(input)))
            apply(engine.handle(input, now: base.addingTimeInterval(Double(second))), at: second)
        }

        for second in 0...inputs.lastSecond {
            for item in inputs.items(at: second) {
                switch item {
                case let .note(note): record.entries.append(.init(t: Double(second), kind: .note(note)))
                case let .input(input): feed(input, at: second)
                }
            }
            for due in linesDue where due.due <= second { feed(.voiceReady(due.kind, due.line), at: second) }
            linesDue.removeAll { $0.due <= second }
            apply(engine.tick(now: base.addingTimeInterval(Double(second))), at: second)
        }
        record.endPoints = inputs.points
        record.finalStatus = engine.status
        return record
    }
}

/// Stand-in for Luna: plausible lines in Moku's voice.
enum ScriptedLuna {
    static func line(for request: VoiceRequest) -> VoiceLine {
        let name = request.userName
        let text: String = switch request.kind {
        case .nudge: "Hey, weren't we working on the auth flow?"
        case .callName: "\(name)."
        case .remindFocus: "You were focused for \(request.focusMinutes ?? 0) minutes."
        case .comeOn: "Come on, let's finish the login screen first."
        case .welcomeBack: "There you are. The login flow missed you."
        case .celebrate: request.completionLabel.map { "That's it: \($0). Lovely." } ?? "Look! Our little tree is growing."
        case .proud: "What a stretch. I'm proud of us."
        case .water: "Sip of water? You've been at it a while."
        case .stretch: "Stretch those shoulders with me?"
        case .lookAway: "Look out the window for twenty seconds."
        case .walk: "Short walk? I'll keep your spot."
        case .greeting: "Morning, \(name)!"
        }
        return VoiceLine(text: text, source: "luna")
    }
}
