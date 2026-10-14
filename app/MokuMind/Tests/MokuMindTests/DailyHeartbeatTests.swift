import Foundation
import Testing
import MokuKit
@testable import MokuMind

@MainActor
@Suite("Daily heartbeat")
struct DailyHeartbeatTests {
    let device = String(repeating: "c", count: 64)
    /// 15:00 local on 2026-09-29: the finished days to catch up on are the 26th, 27th and 28th.
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 15))!

    func defaults(sharing: Bool) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "moku-heartbeat-\(UUID().uuidString)")!
        defaults.set(sharing, forKey: DailyCounts.shareKey)
        return defaults
    }

    /// The brain's counts: nothing on screen on the 27th.
    nonisolated static func counts(_ date: Date) throws -> Data {
        let day = BrainClient.localDay(date)
        return try JSONSerialization.data(withJSONObject: ["date": day, "screens": day == "2026-09-27" ? 0 : 400, "verdicts": ["working": 300, "drifting": 60]])
    }

    func heartbeat(_ defaults: UserDefaults, asked: LockedBox<[String]> = LockedBox([]), status: LockedBox<Int> = LockedBox(202), sent: LockedBox<[[String: Any]]> = LockedBox([])) -> DailyHeartbeat {
        DailyHeartbeat(defaults: defaults, relay: URL(string: "https://relay.example")!, device: device,
                       counts: { date in asked.mutate { $0.append(BrainClient.localDay(date)) }; return try Self.counts(date) },
                       facts: { ["version": "0.4.0", "plan": "tester", "app": ["cpuPercent": 3.1, "screenRecording": true]] },
                       post: { url, body in
                           #expect(url.absoluteString == "https://relay.example/v1/heartbeat")
                           sent.mutate { $0.append(try! JSONSerialization.jsonObject(with: body) as! [String: Any]) }
                           return (Data(), status.value)
                       }, now: { now })
    }

    @Test func offByDefaultAndOffMeansNothingIsAskedOrSent() async {
        let asked = LockedBox<[String]>([]), sent = LockedBox<[[String: Any]]>([])
        let beat = heartbeat(UserDefaults(suiteName: "moku-heartbeat-\(UUID().uuidString)")!, asked: asked, sent: sent)
        #expect(await beat.tick().isEmpty)
        #expect(asked.value.isEmpty && sent.value.isEmpty)
    }

    @Test func sendsEachFinishedDayOnceSkippingEmptyDaysWithTheAppsNumbersInside() async throws {
        let store = defaults(sharing: true), sent = LockedBox<[[String: Any]]>([])
        let beat = heartbeat(store, sent: sent)
        #expect(await beat.tick() == ["2026-09-26", "2026-09-28"])
        let first = try #require(sent.value.first)
        #expect(first["device"] as? String == device && first["day"] as? String == "2026-09-26")
        #expect(first["version"] as? String == "0.4.0" && first["plan"] as? String == "tester" && first["app"] == nil)
        let counts = try #require(first["counts"] as? [String: Any])
        #expect(counts["screens"] as? Int == 400 && counts["date"] == nil)
        #expect((counts["app"] as? [String: Any])?["screenRecording"] as? Bool == true)
        #expect(await beat.tick().isEmpty)  // all done until tomorrow
        #expect(sent.value.count == 2)
    }

    @Test func aDayTheRelayCouldNotTakeNowIsSentLaterAndABadOneIsDropped() async {
        let store = defaults(sharing: true), status = LockedBox(503), sent = LockedBox<[[String: Any]]>([])
        let beat = heartbeat(store, status: status, sent: sent)
        #expect(await beat.tick().isEmpty)
        #expect(sent.value.count == 1)  // stopped at the first failure
        status.mutate { $0 = 202 }
        #expect(await beat.tick() == ["2026-09-26", "2026-09-28"])
        let refusing = heartbeat(defaults(sharing: true), status: LockedBox(400))
        #expect(await refusing.tick().isEmpty)
        #expect(await refusing.tick().isEmpty)  // not tried again
    }

    @Test func aBrainThatIsNotAnsweringLeavesTheDaysForLater() async {
        let store = defaults(sharing: true)
        let down = DailyHeartbeat(defaults: store, relay: URL(string: "https://relay.example")!, device: device,
                                  counts: { _ in throw URLError(.cannotConnectToHost) }, facts: { [:] }, post: { _, _ in (Data(), 202) }, now: { now })
        #expect(await down.tick().isEmpty)
        #expect(store.string(forKey: DailyHeartbeat.sentThroughKey) == nil)
        #expect(await heartbeat(store).tick() == ["2026-09-26", "2026-09-28"])
    }
}
