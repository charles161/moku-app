import Foundation
import Testing
import MokuKit
@testable import MokuMind

/// Moku's own errors as `app_error`: each kind at each place once in 10 minutes, 30 an hour at most, the brain's counts
/// read as what's new since the last look.
@MainActor
@Suite("Error log")
struct ErrorLogTests {
    final class Sent {
        var events: [(name: String, props: [String: UsageValue])] = []
        var counts: [Int] { events.compactMap { if case let .int(n)? = $0.props["count"] { n } else { nil } } }
    }

    func log(_ sent: Sent, now: LockedBox<Date>) -> ErrorLog {
        ErrorLog(track: { name, props in sent.events.append((name, props)) }, now: { now.value })
    }

    let start = Date(timeIntervalSince1970: 1_790_000_000)
    let unreachable = ErrorReport(kind: .brainUnreachable, domain: "url", code: -1004, place: "BrainClient.swift:today")

    @Test func anErrorGoesAtOnceAndTheSameOneAgainIsFoldedIntoTheNextAfterTenMinutes() {
        let sent = Sent(), now = LockedBox(start)
        let errors = log(sent, now: now)
        // In Moku's first minute the brain is still starting: not answering isn't an error yet.
        errors.note(unreachable)
        #expect(sent.events.isEmpty)
        now.mutate { $0 = $0.addingTimeInterval(ErrorLog.brainStartSeconds) }
        errors.note(unreachable)
        #expect(sent.events.count == 1)
        #expect(sent.events[0].name == "app_error")
        #expect(sent.events[0].props == ["kind": .word("brain_unreachable"), "domain": .word("url"), "code": .int(-1004),
                                         "where": .word("BrainClient.swift:today"), "count": .int(1)])
        for _ in 0..<5 { errors.note(unreachable) }
        // The same kind somewhere else is its own error.
        errors.note(ErrorReport(kind: .brainUnreachable, domain: "url", code: -1004, place: "BrainClient.swift:judge"))
        #expect(sent.events.count == 2)
        now.mutate { $0 = $0.addingTimeInterval(ErrorLog.foldSeconds) }
        errors.note(unreachable)
        #expect(sent.counts == [1, 1, 6])
        // Quitting sends what's folded.
        errors.note(unreachable)
        errors.sendAll()
        #expect(sent.counts == [1, 1, 6, 1])
        errors.sendAll()
        #expect(sent.events.count == 4)
    }

    @Test func noMoreThanThirtyGoInAnHour() {
        let sent = Sent(), now = LockedBox(start)
        let errors = log(sent, now: now)
        now.mutate { $0 = $0.addingTimeInterval(ErrorLog.brainStartSeconds) }
        for n in 0..<40 { errors.note(ErrorReport(kind: .assetLoad, domain: "cocoa", code: 4, place: "HomeWorld.swift:place\(n)")) }
        #expect(sent.events.count == ErrorLog.maxPerHour)
        now.mutate { $0 = $0.addingTimeInterval(3600) }
        errors.note(ErrorReport(kind: .assetLoad, domain: "cocoa", code: 4, place: "HomeWorld.swift:place35"))
        #expect(sent.events.count == 31 && sent.counts.last == 2)  // the one held back comes with it
        errors.sendAll()
        #expect(sent.events.count == 40)
    }

    @Test func theBrainsCountsAreSentAsWhatsNewSinceTheLastLook() {
        let sent = Sent(), now = LockedBox(start)
        let errors = log(sent, now: now)
        errors.brainCounts([BrainErrorCount(kind: "task", place: "labeler.go:Labeler.enqueue.func1", count: 2),
                            BrainErrorCount(kind: "nonsense", place: "app.go:x", count: 1),
                            BrainErrorCount(kind: "request", place: "/Users/priya/app.go:x", count: 1)])
        #expect(sent.events.count == 1)
        #expect(sent.events[0].props == ["kind": .word("brain_task"), "domain": .word("go"), "code": .int(0),
                                         "where": .word("labeler.go:Labeler.enqueue.func1"), "count": .int(2)])
        now.mutate { $0 = $0.addingTimeInterval(ErrorLog.foldSeconds) }
        errors.brainCounts([BrainErrorCount(kind: "task", place: "labeler.go:Labeler.enqueue.func1", count: 2)])
        #expect(sent.events.count == 1)  // nothing new
        errors.brainCounts([BrainErrorCount(kind: "task", place: "labeler.go:Labeler.enqueue.func1", count: 5)])
        #expect(sent.counts == [2, 3])
        // A brain that started again counts from nothing.
        now.mutate { $0 = $0.addingTimeInterval(ErrorLog.foldSeconds) }
        errors.brainCounts([BrainErrorCount(kind: "task", place: "labeler.go:Labeler.enqueue.func1", count: 1)])
        #expect(sent.counts == [2, 3, 1])
    }

    @Test func theBrainsHealthIsReadLeniently() {
        let health = Data("""
        {"ok":true,"service":"moku-brain","errors":[{"kind":"request","where":"app.go:NewHandler.func1","count":3},
         {"kind":"task","where":"brain.go:Background.Go.func1"},{"kind":7,"where":"x.go:y","count":1},
         {"kind":"disk","where":"retention.go:Brain.Retain","count":1}]}
        """.utf8)
        #expect(BrainErrorCount.list(fromHealth: health) == [BrainErrorCount(kind: "request", place: "app.go:NewHandler.func1", count: 3),
                                                             BrainErrorCount(kind: "disk", place: "retention.go:Brain.Retain", count: 1)])
        #expect(BrainErrorCount.list(fromHealth: Data(#"{"ok":true}"#.utf8)).isEmpty)  // an older brain
        #expect(BrainErrorCount.list(fromHealth: Data(#"{"errors":"lots"}"#.utf8)).isEmpty)
    }

    @Test func anAppErrorIsQueuedWithItsPlaceAndEveryKindTheRelayTakes() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("moku-usage-\(UUID().uuidString)/usage-queue.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let usage = UsageEvents(file: file, relay: URL(string: "https://relay.example")!, device: String(repeating: "d", count: 64),
                                appVersion: "0.1.10", post: { _, _, _ in 202 }, flushDelay: .seconds(3600))
        let now = LockedBox(start)
        let errors = ErrorLog(track: { name, props in usage.track(name, props) }, now: { now.value })
        now.mutate { $0 = $0.addingTimeInterval(ErrorLog.brainStartSeconds) }
        for kind in ErrorReport.Kind.allCases {
            errors.note(ErrorReport(kind: kind, domain: "posix", code: 28, place: "UsageEvents.swift:save"))
        }
        #expect(usage.queue.count == ErrorReport.Kind.allCases.count)
        #expect(usage.queue.allSatisfy { $0.name == "app_error" && $0.props["where"] == .word("UsageEvents.swift:save") && $0.props["code"] == .int(28) })
        #expect(Set(usage.queue.compactMap { if case let .word(kind)? = $0.props["kind"] { kind } else { nil } })
                == Set(ErrorReport.Kind.allCases.map(\.rawValue)))
    }
}
