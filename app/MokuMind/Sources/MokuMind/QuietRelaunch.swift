import Foundation
import MokuKit

/// A quiet relaunch: after the companion changes (the welcome's pick, or Settings) RealityKit keeps about 200 MB of the
/// character it let go of until the process ends (docs/specs/launch-qa.md, lens 3). So Moku quits and opens itself again
/// at the next moment nobody can see it: the person is away (idle two minutes or more, and Moku sees them away, not
/// watching or reading), the screen locks, or the Mac
/// goes to sleep. It must come back as it was: the same companion (kept in UserDefaults), at home, content, with no
/// welcome. Only a Moku a fresh engine reproduces exactly is relaunched (`decide`): content, at home, not on a break, in
/// a call, in a drift or in the welcome.
///
/// This file is the decision, the note the old process leaves for the new one, and the shell command that reopens the app.
/// The app shell (Moku/QuietRelauncher.swift) gathers the facts and does it.
public enum QuietRelaunch {
    /// How long the Mac has been left alone before Moku counts the person as away.
    public static let awayAfterSeconds = 120.0

    /// What makes this a quiet moment.
    public enum Moment: String, Sendable, Equatable {
        case away, screenLocked, screensAsleep, macAsleep
    }

    /// Why Moku is not relaunching now (it looks again at the next moment, every 30 s and on every lock or sleep).
    public enum Hold: String, Sendable, Equatable {
        case nothingToDo, personHere, windowOpen, welcomeOpen, manualControl, onBreak, inMeeting, drifting, notAtHome, notCalm
    }

    public enum Decision: Equatable, Sendable {
        case relaunch(Moment)
        case hold(Hold)
    }

    /// Where the person is, as far as the Mac can tell.
    public struct Presence: Sendable, Equatable {
        public var idleSeconds: Double
        public var screenLocked: Bool
        public var screensAsleep: Bool
        public var macSleeping: Bool
        public init(idleSeconds: Double = 0, screenLocked: Bool = false, screensAsleep: Bool = false, macSleeping: Bool = false) {
            self.idleSeconds = idleSeconds; self.screenLocked = screenLocked; self.screensAsleep = screensAsleep; self.macSleeping = macSleeping
        }
    }

    /// What Moku is doing, which a fresh Moku can only reproduce when it is calm.
    public struct State: Sendable, Equatable {
        public var phase: BehaviorEngine.Status.Phase
        public var mood: Mood
        public var atHome: Bool
        public var welcomeOpen: Bool
        public var manualControl: Bool
        /// A Moku window (Settings, Your day, the welcome) is open: someone reading with their hands off the Mac isn't away.
        public var windowOpen: Bool
        public init(phase: BehaviorEngine.Status.Phase, mood: Mood, atHome: Bool, welcomeOpen: Bool = false, manualControl: Bool = false, windowOpen: Bool = false) {
            self.phase = phase; self.mood = mood; self.atHome = atHome
            self.welcomeOpen = welcomeOpen; self.manualControl = manualControl; self.windowOpen = windowOpen
        }
    }

    public static func decide(pending: Bool, presence: Presence, state: State) -> Decision {
        guard pending else { return .hold(.nothingToDo) }
        // Locked, or the screens or the whole Mac asleep: the person is gone, whatever windows are open. Only idleness
        // alone isn't proof (reading Your day takes no input), so an open Moku window holds it back.
        let moment: Moment
        if presence.macSleeping { moment = .macAsleep }
        else if presence.screensAsleep { moment = .screensAsleep }
        else if presence.screenLocked { moment = .screenLocked }
        else if presence.idleSeconds >= awayAfterSeconds {
            guard !state.windowOpen else { return .hold(.windowOpen) }
            // Hands off the Mac while Moku still sees work (a video, a long page) isn't away: only Moku's own away is.
            guard state.phase == .away else { return .hold(.personHere) }
            moment = .away
        } else { return .hold(.personHere) }
        if state.welcomeOpen { return .hold(.welcomeOpen) }
        if state.manualControl { return .hold(.manualControl) }
        switch state.phase {
        case .onBreak: return .hold(.onBreak)       // the break's tea timer lives in this process
        case .meeting: return .hold(.inMeeting)
        case .drifting: return .hold(.drifting)     // the drift's clocks would start over
        case .settling, .focused, .away: break
        }
        if !state.atHome { return .hold(.notAtHome) }
        if state.mood != .content { return .hold(.notCalm) }  // what a new Moku starts as: a long away's doze, a smile in progress, a drift's sadness aren't
        return .relaunch(moment)
    }

    // MARK: The note the old Moku leaves

    /// "I'm the same Moku, relaunched quietly": the new process opens without the welcome or the Move to Applications
    /// offer, and without counting an opening in the usage events. ~/.moku/relaunch, owner-only, gone once read.
    public struct Note: Codable, Equatable, Sendable {
        public var at: Double
        public var reason: String
    }

    /// How long a note counts: the reopen takes a few seconds, not minutes.
    public static let noteLifetime = 120.0

    public static func leaveNote(reason: String, at file: URL, now: Date = Date()) -> Bool {
        guard let data = try? JSONEncoder().encode(Note(at: now.timeIntervalSince1970, reason: reason)) else { return false }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.removeItem(at: file)
        return FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// The note, if a fresh one is there; whatever is there is removed.
    public static func takeNote(at file: URL, now: Date = Date()) -> Note? {
        defer { try? FileManager.default.removeItem(at: file) }
        guard let data = try? Data(contentsOf: file), let note = try? JSONDecoder().decode(Note.self, from: data),
              now.timeIntervalSince1970 - note.at >= -5, now.timeIntervalSince1970 - note.at <= noteLifetime else { return nil }
        return note
    }

    // MARK: Opening the app again

    /// `/bin/sh` arguments that wait for `pid` to be gone (one Moku at a time: the lock is let go when it dies) and then
    /// open the app at `bundlePath`; a second try `retryAfter` seconds later if the first fails, so a Moku that was quit is
    /// not lost. A Moku that doesn't quit within `waitUpTo` seconds is left alone: the reopen must never fire hours later,
    /// when the person quits it.
    public static func reopenArguments(waitingFor pid: Int32, bundlePath: String, opener: String = "/usr/bin/open",
                                       waitUpTo: Double = 60, retryAfter: Double = 3) -> [String] {
        let polls = Int((waitUpTo / 0.2).rounded(.up))
        return ["-c", "i=0; while /bin/kill -0 \(pid) 2>/dev/null; do [ $i -ge \(polls) ] && exit 0; i=$((i+1)); /bin/sleep 0.2; done; \(opener) \"$0\" || { /bin/sleep \(retryAfter); \(opener) \"$0\"; }", bundlePath]
    }
}
