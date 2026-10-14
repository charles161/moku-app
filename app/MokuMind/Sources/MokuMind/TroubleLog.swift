import Foundation
import MokuKit

/// What breaks, for `trouble` (docs/specs/deeper-analytics.md, metric 4): a kind from a fixed list, how many times and for
/// how long. A trouble that lasts (the brain not answering, the relay refusing) is sent when it ends, with its seconds; a
/// one-off (the brain restarted, the stand-in drawn) at once. The same kind is sent at most once in 10 minutes: what
/// happens meanwhile is folded into the next one (its count and seconds added), so a flapping problem is one event, not
/// hundreds.
@MainActor
public final class TroubleLog {
    public static let foldSeconds: TimeInterval = 600
    private let track: UsageTracker
    private let now: () -> Date
    private var lastSent: [String: Date] = [:]
    private var folded: [String: (count: Int, seconds: Int)] = [:]
    private var ongoing: [String: Date] = [:]

    public init(track: @escaping UsageTracker, now: @escaping () -> Date = Date.init) {
        self.track = track; self.now = now
    }

    /// Something went wrong once (the brain restarted, the stand-in drawn, a permission lost).
    public func happened(_ kind: String) { report(kind, seconds: 0) }

    /// What's wrong now, from one look (nil: nothing). A new kind starts; one no longer wrong ends and is sent.
    public func observe(_ kind: String?, among kinds: Set<String>) {
        let time = now()
        for (other, since) in ongoing where other != kind && kinds.contains(other) {
            ongoing[other] = nil
            report(other, seconds: Int(time.timeIntervalSince(since).rounded()))
        }
        if let kind, ongoing[kind] == nil { ongoing[kind] = time }
    }

    /// Moku is quitting: what's still wrong, and what was folded, goes now.
    public func sendAll() {
        let time = now()
        for (kind, since) in ongoing { report(kind, seconds: Int(time.timeIntervalSince(since).rounded()), force: true) }
        ongoing = [:]
        for kind in Array(folded.keys) { report(kind, seconds: 0, adding: false, force: true) }
    }

    private func report(_ kind: String, seconds: Int, adding: Bool = true, force: Bool = false) {
        let time = now()
        var tally = folded[kind] ?? (0, 0)
        if adding { tally.count += 1; tally.seconds += max(0, seconds) }
        guard tally.count > 0 else { return }
        if !force, let last = lastSent[kind], time.timeIntervalSince(last) < Self.foldSeconds {
            folded[kind] = tally
            return
        }
        folded[kind] = nil
        lastSent[kind] = time
        track("trouble", ["kind": .word(kind), "count": .int(tally.count), "seconds": .int(min(tally.seconds, 604_800))])
    }

    /// The brain's and the cloud's troubles, from one /health check: not answering, or Jev's calls failing (the breaker
    /// open), by why: the relay refused (401, 402, 403, 429), the cloud switched off (503), the relay down (other 5xx), or
    /// no network (timeouts and failed connections). Nil when all is well.
    public static func brainKind(answering: Bool, judgeState: String?, lastError: String?) -> String? {
        guard answering else { return "brain_down" }
        guard let judgeState, judgeState != "ok" else { return nil }
        let parts = (lastError ?? "").split(separator: " ")
        let status = parts.count > 1 ? Int(parts[1]) : nil
        switch (parts.first.map(String.init), status) {
        case ("credentials", _): return "relay_401"
        case (_, 401?), (_, 402?), (_, 403?), (_, 429?): return "relay_\(status!)"
        case (_, 503?): return "cloud_off"
        case let (_, code?) where code >= 500: return "relay_down"
        case (_, nil): return "offline"
        default: return "relay_down"
        }
    }

    /// The kinds `brainKind` gives: a look that finds none of them wrong ends them.
    public static let brainKinds: Set<String> = ["brain_down", "relay_401", "relay_402", "relay_403", "relay_429", "cloud_off", "relay_down", "offline"]
}
