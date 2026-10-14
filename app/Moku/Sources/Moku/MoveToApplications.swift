import AppKit

/// Opened from a download or the disk image, Moku offers to move itself into Applications. From anywhere else it
/// can't open at login, and Sparkle can't replace it (macOS runs a downloaded app from a hidden read-only copy).
/// Asked once, and only in release builds: a development build (build/Moku.app) carries no update feed.
@MainActor
enum MoveToApplications {
    private static let declinedKey = "Moku.moveToApplicationsDeclined"
    private static let destination = URL(fileURLWithPath: "/Applications/Moku.app")

    /// True when Moku has moved itself and is quitting; the copy in Applications opens once this one has gone.
    static func offerIfNeeded() -> Bool {
        let source = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let userApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              !source.path.hasPrefix("/Applications/"), !source.path.hasPrefix(userApplications + "/"),
              !UserDefaults.standard.bool(forKey: declinedKey) else { return false }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Move Moku to your Applications folder?"
        alert.informativeText = "From Applications, Moku can open when you log in and keep itself up to date."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: declinedKey)
            AppLog.write("move to Applications: not now")
            return false
        }
        do {
            try move(from: source)
            AppLog.write("move to Applications: moved; reopening from there")
            reopenAfterQuitting()
            return true
        } catch {
            AppLog.write("move to Applications: \(error.localizedDescription)")
            let failed = NSAlert()
            failed.messageText = "Moku couldn’t move itself"
            failed.informativeText = "Drag Moku into your Applications folder, then open it from there.\n\n\(error.localizedDescription)"
            failed.runModal()
            return false
        }
    }

    private static func move(from source: URL) throws {
        let files = FileManager.default
        // The copy goes in beside first: an older Moku is put in the Trash only once the new one is there whole, so a copy
        // that fails (a full disk, no permission) never costs someone the Moku they have.
        let incoming = URL(fileURLWithPath: "/Applications/.Moku-incoming.app")
        try? files.removeItem(at: incoming)
        do {
            try files.copyItem(at: source, to: incoming)
            // This copy was opened with the person's OK, so its twin in Applications shouldn't ask again.
            run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", incoming.path])
            if files.fileExists(atPath: destination.path) { try files.trashItem(at: destination, resultingItemURL: nil) }  // an older copy
            try files.moveItem(at: incoming, to: destination)
        } catch {
            try? files.removeItem(at: incoming)
            throw error
        }
        // A download in a folder goes to the Trash. A disk image, or macOS's hidden read-only copy, stays.
        let hidden = source.path.contains("/AppTranslocation/") || source.path.hasPrefix("/Volumes/")
        if !hidden, files.isWritableFile(atPath: source.deletingLastPathComponent().path) {
            try? files.trashItem(at: source, resultingItemURL: nil)
        }
    }

    /// Only one Moku runs at a time, so the new copy opens once this process has exited.
    private static func reopenAfterQuitting() {
        let pid = ProcessInfo.processInfo.processIdentifier
        run("/bin/sh", ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"\(destination.path)\""], wait: false)
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: [String], wait: Bool = true) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments
        try? process.run()
        if wait { process.waitUntilExit() }
    }
}
