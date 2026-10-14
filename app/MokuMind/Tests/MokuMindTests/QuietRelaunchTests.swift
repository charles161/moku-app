import Darwin
import Foundation
import MokuKit
import Testing
@testable import MokuMind

// The quiet relaunch after a companion change (docs/specs/launch-qa.md, lens 3 follow-ups): when it may happen, what the new
// Moku is told, and that the reopen waits for the old one to be gone (the single-instance lock with it).

@Suite("Quiet relaunch")
struct QuietRelaunchTests {
    typealias Presence = QuietRelaunch.Presence
    typealias State = QuietRelaunch.State
    let calm = State(phase: .focused, mood: .content, atHome: true)

    private func decide(pending: Bool = true, _ presence: Presence, _ state: State) -> QuietRelaunch.Decision {
        QuietRelaunch.decide(pending: pending, presence: presence, state: state)
    }

    // MARK: When

    @Test func nothingHappensUnlessACompanionChangeIsWaiting() {
        #expect(decide(pending: false, Presence(screenLocked: true), calm) == .hold(.nothingToDo))
    }

    @Test func whileYouAreHereItWaits() {
        #expect(decide(Presence(idleSeconds: 0), calm) == .hold(.personHere))
        #expect(decide(Presence(idleSeconds: 119), calm) == .hold(.personHere))
    }

    /// Hands off the Mac while Moku still sees you at work (a video, a long page, a talk) isn't being away: the companion
    /// would vanish for the seconds a relaunch takes, in front of you. Charles's Mac, 2026-10-06 05:27 and 08:49 UTC:
    /// "relaunch: now (companion changed; away)" a minute and a half after "state: focused content focused".
    @Test func handsOffWhileMokuStillSeesWorkIsNotAway() {
        #expect(decide(Presence(idleSeconds: 150), calm) == .hold(.personHere))
        #expect(decide(Presence(idleSeconds: 600), State(phase: .settling, mood: .content, atHome: true)) == .hold(.personHere))
        #expect(decide(Presence(idleSeconds: 150), State(phase: .away, mood: .content, atHome: true)) == .relaunch(.away))
    }

    @Test func twoMinutesAwayIsAQuietMoment() {
        let gone = State(phase: .away, mood: .content, atHome: true)
        #expect(decide(Presence(idleSeconds: 120), gone) == .relaunch(.away))
        #expect(decide(Presence(idleSeconds: 3_600), gone) == .relaunch(.away))
    }

    @Test func aLockedScreenAScreenAsleepOrAMacAsleepEachIsOneToo() {
        #expect(decide(Presence(idleSeconds: 3, screenLocked: true), calm) == .relaunch(.screenLocked))
        #expect(decide(Presence(idleSeconds: 3, screensAsleep: true), calm) == .relaunch(.screensAsleep))
        #expect(decide(Presence(idleSeconds: 3, macSleeping: true), calm) == .relaunch(.macAsleep))
        #expect(decide(Presence(idleSeconds: 500, screenLocked: true, screensAsleep: true, macSleeping: true), calm) == .relaunch(.macAsleep))
    }

    @Test func aMokuWindowOpenHoldsBackIdlenessButNotALock() {
        var reading = calm; reading.windowOpen = true  // Your day, read with the hands off the Mac, isn't being away
        #expect(decide(Presence(idleSeconds: 600), reading) == .hold(.windowOpen))
        #expect(decide(Presence(idleSeconds: 600, screenLocked: true), reading) == .relaunch(.screenLocked))
        #expect(decide(Presence(idleSeconds: 3, macSleeping: true), reading) == .relaunch(.macAsleep))
    }

    // MARK: As it was

    @Test func onlyAMokuAFreshOneReproducesIsRelaunched() {
        let away = Presence(idleSeconds: 300), locked = Presence(screenLocked: true)
        #expect(decide(away, State(phase: .away, mood: .content, atHome: true)) == .relaunch(.away))
        for phase in [BehaviorEngine.Status.Phase.settling, .focused, .away] {
            #expect(decide(Presence(screenLocked: true), State(phase: phase, mood: .content, atHome: true)) == .relaunch(.screenLocked), "\(phase)")
        }
        #expect(decide(locked, State(phase: .onBreak, mood: .content, atHome: true)) == .hold(.onBreak))  // the break's timer lives here
        #expect(decide(locked, State(phase: .meeting, mood: .content, atHome: true)) == .hold(.inMeeting))
        #expect(decide(locked, State(phase: .drifting, mood: .content, atHome: true)) == .hold(.drifting))
        #expect(decide(away, State(phase: .away, mood: .content, atHome: false)) == .hold(.notAtHome))
    }

    @Test func aMokuThatIsNotContentIsLeftAlone() {
        let away = Presence(idleSeconds: 300)
        for mood in Mood.allCases where mood != .content {  // a long away's doze (its welcome-back would be lost), a smile, a drift's sadness
            #expect(decide(away, State(phase: .away, mood: mood, atHome: true)) == .hold(.notCalm), "\(mood)")
        }
    }

    @Test func theWelcomeAndManualControlAreNeverInterrupted() {
        let locked = Presence(screenLocked: true)
        #expect(decide(locked, State(phase: .focused, mood: .content, atHome: true, welcomeOpen: true)) == .hold(.welcomeOpen))
        #expect(decide(locked, State(phase: .focused, mood: .content, atHome: true, manualControl: true)) == .hold(.manualControl))
    }

    // MARK: The note for the new Moku

    private func noteFile() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("moku-note-\(UUID().uuidString)/.moku/relaunch") }

    @Test func theNewMokuReadsTheNoteOnceAndItIsGone() throws {
        let file = noteFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent()) }
        let now = Date()
        #expect(QuietRelaunch.leaveNote(reason: "companion changed", at: file, now: now))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(QuietRelaunch.takeNote(at: file, now: now.addingTimeInterval(4))?.reason == "companion changed")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(QuietRelaunch.takeNote(at: file, now: now) == nil)
    }

    @Test func aStaleNoteIsNotATrueRelaunchAndIsCleared() {
        let file = noteFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent()) }
        let now = Date()
        #expect(QuietRelaunch.leaveNote(reason: "companion changed", at: file, now: now))
        #expect(QuietRelaunch.takeNote(at: file, now: now.addingTimeInterval(QuietRelaunch.noteLifetime + 1)) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aDamagedNoteIsNeitherReadNorKept() throws {
        let file = noteFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        #expect(QuietRelaunch.takeNote(at: file) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Opening it again

    /// A directory with a stand-in for `open`: a script that runs `body` with its argument as $1.
    private func stub(_ body: String) throws -> (folder: URL, opener: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("moku-relaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("open")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        return (folder, script.path)
    }

    private func run(_ arguments: [String]) throws -> Process {
        let shell = Process(); shell.executableURL = URL(fileURLWithPath: "/bin/sh"); shell.arguments = arguments
        try shell.run()
        return shell
    }

    private func waitFor(_ file: URL, upTo seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: file.path) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return FileManager.default.fileExists(atPath: file.path)
    }

    @Test func theReopenWaitsForTheOldMokuToBeGoneAndThenOpensTheSameApp() async throws {
        let (folder, opener) = try stub("echo \"$1\" > \"$(dirname \"$0\")/opened\"")
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = Process(); old.executableURL = URL(fileURLWithPath: "/bin/sleep"); old.arguments = ["1.2"]  // the Moku on its way out
        try old.run()
        let shell = try run(QuietRelaunch.reopenArguments(waitingFor: old.processIdentifier, bundlePath: "/Applications/Moku.app", opener: opener))
        let opened = folder.appendingPathComponent("opened")
        try await Task.sleep(for: .milliseconds(500))
        #expect(!FileManager.default.fileExists(atPath: opened.path), "opened before the old Moku was gone: two Mokus at once")
        #expect(await waitFor(opened, upTo: 5))
        shell.waitUntilExit()
        #expect((try? String(contentsOf: opened, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "/Applications/Moku.app")
    }

    @Test func theReopenTriesAgainWhenTheFirstOpenFails() async throws {
        let (folder, opener) = try stub("d=\"$(dirname \"$0\")\"; if [ -f \"$d/tried\" ]; then echo \"$1\" > \"$d/opened\"; else touch \"$d/tried\"; exit 1; fi")
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = Process(); old.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try old.run(); old.waitUntilExit()  // already gone
        let shell = try run(QuietRelaunch.reopenArguments(waitingFor: old.processIdentifier, bundlePath: "/Applications/Moku.app", opener: opener, retryAfter: 0.2))
        #expect(await waitFor(folder.appendingPathComponent("opened"), upTo: 5))
        shell.waitUntilExit()
    }

    @Test func aMokuThatNeverQuitsIsNotReopenedHoursLater() async throws {
        let (folder, opener) = try stub("touch \"$(dirname \"$0\")/opened\"")
        defer { try? FileManager.default.removeItem(at: folder) }
        // This very process stands in for a Moku that stays: the reopen gives up after its wait.
        let shell = try run(QuietRelaunch.reopenArguments(waitingFor: getpid(), bundlePath: "/Applications/Moku.app", opener: opener, waitUpTo: 0.6))
        shell.waitUntilExit()
        #expect(shell.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("opened").path))
    }

    /// The whole handoff with a real lock: the old Moku holds ~/.moku/moku.lock and exits; the moment the reopen runs, the
    /// new one must be able to take it (InstanceLock.acquire) and the live-process check finds no other Moku.
    @Test func theNewMokuCanTakeTheLockTheMomentTheReopenRuns() async throws {
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent("moku-handoff-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: lock) }
        let (folder, opener) = try stub("""
        /usr/bin/python3 -c "import fcntl,sys
        f=open('\(lock.path)','w')
        try:
         fcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB); r='got'
        except OSError: r='refused'
        open(sys.argv[1],'w').write(r)" "$(dirname "$0")/result"
        """)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = Process(); old.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        old.arguments = ["-c", "import fcntl,sys,time; f=open(sys.argv[1],'w'); fcntl.flock(f, fcntl.LOCK_EX); print('held', flush=True); time.sleep(0.8)", lock.path]
        let out = Pipe(); old.standardOutput = out
        try old.run()
        _ = out.fileHandleForReading.availableData  // "held": the old Moku has the lock
        let shell = try run(QuietRelaunch.reopenArguments(waitingFor: old.processIdentifier, bundlePath: "/Applications/Moku.app", opener: opener))
        let result = folder.appendingPathComponent("result")
        #expect(await waitFor(result, upTo: 8))
        shell.waitUntilExit()
        #expect((try? String(contentsOf: result, encoding: .utf8)) == "got", "the new Moku was refused the lock the old one had just let go")
    }
}
