import Foundation

/// How this Mac reaches Moku's cloud brain (Jev and Luna): a 21-day trial, a tester's invite, a paid plan, the
/// developer's own gateway key, or nothing yet. Whatever it is, Moku keeps working: without the cloud it judges by
/// its rules (and by the local model in builds that carry one, `LocalBrain.isBundled`).
public struct AccessStatus: Sendable, Equatable {
    public enum Plan: String, Sendable { case trial, tester, pro, ownKey, none }
    public var plan: Plan
    /// When a trial or a paid Pro period ends; nil for the others.
    public var expiresAt: Date?

    public init(plan: Plan, expiresAt: Date? = nil) { self.plan = plan; self.expiresAt = expiresAt }

    /// Days left in a trial, counting today (21 on the first day, 1 on the last, 0 once it has ended); nil otherwise.
    public func daysLeft(now: Date = Date()) -> Int? {
        guard plan == .trial, let expiresAt else { return nil }
        return max(0, Int(ceil(expiresAt.timeIntervalSince(now) / 86_400)))
    }

    /// Settings offers Moku Pro: on a trial (running or ended) and with nothing at all; never to a tester or on Pro.
    public var offersPro: Bool { plan == .trial || plan == .none }

    /// One line for Settings.
    public func line(now: Date = Date()) -> String {
        switch plan {
        case .trial:
            guard let days = daysLeft(now: now), days > 0 else {
                return "Your free trial of Moku’s cloud brain has ended. Moku Pro, or an invite code, turns it back on."
            }
            return days == 1 ? "Free trial: the last day of Moku’s cloud brain." : "Free trial: \(days) days of Moku’s cloud brain left."
        case .tester: return "You’re a Moku tester. Thank you."
        case .pro: return "Moku Pro: Moku’s cloud brain. Thank you for supporting Moku."
        case .ownKey: return "Using your own AI Gateway key (development)."
        case .none: return LocalBrain.isBundled ? "Moku thinks on your Mac. An invite code turns on its cloud brain." : "Moku needs its cloud brain to tell work from a detour. An invite code turns it on."
        }
    }
}

/// Settings › "Share daily counts": the opt-in daily heartbeat (MokuMind's DailyHeartbeat). Off unless turned on.
public enum DailyCounts {
    public static let shareKey = "Moku.shareDailyCounts"
}

/// Whether this build carries the local model (the llama.cpp server the brain falls back to). Release builds for the
/// beta don't (MOKU_LOCAL_MODEL=0), so nothing may promise that Moku "thinks on your Mac" without it.
public enum LocalBrain {
    public static let isBundled: Bool = {
        guard let resources = Bundle.main.resourceURL else { return false }
        return FileManager.default.isExecutableFile(atPath: resources.appendingPathComponent("llama/llama-server").path)
    }()
}
