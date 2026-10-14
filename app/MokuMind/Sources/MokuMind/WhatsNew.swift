import Foundation
import MokuKit

/// "What's new" after an update (docs/specs/next-0-1-9.md §1). Sparkle installs updates quietly while the person is away,
/// so they never learn what changed. After an update, at the first calm moment, the companion says so in its own bubble
/// (Moku: "I updated! See what's new"; Tetsu: "> updated: see what's new"). A click opens that version on
/// hellomoku.com/changelog, which the website writes from CHANGELOG.md; ✕ or 15 s closes it. Once per version, and never
/// after a fresh install. Nothing new leaves the Mac: the words are built in, and the page is the website's.
///
/// The first calm moment (`BehaviorEngine.isCalmForNews`): a comeback from a drift or the end of a break, once Moku's own
/// line there is over, or from 2 minutes after Moku started watching (the launch, or the welcome's end) while the person is
/// at the Mac. Never in a meeting or a call, a break, a drift, away, the welcome, or the first 5 minutes of a focus streak;
/// never mid-typing, and never over another bubble, the popover or the day's card.
public enum WhatsNew {
    /// What Moku says. Tetsu's display lays it out its own way (MokuVisual's `WhatsNewLook`).
    public static let words = "I updated! See what’s new"
    /// The bubble stays up this long, unless it's clicked or closed first.
    public static let bubbleSec: TimeInterval = 15
    /// The website's changelog, one anchor per version.
    public static let changelog = URL(string: "https://hellomoku.com/changelog")!

    /// The changelog at `version`: https://hellomoku.com/changelog#0.1.9.
    public static func link(version: String) -> URL {
        var components = URLComponents(url: changelog, resolvingAgainstBaseURL: false)!
        components.fragment = version
        return components.url ?? changelog
    }

    // MARK: When

    /// Moku watches this long (since launch, or since the welcome closed) before it says it unprompted.
    static let afterWatchingSec: Double = 120
    /// The first minutes of a focus streak are for settling into the work: not then, unless it's a comeback or a break's end.
    static let settlingIntoFocusSec: Double = 300
    /// A comeback or a break's end stays a calm moment this long, so Moku's own line there can finish first.
    static let afterWelcomeBackSec: Double = 60
    /// At the Mac: the pointer or the caret moved within this long.
    static let presentWithinSec: Double = 60

    // MARK: Once per version (the app's UserDefaults)

    static let pendingKey = "Moku.whatsNewPending"
    static let toldKey = "Moku.whatsNewTold"

    /// After this launch: the version whose news is still to be told, if any. An update makes it this version (unless it
    /// was told already: an update back to it); a fresh install never does. What an earlier launch of this version left
    /// untold (the person quit before a calm moment) carries over; an older version's is dropped.
    public static func pending(version: String, updated: Bool, defaults: UserDefaults = .standard) -> String? {
        if updated && defaults.string(forKey: toldKey) != version { defaults.set(version, forKey: pendingKey) }
        guard let pending = defaults.string(forKey: pendingKey) else { return nil }
        guard pending == version else {
            defaults.removeObject(forKey: pendingKey)
            return nil
        }
        return pending
    }

    /// Said: never again for this version.
    public static func told(_ version: String, defaults: UserDefaults = .standard) {
        defaults.set(version, forKey: toldKey)
        if defaults.string(forKey: pendingKey) == version { defaults.removeObject(forKey: pendingKey) }
    }
}

// MARK: The engine: when it's calm, and how it's said

extension BehaviorEngine {
    /// Whether "What's new" may go up now. `watchingSince`: when Moku started watching with the news to tell (the launch,
    /// or the welcome's end).
    public func isCalmForNews(now: Date, watchingSince: Date) -> Bool {
        // Never in a meeting or a call, a break, a drift or away, and never over another line, gesture or bubble.
        guard !inMeeting, teaBreak == nil, away == nil, activity != .drifting, settleAt == nil, awaitedLine == nil else { return false }
        if let speechUntil, now < speechUntil { return false }
        // At the Mac, but not mid-typing: the pointer and caret still for a moment, as for a finished piece of work.
        guard let lastAttentionAt else { return false }
        let still = now.timeIntervalSince(lastAttentionAt)
        guard still >= tuning.calmAfterQuietSec, still <= WhatsNew.presentWithinSec else { return false }
        // Coming back from a drift or a break: Moku has just turned to the person, so it's said once its own line is over.
        if let welcomedBackAt, now.timeIntervalSince(welcomedBackAt) <= WhatsNew.afterWelcomeBackSec { return true }
        // Otherwise a while after Moku started watching, and not while the person settles into a stretch of focus.
        guard now.timeIntervalSince(watchingSince) >= WhatsNew.afterWatchingSec else { return false }
        return !(activity == .focused && focusStreakSec < WhatsNew.settlingIntoFocusSec)
    }

    /// Says it: the companion looks up with a smile, and its bubble links to `version`'s changelog.
    public mutating func sayWhatsNew(_ version: String, now requested: Date) -> [EngineEffect] {
        let now = advance(to: requested)
        lookAtUser()
        perform(.smile)
        lastSpokenText = WhatsNew.words
        effects.append(.character(.say(SpeechLine(text: WhatsNew.words, tone: .cheerful, duration: WhatsNew.bubbleSec, whatsNew: version))))
        settleAt = now.addingTimeInterval(tuning.speakingHoldSec)
        holdIsLookUp = false
        welcomedBackAt = nil
        syncWorkState(now: now)
        return takeEffects()
    }

    /// Notes how long the bubble just put up (or taken down) stays: "What's new" never goes over another one.
    mutating func noteSpeech(_ effects: [EngineEffect]) {
        for case let .character(command) in effects {
            switch command {
            case let .say(line): speechUntil = line.duration.isFinite ? lastNow?.addingTimeInterval(line.duration) : .distantFuture
            case .think: speechUntil = .distantFuture  // until the line replaces it
            case .dismissSpeech: speechUntil = nil
            default: break
            }
        }
    }
}
