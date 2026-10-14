import Foundation

/// The rules of the crash sender (app/Moku CrashReports.swift): which of macOS's crash reports are Moku's, which of them
/// are new, when one counts as done, and what a failed post means. Kept here so they're tested.
public enum CrashReportFiles {
    /// What posting a report came to.
    public enum Delivery: Equatable, Sendable {
        /// PostHog took it.
        case delivered
        /// No answer, or an answer that says "later" (offline, a blocked address, a busy server): try at the next scan.
        case retry
        /// An answer that says no and will say no again: stop.
        case refused
    }

    /// Reports macOS writes for Moku ("Moku-…ips", "Moku_…", "Moku Helper-…") and for its brain ("moku-brain-…"), in any
    /// case. Only the `.ips` format (a JSON report): older `.crash` text isn't read.
    public static func isOurs(_ filename: String) -> Bool {
        let name = filename.lowercased()
        guard name.hasSuffix(".ips"), name.count > ".ips".count else { return false }
        return ["moku-", "moku_", "moku "].contains { name.hasPrefix($0) }
    }

    public struct Plan: Equatable, Sendable {
        /// The first scan only: every report there already, to be remembered and not sent.
        public var baseline: [String]?
        /// The reports to send now, in name order.
        public var toSend: [String]
    }

    /// `seen` is nil the first time a build with the sender runs: what's there is old, and stays unsent.
    public static func plan(names: [String], seen: [String]?) -> Plan {
        let ours = names.filter(isOurs).sorted()
        guard let seen else { return Plan(baseline: ours, toSend: []) }
        let known = Set(seen)
        return Plan(baseline: nil, toSend: ours.filter { !known.contains($0) })
    }

    /// What to remember after a scan: what was seen before and the reports now settled (delivered, refused or unreadable),
    /// the newest 200. A report whose delivery wasn't settled isn't in it, so the next scan tries it again.
    public static func remembered(seen: [String], settled: [String]) -> [String] {
        var list = seen
        for name in settled where !list.contains(name) { list.append(name) }
        return Array(list.suffix(200))
    }

    public static func delivery(forStatus status: Int?) -> Delivery {
        guard let status else { return .retry }
        switch status {
        case 200..<300: return .delivered
        case 408, 425, 429, 500..<600: return .retry
        default: return .refused
        }
    }

    /// macOS may still be writing a report a moment after the crash: one changed in the last few seconds waits for the
    /// next scan (half a report reads as nothing).
    public static func isStillBeingWritten(modified: Date?, now: Date, within seconds: TimeInterval = 20) -> Bool {
        guard let modified else { return false }
        return now.timeIntervalSince(modified) < seconds
    }

    // The brain's panics aren't files macOS keeps: they're read from brain.log once, as the brain exits. One that couldn't
    // be delivered waits here (as text), a few at most, for the next scan.
    public static let pendingLimit = 5
    public static let pendingEventBytes = 40_000

    public static func queued(_ queue: [String], adding event: String) -> [String] {
        guard event.utf8.count <= pendingEventBytes else { return queue }
        return Array((queue + [event]).suffix(pendingLimit))
    }
}
