import Foundation
import MokuKit

/// One screen of the QA catalogue (scripts/qa-screens.py): what the sense layer would hand the brain for one window.
struct QAScreen: Decodable {
    var id: String
    var app: String
    var bundle: String
    var title: String
    var url: String?
    var text: String
    var truth: String
    var who: [String]
    var note: String?
    var task: String?
    var bucket: String?
}

enum Catalog {
    static func load(_ path: String) throws -> [String: QAScreen] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let list = try JSONDecoder().decode([QAScreen].self, from: data)
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }
}

/// What a person would say they were doing: the ground truth the engine is measured against.
enum Truth: String, Codable, Sendable {
    case work, drift, meeting
    /// Dictating: work, with the mic live and the hands still.
    case dictation
    /// A tea break the person asked for.
    case teaBreak
    /// Away from the desk: lunch, the screen locked, the Mac asleep.
    case away
    /// A utility (Finder, Preview, Wispr Flow): neither.
    case neutral

    /// Time where Moku must never react to a drift.
    var isNotADrift: Bool { self != .drift }
    var isWork: Bool { self == .work || self == .dictation }
}

/// How the hands move on a screen: keys, clicks, scrolls, and how long the last input was ago.
enum Profile: Sendable {
    /// Writing or coding: keys most seconds.
    case typing
    /// Editing, clicking around, now and then typing.
    case editing
    /// Reading a page: a scroll every ~20 s.
    case reading
    /// Browsing: clicks and scrolls every few seconds.
    case browsing
    /// Watching a video: no input at all, and the page's clock ticks (the words change every sample).
    case watching
    /// Listening to a lecture or a meeting with slides: no input, and the words change only with a slide (every ~90 s).
    case slides
    /// Dictating: the hands still, a key held or a paste every 25 to 45 s.
    case dictating
    /// Away from the desk: no input.
    case still

    /// Seconds between inputs on average; nil: none.
    var inputEverySec: Double? {
        switch self {
        case .typing: 1.4
        case .editing: 4
        case .reading: 20
        case .browsing: 6
        case .dictating: 35
        case .watching, .slides, .still: nil
        }
    }

    var keysPerMinute: Int {
        switch self {
        case .typing: 160
        case .editing: 30
        case .dictating: 4
        default: 0
        }
    }

    var clicksPerMinute: Int {
        switch self {
        case .editing: 8
        case .browsing: 10
        case .typing: 2
        default: 0
        }
    }

    var scrollsPerMinute: Int {
        switch self {
        case .reading: 3
        case .browsing: 8
        default: 0
        }
    }

    /// How often the words on screen change (seconds); nil: they don't.
    var textChangesEverySec: Double? {
        switch self {
        case .typing: 3
        case .editing: 9
        case .reading: 9
        case .browsing: 6
        case .watching: 3
        case .slides: 90
        case .dictating: 9
        case .still: nil
        }
    }
}

enum CallState: Sendable, Equatable {
    case none
    /// In a call: the mic is live, and the camera too if `camera`.
    case on(camera: Bool)
    /// A call whose mic and camera drop out now and then (a muted Meet tab): `offSec` of every `periodSec` the sense layer
    /// sees no live mic or camera, so it reports no call.
    case flapping(periodSec: Double, offSec: Double)
    /// Sharing the screen.
    case sharing
    /// Dictating: the mic is live, but it's no call.
    case dictating
}

/// A thing that happens at the start of a beat besides switching screens.
enum BeatInput: Sendable {
    case startBreak
    case endBreak
    case pat
    /// The model goes away (`down`), comes back (`up`) or fails every other call (`flap`).
    case network(String)
    /// The relay's forceCalm switch.
    case forceCalm(Bool)
}

/// One stretch of a session: where the person is, for how long, and what they are really doing.
struct Beat: Sendable {
    var screen: String
    var seconds: Double
    var profile: Profile
    var truth: Truth?
    var call: CallState = .none
    var inputs: [BeatInput] = []
    /// What happens when the beat ends ("Back to work" on a tea break).
    var endInputs: [BeatInput] = []
    /// The lid is closed: Moku isn't running (no ticks, no samples).
    var asleep = false
    /// Switching between screens many times a minute (a stress test): the beat's screen is only where it starts.
    var storm: Storm?
    var note: String = ""
}

struct Storm: Sendable {
    var perMinute: Double
    var among: [String]
}

/// Beats in order, plus where and when the session happens.
struct Session: Sendable {
    var name: String
    var summary: String
    /// Local day, YYYY-MM-DD, and the time the first beat starts, "HH:mm".
    var date: String
    var start: String
    var beats: [Beat]
    /// Replaces the served config's fields for this session (a name, timings).
    var userName = "Charles"
}

// MARK: Writing sessions

/// A small vocabulary for writing sessions down.
enum B {
    static func min(_ m: Double) -> Double { m * 60 }

    static func work(_ screen: String, _ minutes: Double, _ profile: Profile = .typing, truth: Truth? = nil, note: String = "") -> Beat {
        Beat(screen: screen, seconds: minutes * 60, profile: profile, truth: truth, note: note)
    }

    /// A glance: a few seconds on a screen.
    static func glance(_ screen: String, _ seconds: Double, _ profile: Profile = .browsing, truth: Truth? = nil) -> Beat {
        Beat(screen: screen, seconds: seconds, profile: profile, truth: truth)
    }

    static func drift(_ screen: String, _ minutes: Double, _ profile: Profile = .browsing) -> Beat {
        Beat(screen: screen, seconds: minutes * 60, profile: profile, truth: .drift)
    }

    static func call(_ screen: String, _ minutes: Double, camera: Bool = true, profile: Profile = .watching) -> Beat {
        Beat(screen: screen, seconds: minutes * 60, profile: profile, truth: .meeting, call: .on(camera: camera))
    }

    static func share(_ screen: String, _ minutes: Double) -> Beat {
        Beat(screen: screen, seconds: minutes * 60, profile: .editing, truth: .meeting, call: .sharing)
    }

    static func dictate(_ screen: String, _ minutes: Double) -> Beat {
        Beat(screen: screen, seconds: minutes * 60, profile: .dictating, truth: .dictation, call: .dictating)
    }

    /// The screen is locked (lunch).
    static func lock(_ minutes: Double) -> Beat {
        Beat(screen: "u-login", seconds: minutes * 60, profile: .still, truth: .away)
    }

    /// Away from the desk with the screen left on.
    static func awayAt(_ screen: String, _ minutes: Double) -> Beat {
        Beat(screen: screen, seconds: minutes * 60, profile: .still, truth: .away)
    }

    /// The lid is closed: nothing runs.
    static func sleep(_ minutes: Double, on screen: String = "u-login") -> Beat {
        Beat(screen: screen, seconds: minutes * 60, profile: .still, truth: .away, asleep: true)
    }

    /// "Taking a break" in the dropdown, for `minutes` away from the desk; `button` ends it with "Back to work".
    static func teaBreak(on screen: String, _ minutes: Double, button: Bool = true) -> Beat {
        Beat(screen: screen, seconds: minutes * 60, profile: .still, truth: .teaBreak, inputs: [.startBreak],
             endInputs: button ? [.endBreak] : [], note: button ? "ends with Back to work" : "ends by itself")
    }
}
