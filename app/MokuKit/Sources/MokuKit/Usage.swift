import Foundation

/// One property of a usage event (docs/specs/usage-analytics.md): a yes or no, a whole number, or a code word from a
/// fixed list. Never free text: MokuMind's `UsageEvents` drops any word that isn't on the event's list, and the relay
/// checks every value again.
public enum UsageValue: Sendable, Equatable, Codable {
    case bool(Bool)
    case int(Int)
    /// A code word ("menubar", "started") or a version ("0.1.8"); never a name, a title or anything typed.
    case word(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) { self = .bool(bool) }
        else if let int = try? container.decode(Int.self) { self = .int(int) }
        else { self = .word(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .bool(bool): try container.encode(bool)
        case let .int(int): try container.encode(int)
        case let .word(word): try container.encode(word)
        }
    }
}

/// Records one usage event: its name and its properties. The app fills it with `UsageEvents.track`; the runtime, the
/// world presenter, Settings and the welcome only call it.
public typealias UsageTracker = @MainActor (_ event: String, _ properties: [String: UsageValue]) -> Void

/// Something counted into the day's summary (`day_summary`) rather than sent on its own: it happens often, or only its
/// number matters. Numbers and fixed kinds only, like every usage event.
public enum UsageCount: Sendable, Equatable {
    /// The pointer rested on the companion and it noticed.
    case hover
    /// The companion was picked up and carried, or thrown onto an edge of the screen.
    case drag, toss
    /// A plain click on the companion.
    case companionClick
    /// The popover opened and closed again within a second.
    case popoverBlink
    /// One of the companion's talents played.
    case talent(UsageTalent)
    /// Moku had a sip of water while you worked: the water reminder, by example.
    case waterReminder
    /// A minute with the person at the Mac (not away, not on a break).
    case activeMinute
    /// One judgment from the brain, by what it said.
    case verdict(UsageVerdict)
    /// How long the brain took to answer a judgment, and how long Jev and Luna took when they were asked (milliseconds).
    case brainAnswer(ms: Int), jevAnswer(ms: Int), lunaAnswer(ms: Int)
    /// The main thread was busy for more than a quarter of a second at a time.
    case stall
    /// Frames the companion missed while one of its moves played.
    case framesDropped(Int)
    /// How much memory Moku used and how much of a CPU core, at one of its samples.
    case resources(memoryMB: Int, corePermille: Int)
    /// Today's numbers as the brain last gave them (the latest wins).
    case today(focusedMinutes: Int, returns: Int, longestMinutes: Int)
}

/// The companions' little moments people may or may not get to see.
public enum UsageTalent: String, Sendable, CaseIterable {
    /// Tetsu reads the screen with its beam; Tetsu projects a hologram of a new rocket piece; Moku's petals on a comeback;
    /// a sniff at a window new to the companion.
    case scan, hologram, petals, sniff
}

/// What a judgment said, in four words: work, a switch to another goal, a drift, or not sure (away, a meeting, unknown).
public enum UsageVerdict: String, Sendable, CaseIterable {
    case work, switched, drift, unknown
}

/// Adds one thing to the day's summary. The app fills it with `UsageEvents.count`.
public typealias UsageCounter = @MainActor (_ count: UsageCount) -> Void
