import MokuKit

/// Moku's drift ladder: everything Moku does as a drift goes on, in one table, including the tier
/// (`WorkState`) and how a return from that point is celebrated. The engine runs this table and has
/// no ladder logic of its own. Tuning a number means editing `CompanionConfig` (served by the brain's
/// /v1/config, and set in Settings); changing what Moku *does* means editing a row here. docs/rules.md
/// explains it in plain English.
///
/// How the table runs:
/// - Each drift starts at the top. A step fires once, when the drift clock reaches its `at`.
/// - Steps fire in order: a step never fires before the steps above it, even if the config makes its
///   own threshold smaller. Every step that's due fires in the same tick.
/// - The drift clock only runs on fresh drifting evidence (see `BehaviorEngine`), so nothing here can
///   advance while the brain is unsure or down.
/// - Within a step, effects happen in column order: tier, mood, gesture, gaze, move, line, events.
///   The long-drift event carries the drift's length so far.
/// - The stage blends moods gradually. From the `.drifting` tier on it shows Moku a little red.
struct LadderStep: Sendable {
    enum ID: String, Sendable, CaseIterable {
        case grace, sad, lookBack, longDrift, standUp, ask
    }

    /// When a step fires, on the drift clock.
    enum At: Sendable {
        case start
        /// `graceSec`, or `shortDriftMaxSec` if that's shorter.
        case endOfGrace
        /// This many seconds after the end of grace (never later than `shortDriftMaxSec`).
        case afterGrace(Double)
        case config(KeyPath<CompanionConfig, Double> & Sendable)

        func seconds(in config: CompanionConfig) -> Double {
            switch self {
            case .start: 0
            case .endOfGrace: min(config.graceSec, config.shortDriftMaxSec)
            case let .afterGrace(seconds): min(min(config.graceSec, config.shortDriftMaxSec) + seconds, config.shortDriftMaxSec)
            case let .config(keyPath): config[keyPath: keyPath]
            }
        }
    }

    enum Gaze: Sendable {
        /// Keep looking where the work was; never follow the distracting window. Ends a look at the user.
        case holdPlace
        /// Look at the user until a later row's `holdPlace`, or until the drift ends.
        case atUser
    }

    /// How coming back is celebrated from this step on.
    enum Return: Sendable {
        /// Not a return at all: no celebration, no stone, no bonus.
        case ignored
        case small
        case full
    }

    var id: ID
    var at: At
    /// The tier from this step on.
    var tier: WorkState? = nil
    var returns: Return? = nil
    var mood: Mood? = nil
    var gesture: Gesture? = nil
    var gaze: Gaze? = nil
    var move: StageSpot? = nil
    /// The nudge: the step forceCalm holds back (it once said "Charles, can we focus?"; no words since 2026-10-14).
    var nudges = false
    var events: [CompanionEventType] = []
    /// From here on the drift is long: the focus streak is over, and coming back earns no return bonus.
    var makesDriftLong = false
}

extension LadderStep {
    /// How long the sad face looks at the person before it goes back to the work.
    /// The sad move's length: the 2.5 s sigh and a beat. Then the normal face and the work (one pass: Charles, 2026-10-14).
    static let sadLookSec: Double = 3

    static let ladder: [LadderStep] = [
        // The first moment (graceSec): nothing changes. A glance away isn't a drift.
        LadderStep(id: .grace, at: .start,
                   tier: .grace, returns: .ignored, gaze: .holdPlace),
        // Then one sad move: a sigh, the face sad, a look at the user. Only sad, never angry (Charles, 2026-10-08: "make
        // it simple only with sad face for both").
        LadderStep(id: .sad, at: .endOfGrace,
                   tier: .noticing, returns: .small, mood: .disappointed, gesture: .sigh, gaze: .atUser),
        // The sadness is shown once (Charles, 2026-10-12: "maybe moku can show its sadness once and then go back to
        // watching my screen"): a few seconds on the user, then the eyes go back to where the work was, never the
        // distracting window, and the face goes back to normal (the friends, 2026-10-14: they "dont like a sad face").
        LadderStep(id: .lookBack, at: .afterGrace(sadLookSec), mood: .content, gaze: .holdPlace),
        // Two minutes: a long drift. Nothing shows; the focus streak is over.
        LadderStep(id: .longDrift, at: .config(\.shortDriftMaxSec),
                   tier: .concerned, events: [.longDriftStarted], makesDriftLong: true),
        // Four minutes: stands up, a little red (the .drifting tier), its face still the normal one.
        LadderStep(id: .standUp, at: .config(\.standUpAfterSec),
                   tier: .drifting, returns: .full, gesture: .standUp),
        // Ten minutes: the nudge, standing where it is (no walking for now). No words since 2026-10-14.
        LadderStep(id: .ask, at: .config(\.askAfterSec),
                   tier: .longDrift, nudges: true, events: [.nudged]),
    ]
}

/// What a return lays. Coming back from past grace is always noticed (the nod), but only a drift that lasted lays a
/// stone (`returned`) and earns its return bonus. Charles, 2026-10-04 (docs/specs/next-wave.md §6): with every drift
/// past grace laying one, a day had 63 returns, mostly glances, and the path filled in three days.
enum Stones {
    /// A drift lays a stone only once the drift clock reaches this.
    static let afterDriftSec: Double = 30
}

/// Rules that hang off a ladder step rather than the drift clock alone.
enum LadderFollowUps {
    /// Still drifting `ignoredNudgeAfterSec` after this step: `ignoredNudge` feedback, once.
    /// Coming back before then sends `returnedAfterNudge` instead.
    static let nudge = LadderStep.ID.ask
}

/// While the user works: the occasional look up at them, pride, and break suggestions.
enum FocusMoments {
    /// Charles: "When I'm focusing, occasionally it should see me and smile, sometimes close its eyes, feel
    /// happy, and then go back to seeing the window." And later: "make it once per minute - on continuous focus".
    ///
    /// After every `smileEverySec` of focus (a minute by default), counted afresh after any drift, Moku looks up
    /// at the user and smiles, its eyes open, holds for `holdSec`, and goes back to the work. It used to close its eyes
    /// happily two times in five; Charles (2026-10-08): "moku seems to close his eyes kinda even without me patting it".
    /// Closed happy eyes are for a pat. It waits while
    /// another gesture or line is up; a due break (or pride) goes first.
    static let holdSec: Double = 2.5
    /// After `proudAfterSec` of continuous focus: proud, once per streak.
    static let proudMood = Mood.proud

    /// After `breakAfterSec` of focus: a warm line and a gesture, in this rotation. (Never standing up: that is
    /// the angry drift's.)
    /// How long Moku's drink of water lasts (the drink_water clip): long enough to read as a real drink.
    static let drinkSeconds: Double = 12

    static let breaks: [(kind: VoiceKind, gesture: Gesture)] = [
        (.water, .drinkWater), (.stretch, .stretch), (.lookAway, .glance), (.walk, .wave),
    ]
}
