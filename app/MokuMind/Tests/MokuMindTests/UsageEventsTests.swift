import Foundation
import Testing
import MokuKit
@testable import MokuMind

@MainActor
@Suite("Usage events")
struct UsageEventsTests {
    let device = String(repeating: "d", count: 64)
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// A queue file of its own in a temporary folder: never ~/.moku.
    func queueFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("moku-usage-\(UUID().uuidString)/usage-queue.json")
    }

    /// One post the client made: the token it carried and the body as JSON.
    struct Post { var token: String?; var body: [String: Any] }

    func client(_ file: URL, status: LockedBox<Int> = LockedBox(202), posts: LockedBox<[Post]> = LockedBox([]),
                offline: LockedBox<Bool> = LockedBox(false), token: String? = "moku1.payload.sig", now: LockedBox<Date>? = nil,
                flushDelay: Duration = .seconds(3600), slowPost: Duration? = nil) -> UsageEvents {
        let clock = now ?? LockedBox(start)
        return UsageEvents(file: file, relay: URL(string: "https://relay.example")!, device: device, appVersion: "0.1.8",
                           token: { token }, post: { url, body, token in
                               #expect(url.absoluteString == "https://relay.example/v1/events")
                               if let slowPost { try await Task.sleep(for: slowPost) }
                               if offline.value { throw URLError(.notConnectedToInternet) }
                               posts.mutate { $0.append(Post(token: token, body: try! JSONSerialization.jsonObject(with: body) as! [String: Any])) }
                               return status.value
                           }, now: { clock.value }, flushDelay: flushDelay)
    }

    @Test func anEventGetsTheVersionAndTimeAndOnlyThePropertiesItsShapesAllow() throws {
        let file = queueFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let usage = client(file)
        usage.track("app_opened", ["first_launch": .bool(true), "macos": .int(26), "ram_gb": .int(16), "launched_by": .word("login"),
                                   "screen_recording": .bool(false), "accessibility": .bool(true),
                                   "window_title": .word("Inbox"), "app_version": .word("9.9.9"), "macos_name": .word("Tahoe")])
        usage.track("screen_text", ["text": .word("hello")])
        #expect(usage.queue.count == 1)
        let event = try #require(usage.queue.first)
        #expect(event.name == "app_opened" && event.ts == Int64(start.timeIntervalSince1970 * 1000))
        #expect(event.props == ["first_launch": .bool(true), "macos": .int(26), "ram_gb": .int(16), "launched_by": .word("login"),
                                "screen_recording": .bool(false), "accessibility": .bool(true), "app_version": .word("0.1.8")])
        // Out of range, the wrong kind, or not one of the words: dropped, and the rest of the event kept.
        usage.track("comeback", ["drift_seconds": .int(1_000_000), "first_today": .word("yes")])
        usage.track("popover_opened", ["from": .word("dock")])
        #expect(usage.queue.suffix(2).map(\.props) == [["app_version": .word("0.1.8")], ["app_version": .word("0.1.8")]])
    }

    @Test func yourDayAndThePopoverControlsSayOnlyWhereFromAndWhich() {
        let file = queueFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let usage = client(file)
        usage.track("day_opened", ["from": .word("popover_numbers")])
        usage.track("popover_action", ["action": .word("put_back"), "from": .word("menu")])
        usage.track("popover_action", ["action": .word("open_url"), "from": .word("postcard")])
        #expect(usage.queue.map(\.props) == [["from": .word("popover_numbers"), "app_version": .word("0.1.8")],
                                             ["action": .word("put_back"), "from": .word("menu"), "app_version": .word("0.1.8")],
                                             ["app_version": .word("0.1.8")]])
    }

    @Test func neverQueuesAStringOutsideAFixedVocabulary() throws {
        let file = queueFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let usage = client(file)
        let sensitive = ["Q3 board deck — Confidential.key", "https://mail.google.com/mail/u/0/#inbox", "Hey, are we still on for tonight?",
                         "priya@example.com", "building Moku", "WhatsApp", "Slack", "step two", "../etc/passwd", "ABC", "0.1.8 (beta)",
                         "Menubar", " moku", "pat\n", "user_name=Charles", ""]
        // Every string that would leave the Mac is one of its event's code words, or the app's version.
        for (name, shapes) in UsageEvents.schema {
            for key in Array(shapes.keys) + ["app_version", "title", "url", "text", "app", "goal", "name"] {
                for value in sensitive {
                    usage.track(name, [key: .word(value)])
                    let event = try #require(usage.queue.last)
                    try #require(event.name == name)
                    for (key, value) in event.props {
                guard case let .word(word) = value else { continue }
                if key == "app_version" { #expect(word == "0.1.8"); continue }
                switch UsageEvents.schema[event.name]?[key] {
                case let .word(words)?: #expect(words.contains(word), "\(event.name).\(key) let \(word) through")
                case .version?: #expect(word.wholeMatch(of: /[0-9]{1,3}(\.[0-9]{1,3}){0,3}/) != nil)
                case .place?: #expect(ErrorReports.isPlace(word), "\(event.name).\(key) let \(word) through")
                default: Issue.record("\(event.name).\(key) carried a string")
                }
                    }
                }
            }
        }
        let saved = try String(contentsOf: file, encoding: .utf8)
        for value in sensitive { #expect(!saved.contains("\"\(value)\""), "the queue file holds \(value)") }
        // The code words themselves are short identifiers: none can carry a name or a title.
        for shapes in UsageEvents.schema.values {
            for case let .word(words) in shapes.values {
                #expect(words.allSatisfy { $0.wholeMatch(of: /[a-z][a-z0-9_]{0,31}/) != nil })
            }
        }
    }

    @Test func everyEventAndPropertyIsOneTheRelayTakes() throws {
        let relay = try RelayAllowlist.read()
        #expect(relay.common["app_version"] == .version)
        for (key, shape) in UsageEvents.common {
            guard case let .word(ours) = shape, case let .oneOf(words)? = relay.common[key] else { Issue.record("common \(key)"); continue }
            #expect(ours.isSubset(of: words), "common \(key)")
        }
        for (name, shapes) in UsageEvents.schema {
            let allowed = try #require(relay.events[name], "the relay doesn't take \(name)")
            for (key, shape) in shapes {
                let theirs = try #require(allowed[key], "the relay doesn't take \(name).\(key)")
                switch (shape, theirs) {
                case (.bool, .bool), (.version, .version), (.place, .place): break
                case let (.int(ours), .int(min, max)): #expect(ours.lowerBound >= min && ours.upperBound <= max, "\(name).\(key)")
                case let (.word(ours), .oneOf(words)): #expect(ours.isSubset(of: words), "\(name).\(key): \(ours.subtracting(words))")
                case let (.word(ours), .identifier): #expect(ours.allSatisfy { $0.wholeMatch(of: /[a-z][a-z0-9_]{0,31}/) != nil })
                default: Issue.record("\(name).\(key) is \(shape) here but \(theirs) on the relay")
                }
            }
        }
    }

    @Test func everyEventIsOnThePrivacyPage() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let page = try String(contentsOf: repo.appendingPathComponent("website/privacy.html"), encoding: .utf8)
        let listed = try #require(page.firstMatch(of: /usage-events: ([a-z0-9_ ]+) -->/)).1.split(separator: " ").map(String.init)
        let named = Set(UsageEvents.schema.keys).union(UsageEvents.retired)
        #expect(Set(listed) == named, "privacy.html lists \(Set(listed).symmetricDifference(named))")
        #expect(UsageEvents.retired.isDisjoint(with: UsageEvents.schema.keys), "a retired event isn't sent any more")
    }

    @Test func theQueueSurvivesARelaunchKeeps200AndForgetsAfterAWeek() {
        let file = queueFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let now = LockedBox(start)
        let usage = client(file, now: now)
        for _ in 0..<5 { usage.track("day_opened") }
        now.mutate { $0 = $0.addingTimeInterval(86_400) }
        for _ in 0..<200 { usage.track("popover_opened", ["from": .word("menubar")]) }
        #expect(usage.queue.count == 200)
        #expect(usage.queue.allSatisfy { $0.name == "popover_opened" })  // the oldest went first
        // Back after the weekend: the queue is read again. A week later it's forgotten.
        #expect(client(file, now: now).queue.count == 200)
        now.mutate { $0 = $0.addingTimeInterval(7 * 86_400 + 1) }
        #expect(client(file, now: now).queue.isEmpty)
    }

    @Test func sendsBatchesOfFiftyWithTheDeviceAndTokenAndNoLocalIds() async throws {
        let file = queueFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let posts = LockedBox<[Post]>([])
        let usage = client(file, posts: posts)
        for n in 1...120 { usage.track("house_piece", ["pieces_today": .int(n % 24)]) }
        await usage.flush()
        #expect(posts.value.map { ($0.body["events"] as? [Any])?.count } == [50, 50, 20])
        #expect(posts.value.allSatisfy { $0.token == "moku1.payload.sig" && $0.body["device"] as? String == device })
        let first = try #require((posts.value.first?.body["events"] as? [[String: Any]])?.first)
        #expect(Set(first.keys) == ["name", "ts", "props"])
        #expect(first["name"] as? String == "house_piece" && (first["ts"] as? Int) == Int(start.timeIntervalSince1970 * 1000))
        #expect(first["props"] as? [String: AnyHashable] == ["pieces_today": 1, "app_version": "0.1.8"])
        #expect(usage.queue.isEmpty)
        #expect(client(file).queue.isEmpty)  // and the file says so
        // Without a token (no trial or invite yet) the events still go, unsigned.
        let unsigned = client(queueFile(), posts: posts, token: nil)
        unsigned.track("day_opened")
        await unsigned.flush()
        #expect(posts.value.last?.token == nil)
    }

    @Test func keepsEventsWhenTheRelayIsBusyOrOfflineAndDropsThemWhenItRefuses() async {
        let file = queueFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let status = LockedBox(503), offline = LockedBox(false), posts = LockedBox<[Post]>([])
        let usage = client(file, status: status, posts: posts, offline: offline)
        usage.track("day_opened")
        await usage.flush()
        #expect(usage.queue.count == 1)
        status.mutate { $0 = 429 }
        await usage.flush()
        #expect(usage.queue.count == 1)
        offline.mutate { $0 = true }
        await usage.flush()
        #expect(usage.queue.count == 1)
        offline.mutate { $0 = false }; status.mutate { $0 = 400 }
        await usage.flush()
        #expect(usage.queue.isEmpty)  // the relay will never take it
        status.mutate { $0 = 202 }
        usage.track("day_opened")
        await usage.flush()
        #expect(usage.queue.isEmpty && posts.value.count == 4)
    }

    @Test func sendsAMomentAfterTheLastEvent() async {
        let file = queueFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let posts = LockedBox<[Post]>([])
        let usage = client(file, posts: posts, flushDelay: .milliseconds(100))
        usage.track("day_opened")
        try? await Task.sleep(for: .milliseconds(40))
        usage.track("popover_opened", ["from": .word("moku")])  // the wait starts again
        #expect(posts.value.isEmpty)
        #expect(await eventually { posts.value.count == 1 })
        #expect((posts.value.first?.body["events"] as? [Any])?.count == 2)
    }

    @Test func quittingSendsOneLastBatchButWaitsAMomentAtMost() {
        let file = queueFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let posts = LockedBox<[Post]>([])
        let quick = client(file, posts: posts)
        quick.track("day_opened")
        quick.sendBeforeQuit(within: 2)
        #expect(posts.value.count == 1 && quick.queue.isEmpty && client(file).queue.isEmpty)
        // A relay that doesn't answer in time: Moku quits anyway, and the event goes next launch.
        let slow = client(file, slowPost: .seconds(5))
        slow.track("day_opened")
        let clock = ContinuousClock(), began = clock.now
        slow.sendBeforeQuit(within: 0.2)
        #expect(clock.now - began < .seconds(2))
        #expect(client(file).queue.count == 1)
    }

    @Test func aLaunchIsAFirstLaunchAnUpdateOrTheSameVersionAgain() {
        let defaults = UserDefaults(suiteName: "moku-usage-\(UUID().uuidString)")!
        let first = UsageEvents.recordLaunch(version: "0.1.8", onboarded: false, loginItem: false, defaults: defaults, now: start)
        #expect(first == .init(firstLaunch: true, updated: false, previousVersion: nil, launchedBy: "person"))
        #expect(UsageEvents.installedAt(defaults: defaults) == start)
        UsageEvents.recordQuit(defaults: defaults)
        let again = UsageEvents.recordLaunch(version: "0.1.8", onboarded: true, loginItem: true, defaults: defaults, now: start.addingTimeInterval(86_400))
        #expect(again == .init(firstLaunch: false, updated: false, previousVersion: nil, launchedBy: "login", previousExit: .clean))
        UsageEvents.recordQuit(defaults: defaults)
        let updated = UsageEvents.recordLaunch(version: "0.1.9", onboarded: true, loginItem: false, defaults: defaults)
        #expect(updated == .init(firstLaunch: false, updated: true, previousVersion: "0.1.8", launchedBy: "update", previousExit: .clean))
        #expect(UsageEvents.installedAt(defaults: defaults) == start)  // kept from the first launch
        // A Mac that ran 0.1.7 (which saved no version) and finished the welcome: an update from an unknown version.
        let older = UserDefaults(suiteName: "moku-usage-\(UUID().uuidString)")!
        #expect(UsageEvents.recordLaunch(version: "0.1.8", onboarded: true, loginItem: false, defaults: older)
                == .init(firstLaunch: false, updated: true, previousVersion: nil, launchedBy: "update"))
    }

    /// A friend's crash never reached PostHog (2026-10-12): a crash report can fail to be written, found or sent, and then
    /// nothing says Moku died. So each launch also says how the last one ended, through the relay like any usage event.
    @Test func aLaunchSaysWhetherTheLastOneEndedNormally() {
        let defaults = UserDefaults(suiteName: "moku-usage-\(UUID().uuidString)")!
        // The first launch, and a Mac that ran a version before this was kept: nothing to say.
        #expect(UsageEvents.recordLaunch(version: "0.1.12", onboarded: false, loginItem: false, defaults: defaults).previousExit == nil)
        let older = UserDefaults(suiteName: "moku-usage-\(UUID().uuidString)")!
        older.set("0.1.11", forKey: UsageEvents.lastVersionKey)
        #expect(UsageEvents.recordLaunch(version: "0.1.12", onboarded: true, loginItem: false, defaults: older).previousExit == nil)
        // A quit that ran to its end.
        UsageEvents.recordQuit(defaults: defaults)
        #expect(UsageEvents.recordLaunch(version: "0.1.12", onboarded: true, loginItem: false, defaults: defaults).previousExit == .clean)
        // A launch that nothing ended: a crash, a force quit, a power cut.
        #expect(UsageEvents.recordLaunch(version: "0.1.12", onboarded: true, loginItem: false, defaults: defaults).previousExit == .unclean)
        // And it only counts once: after that quit it's clean again.
        UsageEvents.recordQuit(defaults: defaults)
        #expect(UsageEvents.recordLaunch(version: "0.1.12", onboarded: true, loginItem: false, defaults: defaults).previousExit == .clean)
    }

    /// A quiet relaunch (after a companion change) sends no `app_opened`, but its Moku can still crash: the old Moku's quit
    /// closed the session, so the relaunched one must open it again, or its crash reads "clean" (2026-10-14).
    @Test func aCrashAfterAQuietRelaunchIsUnclean() {
        let defaults = UserDefaults(suiteName: "moku-usage-\(UUID().uuidString)")!
        _ = UsageEvents.recordLaunch(version: "0.1.12", onboarded: true, loginItem: false, defaults: defaults)
        UsageEvents.recordQuit(defaults: defaults)                 // the old Moku quits to reopen quietly
        UsageEvents.recordQuietRelaunch(defaults: defaults)       // the same Moku, opened again
        // …and it crashes: nothing runs recordQuit.
        #expect(UsageEvents.recordLaunch(version: "0.1.12", onboarded: true, loginItem: false, defaults: defaults).previousExit == .unclean)
        // A quiet relaunch whose Moku quits normally stays clean.
        UsageEvents.recordQuit(defaults: defaults)
        UsageEvents.recordQuietRelaunch(defaults: defaults)
        UsageEvents.recordQuit(defaults: defaults)
        #expect(UsageEvents.recordLaunch(version: "0.1.12", onboarded: true, loginItem: false, defaults: defaults).previousExit == .clean)
    }

    /// A Moku that quits without having recorded a launch (the disk image's copy handing over to the one it moved into
    /// Applications) must not close another Moku's session: a crash before it would read "clean", and a first install
    /// would say "clean" instead of nothing (2026-10-14 review).
    @Test func onlyTheMokuThatOpenedTheSessionClosesIt() {
        let crashed = UserDefaults(suiteName: "moku-usage-\(UUID().uuidString)")!
        _ = UsageEvents.recordLaunch(version: "0.1.12", onboarded: true, loginItem: false, defaults: crashed, pid: 100)  // it crashes
        UsageEvents.recordQuit(defaults: crashed, pid: 200)                     // the disk image's copy moves and quits
        #expect(UsageEvents.recordLaunch(version: "0.1.12", onboarded: true, loginItem: false, defaults: crashed, pid: 300).previousExit == .unclean)

        let fresh = UserDefaults(suiteName: "moku-usage-\(UUID().uuidString)")!
        UsageEvents.recordQuit(defaults: fresh, pid: 200)                       // a first install from the disk image
        #expect(UsageEvents.recordLaunch(version: "0.1.12", onboarded: false, loginItem: false, defaults: fresh, pid: 300).previousExit == nil)
    }

    @Test func appOpenedMaySayHowTheLastLaunchEnded() {
        #expect(UsageEvents.schema["app_opened"]?["previous_exit"] == .word(["clean", "unclean"]))
    }

    @Test func memoryAndDriftsAreSentInBroadSteps() {
        let gb: UInt64 = 1_073_741_824
        #expect([4, 8, 16, 18, 24, 36, 64, 128].map { UsageEvents.ramBucket(bytes: $0 * gb) } == [8, 8, 16, 16, 24, 32, 32, 32])
        #expect([0, 9, 10, 45, 61, 299, 300, 4000, 90_000].map { UsageEvents.driftBucket(seconds: $0) } == [0, 0, 10, 30, 60, 120, 300, 3600, 7200])
    }
}

/// The relay's allowlist, read from proxy/api/_lib/events.js, so the app can't drift from it unnoticed.
struct RelayAllowlist {
    enum Shape: Equatable { case bool, int(Int, Int), oneOf(Set<String>), version, identifier, place }
    var common: [String: Shape] = [:]
    var events: [String: [String: Shape]] = [:]

    static func read() throws -> RelayAllowlist {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: repo.appendingPathComponent("proxy/api/_lib/events.js"), encoding: .utf8)
        func block(after marker: String) throws -> String {
            let from = try #require(source.range(of: marker)).upperBound
            let to = try #require(source.range(of: "});", range: from..<source.endIndex)).lowerBound
            return String(source[from..<to])
        }
        func shapes(_ body: Substring) -> [String: Shape] {
            var shapes: [String: Shape] = [:]
            for match in body.matches(of: /([a-z][a-z0-9_]*): (bool|version|identifier|place|int\((-?[0-9_]+), (-?[0-9_]+)\)|oneOf\(([^)]*)\))/) {
                let key = String(match.1), kind = String(match.2)
                let number = { (text: Substring?) in Int((text ?? "").replacingOccurrences(of: "_", with: "")) ?? 0 }
                shapes[key] = switch kind {
                case "bool": .bool
                case "version": .version
                case "identifier": .identifier
                case "place": .place
                case _ where kind.hasPrefix("int"): .int(number(match.3), number(match.4))
                default: .oneOf(Set((match.5 ?? "").split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\n")) }))
                }
            }
            return shapes
        }
        var allowlist = RelayAllowlist()
        let common = try #require(source.firstMatch(of: /const COMMON = \{([^}]*)\}/))
        allowlist.common = shapes(common.1)
        for entry in try block(after: "export const EVENTS = /** @type {Record<string, Record<string, Shape>>} */ ({").matches(of: /([a-z_]+): \{([^{}]*)\}/) {
            allowlist.events[String(entry.1)] = shapes(entry.2)
        }
        return allowlist
    }
}
