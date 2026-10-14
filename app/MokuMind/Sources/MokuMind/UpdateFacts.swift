import Foundation
import MokuKit

/// What the update events say about versions and Sparkle's errors, in fixed words.
public enum UpdateFacts {
    static func releaseKey(_ version: String) -> String { "Moku.updateReleasedAt.\(version)" }

    /// When a version found in the feed was released (its pubDate), for `update_installed`'s hours since the release.
    public static func noteRelease(version: String, date: Date?, defaults: UserDefaults = .standard) {
        guard let date else { return }
        defaults.set(date.timeIntervalSince1970, forKey: releaseKey(version))
    }

    /// Hours from `version`'s release to now (its first launch), and the note forgotten; nil when it wasn't noted.
    public static func hoursSinceRelease(of version: String, now: Date = Date(), defaults: UserDefaults = .standard) -> Int? {
        let key = releaseKey(version)
        guard let released = defaults.object(forKey: key) as? Double else { return nil }
        defaults.removeObject(forKey: key)
        return max(0, Int((now.timeIntervalSince1970 - released) / 3600))
    }

    /// A Sparkle error, in a word: download, signature, feed, install, no_permission, disk_image, network, other; "none"
    /// for the "no update" that also arrives as an error. A feed or download error caused by the network (a connection
    /// reset, lost or refused, a TLS failure, no internet) is "network": Sparkle wraps those as "An error occurred in
    /// retrieving update information" or "…while downloading the update", which hid that the files were fine (2026-10-06).
    public static func kind(of error: NSError) -> String {
        if isNetwork(error) { return "network" }
        guard error.domain == "SUSparkleErrorDomain" else { return "other" }
        switch error.code {
        case 1001: return "none"                                  // SUNoUpdateError
        case 2000, 2001: return "download"                        // temporary folder, download
        case 1, 2, 3000, 3001, 3002: return "signature"           // no key, insufficient signing, unarchiving, signature, validation
        case 3, 4, 1000, 1002, 1004: return "feed"                // insecure or invalid feed URL, appcast parse or error
        case 1003: return "disk_image"                            // running from a disk image
        case 4008, 4012: return "no_permission"                   // authorize later, no permission to write
        case 4000...4011: return "install"
        default: return "other"
        }
    }

    /// Whether the network caused this error, at any layer: Sparkle's error wraps the URL loading system's.
    public static func isNetwork(_ error: NSError) -> Bool {
        chain(error).contains { $0.domain == NSURLErrorDomain || $0.domain == "kCFErrorDomainCFNetwork" }
    }

    /// The HTTP status a server answered with, when that's why Sparkle failed: its downloader says so only in words,
    /// "A network error occurred while downloading <url>. forbidden (403)" (Sparkle 2.10, SPUDownloader.m).
    public static func httpStatus(of error: NSError) -> Int? {
        for layer in chain(error) where layer.domain == "SUSparkleErrorDomain" {
            let text = layer.localizedDescription
            guard text.hasSuffix(")"), let open = text.lastIndex(of: "("),
                  let status = Int(text[text.index(after: open)..<text.index(before: text.endIndex)]), (100...599).contains(status) else { continue }
            return status
        }
        return nil
    }

    /// Whether trying again soon may work: the network failed, or the server was busy or turned the request away for now
    /// (a 403 from Vercel's firewall challenge, which Sparkle can't pass; 408, 425, 429, 5xx). Seen 2026-10-06 on
    /// Charles's network: connections reset mid-download, a TLS failure on the feed, and the Blob store's "Security
    /// Checkpoint" after a burst of requests from one address.
    public static func isTransient(_ error: NSError) -> Bool {
        if isNetwork(error) { return true }
        guard let status = httpStatus(of: error) else { return false }
        return [403, 408, 425, 429].contains(status) || (500...599).contains(status)
    }

    /// The error and every error under it, outermost first.
    public static func chain(_ error: NSError) -> [NSError] {
        var errors = [error], index = 0
        while index < errors.count, errors.count < 8 {
            errors += errors[index].underlyingErrors.map { $0 as NSError }
            index += 1
        }
        return errors
    }

    /// An update error on one line for the app's log: each layer's domain, code and message, then the URL that failed.
    /// "SUSparkleErrorDomain 2001 An error occurred while downloading the update. › NSURLErrorDomain -1005 The network
    /// connection was lost. (https://…/updates/Moku-0.1.9.zip)"
    public static func describe(_ error: NSError) -> String {
        let layers = chain(error)
        let text = layers.map { "\($0.domain) \($0.code) \($0.localizedDescription.replacingOccurrences(of: " Please try again later.", with: ""))" }
            .joined(separator: " › ")
        let url = layers.lazy.compactMap { ($0.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? ($0.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString }.first
        return url.map { "\(text) (\($0))" } ?? text
    }

    /// What `update_check` and `update_stuck` say about an error, besides its kind: the network's error number (-1009
    /// offline, -1003 no such host, -1200 TLS, -1005 lost…), the HTTP status a server answered with, and which of Moku's
    /// servers it was: the relay, or R2 (updates.hellomoku.com). Numbers and fixed words, never the URL. Two friends'
    /// checks failed on 2026-10-08 as just "network" while their AI calls through the relay worked.
    public static func facts(of error: NSError) -> [String: UsageValue] {
        var facts: [String: UsageValue] = [:]
        let layers = chain(error)
        if let code = layers.last(where: { $0.domain == NSURLErrorDomain })?.code { facts["network_code"] = .int(code) }
        if let status = httpStatus(of: error) { facts["http_status"] = .int(status) }
        let url = layers.lazy.compactMap { ($0.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.host ?? ($0.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap { URL(string: $0)?.host } }.first
        facts["host"] = .word(url == "moku-proxy.vercel.app" ? "relay" : url == "updates.hellomoku.com" ? "r2" : "other")
        return facts
    }

    /// The `update_stuck` reason for an error's kind, if it keeps the Mac on its version.
    public static func stuck(_ kind: String) -> String? {
        switch kind {
        case "download": "download_failed"
        case "signature": "signature_failed"
        case "no_permission": "no_permission"
        case "disk_image": "not_in_applications"
        default: nil  // "network" isn't: Moku checks again soon (UpdateRetry)
        }
    }

    /// Whether Moku runs from where it can update itself: /Applications or ~/Applications.
    public static func inApplications(_ path: String = Bundle.main.bundlePath) -> Bool {
        path.hasPrefix("/Applications/") || path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/")
    }
}

/// When to check again after a check failed for the network or a server's passing refusal (UpdateFacts.isTransient).
/// Sparkle waits its full interval (a day for Moku) after any error, so one dropped connection kept a Mac on its version
/// for a day (2026-10-06: Charles's Mac on a network that resets long downloads). After such a failure Moku asks again
/// in 10 minutes, then 30, then 2 hours; then Sparkle's day.
public struct UpdateRetry: Sendable {
    public static let delays: [TimeInterval] = [600, 1_800, 7_200]
    private var failures = 0

    public init() {}

    /// The wait before the next check, after a check ended (nil: no extra check, Sparkle's own schedule stands).
    public mutating func next(after error: NSError?) -> TimeInterval? {
        guard let error, UpdateFacts.isTransient(error) else {
            failures = 0
            return nil
        }
        guard failures < Self.delays.count else { return nil }
        failures += 1
        return Self.delays[failures - 1]
    }
}

/// What the last update check came to, as Settings says it under "Check for updates…": up to date, downloading, ready,
/// or why it failed and when Moku tries again. Sparkle's own alert said only "An error occurred while downloading the
/// update" when Charles's network reset the download (2026-10-06).
public enum UpdateOutcome: Equatable, Sendable {
    case upToDate(at: Date)
    case downloading(version: String)
    case ready(version: String)
    case failed(at: Date, network: Bool, reason: String, retryAt: Date?)

    public func sentence(calendar: Calendar = .current) -> String {
        let time = { (date: Date) in date.formatted(date: calendar.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened) }
        switch self {
        case .upToDate(let at): return "Up to date (checked at \(time(at)))."
        case .downloading(let version): return "Downloading Moku \(version)…"
        case .ready(let version): return "Moku \(version) is downloaded. It installs the next time you’re away from your Mac for a few minutes."
        case .failed(let at, let network, let reason, let retryAt):
            let what = network ? "Couldn’t reach Moku’s update server at \(time(at)) (\(reason))." : "The update at \(time(at)) didn’t work (\(reason))."
            return what + (retryAt.map { " Moku tries again at \(time($0))." } ?? " Moku tries again tomorrow, or use Check for updates.")
        }
    }

    /// The failure in a few words: the network's own message when it caused it, the server's answer, else Sparkle's.
    public static func reason(of error: NSError) -> String {
        let layers = UpdateFacts.chain(error)
        if !UpdateFacts.isNetwork(error), let status = UpdateFacts.httpStatus(of: error) {
            return "the server answered \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))"
        }
        let cause = layers.first { $0.domain == NSURLErrorDomain } ?? layers.first!
        return cause.localizedDescription.replacingOccurrences(of: " Please try again later.", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercasedFirst
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
