import Foundation
import Testing
import MokuKit
@testable import MokuMind

/// The day's summary (`day_summary`), the companion on every event, and what breaks (`trouble`).
@MainActor
@Suite("Usage: the day's summary and trouble")
struct UsageDayTests {
    let start = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21, mid-morning in UTC
    var utc: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!; return calendar }

    func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("moku-usage-day-\(UUID().uuidString)") }

    func client(_ folder: URL, now: LockedBox<Date>, companion: String = "tetsu") -> UsageEvents {
        UsageEvents(file: folder.appendingPathComponent("usage-queue.json"), relay: URL(string: "https://relay.example")!,
                    device: String(repeating: "d", count: 64), appVersion: "0.1.9", common: { ["companion": .word(companion)] },
                    installedAt: start.addingTimeInterval(-3 * 86_400), calendar: utc, post: { _, _, _ in 202 }, now: { now.value },
                    flushDelay: .seconds(3600))
    }

    /// Hidden minutes are counted as they pass, at the Mac, by who hid it. 2ba8 kept the companion hidden all day
    /// (2026-10-07), but its day_summary said 59 minutes, all calls: minutes were added only at `shown`, so a hide still
    /// on at midnight, or from before the launch, counted nothing.
    @Test func hiddenMinutesAreCountedAsTheyPassByWhoHidIt() throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let now = LockedBox(start)
        let usage = client(dir, now: now)
        func minutes(_ n: Int) { for _ in 0..<n { now.mutate { $0 = $0.addingTimeInterval(60) }; usage.count(.activeMinute) } }
        usage.track("app_opened", ["hidden": .bool(true)])  // put away before this launch
        minutes(30)
        usage.track("shown", ["by": .word("person"), "after_seconds": .int(86_400)])
        minutes(5)
        usage.track("hidden", ["by": .word("call")])
        minutes(12)
        usage.track("shown", ["by": .word("automatic"), "after_seconds": .int(720)])
        usage.track("hidden", ["by": .word("person")])
        minutes(20)  // still hidden at midnight
        usage.sendBeforeQuit()
        now.mutate { $0 = $0.addingTimeInterval(86_400) }
        let next = client(dir, now: now)
        next.track("day_opened", ["from": .word("popover")])
        let p = try #require(next.queue.first { $0.name == "day_summary" }).props
        #expect(p["minutes_hidden_person"] == .int(50)); #expect(p["minutes_hidden_call"] == .int(12)); #expect(p["minutes_hidden"] == .int(62))
    }

    /// A nudge nobody saw isn't one: while the person has the companion hidden, drift steps aren't sent or counted, and
    /// hiding it again soon after isn't frustration. Nor is a break suggestion nobody saw (PostHog, 2026-10-14: 35
    /// suggested in four days on Macs where the companion was hidden all day, none taken).
    @Test func driftStepsWhileTheCompanionIsHiddenAreNotNudges() throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let now = LockedBox(start)
        let usage = client(dir, now: now)
        usage.track("hidden", ["by": .word("person")])
        usage.track("drift_step", ["step": .word("sad")])
        usage.track("ask_outcome", ["outcome": .word("later")])
        usage.track("break_suggested", ["kind": .word("water")])
        #expect(!usage.queue.contains { $0.name == "drift_step" || $0.name == "ask_outcome" || $0.name == "break_suggested" })
        usage.track("shown", ["by": .word("person")])
        usage.track("hidden", ["by": .word("person")])
        #expect(!usage.queue.contains { $0.name == "frustration" })
        usage.track("shown", ["by": .word("welcome")])
        usage.track("drift_step", ["step": .word("sad")])
        #expect(usage.queue.filter { $0.name == "drift_step" }.count == 1)
        now.mutate { $0 = $0.addingTimeInterval(86_400) }
        usage.track("day_opened", ["from": .word("popover")])
        let p = try #require(usage.queue.first { $0.name == "day_summary" }).props
        #expect(p["drifts_sad"] == .int(1))
    }

    @Test func aDayIsSentOnceItsOverAsOneSummaryOfNumbers() throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let now = LockedBox(start)
        let usage = client(dir, now: now)
        for _ in 0..<3 { usage.count(.hover) }
        usage.count(.drag); usage.count(.toss); usage.count(.companionClick); usage.count(.talent(.sniff)); usage.count(.waterReminder)
        usage.count(.verdict(.work)); usage.count(.verdict(.work)); usage.count(.verdict(.switched)); usage.count(.verdict(.drift))
        for ms in [120, 130, 140] { usage.count(.brainAnswer(ms: ms)) }
        usage.count(.brainAnswer(ms: 900))
        usage.count(.jevAnswer(ms: 700)); usage.count(.lunaAnswer(ms: 2400))
        usage.count(.resources(memoryMB: 312, corePermille: 7)); usage.count(.resources(memoryMB: 290, corePermille: 3))
        usage.count(.resources(memoryMB: 340, corePermille: 40))
        usage.count(.today(focusedMinutes: 95, returns: 4, longestMinutes: 41))
        for _ in 0..<61 { usage.count(.activeMinute) }
        usage.count(.stall); usage.count(.framesDropped(3))
        usage.track("drift_step", ["step": .word("sad")]); usage.track("drift_step", ["step": .word("ask")])
        usage.track("correction", ["kind": .word("pat")]); usage.track("correction", ["kind": .word("marked_work")])
        usage.track("popover_opened", ["from": .word("menubar")]); usage.track("popover_opened", ["from": .word("moku")])
        #expect(!usage.queue.contains { $0.name == "day_summary" })
        // Quit and opened again the next morning: the counts were kept, and the first thing of the new day sends them.
        now.mutate { $0 = $0.addingTimeInterval(86_400) }
        let next = client(dir, now: now)
        next.track("day_opened", ["from": .word("popover")])
        let summaries = next.queue.filter { $0.name == "day_summary" }
        let summary = try #require(summaries.first)
        #expect(summaries.count == 1 && next.queue.last?.name == "day_opened")
        let p = summary.props
        #expect(p["days_ago"] == .int(1) && p["days_since_install"] == .int(3) && p["companion"] == .word("tetsu") && p["app_version"] == .word("0.1.9"))
        #expect(p["hovers"] == .int(3) && p["drags"] == .int(1) && p["tosses"] == .int(1) && p["clicks"] == .int(1) && p["icon_clicks"] == .int(1))
        #expect(p["talent_sniff"] == .int(1) && p["talent_petals"] == .int(0) && p["water_reminders"] == .int(1))
        #expect(p["verdicts_work"] == .int(2) && p["verdicts_switched"] == .int(1) && p["verdicts_drift"] == .int(1) && p["verdicts_unknown"] == .int(0))
        #expect(p["brain_p50_ms"] == .int(150) && p["brain_p95_ms"] == .int(1000) && p["jev_p50_ms"] == .int(750) && p["luna_p95_ms"] == .int(3000))
        #expect(p["memory_mb"] == .int(300) && p["core_permille"] == .int(5))
        #expect(p["focused_minutes"] == .int(95) && p["returns"] == .int(4) && p["longest_minutes"] == .int(41) && p["active_minutes"] == .int(61))
        #expect(p["drifts_sad"] == .int(1) && p["drifts_ask"] == .int(1) && p["drifts_long"] == .int(0))
        #expect(p["pats"] == .int(1) && p["corrections"] == .int(1) && p["minutes_hidden"] == .int(0))
        #expect(p["stalls"] == .int(1) && p["frames_dropped"] == .int(3))
        #expect(p["macos"] != nil)
        // Every property is in the summary's shapes: nothing was dropped on the way.
        #expect(Set(p.keys).subtracting(["app_version", "companion"]).isSubset(of: Set(UsageEvents.daySummary.keys)))
        // Sent once: the rest of the new day adds to a new summary.
        next.track("day_opened", ["from": .word("popover")])
        #expect(next.queue.filter { $0.name == "day_summary" }.count == 1)
    }

    @Test func aDayWithNothingInItOrLongAgoIsNotSent() {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let now = LockedBox(start)
        let quiet = client(dir, now: now)
        now.mutate { $0 = $0.addingTimeInterval(86_400) }
        quiet.track("day_opened")
        #expect(!quiet.queue.contains { $0.name == "day_summary" })
        quiet.count(.hover)
        now.mutate { $0 = $0.addingTimeInterval(90 * 86_400) }  // back after three months: that day is too old to say
        quiet.track("day_opened")
        #expect(!quiet.queue.contains { $0.name == "day_summary" })
    }

    @Test func everyEventCarriesTheCompanionOnShowButNeverAnotherWord() {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let usage = client(dir, now: LockedBox(start))
        usage.track("day_opened", ["from": .word("menu")])
        #expect(usage.queue.last?.props["companion"] == .word("tetsu"))
        let odd = client(folder(), now: LockedBox(start), companion: "Clippy")
        odd.track("day_opened", ["from": .word("menu")])
        #expect(odd.queue.last?.props["companion"] == nil)
    }

    @Test func troubleIsSentOnceInTenMinutesWithWhatHappenedMeanwhileFoldedIn() {
        var sent: [[String: UsageValue]] = []
        let now = LockedBox(start)
        let log = TroubleLog(track: { _, props in sent.append(props) }, now: { now.value })
        log.happened("brain_restarted")
        now.mutate { $0 = $0.addingTimeInterval(60) }
        log.happened("brain_restarted")
        log.happened("brain_restarted")
        #expect(sent == [["kind": .word("brain_restarted"), "count": .int(1), "seconds": .int(0)]])
        now.mutate { $0 = $0.addingTimeInterval(600) }
        log.happened("brain_restarted")
        #expect(sent.last == ["kind": .word("brain_restarted"), "count": .int(3), "seconds": .int(0)])
        // A trouble that lasts goes when it ends, with its seconds; another kind starting ends the first.
        log.observe("relay_429", among: TroubleLog.brainKinds)
        now.mutate { $0 = $0.addingTimeInterval(90) }
        log.observe("relay_429", among: TroubleLog.brainKinds)
        log.observe("offline", among: TroubleLog.brainKinds)
        #expect(sent.last == ["kind": .word("relay_429"), "count": .int(1), "seconds": .int(90)])
        now.mutate { $0 = $0.addingTimeInterval(30) }
        log.sendAll()  // quitting: what's still wrong goes too
        #expect(sent.last == ["kind": .word("offline"), "count": .int(1), "seconds": .int(30)])
    }

    @Test func theBrainsHealthSaysWhichTroubleInAFewWords() {
        #expect(TroubleLog.brainKind(answering: false, judgeState: nil, lastError: nil) == "brain_down")
        #expect(TroubleLog.brainKind(answering: true, judgeState: "ok", lastError: "provider 429") == nil)
        #expect(TroubleLog.brainKind(answering: true, judgeState: "backoff", lastError: "provider 429") == "relay_429")
        #expect(TroubleLog.brainKind(answering: true, judgeState: "paused", lastError: "provider 402") == "relay_402")
        #expect(TroubleLog.brainKind(answering: true, judgeState: "paused", lastError: "credentials") == "relay_401")
        #expect(TroubleLog.brainKind(answering: true, judgeState: "backoff", lastError: "provider 503") == "cloud_off")
        #expect(TroubleLog.brainKind(answering: true, judgeState: "backoff", lastError: "provider 502") == "relay_down")
        #expect(TroubleLog.brainKind(answering: true, judgeState: "backoff", lastError: "timeout") == "offline")
        #expect(TroubleLog.brainKind(answering: true, judgeState: "backoff", lastError: "provider") == "offline")
        for kind in ["brain_down", "relay_429", "relay_402", "relay_401", "cloud_off", "relay_down", "offline"] {
            #expect(UsageEvents.troubleKinds.contains(kind) && TroubleLog.brainKinds.contains(kind))
        }
    }
}

/// Trying again and frustration, worked out from the events and counts going by.
@MainActor
@Suite("Usage: repeats and frustration")
struct UsageSignalsTests {
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    func client(now: LockedBox<Date>) -> UsageEvents {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("moku-usage-signals-\(UUID().uuidString)")
        return UsageEvents(file: folder.appendingPathComponent("usage-queue.json"), relay: URL(string: "https://relay.example")!,
                           device: String(repeating: "d", count: 64), appVersion: "0.1.9", post: { _, _, _ in 503 }, now: { now.value },
                           flushDelay: .seconds(3600))  // the relay busy: everything stays in the queue to be read here
    }
    func named(_ usage: UsageEvents, _ name: String) -> [[String: UsageValue]] {
        usage.queue.filter { $0.name == name }.map { $0.props.filter { $0.key != "app_version" } }
    }

    @Test func theSameActionAgainWithin30sIsOneRepeatOnceTheBurstIsOver() async {
        let now = LockedBox(start)
        let usage = client(now: now)
        for second in [0.0, 10, 25] { now.mutate { $0 = start.addingTimeInterval(second) }; usage.track("break", ["what": .word("started")]) }
        now.mutate { $0 = start.addingTimeInterval(40) }
        usage.track("day_opened", ["from": .word("popover")])
        #expect(named(usage, "repeat").isEmpty)  // the burst may go on
        now.mutate { $0 = start.addingTimeInterval(80) }
        usage.track("day_opened", ["from": .word("popover")])  // 40 s after the last one: not a repeat
        #expect(named(usage, "repeat") == [["action": .word("break"), "count": .int(3)]])
        // Settings: the same setting again is a repeat; two different ones aren't.
        usage.track("setting_changed", ["key": .word("size")]); usage.track("setting_changed", ["key": .word("size")])
        usage.track("setting_changed", ["key": .word("companion")])
        // The popover opened and shut at once, twice.
        usage.count(.popoverBlink); usage.count(.popoverBlink)
        usage.sendBeforeQuit(within: 0.01)  // quitting ends every burst
        let actions = named(usage, "repeat").compactMap { if case let .word(word)? = $0["action"] { word } else { nil } }
        #expect(Set(actions) == ["break", "setting", "popover_blink"])
        #expect(!named(usage, "repeat").contains { $0["action"] == .word("day_open") })
    }

    /// Hiding from the popover sends the action and the hidden event: one hide after a nudge is one signal, not two.
    @Test func oneHideAfterANudgeIsOneSignal() {
        let now = LockedBox(start)
        let usage = client(now: now)
        usage.track("drift_step", ["step": .word("sad")])
        now.mutate { $0 = start.addingTimeInterval(30) }
        usage.track("popover_action", ["action": .word("hide"), "from": .word("popover")])
        usage.track("hidden", ["by": .word("person")])
        #expect(named(usage, "frustration").map { $0["signal"] } == [UsageValue.word("hide_after_nudge")])
    }

    @Test func rapidClicksAndUndoingANudgeAreFrustration() {
        let now = LockedBox(start)
        let usage = client(now: now)
        for tenth in [0.0, 0.4, 0.9, 1.2] { now.mutate { $0 = start.addingTimeInterval(tenth) }; usage.count(.companionClick) }
        #expect(named(usage, "frustration") == [["signal": .word("rapid_clicks")]])  // once for the burst
        now.mutate { $0 = start.addingTimeInterval(10) }
        usage.count(.companionClick); usage.count(.companionClick)  // two: not frustration
        // No nudge yet: hiding is just hiding.
        usage.track("popover_action", ["action": .word("hide"), "from": .word("popover")])
        usage.track("drift_step", ["step": .word("sad")])
        now.mutate { $0 = start.addingTimeInterval(60) }
        usage.track("hidden", ["by": .word("person")])
        usage.track("correction", ["kind": .word("marked_work")])
        now.mutate { $0 = start.addingTimeInterval(500) }
        usage.track("app_quit", ["how": .word("menu")])  // too long after the nudge
        #expect(named(usage, "frustration").map { $0["signal"] } == ["rapid_clicks", "hide_after_nudge", "work_after_nudge"].map { UsageValue.word($0) })
    }

    /// Moku's own quits aren't the person giving up: a relaunch, an update, a logout, a signal or an unknown quit after a
    /// nudge isn't frustration. Only quitting from Moku's own menus is.
    /// Only the person's quit is frustration: Moku's menus, or the Dock's Quit (`other`). A relaunch, an update, a logout or
    /// a signal is Moku's doing or the Mac's.
    @Test func onlyThePersonsQuitAfterANudgeIsFrustration() {
        let now = LockedBox(start)
        let usage = client(now: now)
        usage.track("drift_step", ["step": .word("sad")])
        now.mutate { $0 = start.addingTimeInterval(20) }
        for how in ["relaunch", "update", "logout", "signal"] { usage.track("app_quit", ["how": .word(how)]) }
        #expect(named(usage, "frustration").isEmpty)
        usage.track("app_quit", ["how": .word("menu")])
        #expect(named(usage, "frustration") == [["signal": .word("quit_after_nudge")]])
        usage.track("drift_step", ["step": .word("sad")])
        usage.track("app_quit", ["how": .word("other")])  // the Dock's Quit
        #expect(named(usage, "frustration").count == 2)
    }
}

/// Updates in fixed words: Sparkle's errors, why a Mac is stuck, and hours since a release.
@MainActor
@Suite("Usage: updates")
struct UpdateFactsTests {
    @Test func sparklesErrorsAreAFewWordsAndSomeKeepAMacStuck() {
        let sparkle = { (code: Int) in NSError(domain: "SUSparkleErrorDomain", code: code) }
        #expect(UpdateFacts.kind(of: sparkle(1001)) == "none")
        #expect(UpdateFacts.kind(of: sparkle(2001)) == "download" && UpdateFacts.stuck("download") == "download_failed")
        #expect(UpdateFacts.kind(of: sparkle(3001)) == "signature" && UpdateFacts.stuck("signature") == "signature_failed")
        #expect(UpdateFacts.kind(of: sparkle(4012)) == "no_permission" && UpdateFacts.stuck("no_permission") == "no_permission")
        #expect(UpdateFacts.kind(of: sparkle(1003)) == "disk_image" && UpdateFacts.stuck("disk_image") == "not_in_applications")
        #expect(UpdateFacts.kind(of: sparkle(1000)) == "feed" && UpdateFacts.stuck("feed") == nil)
        #expect(UpdateFacts.kind(of: NSError(domain: NSURLErrorDomain, code: -1009)) == "network")
        #expect(UpdateFacts.kind(of: NSError(domain: "Other", code: 1)) == "other")
        for code in [1001, 2001, 3001, 4012, 1003, 1000, 4005, 9999] {
            let kind = UpdateFacts.kind(of: sparkle(code))
            guard kind != "none" else { continue }
            guard case let .word(words)? = UsageEvents.schema["update_check"]?["error"] else { Issue.record("update_check.error"); return }
            #expect(words.contains(kind))
            if let why = UpdateFacts.stuck(kind), case let .word(reasons)? = UsageEvents.schema["update_stuck"]?["why"] { #expect(reasons.contains(why)) }
        }
    }

    /// Two friends' 0.1.10 failed every update check on 2026-10-08 ("sparkle 2001", error "network") while their AI calls
    /// through the relay went through. The event couldn't say why. It now carries the network's error number, the HTTP
    /// status, and which of Moku's servers failed: the relay, or R2 (updates.hellomoku.com, a young domain that security
    /// filters block). Numbers and fixed words only, never the URL.
    @Test func anUpdateErrorSaysWhichServerAndWhichNetworkError() {
        let blocked = NSError(domain: "SUSparkleErrorDomain", code: 2001, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: -1003,
            userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://updates.hellomoku.com/updates/appcast.xml")!])])
        #expect(UpdateFacts.facts(of: blocked) == ["network_code": .int(-1003), "host": .word("r2")])
        let offline = NSError(domain: "SUSparkleErrorDomain", code: 2001, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: -1009,
            userInfo: [NSURLErrorFailingURLStringErrorKey: "https://moku-proxy.vercel.app/updates/appcast.xml"])])
        #expect(UpdateFacts.facts(of: offline) == ["network_code": .int(-1009), "host": .word("relay")])
        let refused = NSError(domain: "SUSparkleErrorDomain", code: 2001, userInfo: [NSLocalizedDescriptionKey: "A network error occurred while downloading https://example.com/x.zip. forbidden (403)"])
        #expect(UpdateFacts.facts(of: refused) == ["http_status": .int(403), "host": .word("other")])
        // Every one of them is something the relay takes.
        for facts in [UpdateFacts.facts(of: blocked), UpdateFacts.facts(of: offline), UpdateFacts.facts(of: refused)] {
            for (key, value) in facts {
                #expect(UsageEvents.schema["update_check"]?[key].map { UsageEvents.fits(value, $0) } == true, "update_check.\(key)")
                #expect(UsageEvents.schema["update_stuck"]?[key].map { UsageEvents.fits(value, $0) } == true, "update_stuck.\(key)")
            }
        }
    }

    /// Charles's 0.1.8, 2026-10-06: the feed's fetch failed on TLS and the full update's download was reset by the network;
    /// Sparkle said "retrieving update information" and "downloading the update", as if the files were at fault.
    @Test func aFeedOrDownloadErrorCausedByTheNetworkIsNetworkAndSaysEveryLayer() {
        let url = "https://updates.example.com/updates/Moku-0.1.9.zip"
        let reset = NSError(domain: "kCFErrorDomainCFNetwork", code: -1005)
        let lost = NSError(domain: NSURLErrorDomain, code: -1005, userInfo: [NSLocalizedDescriptionKey: "The network connection was lost.",
                                                                            NSURLErrorFailingURLStringErrorKey: url, NSUnderlyingErrorKey: reset])
        let download = NSError(domain: "SUSparkleErrorDomain", code: 2001, userInfo: [
            NSLocalizedDescriptionKey: "An error occurred while downloading the update. Please try again later.", NSUnderlyingErrorKey: lost])
        let tls = NSError(domain: NSURLErrorDomain, code: -1200)
        let feed = NSError(domain: "SUSparkleErrorDomain", code: 1002, userInfo: [NSUnderlyingErrorKey:
            NSError(domain: "SUSparkleErrorDomain", code: 2001, userInfo: [NSUnderlyingErrorKey: tls])])
        #expect(UpdateFacts.kind(of: download) == "network" && UpdateFacts.kind(of: feed) == "network")
        #expect(UpdateFacts.stuck("network") == nil)
        #expect(UpdateFacts.describe(download) == "SUSparkleErrorDomain 2001 An error occurred while downloading the update. › NSURLErrorDomain -1005 The network connection was lost. › kCFErrorDomainCFNetwork -1005 \(reset.localizedDescription) (\(url))")
        // Not the network: still Sparkle's own words.
        #expect(UpdateFacts.kind(of: NSError(domain: "SUSparkleErrorDomain", code: 3000, userInfo: [NSUnderlyingErrorKey: NSError(domain: "Other", code: 1)])) == "signature")
    }

    @Test func afterANetworkFailureMokuChecksAgainSoonThenLeavesItToSparkle() {
        var retry = UpdateRetry()
        let network = NSError(domain: "SUSparkleErrorDomain", code: 2001, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: -1005)])
        #expect(retry.next(after: network) == 600)
        #expect(retry.next(after: network) == 1_800)
        #expect(retry.next(after: network) == 7_200)
        #expect(retry.next(after: network) == nil)  // Sparkle's daily check from here
        #expect(retry.next(after: nil) == nil)      // a check that worked starts the count again
        #expect(retry.next(after: network) == 600)
        #expect(retry.next(after: NSError(domain: "SUSparkleErrorDomain", code: 3001)) == nil)  // a bad signature isn't retried
        #expect(retry.next(after: network) == 600)
    }

    /// The probe, 2026-10-06: after a burst of requests the Blob store answered with Vercel's "Security Checkpoint" (403),
    /// which Sparkle can't pass: "An error occurred in retrieving update information".
    @Test func aServersPassingRefusalIsTriedAgainSoonAndSaidPlainly() {
        let message = "A network error occurred while downloading https://moku-proxy.vercel.app/updates/appcast.xml. forbidden (403)"
        let challenge = NSError(domain: "SUSparkleErrorDomain", code: 2001, userInfo: [
            NSLocalizedDescriptionKey: "An error occurred in retrieving update information. Please try again later.",
            NSUnderlyingErrorKey: NSError(domain: "SUSparkleErrorDomain", code: 2001, userInfo: [NSLocalizedDescriptionKey: message])])
        #expect(UpdateFacts.httpStatus(of: challenge) == 403 && UpdateFacts.isTransient(challenge) && !UpdateFacts.isNetwork(challenge))
        var retry = UpdateRetry()
        #expect(retry.next(after: challenge) == 600)
        #expect(UpdateOutcome.reason(of: challenge) == "the server answered 403 \(HTTPURLResponse.localizedString(forStatusCode: 403))")
        let missing = NSError(domain: "SUSparkleErrorDomain", code: 2001, userInfo: [NSLocalizedDescriptionKey: "A network error occurred while downloading x. not found (404)"])
        #expect(UpdateFacts.httpStatus(of: missing) == 404 && !UpdateFacts.isTransient(missing))
        #expect(UpdateFacts.httpStatus(of: NSError(domain: "SUSparkleErrorDomain", code: 2001, userInfo: [NSLocalizedDescriptionKey: "Something (Moku)"])) == nil)
    }

    @Test func settingsSaysWhatTheLastCheckCameTo() {
        let at = Calendar.current.date(bySettingHour: 9, minute: 43, second: 0, of: Date())!
        let lost = NSError(domain: "SUSparkleErrorDomain", code: 2001, userInfo: [
            NSLocalizedDescriptionKey: "An error occurred while downloading the update. Please try again later.",
            NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: -1005, userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."])])
        #expect(UpdateOutcome.reason(of: lost) == "the network connection was lost")
        let failed = UpdateOutcome.failed(at: at, network: true, reason: UpdateOutcome.reason(of: lost), retryAt: at.addingTimeInterval(600))
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        #expect(failed.sentence() == "Couldn’t reach Moku’s update server at \(time(at)) (the network connection was lost). Moku tries again at \(time(at.addingTimeInterval(600))).")
        let signature = NSError(domain: "SUSparkleErrorDomain", code: 3001, userInfo: [NSLocalizedDescriptionKey: "The update is improperly signed and could not be validated."])
        #expect(UpdateOutcome.failed(at: at, network: false, reason: UpdateOutcome.reason(of: signature), retryAt: nil).sentence()
                == "The update at \(time(at)) didn’t work (the update is improperly signed and could not be validated). Moku tries again tomorrow, or use Check for updates.")
        #expect(UpdateOutcome.upToDate(at: at).sentence() == "Up to date (checked at \(time(at))).")
        #expect(UpdateOutcome.ready(version: "0.1.10").sentence().hasPrefix("Moku 0.1.10 is downloaded."))
    }

    @Test func hoursSinceAReleaseAreCountedOnceFromItsFeedDate() {
        let defaults = UserDefaults(suiteName: "moku-updates-\(UUID().uuidString)")!
        let released = Date(timeIntervalSince1970: 1_790_000_000)
        UpdateFacts.noteRelease(version: "0.1.9", date: released, defaults: defaults)
        #expect(UpdateFacts.hoursSinceRelease(of: "0.1.9", now: released.addingTimeInterval(30 * 3600), defaults: defaults) == 30)
        #expect(UpdateFacts.hoursSinceRelease(of: "0.1.9", defaults: defaults) == nil)  // said once
        #expect(UpdateFacts.inApplications("/Applications/Moku.app") && !UpdateFacts.inApplications("/Users/x/Downloads/Moku.app"))
    }
}
