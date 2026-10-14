import Darwin
import Foundation
import IOKit.pwr_mgt

/// Which apps are playing something to watch. A film keeps the display awake: video players, and browsers while a
/// video plays, hold a power assertion ("PreventUserIdleDisplaySleep"); an editor or a terminal in full screen doesn't.
/// Read from the power manager, with no permission and nothing about what's playing.
///
/// The friends asked for Moku to step aside for full-screen media (2026-10-14); hiding for every full-screen window hid
/// it all day from people who work in a full-screen editor.
enum MediaPlayback {
    struct Assertion: Equatable, Sendable {
        var pid: pid_t
        /// The app a helper holds it for (WebKit's media process for Safari, say), when the assertion says.
        var onBehalfOf: pid_t?
        var type: String
    }

    /// The assertion types that keep a display on.
    static let displayAwakeTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]

    /// Apps that are for watching: full screen, they count as media even while paused (no assertion held).
    static let watchingApps: Set<String> = [
        "com.apple.QuickTimePlayerX", "com.apple.TV", "com.colliderli.iina", "org.videolan.vlc", "com.firecore.infuse",
        "tv.plex.desktop", "com.apple.iWork.Keynote", "com.microsoft.Powerpoint",
    ]

    /// Sites for watching: a browser full screen on one of them is media even with no keep-awake lock (a muted reel takes
    /// none in Chrome: Charles's photo, 2026-10-14). The site or any of its subdomains.
    static let watchingSites: Set<String> = [
        "youtube.com", "youtu.be", "instagram.com", "netflix.com", "primevideo.com", "hotstar.com", "jiohotstar.com",
        "twitch.tv", "vimeo.com", "tiktok.com", "disneyplus.com", "hulu.com", "max.com", "tv.apple.com", "crunchyroll.com",
        "zee5.com", "sonyliv.com", "jiocinema.com", "mxplayer.in", "sunnxt.com", "aha.video", "dailymotion.com",
        "peacocktv.com", "paramountplus.com", "facebook.com/watch", "facebook.com/reel",
    ]

    /// Whether a page's address is on a site for watching.
    static func isMediaPage(_ address: String) -> Bool {
        guard let url = URL(string: address), let rawHost = url.host?.lowercased() else { return false }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        return watchingSites.contains { site in
            let parts = site.split(separator: "/", maxSplits: 1).map(String.init)
            guard host == parts[0] || host.hasSuffix("." + parts[0]) else { return false }
            return parts.count == 1 || url.path.hasPrefix("/" + parts[1])
        }
    }

    /// The display-awake assertions held now.
    static func displayAwakeAssertions() -> [Assertion] {
        var out: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&out) == kIOReturnSuccess,
              let byProcess = out?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        return byProcess.flatMap { pid, assertions in
            assertions.compactMap { assertion -> Assertion? in
                guard let type = assertion["AssertType"] as? String, displayAwakeTypes.contains(type),
                      (assertion["AssertLevel"] as? Int ?? 255) > 0 else { return nil }
                let onBehalfOf = (assertion["AssertionOnBehalfOfPID"] as? NSNumber).map { pid_t($0.int32Value) }
                return Assertion(pid: (assertion["AssertPID"] as? NSNumber).map { pid_t($0.int32Value) } ?? pid_t(pid.int32Value),
                                 onBehalfOf: onBehalfOf, type: type)
            }
        }
    }

    /// The apps those assertions play for: the holder, whom it holds it for, and the holder's parent (Chrome's helpers
    /// are children of Chrome).
    static func playingPIDs(_ assertions: [Assertion], parent: (pid_t) -> pid_t? = parentPID) -> Set<pid_t> {
        var pids: Set<pid_t> = []
        for assertion in assertions {
            pids.insert(assertion.pid)
            if let owner = assertion.onBehalfOf, owner > 0 { pids.insert(owner) }
            if let up = parent(assertion.pid), up > 1 { pids.insert(up) }
        }
        return pids
    }

    static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
