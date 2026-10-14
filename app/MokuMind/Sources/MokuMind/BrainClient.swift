import Foundation
import Synchronization
import MokuKit

/// The local brain's HTTP API. Every call throws on failure; callers decide what "down" means.
public protocol BrainAPI: Sendable {
    func judge(_ sample: ActivitySample) async throws -> Verdict
    func voice(_ request: VoiceRequest) async throws -> VoiceLine
    func sendFeedback(_ feedback: Feedback) async throws
    func sendEvent(_ event: CompanionEvent) async throws
    func world() async throws -> WorldSnapshot
    func config() async throws -> CompanionConfig
    func threads() async throws -> [ThreadSummary]
    /// The Today window: `date` is a local day (nil for today).
    func today(date: Date?) async throws -> TodaySummary
    /// Each local day's totals, `from` to `to` inclusive, for the Today window's strip of days.
    func days(from: Date, to: Date) async throws -> DaysResponse
    /// The same day as `today(date:)` from what's already written, for "Today counted": never a model call, and the
    /// note only when Luna's is still true of the day.
    func todayCached(date: Date?) async throws -> TodaySummary
}

extension BrainAPI {
    /// A brain that can't say the day without writing: no card, rather than a model call.
    public func todayCached(date: Date?) async throws -> TodaySummary {
        throw BrainError.status(path: "/v1/today?cached=1", code: 404, body: "not supported")
    }
}

public enum BrainError: Error, Equatable, CustomStringConvertible {
    /// No answer in time.
    case timedOut(path: String)
    /// Couldn't reach the brain (not running, connection refused, ...).
    case unreachable(path: String, reason: String)
    /// The brain answered with a non-2xx status.
    case status(path: String, code: Int, body: String)
    /// The brain answered 2xx with something that doesn't match the contract.
    case malformed(path: String, reason: String)

    public var description: String {
        switch self {
        case let .timedOut(path): "brain \(path): timed out"
        case let .unreachable(path, reason): "brain \(path): unreachable (\(reason))"
        case let .status(path, code, body): "brain \(path): HTTP \(code) \(body.prefix(200))"
        case let .malformed(path, reason): "brain \(path): unexpected response (\(reason))"
        }
    }
}

/// `BrainAPI` over URLSession against the brain on 127.0.0.1:8020 (or the port the app found free: `use(port:)`), with
/// `MokuJSON` coders.
/// Judge and voice may wait on a model, so they get 8 s; everything else is local and gets 3 s.
/// Every request carries the brain token (`BrainToken`), without which the brain answers nothing but /health.
public final class BrainClient: BrainAPI {
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:8020")!
    public static let modelTimeout: TimeInterval = 8
    public static let localTimeout: TimeInterval = 3

    private let address: Mutex<URL>
    private var baseURL: URL { address.withLock { $0 } }
    private let session: URLSession
    private let token: String?

    public init(baseURL: URL = BrainClient.defaultBaseURL, session: URLSession = MokuNetwork.session, token: String? = nil) {
        self.address = Mutex(baseURL)
        self.session = session
        self.token = token
    }

    /// Talk to the brain on another port on this Mac: the one the app's supervisor settled on when 8020 was taken.
    public func use(port: Int) {
        guard var parts = URLComponents(url: address.withLock { $0 }, resolvingAgainstBaseURL: false) else { return }
        parts.port = port
        if let url = parts.url { address.withLock { $0 = url } }
    }

    public func judge(_ sample: ActivitySample) async throws -> Verdict {
        try await post("/v1/judge", body: sample, timeout: Self.modelTimeout)
    }

    public func voice(_ request: VoiceRequest) async throws -> VoiceLine {
        try await post("/v1/voice", body: request, timeout: Self.modelTimeout)
    }

    public func sendFeedback(_ feedback: Feedback) async throws {
        _ = try await send(makeRequest("/v1/feedback", method: "POST", body: feedback, timeout: Self.localTimeout))
    }

    public func sendEvent(_ event: CompanionEvent) async throws {
        _ = try await send(makeRequest("/v1/events", method: "POST", body: event, timeout: Self.localTimeout))
    }

    public func world() async throws -> WorldSnapshot {
        try await get("/v1/world")
    }

    public func config() async throws -> CompanionConfig {
        try await get("/v1/config")
    }

    /// "Delete my data": everything the brain saw, decided and learned (config and credentials stay).
    public func deleteEverything() async throws {
        // The brain lets its background work finish first (naming a thread can take 15 s).
        _ = try await send(makeRequest("/v1/data", method: "DELETE", body: nil as Never?, timeout: 40))
    }

    /// Sets the name Moku calls the person by (onboarding) and returns the config served from then on.
    public func setUserName(_ name: String) async throws -> CompanionConfig {
        let data = try await send(makeRequest("/v1/config", method: "PUT", body: ["userName": name], timeout: Self.localTimeout))
        return try decode(CompanionConfig.self, from: data, path: "/v1/config")
    }

    /// Saves timings from Settings and returns the config served from then on.
    public func updateConfig(_ patch: CompanionConfigPatch) async throws -> CompanionConfig {
        let data = try await send(makeRequest("/v1/config", method: "PUT", body: patch, timeout: Self.localTimeout))
        return try decode(CompanionConfig.self, from: data, path: "/v1/config")
    }

    /// A bare array of threads; `{"threads": [...]}` is accepted too.
    public func threads() async throws -> [ThreadSummary] {
        let data = try await send(makeRequest("/v1/threads", method: "GET", body: nil as Never?, timeout: Self.localTimeout))
        if let list = try? MokuJSON.decoder().decode([ThreadSummary].self, from: data) { return list }
        return try decode(ThreadList.self, from: data, path: "/v1/threads").threads
    }

    /// The day may need Moku's note from Luna, so it gets the model timeout.
    public func today(date: Date? = nil) async throws -> TodaySummary {
        var path = "/v1/today"
        if let date { path += "?date=" + Self.localDay(date) }
        let data = try await send(makeRequest(path, method: "GET", body: nil as Never?, timeout: Self.modelTimeout))
        return try decode(TodaySummary.self, from: data, path: "/v1/today")
    }

    /// "Today counted": the day with only what's written (`cached=1`): nothing waits on a model, so the local timeout.
    public func todayCached(date: Date? = nil) async throws -> TodaySummary {
        var path = "/v1/today?cached=1"
        if let date { path += "&date=" + Self.localDay(date) }
        let data = try await send(makeRequest(path, method: "GET", body: nil as Never?, timeout: Self.localTimeout))
        return try decode(TodaySummary.self, from: data, path: "/v1/today")
    }

    /// Totals only (no note), so the local timeout.
    public func days(from: Date, to: Date) async throws -> DaysResponse {
        let path = "/v1/days?from=" + Self.localDay(from) + "&to=" + Self.localDay(to)
        let data = try await send(makeRequest(path, method: "GET", body: nil as Never?, timeout: Self.localTimeout))
        return try decode(DaysResponse.self, from: data, path: "/v1/days")
    }

    /// One day in numbers for the opt-in heartbeat (DailyHeartbeat), passed on as is: the app never decodes it.
    public func counts(date: Date) async throws -> Data {
        try await send(makeRequest("/v1/counts?date=" + Self.localDay(date), method: "GET", body: nil as Never?, timeout: Self.localTimeout))
    }

    /// YYYY-MM-DD in the user's time zone, as the brain expects.
    static func localDay(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: Plumbing

    private struct ThreadList: Decodable { var threads: [ThreadSummary] }

    private func post<Body: Encodable, Reply: Decodable>(_ path: String, body: Body, timeout: TimeInterval, caller: String = #function) async throws -> Reply {
        let data = try await send(makeRequest(path, method: "POST", body: body, timeout: timeout), caller: caller)
        return try decode(Reply.self, from: data, path: path, caller: caller)
    }

    private func get<Reply: Decodable>(_ path: String, caller: String = #function) async throws -> Reply {
        let data = try await send(makeRequest(path, method: "GET", body: nil as Never?, timeout: Self.localTimeout), caller: caller)
        return try decode(Reply.self, from: data, path: path, caller: caller)
    }

    func makeRequest<Body: Encodable>(_ path: String, method: String, body: Body?, timeout: TimeInterval) throws -> URLRequest {
        let url = URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL.appending(path: path)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try MokuJSON.encoder().encode(body)
            } catch {
                throw BrainError.malformed(path: path, reason: "could not encode request: \(error)")
            }
        }
        return request
    }

    /// Sends a request; what goes wrong is also reported (`ErrorReports`) as happening in `caller`, the public call.
    /// A 404 isn't: an older brain without an endpoint says so, and callers expect it.
    private func send(_ request: URLRequest, caller: String = #function) async throws -> Data {
        let path = request.url?.path() ?? "?"
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            ErrorReports.report(.brainTimeout, error, function: caller)
            throw BrainError.timedOut(path: path)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            ErrorReports.report(.brainUnreachable, error, function: caller)
            throw BrainError.unreachable(path: path, reason: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw BrainError.malformed(path: path, reason: "not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode >= 500 { ErrorReports.report(.brain5xx, domain: "http", code: http.statusCode, function: caller) }
            else if http.statusCode != 404 { ErrorReports.report(.brainRefused, domain: "http", code: http.statusCode, function: caller) }
            throw BrainError.status(path: path, code: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    private func decode<Reply: Decodable>(_ type: Reply.Type, from data: Data, path: String, caller: String = #function) throws -> Reply {
        do {
            return try MokuJSON.decoder().decode(type, from: data)
        } catch {
            ErrorReports.report(.brainDecode, error, function: caller)
            throw BrainError.malformed(path: path, reason: "\(error)")
        }
    }
}
