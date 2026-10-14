import Foundation
import MokuKit

/// The relay's remote switches (docs/launch-plan.md §4; the relay's side is proxy/api/_lib/flags.js). Charles flips
/// them on the relay, for everyone, one plan or one Mac, and the app acts on them:
/// - `forceCalm`: Moku never reacts to a drift (`BehaviorEngine.setForceCalm`).
/// - `cloudJudging` off: the relay refuses Jev, so the brain judges by its rules alone (release builds have no local
///   model). The popover says, calmly, that Moku is thinking offline.
/// - `cloudVoice` off: the relay refuses Luna, so Moku says its built-in lines. Nothing to do here.
/// - `minVersion` above this build: Sparkle checks for an update in the background.
/// The defaults change nothing.
public struct RemoteFlags: Codable, Equatable, Sendable, CustomStringConvertible {
    public var cloudJudging: Bool
    public var cloudVoice: Bool
    public var forceCalm: Bool
    public var minVersion: String?

    public init(cloudJudging: Bool = true, cloudVoice: Bool = true, forceCalm: Bool = false, minVersion: String? = nil) {
        self.cloudJudging = cloudJudging; self.cloudVoice = cloudVoice; self.forceCalm = forceCalm; self.minVersion = minVersion
    }

    public static let standard = RemoteFlags()

    /// A key that's missing or of the wrong kind keeps its default (an older relay), and unknown keys are ignored (a newer one).
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let standard = Self.standard
        cloudJudging = (try? values.decodeIfPresent(Bool.self, forKey: .cloudJudging)) ?? standard.cloudJudging
        cloudVoice = (try? values.decodeIfPresent(Bool.self, forKey: .cloudVoice)) ?? standard.cloudVoice
        forceCalm = (try? values.decodeIfPresent(Bool.self, forKey: .forceCalm)) ?? standard.forceCalm
        minVersion = try? values.decodeIfPresent(String.self, forKey: .minVersion)
    }

    /// Whether a build of `version` is older than `minVersion` ("0.1.7" < "0.1.10" < "0.2").
    public func requiresUpdate(from version: String) -> Bool {
        guard let minVersion else { return false }
        let mine = version.split(separator: ".").map { Int($0) ?? 0 }, least = minVersion.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(mine.count, least.count) {
            let a = index < mine.count ? mine[index] : 0, b = index < least.count ? least[index] : 0
            if a != b { return a < b }
        }
        return false
    }

    /// The popover's quiet line. With Jev switched off on purpose, Moku is thinking offline by its rules: not refused,
    /// not failing, and said at once rather than after the brain's breaker has given up. A brain that isn't answering,
    /// or a local model that is, still says so.
    public func thinkingStatus(from brain: ThinkingStatus) -> ThinkingStatus {
        guard !cloudJudging else { return brain }
        switch brain {
        case .fine, .cloudResting, .accessRefused, .restingToday: return .cloudResting
        case .thinkingOnMac, .brainDown: return brain
        }
    }

    public var description: String {
        let on = { (flag: Bool) in flag ? "on" : "off" }
        return "cloudJudging \(on(cloudJudging)), cloudVoice \(on(cloudVoice)), forceCalm \(on(forceCalm)), minVersion \(minVersion ?? "none")"
    }
}

/// Asks the relay for this Mac's switches (POST /v1/flags with the install's token; the body is the device id and the
/// app's version, nothing else), at launch and every 10 minutes, and keeps the last answer in UserDefaults so a
/// switch holds across restarts and while offline. Without a token (a Mac with no access yet) it doesn't ask.
@MainActor
public final class RemoteFlagsClient {
    public typealias Post = @Sendable (_ url: URL, _ body: Data, _ token: String) async throws -> (Data, Int)
    static let cacheKey = "Moku.remoteFlags"
    public static let refreshEverySec: Double = 600
    /// While this build is below `minVersion`, Sparkle is asked at most this often.
    static let updateAskEverySec: Double = 3600

    /// The last answer (the standard flags until there's one).
    public private(set) var current: RemoteFlags
    /// Hears each change (not answers that change nothing).
    public var onChange: (@MainActor (RemoteFlags) -> Void)?
    /// Set by the app in builds with auto-update: Sparkle's background check, which downloads quietly (QuietUpdates installs it).
    public var checkForUpdates: (@MainActor () -> Void)?

    private let defaults: UserDefaults
    private let endpoint: URL
    private let device: String
    private let appVersion: String
    private let token: @MainActor () -> String?
    private let post: Post
    private let now: () -> Date
    private var askedForUpdateAt: Date?
    private var loop: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard, relay: URL = RelayAccess.defaultRelay, device: String = RelayAccess.deviceHash(),
                appVersion: String, token: @escaping @MainActor () -> String?, post: Post? = nil, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.endpoint = relay.appendingPathComponent("v1/flags"); self.device = device
        self.appVersion = appVersion; self.token = token; self.now = now
        self.post = post ?? { url, body, token in
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
            request.httpBody = body
            let (data, response) = try await MokuNetwork.session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        current = defaults.data(forKey: Self.cacheKey).flatMap { try? JSONDecoder().decode(RemoteFlags.self, from: $0) } ?? .standard
    }

    /// Asks the relay now and every 10 minutes, for as long as Moku runs.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(Self.refreshEverySec))
            }
        }
    }

    /// Asks the relay once and returns the flags in force. The last answer stays when there's no new one: offline,
    /// no token, an unknown token (401) or a relay without /v1/flags (404).
    @discardableResult public func refresh() async -> RemoteFlags {
        if let token = token(), let body = try? JSONSerialization.data(withJSONObject: ["device": device, "version": appVersion]),
           let (data, code) = try? await post(endpoint, body, token), code == 200,
           let flags = Self.read(data), flags != current {
            current = flags
            if let saved = try? JSONEncoder().encode(flags) { defaults.set(saved, forKey: Self.cacheKey) }
            onChange?(flags)
        }
        askForUpdateIfDue()
        return current
    }

    /// The relay's answer, or nil (reported: a 200 the app can't read).
    private static func read(_ data: Data) -> RemoteFlags? {
        do { return try JSONDecoder().decode(RemoteFlags.self, from: data) } catch {
            ErrorReports.report(.relayDecode, error)
            return nil
        }
    }

    private func askForUpdateIfDue() {
        guard current.requiresUpdate(from: appVersion), let checkForUpdates else { return }
        if let askedForUpdateAt, now().timeIntervalSince(askedForUpdateAt) < Self.updateAskEverySec { return }
        askedForUpdateAt = now()
        checkForUpdates()
    }
}
