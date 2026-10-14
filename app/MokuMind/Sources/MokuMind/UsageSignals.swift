import Foundation
import MokuKit

/// What the events going by say together (docs/specs/next-0-1-9.md §2), worked out on the Mac from the events and counts
/// themselves, so nothing new is watched:
/// - **Trying again:** the same action again within 30 s (`repeat` {action, count}), sent once the burst is over: a second
///   Take me there, a setting changed again, Your day or a break or hiding done twice, the popover opened and shut at once
///   twice.
/// - **Frustration** (`frustration` {signal}): three or more clicks on the companion within 2 s; hiding it within 2 minutes
///   of a nudge (a drift step); "this was work" or a pat within 10 minutes of one (Moku was wrong); the person quitting
///   (not a relaunch, an update or a logout) within 2 minutes of one. ("Delete my data" is sent by Settings itself.)
struct UsageSignals {
    /// One event or more to send because of what just happened, and when it happened.
    struct Follow: Equatable {
        var name: String
        var props: [String: UsageValue]
        var at: Date
    }

    static let repeatWithinSec: TimeInterval = 30
    static let rapidClicks = 3, rapidClicksWithinSec: TimeInterval = 2
    static let hideAfterNudgeSec: TimeInterval = 120, quitAfterNudgeSec: TimeInterval = 120, workAfterNudgeSec: TimeInterval = 600

    /// Bursts of the same action under way: the action's word, how many so far, and the last one.
    private var bursts: [String: (action: String, count: Int, last: Date)] = [:]
    private var clicks: [Date] = []
    private var clickBurstSent = false
    private var lastNudge: Date?

    /// An event that just went by. (Bursts already over go first: `due`.)
    mutating func observe(_ name: String, _ props: [String: UsageValue], at time: Date) -> [Follow] {
        var follows: [Follow] = []
        func word(_ key: String) -> String? { if case let .word(word)? = props[key] { word } else { nil } }
        switch name {
        case "drift_step" where word("step") != nil: lastNudge = time
        case "setting_changed": follows += again("setting", key: "setting:\(word("key") ?? "")", at: time)
        case "day_opened": follows += again("day_open", key: "day_open", at: time)
        case "popover_action" where word("action") == "hide" || word("action") == "show":
            follows += again("hide", key: "hide", at: time)
        case "hidden" where word("by") == "person":  // every way to hide (popover, menu, Settings) ends here: one signal
            follows += afterNudge("hide_after_nudge", within: Self.hideAfterNudgeSec, at: time)
        case "break" where word("what") == "started" || word("what") == "cancelled": follows += again("break", key: "break", at: time)
        case "correction" where word("kind") == "marked_work" || word("kind") == "pat":
            follows += afterNudge("work_after_nudge", within: Self.workAfterNudgeSec, at: time)
        // Only the person's quit (Moku's menus, or `other`: the Dock's Quit): a relaunch, an update, a logout or a signal
        // is Moku's doing or the Mac's.
        case "app_quit" where word("how") == "menu" || word("how") == "other": follows += afterNudge("quit_after_nudge", within: Self.quitAfterNudgeSec, at: time)
        default: break
        }
        return follows
    }

    /// A count that just went in: clicks on the companion (three quick ones is frustration), and a popover opened and shut
    /// at once (twice is trying again).
    mutating func count(_ count: UsageCount, at time: Date) -> [Follow] {
        var follows: [Follow] = []
        switch count {
        case .companionClick:
            clicks = clicks.filter { time.timeIntervalSince($0) <= Self.rapidClicksWithinSec } + [time]
            if clicks.count == 1 { clickBurstSent = false }
            if clicks.count >= Self.rapidClicks && !clickBurstSent {
                clickBurstSent = true
                follows.append(Follow(name: "frustration", props: ["signal": .word("rapid_clicks")], at: time))
            }
        case .popoverBlink: follows += again("popover_blink", key: "popover_blink", at: time)
        default: break
        }
        return follows
    }

    /// The bursts that are over by `time` (nothing again for 30 s), as `repeat`; `all` ends every one (Moku is quitting).
    mutating func due(at time: Date, all: Bool = false) -> [Follow] {
        var follows: [Follow] = []
        for (key, burst) in bursts where all || time.timeIntervalSince(burst.last) > Self.repeatWithinSec {
            bursts[key] = nil
            if burst.count >= 2 { follows.append(Follow(name: "repeat", props: ["action": .word(burst.action), "count": .int(burst.count)], at: burst.last)) }
        }
        return follows.sorted { $0.at < $1.at }
    }

    private mutating func again(_ action: String, key: String, at time: Date) -> [Follow] {
        if let burst = bursts[key], time.timeIntervalSince(burst.last) <= Self.repeatWithinSec {
            bursts[key] = (action, burst.count + 1, time)
        } else {
            bursts[key] = (action, 1, time)
        }
        return []
    }

    private func afterNudge(_ signal: String, within seconds: TimeInterval, at time: Date) -> [Follow] {
        guard let lastNudge, time.timeIntervalSince(lastNudge) <= seconds else { return [] }
        return [Follow(name: "frustration", props: ["signal": .word(signal)], at: time)]
    }
}
