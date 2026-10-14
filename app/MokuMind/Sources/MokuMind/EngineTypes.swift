import CoreGraphics
import Foundation
import MokuKit

/// Everything the behavior engine reacts to. The runtime turns sense events, brain replies and
/// stage callbacks into these.
public enum EngineInput: Sendable, Equatable {
    /// The brain's judgment of one sample. `context` is where that sample was taken. When it no longer
    /// matches the focused app, the verdict only updates what Moku remembers about that place.
    /// Nil means "the current focus". `window` is the window the sample was taken of: what "Where was I?" names when the
    /// verdict says work (nil: the window in front).
    case verdict(Verdict, context: WorkContext? = nil, window: WindowInfo? = nil)
    /// The frontmost app or its focused window changed (sent immediately, before any judgment).
    case focusChanged(AppInfo, WindowInfo?)
    /// Where the user is working right now (cursor or caret), AppKit global coordinates.
    case attention(CGPoint)
    case meeting(MeetingContext)
    /// A stroke across Moku's head: "this is fine".
    case pat
    /// The companion's right-click: "This is work" in a drift (`true`), "This isn't work" while working (`false`).
    case correct(isWork: Bool)
    /// A plain click on Moku.
    case click
    /// A line the engine asked for with `.requestVoice` is ready.
    case voiceReady(VoiceKind, VoiceLine)
    case config(CompanionConfig)
    case world(WorldSnapshot)
    /// "Taking a break" in the world dropdown.
    case startBreak
    /// "Back to work" on the same button: the break ends as a return.
    case endBreak
}

/// One call on `CharacterStage`, as data.
public enum CharacterCommand: Sendable, Equatable {
    case setMood(Mood)
    case setAttention(AttentionTarget)
    case perform(Gesture)
    /// Asynchronous on the stage: later commands wait until Moku arrives.
    case move(StageSpot)
    case say(SpeechLine)
    /// A thinking bubble while Luna writes the line that's coming (a celebration's).
    case think
    case dismissSpeech
    case setHidden(Bool)
    /// The lantern and the gaze mode: sent on every change.
    case setWorkState(WorkState)
    /// The return: light and body, never words.
    case celebrateReturn(ReturnSize)
    /// A break's countdown over Moku's head (nil: none).
    case breakTimer(until: Date?, total: TimeInterval)
}

/// What the engine asks the runtime to do.
public enum EngineEffect: Sendable, Equatable {
    case character(CharacterCommand)
    /// Ask the brain for a line ahead of time. The reply comes back as `.voiceReady`.
    case requestVoice(VoiceRequest)
    case event(CompanionEvent)
    case feedback(Feedback)
    case openWorld
    case celebrateStage(ForestStage)
    /// A break started or ended: the dropdown's button, and the app stops watching for the length of it.
    case setOnBreak(Bool)
}

/// Where a sample was taken, at the granularity Moku remembers judgments: the app, plus the site's host
/// when the app is a browser. Window titles are ignored because editors and players change them constantly.
public struct WorkContext: Hashable, Sendable {
    public var bundleId: String
    public var host: String?

    public init(bundleId: String, host: String? = nil) {
        self.bundleId = bundleId
        self.host = host
    }

    public init(app: AppInfo, window: WindowInfo?) {
        self.init(bundleId: app.bundleId, host: window?.url.flatMap(WorkContext.host(of:)))
    }

    static func host(of url: String) -> String? {
        guard let host = URL(string: url)?.host(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Local pacing that isn't worth serving from `/v1/config`: how long gestures, gazes and blips last,
/// how often the eyes update, and small memory limits. Every behavior timing lives in `CompanionConfig`.
public struct EngineTuning: Sendable, Equatable {
    /// Attention pass-through is throttled to one update per this interval (0.2 s = 5 per second).
    public var attentionIntervalSec: Double
    /// How long the happy blip lasts after a short return or a pat.
    public var blipSec: Double
    /// How long Moku looks at the user while it speaks (nudge, welcome back, breaks, milestones).
    public var speakingHoldSec: Double
    /// Break lines are requested this long before they are due.
    public var breakPrefetchLeadSec: Double
    /// A milestone waits this long for Luna's line before using a built-in one.
    public var voiceWaitSec: Double
    /// How many places Moku remembers judgments for (fast return detection).
    public var contextMemoryLimit: Int
    /// A queued completion celebration plays once the cursor and caret have been still this long.
    public var calmAfterQuietSec: Double
    /// During a tea break, the cursor moving at least this long after the break started means the user is
    /// back at the desk, so a working verdict ends the break. (Moving the mouse to click the button doesn't count.)
    public var backAtDeskAfterSec: Double
    /// The same completion reported again within this long is not celebrated twice.
    public var completionRepeatSec: Double
    /// A window counts as new to Moku (it sniffs it) when it hasn't been in front for this long.
    public var sniffNewAfterSec: Double
    /// At most one sniff in this long.
    public var sniffGapSec: Double
    /// A neutral app (Finder, Preview, a system screen) in front keeps crediting the focus before it for this long at most:
    /// reading a PDF is work, an hour of tidying files is not worth the whole hour.
    public var neutralHoldSec: Double

    public init(attentionIntervalSec: Double = 0.2, blipSec: Double = 3,
                speakingHoldSec: Double = 6, breakPrefetchLeadSec: Double = 60, voiceWaitSec: Double = 5,
                contextMemoryLimit: Int = 256, calmAfterQuietSec: Double = 5,
                backAtDeskAfterSec: Double = 10, completionRepeatSec: Double = 600,
                sniffNewAfterSec: Double = 600, sniffGapSec: Double = 60, neutralHoldSec: Double = 1_800) {
        self.attentionIntervalSec = attentionIntervalSec
        self.blipSec = blipSec
        self.speakingHoldSec = speakingHoldSec
        self.breakPrefetchLeadSec = breakPrefetchLeadSec
        self.voiceWaitSec = voiceWaitSec
        self.contextMemoryLimit = contextMemoryLimit
        self.calmAfterQuietSec = calmAfterQuietSec
        self.backAtDeskAfterSec = backAtDeskAfterSec
        self.completionRepeatSec = completionRepeatSec
        self.sniffNewAfterSec = sniffNewAfterSec
        self.sniffGapSec = sniffGapSec
        self.neutralHoldSec = neutralHoldSec
    }

    public static let standard = EngineTuning()
}
