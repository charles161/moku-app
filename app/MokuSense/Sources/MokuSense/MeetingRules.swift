import Foundation
import MokuKit

/// A visible window, named by its owner's bundle id.
struct TitledWindow: Sendable, Equatable {
    var bundleId: String
    var title: String
}

/// What the sensors saw that bears on "is the user in a call or sharing their screen".
struct MeetingEvidence: Sendable, Equatable {
    var micInUse = false
    var cameraInUse = false
    var runningBundleIds: Set<String> = []
    /// Titles are empty for other apps' windows without Screen Recording, except the focused window
    /// whose title comes from Accessibility.
    var windows: [TitledWindow] = []
    /// Address of the focused browser tab, if any.
    var focusedURL: String?
    /// The app in front.
    var focusedBundleId: String?
}

/// Best-effort call and screen-share inference. A call needs a live mic or camera *and* a call on screen, so
/// dictation or a voice memo never silences Moku, and neither does Zoom, Discord or FaceTime just running while
/// you dictate somewhere else (the 2026-09-28 audit; docs/specs/next-wave.md §6).
enum MeetingRules {
    /// Apps that hold calls. They can run all day, and most of their call windows have no telling title, so a call is
    /// the camera live while one runs, the mic live while one is in front (dictating there hides Moku for as long,
    /// which is harmless), or a call window that says so (`isCallAppWindow`).
    static let callApps: Set<String> = [
        "us.zoom.xos", "com.apple.FaceTime", "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark",
        "com.skype.skype", "com.hnc.Discord", "app.tuple.app", "com.around.Around", "com.gotomeeting.GoToMeeting",
        "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "org.telegram.desktop",
    ]
    /// Chat apps that also hold calls. They count only with a call window.
    static let chatAppsWithCalls: Set<String> = ["com.microsoft.teams2", "com.microsoft.teams", "com.tinyspeck.slackmacgap"]

    /// `previous` is the last context: a call once seen lasts while the mic or camera stays live, so switching
    /// away from the Meet tab or the call window mid-call doesn't end it.
    static func context(from evidence: MeetingEvidence, previous: MeetingContext = .none) -> MeetingContext {
        let mediaLive = evidence.micInUse || evidence.cameraInUse
        return MeetingContext(
            inCall: mediaLive && (previous.inCall || hasCallSurface(evidence)),
            sharingScreen: evidence.windows.contains { isSharingIndicator($0.title) },
            micInUse: evidence.micInUse,
            cameraInUse: evidence.cameraInUse)
    }

    static func hasCallSurface(_ evidence: MeetingEvidence) -> Bool {
        if let front = evidence.focusedBundleId, callApps.contains(front) { return true }
        if evidence.cameraInUse && !evidence.runningBundleIds.isDisjoint(with: callApps) { return true }
        if let url = evidence.focusedURL, isCallPage(url: url) { return true }
        return evidence.windows.contains { window in
            if callApps.contains(window.bundleId) { return isCallAppWindow(window.title) }
            if chatAppsWithCalls.contains(window.bundleId) { return isChatCallWindow(window.title) }
            if Browsers.all.contains(window.bundleId) { return isCallPage(title: window.title) }
            return false
        }
    }

    /// Zoom's meeting and webinar windows, wherever they are (titles need Screen Recording, or the window in front).
    static func isCallAppWindow(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower.hasPrefix("zoom meeting") || lower.hasPrefix("zoom webinar")
    }

    /// Teams meeting and call windows, Slack huddles.
    static func isChatCallWindow(_ title: String) -> Bool {
        let lower = title.lowercased()
        return ["huddle", "meeting", "call with", "| call", "meet now"].contains { lower.contains($0) }
    }

    /// Browser tab titles of web meetings. Only the active tab of each window is visible.
    static func isCallPage(title: String) -> Bool {
        let lower = title.lowercased()
        if lower.hasPrefix("meet - ") || lower.hasPrefix("meet – ") || lower.hasPrefix("meet — ") { return true }
        if lower.contains("| microsoft teams") { return isChatCallWindow(lower) }
        return ["google meet", "zoom meeting", "zoom webinar", "jitsi meet", "whereby", "webex meeting"]
            .contains { lower.contains($0) }
    }

    static func isCallPage(url: String) -> Bool {
        guard let components = URLComponents(string: url), let host = components.host?.lowercased() else { return false }
        let path = components.path.lowercased()
        let hasRoom = path.count > 1
        if host == "meet.google.com" || host == "meet.jit.si" || host.hasSuffix("whereby.com") { return hasRoom }
        if host.hasSuffix("zoom.us") { return path.hasPrefix("/wc/") || path.hasPrefix("/j/") }
        if host == "teams.microsoft.com" || host == "teams.live.com" { return path.contains("meetup-join") || path.contains("/meet/") }
        if host.hasSuffix("webex.com") { return path.contains("/meet/") || path.contains("/wbxmjs/") }
        return false
    }

    /// Windows that meeting apps and browsers show only while the screen is being shared.
    static func isSharingIndicator(_ title: String) -> Bool {
        let lower = title.lowercased()
        return [
            // Chrome, Edge, Brave, Arc: "meet.google.com is sharing your screen."
            "is sharing your screen", "is sharing a window", "is sharing this tab", "is sharing a tab",
            "is sharing your entire screen",
            // Zoom's share toolbar and status bar.
            "zoom share toolbar", "zoom share statusbar",
            // Teams.
            "sharing control bar", "sharing toolbar",
            // Webex, Slack and others.
            "you're sharing", "you are sharing", "you’re sharing",
        ].contains { lower.contains($0) }
    }
}
