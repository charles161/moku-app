import Foundation
import MokuKit

/// The opt-in daily heartbeat (docs/launch-plan.md §5), so Charles can tell when Moku isn't working for someone.
/// Only when the person has turned on "Share daily counts" in Settings (off by default): each finished day not
/// sent yet, the last three at most, goes through the relay as the brain's numbers for that day (GET /v1/counts)
/// plus a few of the app's own, taken when it's sent (version, macOS, chip, plan, permissions, CPU, memory).
/// Days with nothing on screen are skipped. A day that fails is tried again on the next tick.
/// Numbers only: the brain's counts are numbers by construction, and the relay drops anything else.
@MainActor
public final class DailyHeartbeat {
    /// What the app adds: top-level strings (version, build, macos, chip, plan) and "app": [String: number or Bool].
    public typealias Facts = @MainActor () async -> [String: Any]
    static let sentThroughKey = "Moku.heartbeatSentThrough"
    static let catchUpDays = 3

    private let defaults: UserDefaults
    private let relay: URL
    private let device: String
    private let counts: (Date) async throws -> Data
    private let facts: Facts
    private let post: RelayAccess.Post
    private let now: () -> Date
    private var sending = false

    public init(defaults: UserDefaults = .standard, relay: URL = RelayAccess.defaultRelay, device: String = RelayAccess.deviceHash(),
                counts: @escaping (Date) async throws -> Data, facts: @escaping Facts, post: RelayAccess.Post? = nil, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.relay = relay; self.device = device; self.counts = counts; self.facts = facts; self.now = now
        self.post = post ?? { url, body in
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "content-type"); request.httpBody = body
            let (data, response) = try await MokuNetwork.session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// Sends what's due and returns the days it sent. Cheap when nothing is: the days already done are skipped.
    @discardableResult public func tick() async -> [String] {
        guard defaults.bool(forKey: DailyCounts.shareKey), !sending else { return [] }
        sending = true; defer { sending = false }
        let calendar = Calendar.current, today = calendar.startOfDay(for: now())
        var sent: [String] = []
        for back in stride(from: Self.catchUpDays, through: 1, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let day = BrainClient.localDay(date)
            if let through = defaults.string(forKey: Self.sentThroughKey), day <= through { continue }
            // The brain isn't answering: this day and the ones after wait for the next tick.
            guard let data = try? await counts(date), var numbers = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return sent }
            if (numbers["screens"] as? Int ?? 0) > 0 {
                var body = await facts()
                numbers.removeValue(forKey: "date")
                numbers["app"] = body.removeValue(forKey: "app")
                body["device"] = device; body["day"] = day; body["counts"] = numbers
                switch await send(body) {
                case .sent: sent.append(day)
                case .refused: break  // the relay will never take this one (a bad body): move on
                case .later: return sent
                }
            }
            defaults.set(day, forKey: Self.sentThroughKey)
        }
        return sent
    }

    private enum Outcome { case sent, refused, later }

    private func send(_ body: [String: Any]) async -> Outcome {
        guard let json = try? JSONSerialization.data(withJSONObject: body) else { return .refused }
        guard let (_, code) = try? await post(relay.appendingPathComponent("v1/heartbeat"), json) else { return .later }
        switch code {
        case 200..<300: return .sent
        case 429, 500...: return .later
        default: return .refused
        }
    }
}
