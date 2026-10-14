import Foundation
import MokuKit
import os

/// Moku's usage events (docs/specs/usage-analytics.md), always on: what Moku and the person do with it, never what's on
/// the screen. Every event is one of `schema`, and each of its properties has a fixed shape: a yes or no, a whole
/// number in a range, a code word from a fixed list, or a version. Anything else is dropped here, and the relay checks
/// it all again (proxy/api/_lib/events.js), so no app name, window title, address, screen text, goal or anything typed
/// can be sent.
///
/// Events wait in a small queue saved to ~/.moku/usage-queue.json (200 at most, none older than a week). They go to the
/// relay's POST /v1/events about 20 s after the last one, and when Moku quits, in batches of up to 50, with the
/// install's token when it has one. An answer of 2xx means sent; 429, 5xx or no network keeps them for later; any other
/// answer drops them (the relay will never take them).
@MainActor
public final class UsageEvents {
    /// Posts a batch and returns the HTTP status.
    public typealias Post = @Sendable (_ url: URL, _ body: Data, _ token: String?) async throws -> Int

    /// A property's shape, as the relay's allowlist has it.
    enum Shape: Equatable {
        case bool
        case int(ClosedRange<Int>)
        /// One of these code words, and nothing else.
        case word(Set<String>)
        /// A version such as "0.1.8".
        case version
        /// A place in Moku's own code, "BrainClient.swift:today" (`ErrorReports.isPlace`).
        case place
    }

    /// Events this build no longer sends but older ones still do ("Where was I?", removed on 2026-10-14): the relay keeps
    /// taking them and the privacy page keeps naming them until no Mac runs 0.1.11 or older.
    public static let retired: Set<String> = ["resume_offered", "resume_used"]

    /// Every event the app may send, and the only properties each may carry. Each is on the relay's list too (a test
    /// reads events.js to check), and on the privacy page.
    static let schema: [String: [String: Shape]] = [
        "app_opened": [
            "first_launch": .bool, "macos": .int(11...40), "ram_gb": .int(1...1024), "launched_by": .word(["login", "person", "update"]),
            "screen_recording": .bool, "accessibility": .bool, "companion": .word(companions),
            // Who we're designing for: how many displays, and two system settings that change what Moku does.
            "displays": .int(1...16), "reduce_motion": .bool, "low_power": .bool,
            // The companion put away before this launch (it was inferred from a missing launch_speed).
            "hidden": .bool,
            // How the launch before this one ended: a quit that ran to its end, or none (a crash, a force quit, a power cut).
            // It reaches us through the relay, so it says so even when a crash report couldn't be sent.
            "previous_exit": .word(["clean", "unclean"]),
        ],
        // Updates (Sparkle's delegate): each check, a download, the first launch of a new version (from, to, and hours
        // since that version was released), and why a Mac hasn't moved.
        "update_installed": ["from": .version, "to": .version, "hours_since_release": .int(0...100_000)],
        // "What's new" after an update (WhatsNew.swift): the bubble went up, then was clicked or closed (✕, its time, or
        // another line), and how many seconds it stayed up.
        "whats_new": ["what": .word(["shown", "opened", "closed"]), "seconds": .int(0...86_400)],
        "update_check": ["result": .word(["up_to_date", "found", "error"]),
                         "error": .word(["download", "signature", "feed", "install", "no_permission", "disk_image", "network", "other"]),
                         "network_code": .int(-4000...0), "http_status": .int(100...599), "host": .word(["relay", "r2", "other"])],
        "update_downloaded": ["to": .version],
        "update_stuck": ["why": .word(["download_failed", "signature_failed", "waiting_for_away", "no_permission", "not_in_applications", "sparkle_off"]),
                         "network_code": .int(-4000...0), "http_status": .int(100...599), "host": .word(["relay", "r2", "other"])],
        // The welcome (one window): it opens, picks up again after a relaunch, or its Quit & Reopen is pressed; then each
        // step: the hello, a companion picked, what it reads, each Allow, and how it ended (Start or Skip).
        "welcome_step": ["step": .word(welcomeSteps)],
        // The welcome closed (its close button, or Moku quit) before Start or Skip: the last step it reached.
        "welcome_left": ["last_step": .word(welcomeSteps), "seconds": .int(0...86_400)],
        // A permission answered: which, whether it was granted, where it was asked, and the seconds from the ask to the answer.
        "permission_answered": ["kind": .word(["screen", "accessibility"]), "granted": .bool, "where": .word(["welcome", "settings"]),
                                "seconds": .int(0...86_400)],
        "welcome_finished": ["how": .word(["completed", "skipped"]), "seconds": .int(0...86_400)],
        // The popover opens (from the click until it's shown, in milliseconds).
        "popover_opened": ["from": .word(["menubar", "moku"]), "ms": .int(0...60_000)],
        // Your day opens: from the popover's button, its house or its three numbers, the menu bar icon's right-click
        // menu, a moku://day link, or the "Today counted" card.
        "day_opened": ["from": .word(["popover", "popover_house", "popover_numbers", "menu", "link", "card"])],
        // Your day opened and shown: how long it took, and whether the day loaded.
        "day_loaded": ["ms": .int(0...600_000), "ok": .bool],
        // Your day closes: how long it was open, and how many of its folded parts were opened.
        "day_closed": ["seconds_open": .int(0...86_400), "expanded": .int(0...1000)],
        // One of the popover's controls (Break, Hide, Settings, or what "···" holds), or the same item in the right-click
        // menu on the menu bar icon.
        "popover_action": [
            "action": .word(["break", "hide", "show", "put_back", "settings", "hi", "feedback", "quit"]),
            "from": .word(["popover", "menu"]),
        ],
        "first_focus": ["minutes_since_install": .int(0...10_000_000)],
        "comeback": ["drift_seconds": .int(0...86_400), "first_today": .bool],
        "house_piece": ["pieces_today": .int(0...1000)],
        // A break starts (from the popover, Moku's menu or its timer, or a moku://break link), ends by itself (time's up,
        // or back to work) or is cancelled early by the person. A start says whether a break had been suggested in the 10
        // minutes before; an end says how long it lasted.
        "break": ["what": .word(["started", "ended", "cancelled"]), "from": .word(["popover", "moku", "link", "timer", "work"]),
                  "after_suggestion": .bool, "seconds": .int(0...86_400)],
        "break_suggested": ["kind": .word(["water", "stretch", "look_away", "walk"])],
        "correction": ["kind": .word(["pat", "marked_work", "marked_not_work"])],
        // A setting's name, never its value; for a switch, whether it was turned on or off.
        "setting_changed": ["key": .word(settingKeys), "turned": .word(["on", "off"])],
        "settings_opened": ["tab": .word(["general", "breaks", "privacy"]), "how": .word(["opened", "switched"])],
        // A setting changed in Settings stayed so for 5 minutes, or was changed back (and after how many seconds).
        "setting_outcome": ["key": .word(settingKeys), "outcome": .word(["kept", "changed_back"]), "seconds": .int(0...86_400)],
        "companion_changed": ["from": .word(companions), "to": .word(companions), "where": .word(["welcome", "settings"])],
        // The companion put away and back: by the person, or by Moku during a call or screen sharing.
        "hidden": ["by": .word(["person", "call", "screen_share"])],
        "shown": ["by": .word(["person", "automatic", "welcome"]), "after_seconds": .int(0...31_536_000)],
        // Your day's numbers disagreeing on today: which view against its header, and by how many minutes.
        "numbers_disagree": ["views": .word(["tasks_header", "rows_header", "house_header", "popover_header"]), "gap_minutes": .int(0...1440)],
        // A drift reaching a step of the ladder: sad, cross, a long drift (2 minutes), sitting up tall, the ask.
        "drift_step": ["step": .word(["sad", "long", "tall", "ask"])],  // "cross" went with the angry face (0.1.11)
        "ask_outcome": ["outcome": .word(["within_2_min", "later", "not_that_day"]), "seconds": .int(0...86_400)],
        // "Where was I?": the bubble after a long drift or an away (and whether that window was already in front), and a
        // click on its "Take me there".
        // "Today counted": the day's card.
        "day_card": ["what": .word(["shown", "opened", "closed", "timed_out", "missed"]), "yesterday": .bool, "farewell": .bool],
        // Something went wrong, and for how long (the first of its kind in 10 minutes, with any since folded into it).
        "trouble": ["kind": .word(troubleKinds), "count": .int(1...100_000), "seconds": .int(0...604_800)],
        "app_quit": ["uptime_minutes": .int(0...10_000_000), "how": .word(["menu", "logout", "update", "relaunch", "signal", "other"])],
        // Trying again: the same action again within 30 s, and how many times in a row (UsageSignals).
        "repeat": ["action": .word(["setting", "day_open", "hide", "break", "popover_blink"]), "count": .int(2...1000)],
        // Signs that Moku got in the way (UsageSignals), and Delete my data.
        "frustration": ["signal": .word(["rapid_clicks", "hide_after_nudge", "work_after_nudge", "quit_after_nudge", "delete_data"])],
        // From the process starting to the companion on screen (the stand-in if its character couldn't load).
        "launch_speed": ["ms": .int(0...600_000), "stand_in": .bool],
        // A day that's over (yesterday, or an earlier one Moku missed), in numbers (UsageDay).
        "day_summary": daySummary,
        // An error Moku carried on from (ErrorLog): what failed, the error's family and number, where in Moku's code, and
        // how many times. The relay passes it to PostHog as an `$exception` with level "error".
        "app_error": ["kind": .word(Set(ErrorReport.Kind.allCases.map(\.rawValue))), "domain": .word(ErrorReports.domains),
                      "code": .int(Int(Int32.min)...Int(Int32.max)), "where": .place, "count": .int(1...100_000)],
    ]

    static let companions: Set<String> = ["moku", "tetsu"]
    static let welcomeSteps: Set<String> = [
        "opened", "resumed", "relaunch", "hello", "picked", "reads", "allow_screen", "allow_accessibility", "start", "skip",
    ]
    static let troubleKinds: Set<String> = [
        "brain_restarted", "brain_down", "relay_401", "relay_402", "relay_403", "relay_429", "relay_down", "offline", "cloud_off",
        "stand_in", "permission_lost", "store_set_aside",
    ]
    static let daySummary: [String: Shape] = {
        var shapes: [String: Shape] = [
            "days_ago": .int(0...60), "days_since_install": .int(0...100_000), "macos": .int(11...40),
            "focused_minutes": .int(0...1440), "returns": .int(0...100_000), "longest_minutes": .int(0...1440),
            "minutes_hidden": .int(0...1440), "minutes_hidden_person": .int(0...1440), "minutes_hidden_call": .int(0...1440),
            "memory_mb": .int(0...100_000), "core_permille": .int(0...1000),
        ]
        for key in UsageDay.countKeys { shapes[key] = .int(0...10_000_000) }
        for name in ["brain", "jev", "luna"] { shapes["\(name)_p50_ms"] = .int(0...600_000); shapes["\(name)_p95_ms"] = .int(0...600_000) }
        return shapes
    }()

    /// Settings' names, never their values: the brain's timings and name (snake_case), then the app's own.
    static let settingKeys: Set<String> = [
        "user_name", "drink_every_sec", "tea_break_max_sec", "break_after_sec",
        "share_daily_counts", "size", "open_at_login", "companion", "ignored_apps", "ignored_apps_watch",
    ]

    /// What every event may carry besides `app_version`: the companion on show, so each chart can compare them.
    static let common: [String: Shape] = ["companion": .word(companions)]

    static let maxQueued = 200
    static let maxAge: TimeInterval = 7 * 86_400
    static let batchSize = 50

    /// One event waiting to go. `id` stays on this Mac; it only tells events apart while a batch is out.
    struct Event: Codable, Equatable {
        var id: UUID
        var name: String
        /// When it happened, in milliseconds since 1970, as the relay reads it.
        var ts: Int64
        var props: [String: UsageValue]
    }

    /// What the relay receives: the device hash and the events, without their local ids.
    private struct Batch: Encodable {
        struct Sent: Encodable { var name: String; var ts: Int64; var props: [String: UsageValue] }
        var device: String
        var events: [Sent]
    }

    private let file: URL
    private let dayFile: URL
    private let endpoint: URL
    private let device: String
    private let appVersion: String
    private let token: @MainActor () -> String?
    private let common: @MainActor () -> [String: UsageValue]
    private let installedAt: Date?
    private let calendar: Calendar
    private let post: Post
    private let now: () -> Date
    private let flushDelay: Duration
    private let log = Logger(subsystem: "ai.lightslips.moku", category: "usage")
    private(set) var queue: [Event]
    /// Today's counts, sent as `day_summary` once the day is over.
    private(set) var today: UsageDay
    /// Repeats and frustration, from the events and counts going by.
    private var signals = UsageSignals()
    /// Whether the companion is hidden, and by whom: from `app_opened` and the `hidden` and `shown` events that go by.
    private var hiddenByPerson = false, hiddenByCall = false
    private var daySavedAt = Date.distantPast
    private var flushTimer: Task<Void, Never>?
    /// The send under way, if any; it clears itself when done.
    private var sending: Task<Void, Never>?

    /// `file` is where the queue waits (~/.moku/usage-queue.json), and `dayFile` the day's counts (usage-day.json beside it).
    /// `token` is the install's relay token, when it has one; `common` what every event carries (the companion);
    /// `installedAt` when Moku first opened here, for the summary's day of use.
    public init(file: URL, dayFile: URL? = nil, relay: URL = RelayAccess.defaultRelay, device: String = RelayAccess.deviceHash(),
                appVersion: String, token: @escaping @MainActor () -> String? = { nil },
                common: @escaping @MainActor () -> [String: UsageValue] = { [:] }, installedAt: Date? = nil, calendar: Calendar = .current,
                post: Post? = nil, now: @escaping () -> Date = Date.init, flushDelay: Duration = .seconds(20)) {
        self.file = file; self.dayFile = dayFile ?? file.deletingLastPathComponent().appendingPathComponent("usage-day.json")
        self.endpoint = relay.appendingPathComponent("v1/events"); self.device = device
        self.appVersion = appVersion; self.token = token; self.common = common; self.installedAt = installedAt; self.calendar = calendar
        self.now = now; self.flushDelay = flushDelay
        self.post = post ?? { url, body, token in
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
            request.httpBody = body
            let (_, response) = try await MokuNetwork.session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        queue = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Event].self, from: $0) } ?? []
        today = (try? Data(contentsOf: self.dayFile)).flatMap { try? JSONDecoder().decode(UsageDay.self, from: $0) }
            ?? UsageDay(day: Self.dayKey(now(), calendar))
        trim()
    }

    // MARK: Tracking

    /// Records an event, keeping only the properties its shapes allow, and sends it about 20 s after the last one.
    /// An event that isn't in `schema` is dropped.
    public func track(_ name: String, _ properties: [String: UsageValue] = [:]) {
        rollDayIfNeeded()
        record(name, properties, at: now())
    }

    /// Adds to the day's counts (sent once the day is over, as `day_summary`).
    public func count(_ count: UsageCount) {
        rollDayIfNeeded()
        follow(signals.due(at: now()))
        today.add(count)
        if case .activeMinute = count, hiddenByPerson || hiddenByCall { today.addHiddenMinute(byPerson: hiddenByPerson) }
        follow(signals.count(count, at: now()))
        if now().timeIntervalSince(daySavedAt) > 300 { saveDay() }
    }

    private func record(_ name: String, _ properties: [String: UsageValue], at time: Date) {
        guard let shapes = Self.schema[name] else {
            log.error("usage: \(name, privacy: .public) isn't a known event; dropped")
            return
        }
        var props = properties.filter { key, value in shapes[key].map { Self.fits(value, $0) } ?? false }
        if props.count < properties.count {
            log.error("usage: \(name, privacy: .public) had properties outside its shapes; dropped them")
        }
        for (key, value) in common() where props[key] == nil && Self.common[key].map({ Self.fits(value, $0) }) == true { props[key] = value }
        if Self.fits(.word(appVersion), .version) { props["app_version"] = .word(appVersion) }
        noteVisibility(name, props)
        // A nudge nobody saw isn't one: drift steps (and how the ask went) while the person has the companion put away. Nor
        // is a break suggestion: the companion suggests it, so nobody saw it either.
        if hiddenByPerson, ["drift_step", "ask_outcome", "break_suggested"].contains(name) { return }
        follow(signals.due(at: time))  // repeats that ended before this go first
        queue.append(Event(id: UUID(), name: name, ts: Int64((time.timeIntervalSince1970 * 1000).rounded()), props: props))
        today.observe(name, props)
        follow(signals.observe(name, props, at: time))
        trim()
        save()
        flushTimer?.cancel()
        flushTimer = Task { [weak self, flushDelay] in
            do { try await Task.sleep(for: flushDelay) } catch { return }
            await self?.flush()
        }
    }

    private func noteVisibility(_ name: String, _ props: [String: UsageValue]) {
        switch (name, props["by"]) {
        case ("app_opened", _): if case let .bool(hidden)? = props["hidden"] { hiddenByPerson = hidden }; hiddenByCall = false
        case ("hidden", .word("person")?): hiddenByPerson = true
        case ("hidden", _): hiddenByCall = true
        case ("shown", .word("automatic")?): hiddenByCall = false
        case ("shown", _): hiddenByPerson = false
        default: break
        }
    }

    /// What the signals made of it: `repeat` and `frustration`, at the moment they happened.
    private func follow(_ follows: [UsageSignals.Follow]) {
        for follow in follows { record(follow.name, follow.props, at: follow.at) }
    }

    // MARK: The day's summary

    /// A day that's over is sent as one `day_summary` (and forgotten), before anything of the new day. A day with nothing
    /// in it isn't sent, nor one more than 60 days back.
    private func rollDayIfNeeded() {
        let key = Self.dayKey(now(), calendar)
        guard today.day != key else { return }
        let finished = today
        today = UsageDay(day: key)
        saveDay()
        guard finished != UsageDay(day: finished.day), let ended = Self.date(finished.day, calendar),
              let daysAgo = calendar.dateComponents([.day], from: ended, to: calendar.startOfDay(for: now())).day, (1...60).contains(daysAgo) else { return }
        let daysSinceInstall = installedAt.flatMap { calendar.dateComponents([.day], from: calendar.startOfDay(for: $0), to: ended).day }.map { max(0, $0) }
        var props = finished.summary(daysAgo: daysAgo, daysSinceInstall: daysSinceInstall)
        props["macos"] = .int(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        record("day_summary", props, at: now())
    }

    static func dayKey(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(_ key: String, _ calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private func saveDay() {
        daySavedAt = now()
        do {
            try FileManager.default.createDirectory(at: dayFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(today).write(to: dayFile, options: .atomic)
        } catch {
            log.error("usage: couldn't save the day's counts: \(error.localizedDescription, privacy: .public)")
            ErrorReports.report(.writeFailed, error)
        }
    }

    /// Whether `value` has `shape`.
    static func fits(_ value: UsageValue, _ shape: Shape) -> Bool {
        switch (shape, value) {
        case (.bool, .bool): true
        case let (.int(range), .int(number)): range.contains(number)
        case let (.word(words), .word(word)): words.contains(word)
        case let (.version, .word(word)): word.wholeMatch(of: /[0-9]{1,3}(\.[0-9]{1,3}){0,3}/) != nil
        case let (.place, .word(word)): ErrorReports.isPlace(word)
        default: false
        }
    }

    // MARK: Sending

    /// Sends everything waiting, after any send already under way.
    public func flush() async {
        follow(signals.due(at: now()))
        while true {
            if let running = sending {
                await running.value
                continue
            }
            trim()
            guard !queue.isEmpty else { return }
            let send = Task { await self.sendWaiting(); self.sending = nil }
            sending = send
            await send.value
            return
        }
    }

    /// When Moku quits (`applicationWillTerminate`): one last batch, waiting `seconds` at most. It blocks the main thread
    /// on purpose: an app that's quitting can't wait on main-actor tasks, since AppKit may not run them again. What
    /// doesn't go waits in the file for the next launch. A send already under way is left to finish or not.
    public func sendBeforeQuit(within seconds: Double = 2) {
        follow(signals.due(at: now(), all: true))
        flushTimer?.cancel()
        trim()
        save()
        saveDay()
        guard sending == nil, !queue.isEmpty else { return }
        let batch = Array(queue.prefix(Self.batchSize))
        guard let body = encode(batch) else { return }
        let answer = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let answered = DispatchSemaphore(value: 0)
        Task.detached { [post, endpoint, token = token()] in
            let code = try? await post(endpoint, body, token)
            answer.withLock { $0 = code }
            answered.signal()
        }
        guard answered.wait(timeout: .now() + seconds) == .success, let code = answer.withLock({ $0 }), Self.outcome(code) != .later else { return }
        let done = Set(batch.map(\.id))
        queue.removeAll { done.contains($0.id) }
        save()
    }

    private func sendWaiting() async {
        while let first = queue.first {
            let batch = Array(queue.prefix(Self.batchSize))
            let outcome = await send(batch)
            guard outcome != .later else { return }
            if outcome == .refused { log.error("usage: the relay refused \(batch.count) events (first \(first.name, privacy: .public)); dropped") }
            let done = Set(batch.map(\.id))
            queue.removeAll { done.contains($0.id) }
            save()
        }
    }

    private enum Outcome { case sent, refused, later }

    private func send(_ batch: [Event]) async -> Outcome {
        guard let body = encode(batch) else { return .refused }
        guard let code = try? await post(endpoint, body, token()) else { return .later }
        return Self.outcome(code)
    }

    private func encode(_ batch: [Event]) -> Data? {
        try? JSONEncoder().encode(Batch(device: device, events: batch.map { Batch.Sent(name: $0.name, ts: $0.ts, props: $0.props) }))
    }

    /// 2xx: sent. 429, 5xx or anything odd: try later. Any other 4xx: the relay will never take it.
    private static func outcome(_ code: Int) -> Outcome {
        switch code {
        case 200..<300: .sent
        case 429: .later
        case 400..<500: .refused
        default: .later
        }
    }

    // MARK: The queue on disk

    /// Drops what's older than a week, then the oldest past 200.
    private func trim() {
        let oldest = Int64(((now().timeIntervalSince1970 - Self.maxAge) * 1000).rounded())
        queue.removeAll { $0.ts < oldest }
        if queue.count > Self.maxQueued { queue.removeFirst(queue.count - Self.maxQueued) }
    }

    private func save() {
        saveDay()
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(queue).write(to: file, options: .atomic)
        } catch {
            log.error("usage: couldn't save the queue: \(error.localizedDescription, privacy: .public)")
            ErrorReports.report(.writeFailed, error)
        }
    }
}

// MARK: Launches and buckets

extension UsageEvents {
    static let lastVersionKey = "Moku.lastVersion"
    static let installedAtKey = "Moku.installedAt"
    /// The process id of the Moku whose launch is open, from its launch until its quit runs (`recordQuit`); 0 once it
    /// quit. Still set at the next launch means that Moku ended some other way. Only the Moku that opened it closes it.
    /// (Builds before 2026-10-14 kept true or false here; true reads as 1, so they're understood too.)
    static let sessionOpenKey = "Moku.sessionOpen"

    /// How the launch before this one ended.
    public enum PreviousExit: String, Equatable, Sendable { case clean, unclean }

    /// What this launch is, for `app_opened` and `update_installed`.
    public struct Launch: Equatable, Sendable {
        /// Nothing says Moku ran here before: no version saved, and the welcome never finished.
        public var firstLaunch: Bool
        /// The first launch of a new version.
        public var updated: Bool
        /// The version before an update; nil when it's unknown (an update from 0.1.7 or earlier, which saved none).
        public var previousVersion: String?
        /// "login" (opened at login), "update" (the first launch of a new version) or "person".
        public var launchedBy: String
        /// Nil when it's unknown: the first launch, or a Mac that ran a version that kept no record.
        public var previousExit: PreviousExit? = nil
    }

    /// Reads the version the last launch saved, then saves this one (and the install time, the first time there's none).
    public static func recordLaunch(version: String, onboarded: Bool, loginItem: Bool, defaults: UserDefaults = .standard,
                                    pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                                    now: Date = Date()) -> Launch {
        let previous = defaults.string(forKey: lastVersionKey)
        defaults.set(version, forKey: lastVersionKey)
        if defaults.object(forKey: installedAtKey) == nil { defaults.set(now, forKey: installedAtKey) }
        let firstLaunch = previous == nil && !onboarded
        let updated = !firstLaunch && previous != version
        let previousExit = defaults.object(forKey: sessionOpenKey).map { _ in
            defaults.integer(forKey: sessionOpenKey) != 0 ? PreviousExit.unclean : .clean
        }
        defaults.set(Int(pid), forKey: sessionOpenKey)
        return Launch(firstLaunch: firstLaunch, updated: updated, previousVersion: updated ? previous : nil,
                      launchedBy: loginItem ? "login" : updated ? "update" : "person", previousExit: previousExit)
    }

    /// Moku is quitting (`applicationWillTerminate`): the next launch finds this one ended normally.
    /// A Moku that never recorded a launch (the disk image's copy handing over to Applications) leaves it alone.
    public static func recordQuit(defaults: UserDefaults = .standard, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        guard defaults.integer(forKey: sessionOpenKey) == Int(pid) else { return }
        defaults.set(0, forKey: sessionOpenKey)
    }

    /// Opened again by a quiet relaunch: no `app_opened` (the same Moku), but the old one's quit closed the session, so
    /// this one opens it again. Without it, a crash after a quiet relaunch would read "clean" at the next launch.
    public static func recordQuietRelaunch(defaults: UserDefaults = .standard, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        defaults.set(Int(pid), forKey: sessionOpenKey)
    }

    /// When Moku was first opened on this Mac (for a Mac that had Moku before 0.1.8: its first launch of 0.1.8).
    public static func installedAt(defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: installedAtKey) as? Date
    }

    /// The Mac's memory in broad steps (8, 16, 24 or 32 GB and more), so it says little about the Mac.
    public static func ramBucket(bytes: UInt64) -> Int {
        let gb = Int((Double(bytes) / 1_073_741_824).rounded())
        return [32, 24, 16, 8].first { gb >= $0 } ?? 8
    }

    /// A drift's length in broad steps (the step it reached: 10 s, 30 s, 1, 2, 5, 10, 30 minutes, 1 or 2 hours).
    static func driftBucket(seconds: Double) -> Int {
        let steps = [7200, 3600, 1800, 600, 300, 120, 60, 30, 10]
        return steps.first { seconds >= Double($0) } ?? 0
    }
}
