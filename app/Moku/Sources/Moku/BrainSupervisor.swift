import Foundation
import MokuKit
import MokuMind

/// Keeps the brain (the local judging server on 127.0.0.1:8020, or the next free port up to 8029) running for as long as
/// Moku runs.
///
/// If a brain already answers on the port (a developer started one by hand), Moku leaves it alone; it must hold the
/// same brain token (~/.moku/brain-token, BrainToken), or it answers Moku nothing and Moku stays calm. A moku-brain
/// that an earlier Moku left behind (its app crashed; the brain's parent is launchd) is stopped and replaced
/// (BrainAdoption). A brain Moku didn't start that stops answering is replaced after a minute.
/// Otherwise it starts the one inside Moku.app (`Resources/brain/moku-brain`, built from brain-go/). A brain that
/// exits is restarted after 2 s; one that exits more
/// than 5 times in 10 minutes rests 10 minutes before the next try. Every 30 s Moku checks /health: a
/// brain it started that stops answering for 1.5 minutes (hung, not exited) is stopped and started
/// again, and `onStatus` hears whether the brain and its cloud models are answering. Everything goes to
/// ~/.moku/app.log. Moku keeps working meanwhile: without verdicts it stays calm.
@MainActor
final class BrainSupervisor {
    /// Charles's calibration build (scripts/build-app.sh with MOKU_CALIBRATE=1; never a release).
    static let calibrating = Bundle.main.object(forInfoDictionaryKey: "MokuCalibrate") as? Bool == true
    private let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".moku")
    private func healthURL(_ port: Int) -> URL { URL(string: "http://127.0.0.1:\(port)/health")! }
    private var health: URL { healthURL(port) }
    /// The brain token the app's BrainClient sends; handed to the brain Moku starts (MOKU_BRAIN_TOKEN).
    private let token: String?
    private var process: Process?
    private var recentStarts: [Date] = []
    private var stopping = false
    private var watching = false
    /// A brain is about to be started (the 2 s after an exit, or the rest after repeated crashes): the watch mustn't start another.
    private var launchPending = false
    /// Something answers on the port that doesn't take Moku's token: Moku looks again at every check.
    private var standingOff = false
    /// The first of the ten ports Moku's brain may live on (BrainPorts): 8020 unless something else holds it.
    private static let firstPort = BrainPorts.first
    /// The port in use now. Heard by `onPort` as soon as it's settled, before anything asks the brain.
    private(set) var port = BrainSupervisor.firstPort
    var onPort: (@MainActor (Int) -> Void)?
    /// Hears, every 30 s, whether the brain and its cloud models are answering (the popover's quiet line).
    var onStatus: (@MainActor (ThinkingStatus) -> Void)?
    /// Times the brain exited without being asked to since launch (crashes, and hung brains Moku stopped): for the heartbeat.
    private(set) var unexpectedExits = 0
    /// Usage (`trouble`): every 30 s, whether the brain answered, Jev's breaker state and its last error ("provider 429").
    var onHealth: (@MainActor (_ answering: Bool, _ judgeState: String?, _ lastError: String?) -> Void)?
    /// Usage (`trouble`): the brain exited without being asked to and is being started again.
    var onUnexpectedExit: (@MainActor () -> Void)?
    /// Every 30 s too: the brain's own errors since it started, by kind and place (brain-go errors.go), for `ErrorLog`.
    var onErrors: (@MainActor ([BrainErrorCount]) -> Void)?
    static let watchEvery: Duration = .seconds(30)
    /// Checks in a row without an answer before a brain Moku started counts as hung (1.5 minutes).
    static let hungAfterMisses = 3

    init(token: String?) {
        self.token = token
        if token == nil { AppLog.write("brain: no brain token (~/.moku isn't writable); the brain won't answer Moku") }
    }

    /// Starts the brain unless one is already running. Returns once it answers, or after 15 s.
    func start() async {
        defer { if !watching { watching = true; Task { await watch() } } }
        switch await settle() {
        case .useIt:
            AppLog.write("brain: already running on port \(port), not managed by Moku")
            return
        case .standOff:
            AppLog.write("brain: every port from \(Self.firstPort) to \(Self.firstPort + BrainPorts.count - 1) is taken by something else; Moku stays calm until one is free")
            standingOff = true
            return
        case .launchOwn: break
        }
        launch()
        for _ in 0..<60 {
            if await isHealthy() { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        AppLog.write("brain: not answering 15 s after launch; Moku stays calm until it does")
    }

    private enum Settled { case useIt, launchOwn, standOff }

    /// Which port is Moku's to use (BrainPorts.choose, in order), and what to do on it (BrainAdoption.decide): its own
    /// brain is used, a left-behind moku-brain is stopped, a free port gets a new brain, and whatever else holds a port
    /// is left alone and passed by.
    private func settle() async -> Settled {
        let choice = await BrainPorts.choose(among: Array(Self.firstPort..<(Self.firstPort + BrainPorts.count))) { await probe($0) }
        switch choice {
        case let .adopt(port):
            use(port: port)
            return .useIt
        case let .replace(port, pid):
            use(port: port)
            AppLog.write("brain: pid \(pid) was left behind by an earlier Moku (no app is its parent); stopping it")
            await stop(orphan: pid, port: port)
            return .launchOwn
        case let .start(port):
            use(port: port)
            return .launchOwn
        case .none:
            return .standOff
        }
    }

    private func use(port: Int) {
        if port != Self.firstPort, port != self.port { AppLog.write("brain: port \(Self.firstPort) is held by something else; using \(port)") }
        self.port = port
        onPort?(port)
    }

    /// What is on `port`, as BrainPorts.choose wants to know.
    private func probe(_ port: Int) async -> BrainPorts.Probe {
        guard await isHealthy(port) else { return BrainPorts.isFree(port) ? .free : .taken }
        // A dev server that answers 200 to everything isn't a brain: /health must say so (brain-go app.go).
        guard await isMokuBrain(port) else { return .taken }
        let accepts = await acceptsToken(port)
        let listener = await BrainAdoption.listener(onPort: port)
        switch BrainAdoption.decide(answersHealth: true, acceptsToken: accepts, listener: listener) {
        case .adopt: return .ours
        case let .replace(pid): return .orphan(pid: pid)
        case .standOff, .start: return .taken
        }
    }

    /// SIGTERM, SIGKILL 4 s later if it's still there, then until the port is free (2 s at most).
    private func stop(orphan pid: Int32, port: Int) async {
        kill(pid, SIGTERM)
        for _ in 0..<40 where kill(pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(100)) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        for _ in 0..<20 where await isHealthy(port) { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// Whether what answers /health on `port` says it is a moku-brain.
    private func isMokuBrain(_ port: Int) async -> Bool {
        var request = URLRequest(url: healthURL(port))
        request.timeoutInterval = 2
        guard let (data, response) = try? await MokuNetwork.session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return body["service"] as? String == "moku-brain"
    }

    /// Whether the brain on `port` takes Moku's token (/health doesn't ask for it, so it can't say): it answers its config.
    private func acceptsToken(_ port: Int) async -> Bool {
        guard let token, let url = URL(string: "http://127.0.0.1:\(port)/v1/config") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await MokuNetwork.session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return body["userName"] is String
    }

    /// Every 30 s: is the brain answering, and are its models? Reports the status on change, and restarts a
    /// brain Moku started that has stopped answering for `hungAfterMisses` checks while still running. With no brain
    /// of its own (one it adopted, or one that stood in the way), it starts its own once that one stops answering.
    private func watch() async {
        var misses = 0, last: ThinkingStatus?
        while !stopping {
            try? await Task.sleep(for: Self.watchEvery)
            guard !stopping else { return }
            keepLogsSmall()
            let health = await readHealth()
            misses = health == nil ? misses + 1 : 0
            if misses != 1 { onHealth?(health != nil, health?.cloud?.judge.state, health?.cloud?.judge.lastError) }
            if let errors = health?.errors, !errors.isEmpty { onErrors?(errors) }
            // One missed check could be a busy moment; say it's down from the second.
            let status = misses == 1 ? (last ?? .fine) : ThinkingStatus.from(answering: health != nil, judge: health?.cloud?.judge.state,
                                                                                since: health?.cloud?.judge.since.map { Date(timeIntervalSince1970: $0 / 1000) },
                                                                                local: health?.cloud?.local?.state)
            if status != last {
                AppLog.write("brain: status \(status)\(health?.cloud?.judge.lastError.map { " (\($0))" } ?? "")")
                onStatus?(status); last = status
            }
            if process == nil, !launchPending { await watchWithoutABrainOfItsOwn(answering: health != nil, misses: misses) }
            if misses >= Self.hungAfterMisses, let process, process.isRunning {
                AppLog.write("brain: not answering for \(misses * 30) s while running; restarting it")
                misses = 0
                stopHung(process)
            }
        }
    }

    /// brain.log and app.log stay under 5 and 2 MB while Moku runs, not only when it starts: Moku runs for weeks.
    private func keepLogsSmall() {
        AppLog.rotateInPlace(home.appendingPathComponent("brain.log"), maxBytes: 5_000_000)
        AppLog.rotate(home.appendingPathComponent("app.log"), maxBytes: 2_000_000)
    }

    /// The brain on the port isn't one Moku started: take its place when it's gone, or when it turns out to be a left-behind one.
    private func watchWithoutABrainOfItsOwn(answering: Bool, misses: Int) async {
        if !answering {
            guard misses >= BrainAdoption.missesBeforeStartingOwn else { return }
            if !standingOff { AppLog.write("brain: the one Moku found has stopped answering; starting its own") }
            await relaunch()
        } else if standingOff {
            await relaunch()
        }
    }

    /// Settles the port again and starts a brain if there's room for one: after an exit, after the rest, and when what
    /// stood in the way is gone.
    private func relaunch() async {
        guard !stopping, !launchPending else { return }
        switch await settle() {
        case .launchOwn:
            standingOff = false
            launch()
        case .useIt:
            if standingOff { AppLog.write("brain: now answers with Moku's token on port \(port); using it") }
            standingOff = false
        case .standOff:
            if !standingOff { AppLog.write("brain: every port is taken by something else; Moku stays calm until one is free") }
            standingOff = true
        }
    }

    /// SIGTERM, then SIGKILL 5 s later if it's still there; the termination handler starts a new one.
    private func stopHung(_ process: Process) {
        process.terminate()
        let pid = process.processIdentifier
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// Stops the brain Moku started (never one it found running).
    func stop() {
        stopping = true
        guard let process, process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
        AppLog.write("brain: stopped")
    }

    private func launch() {
        guard let command = locate() else {
            AppLog.write("brain: not found in Moku.app (Resources/brain/moku-brain); Moku stays calm")
            return
        }
        recentStarts = recentStarts.filter { $0.timeIntervalSinceNow > -600 } + [Date()]
        if recentStarts.count > 5 {
            AppLog.write("brain: exited 5 times in 10 min; trying again in 10 min")
            launchPending = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(600))
                launchPending = false
                recentStarts = []
                await relaunch()
            }
            return
        }
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let log = home.appendingPathComponent("brain.log")
        AppLog.rotate(log, maxBytes: 5_000_000)
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        // O_APPEND, so keepLogsSmall can empty it under the running brain.
        let descriptor = open(log.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        let output = descriptor >= 0 ? FileHandle(fileDescriptor: descriptor, closeOnDealloc: true) : nil

        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = command.directory
        var environment = ProcessInfo.processInfo.environment
        environment["MOKU_HOME"] = home.path
        environment["MOKU_BRAIN_PORT"] = String(port)
        // The brain stops when this app does, however it ends (a crash, kill -9): it never outlives Moku as an orphan.
        environment["MOKU_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        // The same token the app's BrainClient sends (never one inherited from the environment).
        environment["MOKU_BRAIN_TOKEN"] = token
        // A development build finds its credentials fallback (bunny/.env) here; a release has none.
        if let devEnv = Bundle.main.object(forInfoDictionaryKey: "MokuDevEnv") as? String { environment["MOKU_DEV_ENV"] = devEnv }
        // Charles's calibration build: goal-aware judging, the dashboard at /calibrate, screen text kept 14 days. Only the
        // build decides: a switch inherited from the environment never turns either on.
        environment["MOKU_GOAL_JUDGING"] = nil
        environment["MOKU_CALIBRATE"] = Self.calibrating ? "1" : nil
        // The llama.cpp server for the local model the brain runs while Jev or Luna is failing (brain-go/internal/brain/local.go).
        if let server = Bundle.main.resourceURL?.appendingPathComponent("llama/llama-server"),
           FileManager.default.isExecutableFile(atPath: server.path) { environment["MOKU_LLAMA_SERVER"] = server.path }
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.exited(status: status) }
        }
        do {
            try process.run()
            self.process = process
            AppLog.write("brain: started pid \(process.processIdentifier) from \(command.executable.path)\(command.arguments.last.map { " \($0)" } ?? "")")
        } catch {
            AppLog.write("brain: failed to start (\(error.localizedDescription))")
        }
    }

    private func exited(status: Int32) {
        process = nil
        guard !stopping else { return }
        unexpectedExits += 1
        onUnexpectedExit?()
        AppLog.write("brain: exited with status \(status); restarting in 2 s")
        CrashReports.brainExited(status: status, log: home.appendingPathComponent("brain.log"))
        if status == 1 {  // "cannot listen" or "cannot open": say who is in the way, for a report that says "Moku does nothing"
            Task { @MainActor in
                if let other = await BrainAdoption.listener(onPort: port), other.pid != 0 {
                    AppLog.write("brain: port \(port) is held by \(other.name) (pid \(other.pid)); Moku looks for another")
                }
            }
        }
        launchPending = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            launchPending = false
            await relaunch()
        }
    }

    private struct Command { let executable: URL; let arguments: [String]; let directory: URL }

    private func locate() -> Command? {
        guard let native = Bundle.main.resourceURL?.appendingPathComponent("brain/moku-brain"),
              FileManager.default.isExecutableFile(atPath: native.path) else { return nil }
        return Command(executable: native, arguments: [], directory: native.deletingLastPathComponent())
    }

    private func isHealthy(_ port: Int? = nil) async -> Bool {
        var request = URLRequest(url: port.map(healthURL) ?? health)
        request.timeoutInterval = 1
        guard let (_, response) = try? await MokuNetwork.session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// How the brain reaches the models right now ("key", "proxy" or "none"), or nil if it isn't answering.
    func models() async -> String? { await readHealth()?.models }

    /// The local model's state ("missing", "downloading", "ready", "running" or "failed"), or nil if the brain isn't answering.
    func localModel() async -> String? { await readHealth()?.cloud?.local?.state }

    /// The brain's /health, or nil when it doesn't answer within 3 s. `cloud` is absent on older brains.
    private struct Health: Decodable {
        struct Model: Decodable { let state: String; let since: Double?; let lastError: String? }
        struct Local: Decodable { let state: String }
        struct Cloud: Decodable { let judge: Model; let local: Local? }
        let cloud: Cloud?
        /// How the brain reaches the models: "key", "proxy" or "none".
        var models: String? = nil
        /// The brain's own errors (read on their own, so an odd one never hides the rest).
        var errors: [BrainErrorCount] = []
        private enum CodingKeys: String, CodingKey { case cloud, models }
    }
    private func readHealth() async -> Health? {
        var request = URLRequest(url: health)
        request.timeoutInterval = 3
        guard let (data, response) = try? await MokuNetwork.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        var health = (try? JSONDecoder().decode(Health.self, from: data)) ?? Health(cloud: nil)
        health.errors = BrainErrorCount.list(fromHealth: data)
        return health
    }
}
