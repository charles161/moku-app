import Foundation
import MokuKit

/// Moku's own errors (`ErrorReports`, and the brain's from its /health) as the usage event `app_error`, which the relay
/// passes to PostHog as an `$exception` with level "error". Like `TroubleLog`: the same kind at the same place is sent at
/// most once in 10 minutes, what happens meanwhile folded into the next one's count; and no more than 30 go in an hour,
/// so a Mac in a bad way sends a little, not a flood. The brain not answering in Moku's first minute isn't an error: it's
/// still starting.
@MainActor
public final class ErrorLog {
    public static let foldSeconds: TimeInterval = 600
    public static let maxPerHour = 30
    public static let brainStartSeconds: TimeInterval = 60
    private let track: UsageTracker
    private let now: () -> Date
    private let startedAt: Date
    private var lastSent: [String: Date] = [:]
    private var folded: [String: ErrorReport] = [:]
    private var sentTimes: [Date] = []
    /// The brain's counts at the last look, by kind and place: what's above them is new.
    private var brainSeen: [String: Int] = [:]

    public init(track: @escaping UsageTracker, now: @escaping () -> Date = Date.init) {
        self.track = track; self.now = now; startedAt = now()
    }

    /// One error, from anywhere in the app (`ErrorReports.sink`).
    public func note(_ report: ErrorReport) {
        if report.kind == .brainUnreachable, now().timeIntervalSince(startedAt) < Self.brainStartSeconds { return }
        let key = "\(report.kind.rawValue) \(report.place)"
        var report = report
        if let earlier = folded[key] { report.count += earlier.count }
        let time = now()
        sentTimes.removeAll { time.timeIntervalSince($0) >= 3600 }
        if let last = lastSent[key], time.timeIntervalSince(last) < Self.foldSeconds { folded[key] = report; return }
        if sentTimes.count >= Self.maxPerHour { folded[key] = report; return }
        folded[key] = nil
        lastSent[key] = time
        sentTimes.append(time)
        send(report)
    }

    /// The brain's errors from its /health: counts since it started, by kind and place. What's new since the last look is
    /// noted; a count lower than before is a brain that started again, all of it new.
    public func brainCounts(_ counts: [BrainErrorCount]) {
        for count in counts {
            guard let kind = BrainErrorCount.kinds[count.kind], ErrorReports.isPlace(count.place) else { continue }
            let key = "\(count.kind) \(count.place)"
            let new = count.count >= (brainSeen[key] ?? 0) ? count.count - (brainSeen[key] ?? 0) : count.count
            brainSeen[key] = count.count
            if new > 0 { note(ErrorReport(kind: kind, domain: "go", code: 0, place: count.place, count: new)) }
        }
    }

    /// Moku is quitting: what was folded goes now.
    public func sendAll() {
        for report in folded.values { send(report) }
        folded = [:]
    }

    private func send(_ report: ErrorReport) {
        track("app_error", ["kind": .word(report.kind.rawValue), "domain": .word(report.domain), "code": .int(report.code),
                            "where": .word(report.place), "count": .int(min(max(report.count, 1), 100_000))])
    }
}

/// One line of the brain's error counts on /health (brain-go errors.go): a kind, the place in its code, and how many
/// times since it started.
public struct BrainErrorCount: Sendable, Equatable {
    public var kind: String
    public var place: String
    public var count: Int

    public init(kind: String, place: String, count: Int) { self.kind = kind; self.place = place; self.count = count }

    /// The brain's kinds, and the report each one is.
    static let kinds: [String: ErrorReport.Kind] = ["request": .brainRequest, "task": .brainTask, "disk": .brainDisk, "store": .brainStore]

    /// The counts in a /health answer; an entry that isn't one is left out, and an older brain has none.
    public static func list(fromHealth data: Data) -> [BrainErrorCount] {
        struct Lenient: Decodable {
            var kind: String?, `where`: String?, count: Int?
            enum CodingKeys: CodingKey { case kind, `where`, count }
            init(from decoder: any Decoder) throws {
                let entry = try decoder.container(keyedBy: CodingKeys.self)
                kind = try? entry.decode(String.self, forKey: .kind)
                `where` = try? entry.decode(String.self, forKey: .where)
                count = try? entry.decode(Int.self, forKey: .count)
            }
        }
        struct Health: Decodable { var errors: [Lenient]? }
        let entries = (try? JSONDecoder().decode(Health.self, from: data))?.errors ?? []
        return entries.compactMap { entry in
            guard let kind = entry.kind, let place = entry.where, let count = entry.count, count >= 0 else { return nil }
            return BrainErrorCount(kind: kind, place: place, count: count)
        }
    }
}
