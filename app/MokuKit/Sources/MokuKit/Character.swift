import CoreGraphics
import Foundation
import Observation

/// The character on screen. MokuVisual implements it; the behavior engine drives it.
/// Idle life (breathing, blinking, posture shifts, looking around, hover reactions) is the
/// implementation's own job and never needs a call. Screen points are AppKit global coordinates.
@MainActor
public protocol CharacterStage: AnyObject {
    /// Put the character at its home spot (bottom-right, beside the Dock) and start its idle life.
    func show()
    /// Fade out or back in, e.g. during calls and screen sharing. Idle life pauses while hidden.
    func setHidden(_ hidden: Bool)
    /// Sustained emotional state; idle life keeps running inside it.
    func setMood(_ mood: Mood)
    /// Where the eyes and head point.
    func setAttention(_ target: AttentionTarget)
    /// One-shot action. Returns immediately; a later gesture or move may interrupt it.
    func perform(_ gesture: Gesture)
    /// Walk to a spot and return once arrived (immediately if already there).
    /// A new `move(to:)` during a walk redirects it from where the character is; the earlier call returns at once.
    func move(to spot: StageSpot) async
    /// Show a speech bubble, replacing any current one; it dismisses itself after `line.duration`, unless that's
    /// `SpeechLine.untilDismissed`.
    func say(_ line: SpeechLine)
    /// A line is being written (Luna's, for a celebration): a thinking bubble until `say` or `dismissSpeech`.
    func think()
    func dismissSpeech()
    /// A small, quiet label near the character naming a line of work it just recognized
    /// ("DSA · Trees"). It fades by itself after a few seconds; it is not speech.
    func showThreadLabel(_ title: String)
    /// Drives the lantern, the gaze mode, glances and micro-expressions. Called on every change.
    func setWorkState(_ state: WorkState)
    /// The return: light and body, never words (the lantern flare and the happy beat).
    func celebrateReturn(_ size: ReturnSize)
    /// Set by the app. A pat is a stroke across the head; it means "this is fine". The stage plays the pat reaction
    /// itself, at once; the app doesn't ask for it again.
    var onPat: (@MainActor () -> Void)? { get set }
    /// Set by the app. A plain click on the character opens the world.
    var onClick: (@MainActor () -> Void)? { get set }
    /// Set by the app. "Take a break" (or "End the break") from the character's right-click menu.
    var onTakeBreak: (@MainActor () -> Void)? { get set }
    /// A break's countdown over Moku's head, until `until` (of `total` seconds); nil takes it away.
    func setBreakTimer(until: Date?, total: TimeInterval)
    /// Set by the app: "This is work" (`true`, in a drift) or "This isn't work" (`false`) from the right-click menu.
    var onCorrectNow: (@MainActor (Bool) -> Void)? { get set }
    /// Set by the app: the task you're on and its minutes today, shown while the pointer rests on the companion (it no
    /// longer names tasks by itself: Charles, 2026-10-14). Nil when there's no named task.
    var currentTask: (@MainActor () -> TaskNow?)? { get set }
    /// Set by the app. A "What's new" bubble (a line with `whatsNew`) is over: clicked (`opened`, the app opens that version's
    /// changelog), or closed by its ✕, its time, or another line taking its place. Called once per bubble.
    var onWhatsNew: (@MainActor (_ version: String, _ opened: Bool) -> Void)? { get set }
    /// Set by the app: records a usage event (the companion hidden or shown by the person, trouble drawing it). Code words
    /// and numbers only.
    var track: UsageTracker? { get set }
    /// Set by the app: adds to the day's counts (hovers, drags, throws, talents, frames dropped).
    var count: UsageCounter? { get set }
}

extension CharacterStage {
    /// Until a stage draws its own label, announce the thread as a short cheerful line.
    public func showThreadLabel(_ title: String) {
        say(SpeechLine(text: title, tone: .cheerful, duration: 3))
    }
    public func think() {}
    public func setWorkState(_ state: WorkState) {}
    public func celebrateReturn(_ size: ReturnSize) { perform(.nod) }
    public var onTakeBreak: (@MainActor () -> Void)? { get { nil } set {} }
    public func setBreakTimer(until: Date?, total: TimeInterval) {}
    public var onWhatsNew: (@MainActor (_ version: String, _ opened: Bool) -> Void)? { get { nil } set {} }
    public var currentTask: (@MainActor () -> TaskNow?)? { get { nil } set {} }
    public var onCorrectNow: (@MainActor (Bool) -> Void)? { get { nil } set {} }
    public var track: UsageTracker? { get { nil } set {} }
    public var count: UsageCounter? { get { nil } set {} }
}

/// What the person is doing right now, from the behavior engine's clocks. The stage derives the
/// lantern, the gaze ("watching your work" versus "holding your place"), glance cadence and
/// micro-expressions from it (docs/creative/v1-direction.md sections 1.7, 2 and 3).
public enum WorkState: String, Sendable, CaseIterable {
    /// Working: lantern lit, watching the work.
    case focused
    /// The drift's first moment (`graceSec`, 1 s by default): nothing changes yet.
    case grace
    /// After grace: sad and looking at the user; angry from `annoyedAfterSec`.
    case noticing
    /// A long drift (from `shortDriftMaxSec`, 2 min): still angry, eyes on the user.
    case concerned
    /// From `standUpAfterSec` (4 min): standing, and a little red.
    case drifting
    /// From `askAfterSec` (10 min): has asked to focus; still standing and red.
    case longDrift
    /// Away from the Mac: the lantern burns like a pilot light.
    case away
    /// A tea break the person chose: Moku sits with tea; not drift.
    case onBreak
    /// Nothing known yet (just launched, or the brain is down): calm, no signal.
    case idle
}

public enum ReturnSize: String, Sendable {
    /// Back after 1–5 minutes: the lantern flares and Moku nods (about 1.2 s).
    case small
    /// Back after a longer drift: flare, sparks, ears lift, hop, slow blink and nod (about 2.2 s).
    case full
}

public enum Mood: String, CaseIterable, Sendable {
    case content, happy, proud, curious, concerned, disappointed, annoyed, sleepy
}

public enum Gesture: String, CaseIterable, Sendable {
    case smile, nod, glance, sigh, standUp, sitDown, wave, cheer, celebrate, stretch, drinkWater, yawn, patReaction
    /// A window new to the companion came to the front while you work: a quick sniff of it (next-wave.md §2).
    case sniff
}

public enum AttentionTarget: Sendable, Equatable {
    /// Look out of the screen at the user.
    case user
    /// Look at a point on screen: where the user works, or the window they drifted to.
    case point(CGPoint)
    /// Free, idle looking around.
    case wander
}

public enum StageSpot: Sendable, Equatable {
    /// Bottom-right, beside the Dock.
    case home
    /// The middle of the screen the user is working on: in their field of view.
    case center
    case near(CGPoint)
}

/// The task you're on, for the label a hover shows.
public struct TaskNow: Sendable, Equatable {
    public var title: String
    public var minutesToday: Int
    public init(title: String, minutesToday: Int) {
        self.title = title
        self.minutesToday = minutesToday
    }
}

public struct SpeechLine: Sendable, Equatable {
    public enum Tone: String, Sendable, CaseIterable {
        case gentle, warm, firm, calling, cheerful
    }

    public var text: String
    public var tone: Tone
    /// Seconds on show; `untilDismissed` keeps it up until `dismissSpeech` or the next line.
    public var duration: TimeInterval
    /// "What's new" after an update (docs/specs/next-0-1-9.md §1): the version the line tells about. The bubble is a link to
    /// that version's changelog, with an ✕.
    public var whatsNew: String?

    /// A line that stays until it's taken down: the ask, which stays until you come back.
    public static let untilDismissed = TimeInterval.infinity

    public init(text: String, tone: Tone, duration: TimeInterval = 6, whatsNew: String? = nil) {
        self.text = text
        self.tone = tone
        self.duration = duration
        self.whatsNew = whatsNew
    }
}

/// The menu bar icon and its dropdown, where the world lives. MokuVisual implements it.
@MainActor
public protocol WorldPresenter: AnyObject {
    /// Open the world dropdown (from the menu bar icon, or when the character is clicked).
    func openWorld()
    func closeWorld()
    /// A new forest stage was reached: a small cue on the menu bar icon now, the full moment next time the world opens.
    func celebrate(_ stage: ForestStage)
    /// Set by the app. The dropdown's "Manual control" switch calls it with the new state.
    var onManualControl: (@MainActor (Bool) -> Void)? { get set }
    /// Reflect the switch when the app changes it, e.g. after the control panel was closed.
    func setManualControl(_ on: Bool)
    /// Set by the app: "Taking a break" in the dropdown (or on Moku) starts a tea break.
    var onTakeBreak: (@MainActor () -> Void)? { get set }
    /// Reflect whether a tea break is on (the button becomes "Back to work").
    func setOnBreak(_ on: Bool)
    /// Set by the app: the popover just opened, so its numbers should be fresh (a world refresh from the brain).
    var onOpen: (@MainActor () -> Void)? { get set }
    /// Set by the app: loads a day for the Today window from the brain (nil: today).
    var todayProvider: (@MainActor (Date?) async -> TodaySummary?)? { get set }
    /// Set by the app: loads each day's totals from one day to another, for the Today window's strip of days.
    var daysProvider: (@MainActor (_ from: Date, _ to: Date) async -> DaysResponse?)? { get set }
    /// Set by the app: a Today row was marked "This was work" (true) or "This wasn't work" (false).
    var onCorrection: (@MainActor (_ segmentIds: [String], _ isWork: Bool) -> Void)? { get set }
    /// Set by the app: "Say hi again" in the dropdown replays onboarding.
    var onSayHiAgain: (@MainActor () -> Void)? { get set }
    /// Set by the app: Settings reads Moku's timings from the brain.
    var loadConfig: (@MainActor () async -> CompanionConfig?)? { get set }
    /// Set by the app: Settings saves a change and gets back the config served from then on.
    var saveConfig: (@MainActor (CompanionConfigPatch) async -> CompanionConfig?)? { get set }
    /// Whether the brain and its cloud models are answering: one quiet line in the popover when they aren't.
    func setThinking(_ status: ThinkingStatus)
    /// Set by the app: how this Mac reaches Moku's cloud brain, for Settings.
    var loadAccess: (@MainActor () async -> AccessStatus?)? { get set }
    /// Set by the app: redeem an invite code; the new status, or a message saying what went wrong.
    var redeemInvite: (@MainActor (String) async -> Result<AccessStatus, InviteError>)? { get set }
    /// Set by the app: Settings › Get Moku Pro opens Dodo's checkout for a plan (`monthly` or `yearly`).
    var startCheckout: (@MainActor (String) async -> Result<Void, InviteError>)? { get set }
    /// Set by the app: "Delete my data" in Settings; whether the brain did.
    var deleteData: (@MainActor () async -> Bool)? { get set }
    /// Set by the app: "Check for updates…" in Settings (nil in builds without auto-update).
    var checkForUpdates: (@MainActor () -> Void)? { get set }
    /// Set by the app: how the last update check went, in a sentence for Settings (nil before the first check).
    var updateStatus: String? { get set }
    /// Set by the app: which permissions Moku has, for Settings and the popover. Moku never asks by itself after the
    /// welcome; these are where the person can.
    var permissionStatus: (@MainActor () -> PermissionStatus)? { get set }
    /// Set by the app: a "Turn on" button. macOS's prompt the first time, then the right page of System Settings.
    var requestPermission: (@MainActor (PermissionKind) -> Void)? { get set }
    /// Set by the app: records a usage event (the popover or Your day opening, a setting changed, a permission turned
    /// on in Settings). Code words and numbers only (`UsageValue`).
    var track: UsageTracker? { get set }
    /// Set by the app: adds to the day's counts (a popover opened and closed again at once).
    var count: UsageCounter? { get set }

    // "Today counted" (docs/specs/next-three.md §3): the day's card beside the companion.
    /// Whether the card could go up now: the companion is on show on this desktop (not hidden, not behind a full-screen
    /// app, the display awake).
    var canShowDayCounted: Bool { get }
    /// Puts up the card for `summary` (`yesterday`: the morning after a day that ended without one). True once it's up.
    func showDayCounted(_ summary: TodaySummary, yesterday: Bool) async -> Bool
    /// Moku is quitting from its own menu: the card as a goodbye. Returns once it's gone (closed, or a few seconds on):
    /// true when it was shown.
    func sayGoodbyeWithDayCounted(_ summary: TodaySummary) async -> Bool
    /// Takes the card away (a meeting started).
    func closeDayCounted()
}

extension WorldPresenter {
    public var count: UsageCounter? { get { nil } set {} }
    public var canShowDayCounted: Bool { false }
    public func showDayCounted(_ summary: TodaySummary, yesterday: Bool) async -> Bool { false }
    public func sayGoodbyeWithDayCounted(_ summary: TodaySummary) async -> Bool { false }
    public func closeDayCounted() {}
}

/// Why an invite code didn't take, in words for Settings.
public struct InviteError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Whether Moku's brain and its cloud models are answering, from the brain's /health (breaker.ts). Nothing
/// alarms: the popover shows one quiet line, and Moku keeps judging what the brain's rules already know.
public enum ThinkingStatus: Sendable, Equatable {
    case fine
    /// Jev has been failing for a while.
    case cloudResting
    /// Jev has been failing for a while, and the local model on this Mac is answering instead.
    case thinkingOnMac
    /// The key, token or credit was refused (401, 402, 403) or there are no credentials.
    case accessRefused
    /// This Mac's daily share of the online brain is used, until midnight UTC (the relay's governor).
    case restingToday
    /// The brain itself isn't answering.
    case brainDown

    /// Jev's breaker must have been open this long before the popover says so: a short blip passes unseen.
    public static let restingAfter: TimeInterval = 120

    /// From one /health check: `answering` is whether the brain replied; `judge` is Jev's breaker state
    /// ("ok", "backoff", "paused" or "resting") and `since` when its failures began; `local` the local model's state.
    public static func from(answering: Bool, judge: String?, since: Date?, local: String? = nil, now: Date = Date()) -> ThinkingStatus {
        guard answering else { return .brainDown }
        let onMac = local == "running"
        switch judge {
        case "paused": return onMac ? .thinkingOnMac : .accessRefused
        case "resting": return onMac ? .thinkingOnMac : .restingToday
        case "backoff": return now.timeIntervalSince(since ?? now) < restingAfter ? .fine : onMac ? .thinkingOnMac : .cloudResting
        default: return .fine
        }
    }

    /// The popover's line; nil when all is well.
    public var line: String? {
        switch self {
        case .fine: nil
        case .cloudResting: "Moku’s thinking offline for now. It still knows your usual work apps."
        case .thinkingOnMac: "Moku’s thinking on your Mac while its online brain rests."
        // A trial that has ended, an invite that isn't valid, or no room for new Macs: the person never held a "key".
        case .accessRefused: "Moku’s online brain isn’t on for this Mac. It still knows your usual work apps."
        case .restingToday: "Moku’s thinking offline for the rest of today. It still knows your usual work apps."
        case .brainDown: "Moku’s brain isn’t answering, so Moku stays calm until it’s back."
        }
    }
}

/// Settings' test buttons: see behaviors without waiting. Jump straight to a drift step (Moku holds there),
/// come back to work from it, play the whole drift sped up, or see the focus look-up now. Moku stops watching
/// the screen meanwhile.
public enum BehaviorTest: Sendable, Equatable {
    public enum Step: String, CaseIterable, Sendable {
        /// Sad, looking at the user.
        case sad
        /// Standing up, a little red.
        case standUp
        /// Asking the user to focus, for its house.
        case ask
    }
    case jump(Step)
    case comeBack
    case playAll
    /// The look-up while focusing: Moku smiles at the user, then goes back to work.
    case lookUp
    /// Moku's quiet drink of water, now.
    case drink
    case stop
}

public enum PermissionKind: String, Sendable, CaseIterable {
    case accessibility, screenRecording
}

/// What onboarding can ask the app to do. The app fills it; MokuVisual only calls it.
@MainActor
public struct OnboardingContext {
    /// A first-name guess (from the macOS account) to prefill; the person can change it.
    public var suggestedName: String?
    public var permissions: @MainActor () -> PermissionStatus
    /// Shows the system prompt for one permission (or opens the right Settings pane when the prompt was already used).
    public var requestPermission: @MainActor (PermissionKind) -> Void
    public var launchAtLogin: @MainActor () -> Bool
    public var setLaunchAtLogin: @MainActor (Bool) -> Void
    /// Records a usage event (`welcome_step`, `permission_answered`, `welcome_finished`); a no-op unless the app sets it.
    public var track: UsageTracker
    /// Quits Moku and opens it again (the welcome's "Quit & Reopen": macOS applies Screen Recording only after a
    /// relaunch); a no-op unless the app sets it.
    public var relaunch: @MainActor () -> Void

    public init(suggestedName: String?, permissions: @escaping @MainActor () -> PermissionStatus,
                requestPermission: @escaping @MainActor (PermissionKind) -> Void,
                launchAtLogin: @escaping @MainActor () -> Bool, setLaunchAtLogin: @escaping @MainActor (Bool) -> Void,
                track: @escaping UsageTracker = { _, _ in }, relaunch: @escaping @MainActor () -> Void = {}) {
        self.suggestedName = suggestedName
        self.permissions = permissions
        self.requestPermission = requestPermission
        self.launchAtLogin = launchAtLogin
        self.setLaunchAtLogin = setLaunchAtLogin
        self.track = track
        self.relaunch = relaunch
    }
}

public struct OnboardingResult: Sendable, Equatable {
    /// The name Moku will use ("Charles."). Never empty; falls back to the suggestion or "friend".
    public var name: String
    /// False if the person closed onboarding early; the app offers it again next launch.
    public var completed: Bool

    public init(name: String, completed: Bool) {
        self.name = name
        self.completed = completed
    }
}

/// First launch: the welcome, one window (docs/specs/next-wave.md §1). The companion walks in and says hi, a film shows
/// how it works, the person picks a companion, reads what Moku reads and where it goes, allows the two permissions
/// (live status), and Start folds the window into the menu bar icon. MokuVisual implements it.
@MainActor
public protocol OnboardingPresenter: AnyObject {
    func run(_ context: OnboardingContext) async -> OnboardingResult
}

extension WorldPresenter {
    public var onManualControl: (@MainActor (Bool) -> Void)? { get { nil } set {} }
    public func setManualControl(_ on: Bool) {}
    public var onTakeBreak: (@MainActor () -> Void)? { get { nil } set {} }
    public func setOnBreak(_ on: Bool) {}
    public var onOpen: (@MainActor () -> Void)? { get { nil } set {} }
    public var todayProvider: (@MainActor (Date?) async -> TodaySummary?)? { get { nil } set {} }
    public var daysProvider: (@MainActor (_ from: Date, _ to: Date) async -> DaysResponse?)? { get { nil } set {} }
    public var onCorrection: (@MainActor (_ segmentIds: [String], _ isWork: Bool) -> Void)? { get { nil } set {} }
    public var onSayHiAgain: (@MainActor () -> Void)? { get { nil } set {} }
    public var loadConfig: (@MainActor () async -> CompanionConfig?)? { get { nil } set {} }
    public var saveConfig: (@MainActor (CompanionConfigPatch) async -> CompanionConfig?)? { get { nil } set {} }
    public func setThinking(_ status: ThinkingStatus) {}
    public var loadAccess: (@MainActor () async -> AccessStatus?)? { get { nil } set {} }
    public var redeemInvite: (@MainActor (String) async -> Result<AccessStatus, InviteError>)? { get { nil } set {} }
    public var startCheckout: (@MainActor (String) async -> Result<Void, InviteError>)? { get { nil } set {} }
    public var deleteData: (@MainActor () async -> Bool)? { get { nil } set {} }
    public var checkForUpdates: (@MainActor () -> Void)? { get { nil } set {} }
    public var updateStatus: String? { get { nil } set {} }
    public var permissionStatus: (@MainActor () -> PermissionStatus)? { get { nil } set {} }
    public var requestPermission: (@MainActor (PermissionKind) -> Void)? { get { nil } set {} }
    public var track: UsageTracker? { get { nil } set {} }
}

/// A real behavior replayed for manual control ("Long drift", "Pat during a drift"): the behavior
/// engine drives the stage on a sped-up clock. `play` must stop promptly when its task is cancelled.
public struct ManualScene: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let play: @MainActor @Sendable (_ speed: Double) async -> Void

    public init(id: String, title: String, play: @escaping @MainActor @Sendable (_ speed: Double) async -> Void) {
        self.id = id
        self.title = title
        self.play = play
    }
}

/// The manual control panel: every action as a button, chains of actions, and scenes.
/// While it is open the app stops watching the user entirely.
@MainActor
public protocol ManualControlPanel: AnyObject {
    func open()
    func close()
    /// Set by the app: the person closed the panel themselves.
    var onClose: (@MainActor () -> Void)? { get set }
}

/// What the world view renders; the app replaces `snapshot` whenever the brain reports a change.
@MainActor
@Observable
public final class WorldModel {
    public var snapshot: WorldSnapshot

    public init(snapshot: WorldSnapshot = .empty) {
        self.snapshot = snapshot
    }
}
