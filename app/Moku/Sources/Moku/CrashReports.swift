import Foundation
import MokuKit
import MokuMind

/// Crashes, to PostHog's Error tracking, so we hear about them without anyone having to write in.
///
/// - The app: macOS writes a report for every crash (~/Library/Logs/DiagnosticReports/Moku-….ips). The ones not
///   delivered yet go out (at launch, again soon after, and hourly); the first launch with this only takes note of
///   what's there, so old crashes stay put. Which files, and when one is done, is `CrashReportFiles` (tested).
/// - The brain: a Go panic isn't a macOS crash. It prints to brain.log and exits, and BrainSupervisor hands that
///   here.
///
/// A report carries what explains the crash and nothing else: the error, the crashed thread's functions (binary name
/// and symbol, no paths: they'd name the Mac's user), the app and macOS versions, and a short device id (the one the
/// relay's usage events use). Release builds only.
enum CrashReports {
    private static let seenKey = "Moku.crashReportsSeen"
    private static let endpoint = URL(string: "https://eu.i.posthog.com/i/v0/e/")!
    /// PostHog's project key is write-only and made to ship inside apps; the relay's usage events use the same project.
    private static let projectKey = "phc_xfdmDEjHDsHVsfiywEeDvXhVGD9CnVpiNVV5Zp4ZSxYs"
    private static let ourBinaries: Set<String> = ["Moku", "moku-brain"]

    static var enabled: Bool { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil }

    /// In the background: the app's crash reports that haven't been delivered (`CrashReportFiles` has the rules). At launch,
    /// a little after it (macOS writes a report a moment after the crash, and a quick relaunch can beat it), and every
    /// hour with the heartbeat. A report counts as done only when PostHog has answered; until then it's tried again.
    static func sendNew() {
        guard enabled else { return }
        Task.detached(priority: .utility) { await Scan.shared.run() }
    }

    /// The brain exited on its own: if brain.log ends with a Go panic, send it (kept for the next scan if it can't go).
    static func brainExited(status: Int32, log: URL) {
        guard enabled, status != 0 else { return }
        Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: log) else { return }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
            guard let data = try? handle.readToEnd(), let tail = String(data: data, encoding: .utf8),
                  let event = brainPanic(fromLog: tail, status: status) else { return }
            guard let body = try? JSONSerialization.data(withJSONObject: event) else { return }
            await Scan.shared.deliverBrainPanic(body)
        }
    }

    /// One scan at a time: the launch's, the hourly one and a brain's panic all touch the same remembered lists.
    private actor Scan {
        static let shared = Scan()
        private static let pendingKey = "Moku.crashReportsPending"
        /// Reports sent in one scan, at most: the rest go at the next.
        private static let perScan = 10
        /// An actor lets a second call in at every `await`: without this, the minute-later scan and an overdue hourly one
        /// (both fire at wake) would plan the same report and post it twice.
        private var scanning = false

        func run() async {
            guard !scanning else { return }
            scanning = true
            defer { scanning = false }
            let defaults = UserDefaults.standard
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let plan = CrashReportFiles.plan(names: names, seen: defaults.stringArray(forKey: seenKey))
            if let baseline = plan.baseline {
                defaults.set(baseline, forKey: seenKey)  // the first launch with this: note, don't send
            }
            var settled: [String] = []
            var offline = false
            for name in plan.toSend.prefix(Self.perScan) {
                let url = folder.appendingPathComponent(name)
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if CrashReportFiles.isStillBeingWritten(modified: modified, now: Date()) { continue }
                guard let text = try? String(contentsOf: url, encoding: .utf8), let event = appCrash(fromReport: text) else {
                    AppLog.write("crash report: \(name) can't be read, skipped")
                    settled.append(name)
                    continue
                }
                switch await CrashReports.send(event) {
                case .delivered: AppLog.write("crash report: sent \(name)"); settled.append(name)
                case .refused: AppLog.write("crash report: \(name) refused, dropped"); settled.append(name)
                case .retry: AppLog.write("crash report: \(name) not delivered, will try again"); offline = true
                }
                if offline { break }  // no answer from PostHog: the rest would only wait too
            }
            if !settled.isEmpty { defaults.set(CrashReportFiles.remembered(seen: defaults.stringArray(forKey: seenKey) ?? [], settled: settled), forKey: seenKey) }
            await sendPending()
        }

        func deliverBrainPanic(_ body: Data) async {
            switch await CrashReports.send(body: body) {
            case .delivered: AppLog.write("crash report: sent the brain's panic")
            case .refused: AppLog.write("crash report: the brain's panic was refused, dropped")
            case .retry:
                guard let text = String(data: body, encoding: .utf8) else { return }
                let defaults = UserDefaults.standard
                defaults.set(CrashReportFiles.queued(defaults.stringArray(forKey: Self.pendingKey) ?? [], adding: text), forKey: Self.pendingKey)
                AppLog.write("crash report: the brain's panic not delivered, will try again")
            }
        }

        /// Brain panics that couldn't be delivered, tried again.
        private func sendPending() async {
            let defaults = UserDefaults.standard
            let waiting = defaults.stringArray(forKey: Self.pendingKey) ?? []
            guard !waiting.isEmpty else { return }
            var done: [String] = []
            for text in waiting {
                if await CrashReports.send(body: Data(text.utf8)) == .retry { break }
                done.append(text)
            }
            // Read the queue again: a panic queued while these were sending (deliverBrainPanic) must stay.
            let left = (defaults.stringArray(forKey: Self.pendingKey) ?? []).filter { !done.contains($0) }
            if left.isEmpty { defaults.removeObject(forKey: Self.pendingKey) } else { defaults.set(left, forKey: Self.pendingKey) }
        }
    }

    // MARK: Reading them

    /// A macOS crash report (.ips: a JSON header line, then a JSON body) as a PostHog `$exception`.
    static func appCrash(fromReport text: String) -> [String: Any]? {
        guard let newline = text.firstIndex(of: "\n"),
              let header = json(String(text[..<newline])), let body = json(String(text[newline...])) else { return nil }
        // 309 is a crash. Other reports macOS may name after Moku (a hang, a resource report) aren't crashes.
        if let kind = header["bug_type"] as? String, kind != "309" { return nil }
        let exception = body["exception"] as? [String: Any] ?? [:]
        let kind = [exception["type"] as? String, (exception["signal"] as? String).map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        let messages = (body["asi"] as? [String: [String]])?.values.flatMap { $0 } ?? []
        let termination = (body["termination"] as? [String: Any])?["indicator"] as? String
        let process = header["app_name"] as? String ?? "Moku"
        let images = (body["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "?" }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let crashed = threads.first { $0["triggered"] as? Bool == true } ?? threads.first ?? [:]
        let frames: [[String: Any]] = (crashed["frames"] as? [[String: Any]] ?? []).prefix(50).map { frame in
            let index = frame["imageIndex"] as? Int ?? -1
            let image = images.indices.contains(index) ? images[index] : "?"
            let symbol = frame["symbol"] as? String
            var out: [String: Any] = ["platform": "custom", "lang": "swift", "module": image, "resolved": symbol != nil, "in_app": image == process || ourBinaries.contains(image),
                                      "function": symbol ?? "\(image) + \(frame["imageOffset"] as? Int ?? 0)"]
            if let file = frame["sourceFile"] as? String { out["filename"] = (file as NSString).lastPathComponent }
            if let line = frame["sourceLine"] as? Int { out["lineno"] = line }
            return out
        }.reversed()  // PostHog reads the most recent call last
        // macOS doesn't keep Swift's crash message, so the summary names where it happened in our own code.
        let whereInOurCode = frames.last { $0["in_app"] as? Bool == true }?["function"] as? String
        let value = messages.first ?? [termination ?? exception["subtype"] as? String ?? "Moku quit unexpectedly", whereInOurCode.map { "in \($0)" }]
            .compactMap { $0 }.joined(separator: " ")
        return event(type: kind.isEmpty ? "Crash" : kind, value: value, frames: frames, process: process,
                     version: header["app_version"] as? String, build: header["build_version"] as? String,
                     timestamp: crashTime(header["timestamp"] as? String))
    }

    /// The last Go panic in brain.log as a PostHog `$exception`, or nil if it didn't end in one.
    static func brainPanic(fromLog tail: String, status: Int32) -> [String: Any]? {
        let lines = tail.components(separatedBy: "\n")
        guard let start = lines.lastIndex(where: { $0.hasPrefix("panic: ") || $0.hasPrefix("fatal error: ") }) else { return nil }
        let head = lines[start]
        let colon = head.firstIndex(of: ":")!
        var frames: [[String: Any]] = []
        var index = start + 1
        // Each Go frame is two lines: "pkg.Function(args)", then "\t<file>:<line> +0x…" (paths are module-relative: -trimpath).
        while index + 1 < lines.count, frames.count < 50 {
            let call = lines[index], place = lines[index + 1]
            if place.hasPrefix("\t"), let open = call.lastIndex(of: "("), !call.hasPrefix("goroutine ") {
                let location = place.dropFirst().split(separator: " ").first.map(String.init) ?? ""
                let parts = location.split(separator: ":")
                if parts.count == 2, let line = Int(parts[1]) {
                    let file = String(parts[0])
                    frames.append(["platform": "go", "function": String(call[..<open]), "filename": file, "lineno": line,
                                   "in_app": file.hasPrefix("moku/")])
                }
                index += 2
            } else { index += 1 }
        }
        return event(type: head.hasPrefix("panic") ? "Go panic" : "Go fatal error", value: String(head[head.index(after: colon)...].trimmingCharacters(in: .whitespaces).prefix(300)),
                     frames: frames.reversed(), process: "moku-brain", version: nil, build: nil, timestamp: nil, extra: ["exit_status": Int(status)])
    }

    // MARK: Sending

    /// An error's text with the person's home folder as `~` (a Go panic or a SQLite error can name a file under it, and
    /// the folder carries their account name).
    static func withoutHomePaths(_ text: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let named = home.isEmpty || home == "/" ? text : text.replacingOccurrences(of: home, with: "~")
        return named.replacingOccurrences(of: #"/Users/[^/\s"']+"#, with: "~", options: .regularExpression)
    }

    private static func event(type: String, value: String, frames: [[String: Any]], process: String, version: String?, build: String?,
                              timestamp: String?, extra: [String: Any] = [:]) -> [String: Any] {
        let info = Bundle.main.infoDictionary
        let device = String(RelayAccess.deviceHash().prefix(12))
        var properties: [String: Any] = [
            "$exception_list": [["type": type, "value": String(withoutHomePaths(value).prefix(300)), "mechanism": ["handled": false, "synthetic": false, "type": "generic"],
                                 "stacktrace": ["type": "raw", "frames": frames]]],
            // The report goes straight from the Mac, so PostHog would otherwise look up the city from its address.
            "$exception_level": "fatal", "$lib": "moku-crash-reports", "$process_person_profile": false, "$geoip_disable": true,
            "process": process, "device": device,
            "app_version": version ?? info?["CFBundleShortVersionString"] as? String ?? "?", "build": build ?? info?["CFBundleVersion"] as? String ?? "?",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        properties.merge(extra) { $1 }
        var event: [String: Any] = ["api_key": projectKey, "event": "$exception", "distinct_id": device, "properties": properties]
        if let timestamp { event["timestamp"] = timestamp }
        return event
    }

    /// Posts the event. Delivered only when PostHog says so: no answer at all (offline, a blocked address) is a retry.
    fileprivate static func send(_ event: [String: Any]) async -> CrashReportFiles.Delivery {
        guard let body = try? JSONSerialization.data(withJSONObject: event) else { return .refused }
        return await send(body: body)
    }

    fileprivate static func send(body: Data) async -> CrashReportFiles.Delivery {
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = body
        let status = (try? await MokuNetwork.session.data(for: request))?.1 as? HTTPURLResponse
        return CrashReportFiles.delivery(forStatus: status?.statusCode)
    }

    fileprivate static func json(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// "2026-10-01 01:23:45.00 +0530" → ISO 8601, so the crash is filed when it happened, not when it was sent.
    private static func crashTime(_ text: String?) -> String? {
        guard let text else { return nil }
        let reader = DateFormatter(); reader.locale = Locale(identifier: "en_US_POSIX"); reader.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        return reader.date(from: text).map { ISO8601DateFormatter().string(from: $0) }
    }
}
