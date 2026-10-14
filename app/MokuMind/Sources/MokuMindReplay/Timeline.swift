import Foundation
import MokuKit
import MokuMind

/// Turns a replayed day into a readable timeline, e.g.
/// `t=35:01  say "Hey, weren't we working on the auth flow?" (gentle)`.
/// Cursor-following gaze updates and Luna replies are left out; runs of focus growth are folded into one line.
public enum Timeline {
    public static func lines(_ record: DayRecord) -> [String] {
        var printer = Printer()
        for entry in record.entries {
            switch entry.kind {
            case let .note(note): printer.line(entry.t, "> \(note)")
            case let .input(input): printer.input(input, t: entry.t)
            case let .effect(effect): printer.effect(effect, t: entry.t)
            }
        }
        printer.flushGrowth()
        let stage = ForestStage.at(points: record.endPoints)
        printer.output.append("")
        printer.output.append("Forest: \(points(record.startPoints)) -> \(points(record.endPoints)) points (\(stage))")
        if let status = record.finalStatus {
            printer.output.append("Moku ends the day \(status.phase.rawValue), \(status.mood), \(status.atHome ? "at home" : "away from home").")
        }
        return printer.output
    }

    /// "05:00" for five minutes in, "95:30" past the hour.
    public static func clock(_ t: Double) -> String {
        let seconds = Int(t.rounded())
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    static func points(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private struct Printer {
        var output: [String] = []
        var lastVerdict: Verdict.State?
        var growth: (count: Int, points: Double, t: Double, threadId: String?)?

        mutating func line(_ t: Double, _ text: String) {
            flushGrowth()
            output.append("t=\(Timeline.clock(t))  \(text)")
        }

        mutating func flushGrowth() {
            guard let run = growth else { return }
            growth = nil
            let thread = run.threadId.map { ", \($0)" } ?? ""
            output.append("t=\(Timeline.clock(run.t))  event focusGrowth x\(run.count) (+\(Timeline.points(run.points)) pts\(thread))")
        }

        mutating func input(_ input: EngineInput, t: Double) {
            switch input {
            case let .verdict(verdict, context, _):
                guard verdict.state != lastVerdict else { return }
                lastVerdict = verdict.state
                let place = context?.host.map { " (\($0))" } ?? ""
                line(t, "judge: \(verdict.state.rawValue)\(place)")
            case .pat: line(t, "< pat on the head")
            case let .correct(isWork): line(t, isWork ? "< \"This is work\"" : "< \"This isn't work\"")
            case .click: line(t, "< click")
            case let .meeting(context):
                line(t, context.inCall || context.sharingScreen ? "< meeting started" : "< meeting ended")
            case .startBreak: line(t, "< taking a break")
            case .endBreak: line(t, "< back to work")
            case .focusChanged, .attention, .voiceReady, .config, .world:
                break
            }
        }

        mutating func effect(_ effect: EngineEffect, t: Double) {
            switch effect {
            case let .character(command):
                if let text = describe(command) { line(t, text) }
            case let .requestVoice(request):
                line(t, "prefetch \(request.kind.rawValue) line")
            case let .event(event):
                if event.type == .focusGrowth {
                    let value = event.value ?? 0
                    if let run = growth, run.threadId == event.threadId {
                        growth = (run.count + 1, run.points + value, t, run.threadId)
                    } else {
                        flushGrowth()
                        growth = (1, value, t, event.threadId)
                    }
                } else {
                    line(t, "event \(event.type.rawValue)\(describeValue(of: event))")
                }
            case let .feedback(feedback):
                line(t, "feedback \(feedback.kind.rawValue)")
            case .openWorld:
                line(t, "open world")
            case let .celebrateStage(stage):
                line(t, "celebrate \(stage) on the menu bar")
            case let .setOnBreak(on):
                line(t, on ? "break button: back to work" : "break button: taking a break")
            }
        }

        func describe(_ command: CharacterCommand) -> String? {
            switch command {
            case let .setMood(mood): "mood \(mood.rawValue)"
            case .setAttention(.user): "look at the user"
            case .setAttention(.wander): "look around"
            case .setAttention(.point): nil  // eyes following the cursor: too frequent to print
            case let .perform(gesture): "perform \(gesture.rawValue)"
            case .move(.home): "walk home"
            case .move(.center): "walk to the center of the screen"
            case let .move(.near(point)): "walk near (\(Int(point.x)), \(Int(point.y)))"
            case let .say(line): "say \"\(line.text)\" (\(line.tone.rawValue))"
            case .think: "think"
            case .dismissSpeech: "dismiss speech"
            case let .setHidden(hidden): hidden ? "hide" : "show"
            case let .setWorkState(state): "lantern: \(state.rawValue)"
            case let .celebrateReturn(size): "celebrate the return (\(size.rawValue))"
            case let .breakTimer(until, total): until == nil ? "break timer off" : "break timer \(Int(total / 60)) min"
            }
        }

        func describeValue(of event: CompanionEvent) -> String {
            guard let value = event.value else { return "" }
            switch event.type {
            case .returnGrowth: return " (+\(Timeline.points(value)) pts)"
            case .milestone: return " (\(ForestStage(rawValue: Int(value)).map { "\($0)" } ?? "stage \(Int(value))"))"
            case .breakEnded: return " (\(Timeline.clock(value)) on break)"
            case .returned: return " (after \(Timeline.clock(value)))"
            default: return " (\(Timeline.clock(value)) drifting)"
            }
        }
    }
}
