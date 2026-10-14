import Foundation
import MokuKit

/// One day of counts for `day_summary` (docs/specs/deeper-analytics.md, metrics 9, 16, 17 and 18): numbers only. It's
/// added to as things happen (`UsageEvents.count`, and the events that go by), kept in ~/.moku/usage-day.json so a quit
/// loses nothing, and sent once the day is over, as one event.
struct UsageDay: Codable, Equatable {
    /// The local day it counts ("2026-10-06").
    var day: String
    /// Plain counts, by the summary's property name.
    var counts: [String: Int] = [:]
    /// Timings and samples, by bucket: the bucket's upper bound → how many fell in it. Medians and 95th percentiles come
    /// from these, so a day of judgments costs a few dozen numbers, not thousands.
    var buckets: [String: [Int: Int]] = [:]
    /// Today's numbers as the brain last gave them.
    var focusedMinutes = 0, returns = 0, longestMinutes = 0

    /// Milliseconds, in steps (the last catches anything slower).
    static let msSteps = [25, 50, 100, 150, 200, 300, 500, 750, 1000, 1500, 2000, 3000, 5000, 7500, 10_000, 15_000, 30_000, 60_000, 600_000]
    /// The share of one CPU core, in thousandths, in steps: 0.1 %, 0.2 %, 0.5 %, 1 %, 2 %, 5 %, 10 %, 20 %, 50 %, a whole core.
    static let coreSteps = [0, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000]
    /// Memory in steps of 50 MB.
    static let memoryStep = 50

    mutating func add(_ count: UsageCount) {
        switch count {
        case .hover: bump("hovers")
        case .drag: bump("drags")
        case .toss: bump("tosses")
        case .companionClick: bump("clicks")
        case .popoverBlink: bump("popover_blinks")
        case let .talent(talent): bump("talent_\(talent.rawValue)")
        case .waterReminder: bump("water_reminders")
        case .activeMinute: bump("active_minutes")
        case let .verdict(verdict): bump("verdicts_\(verdict.rawValue)")
        case let .brainAnswer(ms): sample("brain_ms", Self.step(ms, Self.msSteps))
        case let .jevAnswer(ms): sample("jev_ms", Self.step(ms, Self.msSteps))
        case let .lunaAnswer(ms): sample("luna_ms", Self.step(ms, Self.msSteps))
        case .stall: bump("stalls")
        case let .framesDropped(frames): bump("frames_dropped", by: max(0, frames))
        case let .resources(memoryMB, corePermille):
            sample("memory_mb", max(0, memoryMB) / Self.memoryStep * Self.memoryStep)
            sample("core_permille", Self.coreSteps.last { $0 <= max(0, corePermille) } ?? 0)
        case let .today(focused, returns, longest):
            focusedMinutes = max(0, focused); self.returns = max(0, returns); longestMinutes = max(0, longest)
        }
    }

    /// A minute at the Mac with the companion hidden, by the person or for a call (UsageEvents knows which).
    mutating func addHiddenMinute(byPerson: Bool) { bump(byPerson ? "minutes_hidden_person" : "minutes_hidden_call") }

    /// What the day's events add to it: drifts by the step they reached, pats and corrections, the menu bar icon's clicks.
    mutating func observe(_ name: String, _ props: [String: UsageValue]) {
        switch (name, props) {
        case let ("drift_step", props): if case let .word(step)? = props["step"] { bump("drifts_\(step)") }
        case let ("correction", props) where props["kind"] == .word("pat"): bump("pats")
        case ("correction", _): bump("corrections")
        case let ("popover_opened", props) where props["from"] == .word("menubar"): bump("icon_clicks")
        default: break
        }
    }

    /// The properties of its `day_summary`: every count (zero when nothing happened), the medians and 95th percentiles,
    /// and what the dashboards break it down by.
    func summary(daysAgo: Int, daysSinceInstall: Int?) -> [String: UsageValue] {
        var props: [String: UsageValue] = ["days_ago": .int(daysAgo), "focused_minutes": .int(focusedMinutes), "returns": .int(returns),
                                           "longest_minutes": .int(longestMinutes)]
        for key in Self.countKeys { props[key] = .int(counts[key] ?? 0) }
        let person = counts["minutes_hidden_person"] ?? 0, call = counts["minutes_hidden_call"] ?? 0
        props["minutes_hidden"] = .int(person + call); props["minutes_hidden_person"] = .int(person); props["minutes_hidden_call"] = .int(call)
        if let daysSinceInstall { props["days_since_install"] = .int(daysSinceInstall) }
        for (key, name) in [("brain_ms", "brain"), ("jev_ms", "jev"), ("luna_ms", "luna")] {
            if let p50 = percentile(key, 0.5) { props["\(name)_p50_ms"] = .int(p50) }
            if let p95 = percentile(key, 0.95) { props["\(name)_p95_ms"] = .int(p95) }
        }
        if let memory = percentile("memory_mb", 0.5) { props["memory_mb"] = .int(memory) }
        if let core = percentile("core_permille", 0.5) { props["core_permille"] = .int(core) }
        return props
    }

    /// The counts every summary carries.
    static let countKeys = [
        "active_minutes", "hovers", "drags", "tosses", "clicks", "icon_clicks", "popover_blinks", "pats", "corrections",
        "drifts_sad", "drifts_long", "drifts_tall", "drifts_ask",
        "verdicts_work", "verdicts_switched", "verdicts_drift", "verdicts_unknown",
        "talent_scan", "talent_hologram", "talent_petals", "talent_sniff", "water_reminders", "stalls", "frames_dropped",
    ]

    /// The bucket below which `fraction` of the samples fall (nil: none).
    func percentile(_ key: String, _ fraction: Double) -> Int? {
        guard let histogram = buckets[key], !histogram.isEmpty else { return nil }
        let total = histogram.values.reduce(0, +)
        let wanted = max(1, Int((Double(total) * fraction).rounded(.up)))
        var seen = 0
        for bound in histogram.keys.sorted() {
            seen += histogram[bound] ?? 0
            if seen >= wanted { return bound }
        }
        return histogram.keys.max()
    }

    /// The first step at or above `value` (the last step for anything beyond).
    static func step(_ value: Int, _ steps: [Int]) -> Int { steps.first { value <= $0 } ?? steps[steps.count - 1] }

    private mutating func bump(_ key: String, by amount: Int = 1) { counts[key, default: 0] += amount }
    private mutating func sample(_ key: String, _ bucket: Int) { buckets[key, default: [:]][bucket, default: 0] += 1 }
}
