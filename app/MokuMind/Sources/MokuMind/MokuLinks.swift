import Foundation

/// A moku:// link (Shortcuts, Raycast, an invite email or the website): what it asks Moku to do.
public enum MokuLink: Equatable, Sendable {
    /// moku://invite/CODE: redeem the invite, then show Settings.
    case invite(code: String)
    /// moku://break: take a break, or end the one going on.
    case toggleBreak
    /// moku://day: open Your day.
    case openDay
    /// moku://settings: open Settings.
    case openSettings

    /// Nil for anything that isn't a moku:// link Moku knows, and for an invite without a code.
    public init?(_ url: URL) {
        guard url.scheme == "moku" else { return nil }
        switch url.host {
        case "invite":
            guard let code = url.pathComponents.dropFirst().first, !code.isEmpty else { return nil }
            self = .invite(code: code)
        case "break": self = .toggleBreak
        case "day": self = .openDay
        case "settings": self = .openSettings
        default: return nil
        }
    }
}

/// Holds the links that arrive before Moku is ready. A link that opens Moku arrives before launch has finished (AppKit
/// calls `application(_:open:)` before `applicationDidFinishLaunching`), when there's no companion, popover or Settings
/// yet: it would do nothing. The inbox keeps those and hands them over, in order, once launch is done; later links go
/// straight through. So moku://day opens Your day whether or not Moku was running.
@MainActor
public final class LinkInbox {
    private var waiting: [MokuLink]? = []
    private let handle: @MainActor (MokuLink) -> Void

    public init(handle: @escaping @MainActor (MokuLink) -> Void) {
        self.handle = handle
    }

    public func receive(_ urls: [URL]) {
        let links = urls.compactMap(MokuLink.init)
        if waiting != nil {
            waiting?.append(contentsOf: links)
        } else {
            links.forEach(handle)
        }
    }

    /// Launch is done: what waited is handled now, and every later link at once.
    public func open() {
        guard let held = waiting else { return }
        waiting = nil
        held.forEach(handle)
    }
}
