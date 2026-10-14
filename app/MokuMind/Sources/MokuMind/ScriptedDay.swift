import CoreGraphics
import Foundation
import MokuKit

/// A day of work written as moments: where the user goes and what they do. `ScriptedInputs` turns it
/// into the inputs the runtime would produce (focus changes, samples judged by a scripted brain, cursor
/// movement, world refreshes). The simulator replays it, and manual control plays scenes built from it.
public struct ScriptedDay: Sendable {
    public var config: CompanionConfig
    /// Forest points before the day starts.
    public var startPoints: Double
    public var moments: [Moment]
    public var endSec: Double

    public init(config: CompanionConfig, startPoints: Double, moments: [Moment], endSec: Double) {
        self.config = config
        self.startPoints = startPoints
        self.moments = moments
        self.endSec = endSec
    }

    public struct Moment: Sendable {
        public var at: Double
        public var note: String
        public var action: Action

        public init(at minutes: Double, _ note: String, _ action: Action) {
            self.init(atSecond: (minutes * 60).rounded(), note, action)
        }

        public init(atSecond second: Double, _ note: String, _ action: Action) {
            self.at = second
            self.note = note
            self.action = action
        }
    }

    public enum Action: Sendable {
        /// Switch to a place; samples come from it until the next switch.
        case use(Place)
        case meetingStarts(Place)
        case meetingEnds(returningTo: Place)
        case pat
        case click
        /// "Taking a break" in the dropdown, then away from the desk (the cursor stops) until the next `use`.
        case takeBreak
        /// Something finishes on screen: the next verdict for the current place carries it, and the user
        /// sits back for a few seconds (the cursor goes still).
        case complete(Completion)
    }

    /// Somewhere the user can be, and how the scripted brain judges it.
    public struct Place: Sendable {
        public var app: AppInfo
        public var window: WindowInfo?
        public var judged: Verdict.State
        public var thread: ThreadRef?
        /// Where the cursor hangs out in this window.
        public var cursor: CGPoint

        public init(app: AppInfo, window: WindowInfo?, judged: Verdict.State, thread: ThreadRef?, cursor: CGPoint) {
            self.app = app
            self.window = window
            self.judged = judged
            self.thread = thread
            self.cursor = cursor
        }

        public var context: WorkContext { WorkContext(app: app, window: window) }
        /// "twitter.com" for sites, the app name otherwise.
        public var label: String { context.host ?? app.name }
    }
}

extension ScriptedDay {
    static let authThread = ThreadRef(id: "t-auth", title: "Auth · Login flow")
    static let xcode = AppInfo(bundleId: "com.apple.dt.Xcode", name: "Xcode")
    static let safari = AppInfo(bundleId: "com.apple.Safari", name: "Safari")
    static let zoom = AppInfo(bundleId: "us.zoom.xos", name: "zoom.us")

    public static let editor = Place(app: xcode, window: WindowInfo(title: "LoginView.swift", url: nil),
                                     judged: .working, thread: authThread, cursor: CGPoint(x: 620, y: 480))
    public static let twitter = Place(app: safari, window: WindowInfo(title: "Home / X", url: "https://x.com/home"),
                                      judged: .drifting, thread: nil, cursor: CGPoint(x: 1180, y: 610))
    public static let youtube = Place(app: safari,
                                      window: WindowInfo(title: "Lo-fi beats to relax to - YouTube",
                                                         url: "https://www.youtube.com/watch?v=jfKfPfyJRdk"),
                                      judged: .drifting, thread: nil, cursor: CGPoint(x: 1240, y: 560))
    public static let reddit = Place(app: safari,
                                     window: WindowInfo(title: "r/swift", url: "https://www.reddit.com/r/swift/"),
                                     judged: .drifting, thread: nil, cursor: CGPoint(x: 1100, y: 640))
    public static let standup = Place(app: zoom, window: WindowInfo(title: "Zoom Meeting", url: nil),
                                      judged: .meeting, thread: nil, cursor: CGPoint(x: 900, y: 500))

    /// The day in the Mind brief, with v1: focus with a smile, a short drift and a small return with a
    /// growth bonus, a long drift through every step of the ladder and a full return, a finished push
    /// celebrated when the typing stops, a break suggestion, a meeting that hides and freezes everything,
    /// a pat during a drift, a forest milestone, and a tea break that brings Moku's celebration of it.
    public static let standard = ScriptedDay(
        config: .standard,
        startPoints: 242,
        moments: [
            Moment(at: 0, "Opens Xcode and starts on the login flow", .use(editor)),
            Moment(at: 16, "Checks X", .use(twitter)),
            Moment(at: 17.5, "Back to Xcode after a minute and a half", .use(editor)),
            Moment(at: 30, "Puts on a YouTube video", .use(youtube)),
            Moment(at: 48, "Back to Xcode", .use(editor)),
            Moment(at: 60, "Pushes the login flow", .complete(Completion(kind: .codePushed, label: "pushed login-flow"))),
            Moment(at: 70, "Joins the standup on Zoom", .meetingStarts(standup)),
            Moment(at: 80, "Standup ends, back to Xcode", .meetingEnds(returningTo: editor)),
            Moment(at: 84, "Opens r/swift", .use(reddit)),
            Moment(at: 86.5, "Pats Moku: this is research", .pat),
            Moment(at: 88, "Back to Xcode", .use(editor)),
            Moment(at: 90, "Takes a tea break", .takeBreak),
            Moment(at: 95, "Back from tea, into Xcode", .use(editor)),
        ],
        endSec: 96 * 60
    )
}
