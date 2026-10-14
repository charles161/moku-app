import Foundation
import Testing
@testable import MokuKit

/// A friend's crash never reached PostHog (2026-10-12). The sender (app/Moku CrashReports.swift) lived in the app shell,
/// untested: it matched report names by case, so the brain's own ("moku-brain-….ips") were never looked at; it marked a
/// report sent even when the post failed; and it looked once, at launch. These are the rules, now under test.
@Suite struct CrashReportFilesTests {
    @Test func ourReportsAreFoundWhateverTheCase() {
        for name in ["Moku-2026-10-11-173512.ips", "Moku_2026-10-11-173512.ips", "moku-brain-2026-10-11-173512.ips", "Moku Helper-2026-10-11.ips", "MOKU-2026-10-11.ips"] {
            #expect(CrashReportFiles.isOurs(name), "\(name)")
        }
    }

    @Test func otherAppsAndOtherFilesAreLeftAlone() {
        for name in ["Safari-2026-10-11-173512.ips", "Mokuro-2026-10-11.ips", "Moku-2026-10-11.txt", "Moku.crash", "Moku", "", ".ips", "Moku-2026.ips.bak"] {
            #expect(!CrashReportFiles.isOurs(name), "\(name)")
        }
    }

    @Test func theFirstScanOnlyTakesNoteOfWhatIsThere() {
        let plan = CrashReportFiles.plan(names: ["Moku-b.ips", "Moku-a.ips", "Safari-x.ips"], seen: nil)
        #expect(plan.toSend.isEmpty)
        #expect(plan.baseline == ["Moku-a.ips", "Moku-b.ips"])
    }

    @Test func laterScansSendWhatIsNewInOrder() {
        let plan = CrashReportFiles.plan(names: ["Moku-c.ips", "Moku-a.ips", "moku-brain-b.ips", "Safari-x.ips"], seen: ["Moku-a.ips"])
        #expect(plan.baseline == nil)
        #expect(plan.toSend == ["Moku-c.ips", "moku-brain-b.ips"].sorted())
    }

    @Test func aReportThatCameLateIsStillSentAfterEarlierOnesWereSeen() {
        // macOS writes the report after the process is gone: a scan that ran too early doesn't miss it for good.
        let early = CrashReportFiles.plan(names: ["Moku-a.ips"], seen: ["Moku-a.ips"])
        #expect(early.toSend.isEmpty)
        let late = CrashReportFiles.plan(names: ["Moku-a.ips", "Moku-b.ips"], seen: ["Moku-a.ips"])
        #expect(late.toSend == ["Moku-b.ips"])
    }

    @Test func aReportIsRememberedOnlyOnceItsDeliveryIsSettled() {
        // Delivered, or sent and refused for good, or unreadable: done. Not delivered for now: tried again next scan.
        let seen = CrashReportFiles.remembered(seen: ["Moku-a.ips"], settled: ["Moku-b.ips", "Moku-c.ips"])
        #expect(seen == ["Moku-a.ips", "Moku-b.ips", "Moku-c.ips"])
        let plan = CrashReportFiles.plan(names: ["Moku-a.ips", "Moku-b.ips", "Moku-c.ips", "Moku-d.ips"], seen: seen)
        #expect(plan.toSend == ["Moku-d.ips"])
    }

    @Test func theMemoryKeepsTheNewest200() {
        let many = (0..<250).map { String(format: "Moku-%03d.ips", $0) }
        let kept = CrashReportFiles.remembered(seen: many, settled: [])
        #expect(kept.count == 200 && kept.first == "Moku-050.ips" && kept.last == "Moku-249.ips")
    }

    @Test func aStatusIsDeliveredRetriedOrRefused() {
        #expect(CrashReportFiles.delivery(forStatus: 200) == .delivered)
        #expect(CrashReportFiles.delivery(forStatus: 204) == .delivered)
        for retry in [408, 425, 429, 500, 502, 503, 504] { #expect(CrashReportFiles.delivery(forStatus: retry) == .retry, "\(retry)") }
        for refused in [400, 401, 403, 404, 413] { #expect(CrashReportFiles.delivery(forStatus: refused) == .refused, "\(refused)") }
        #expect(CrashReportFiles.delivery(forStatus: nil) == .retry, "no answer at all (offline, blocked): try again later")
    }

    @Test func aReportStillBeingWrittenWaits() {
        let now = Date()
        #expect(CrashReportFiles.isStillBeingWritten(modified: now.addingTimeInterval(-3), now: now))
        #expect(!CrashReportFiles.isStillBeingWritten(modified: now.addingTimeInterval(-60), now: now))
        #expect(!CrashReportFiles.isStillBeingWritten(modified: nil, now: now))
    }

    @Test func failedBrainPanicsWaitForTheNextTryAndAreFew() {
        var queue: [String] = []
        for number in 0..<(CrashReportFiles.pendingLimit + 3) { queue = CrashReportFiles.queued(queue, adding: "event \(number)") }
        #expect(queue.count == CrashReportFiles.pendingLimit)
        #expect(queue.last == "event \(CrashReportFiles.pendingLimit + 2)")
        #expect(CrashReportFiles.queued(["a"], adding: String(repeating: "x", count: CrashReportFiles.pendingEventBytes + 1)) == ["a"], "too big to keep")
    }
}
