import AppKit
import MokuKit
import MokuMind
import ServiceManagement

/// Launch at login through the system's login items (System Settings › General › Login Items).
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            AppLog.write("launch at login: \(enabled ? "on" : "off")")
        } catch {
            AppLog.write("launch at login: could not turn \(enabled ? "on" : "off") (\(error.localizedDescription))")
        }
    }
}

@MainActor
enum AppLifecycle {
    /// Sent by a second launch: the running Moku says it's here (opens its popover) instead of the double-click seeming to
    /// do nothing.
    static let reopenedNotification = Notification.Name("ai.lightslips.moku.reopened")
    static func tellRunningMoku() {
        DistributedNotificationCenter.default().postNotificationName(reopenedNotification, object: nil, userInfo: nil, deliverImmediately: true)
        Thread.sleep(forTimeInterval: 0.3)  // delivery is asynchronous, and this process is about to exit
    }

    /// One Moku at a time: a second launch hands over to the first and quits. Only a live process running Moku itself
    /// counts: macOS lists an app for a moment after it quits, and before this process's run loop starts that list isn't
    /// refreshed (a relaunch, or Sparkle's right after an update, saw the old Moku and quit, leaving none); and the visual
    /// demo, which once shared the bundle id, isn't Moku. One on its way out is waited for, up to `seconds`.
    static func isAnotherInstanceRunning(waitingUpTo seconds: Double = 3) -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let bundleId = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != me && $0.executableURL?.lastPathComponent == "Moku" }
            .map(\.processIdentifier)
        let deadline = Date().addingTimeInterval(seconds)
        while others.contains(where: { kill($0, 0) == 0 }) {
            guard Date() < deadline else { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    /// SIGTERM and SIGINT (a `kill`, a logout, `pkill Moku`) quit through NSApp.terminate, so Moku
    /// stops its brain and logs "terminate" instead of vanishing mid-write.
    private static var sources: [DispatchSourceSignal] = []
    /// Why Moku is quitting, when it isn't its own menu: "signal", "logout", "update" or "relaunch" (`app_quit`).
    static var quitReason: String?

    static func quitCleanlyOnSignals() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { quitReason = quitReason ?? "signal"; NSApp.terminate(nil) }
            source.resume()
            sources.append(source)
        }
    }

    /// The note a quiet relaunch leaves for the Moku that opens next (QuietRelaunch.Note).
    static let relaunchNote = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".moku/relaunch")

    /// Quits and opens Moku again: the welcome's "Quit & Reopen", since macOS gives Moku Screen Recording only after a
    /// relaunch, and the quiet relaunch after a companion change (`quietly`: the reason, which goes in a note so the new
    /// Moku opens without the welcome). A small shell waits for this Moku to be gone (one Moku at a time), then opens the
    /// same app. False when the shell couldn't start (Moku goes on running).
    @discardableResult
    static func relaunch(quietly reason: String? = nil) -> Bool {
        if let reason, !QuietRelaunch.leaveNote(reason: reason, at: relaunchNote) { AppLog.write("relaunch: could not leave the note; the new Moku may offer the welcome") }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = QuietRelaunch.reopenArguments(waitingFor: ProcessInfo.processInfo.processIdentifier, bundlePath: Bundle.main.bundlePath)
        do {
            try shell.run()
            quitReason = "relaunch"
            AppLog.write(reason == nil ? "relaunch: quitting to reopen" : "relaunch: quitting to reopen quietly")
        } catch {
            AppLog.write("relaunch: could not start (\(error.localizedDescription))")
            try? FileManager.default.removeItem(at: relaunchNote)
            return false
        }
        NSApp.terminate(nil)
        return true
    }

    /// The first name of the Mac account, to greet the person with ("Charles"): not a title or an initial in front of it,
    /// nor an account called "Administrator" (PersonName.suggestion).
    static var suggestedName: String? { PersonName.suggestion(fromFullName: NSFullUserName()) }
}
