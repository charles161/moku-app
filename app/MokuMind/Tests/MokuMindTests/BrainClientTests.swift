import Foundation
import MokuKit
import Synchronization
import Testing
@testable import MokuMind

/// Answers every request for a session with a canned status and body, and records what was asked.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var body: String
        var failWith: URLError.Code?
    }

    struct Seen: Sendable {
        var method: String
        var path: String
        var query: String?
        var timeout: TimeInterval
        var contentType: String?
        var authorization: String?
        var body: Data
    }

    /// Keyed by the per-test header so tests can run in parallel.
    static let replies = Mutex<[String: Reply]>([:])
    static let seen = Mutex<[String: [Seen]]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.value(forHTTPHeaderField: "X-Stub") ?? ""
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let seen = Seen(method: request.httpMethod ?? "", path: request.url?.path() ?? "", query: request.url?.query(),
                        timeout: request.timeoutInterval,
                        contentType: request.value(forHTTPHeaderField: "Content-Type"),
                        authorization: request.value(forHTTPHeaderField: "Authorization"), body: body)
        Self.seen.withLock { $0[key, default: []].append(seen) }
        let reply = Self.replies.withLock { $0[key] } ?? Reply(status: 500, body: "no stub", failWith: nil)
        if let code = reply.failWith {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@Suite("Brain client")
struct BrainClientTests {
    let key = UUID().uuidString
    let client: BrainClient

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Stub": key]
        client = BrainClient(session: URLSession(configuration: configuration))
    }

    func reply(_ status: Int = 200, _ body: String = "{}", failWith: URLError.Code? = nil) {
        StubProtocol.replies.withLock { $0[key] = .init(status: status, body: body, failWith: failWith) }
    }

    var seen: [StubProtocol.Seen] { StubProtocol.seen.withLock { $0[key] ?? [] } }

    @Test func judgePostsTheSampleAndDecodesTheVerdict() async throws {
        reply(200, """
        {"sampleId":"s1","state":"drifting","thread":null,"isNewThread":false,"confidence":0.8,
         "source":"jev","reason":"YouTube","latencyMs":512}
        """)
        let sample = Samples.sample("s1", at: Date(timeIntervalSince1970: 1_790_000_000.1234))
        let verdict = try await client.judge(sample)
        #expect(verdict.state == .drifting)
        #expect(verdict.sampleId == "s1")
        let request = try #require(seen.first)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/judge")
        #expect(request.contentType == "application/json")
        let json = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(json["id"] as? String == "s1")
        #expect(json["ts"] as? Int == 1_790_000_000_123)  // whole epoch milliseconds
    }

    @Test func everyRequestCarriesTheBrainTokenWhenThereIsOne() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Stub": key]
        let token = String(repeating: "ab", count: 32)
        let withToken = BrainClient(session: URLSession(configuration: configuration), token: token)
        reply(200, "{}")
        try await withToken.sendFeedback(Feedback(ts: Date(), kind: .pat))
        try? await withToken.deleteEverything()
        _ = try? await withToken.counts(date: Date())
        #expect(seen.count == 3 && seen.allSatisfy { $0.authorization == "Bearer \(token)" })
        try await client.sendFeedback(Feedback(ts: Date(), kind: .pat))  // tests and tools without a token send none
        #expect(seen.last?.authorization == nil)
    }

    @Test func modelCallsGetEightSecondsAndLocalCallsThree() throws {
        let judge = try client.makeRequest("/v1/judge", method: "POST", body: Samples.sample("s"), timeout: BrainClient.modelTimeout)
        #expect(judge.timeoutInterval == 8)
        #expect(BrainClient.modelTimeout == 8)
        #expect(BrainClient.localTimeout == 3)
    }

    @Test func requestsCarryTheirTimeouts() async throws {
        reply(200, #"{"text":"Hey.","source":"luna"}"#)
        _ = try await client.voice(VoiceRequest(kind: .nudge, userName: "Charles"))
        reply(200, #"{"stored":1}"#)
        try await client.sendEvent(CompanionEvent(ts: Date(), type: .patted))
        try await client.sendFeedback(Feedback(ts: Date(), kind: .pat))
        #expect(seen.map(\.path) == ["/v1/voice", "/v1/events", "/v1/feedback"])
        #expect(seen.map(\.timeout) == [8, 3, 3])
    }

    @Test func readsWorldConfigAndThreads() async throws {
        reply(200, #"{"growthPoints":42.5,"todayFocusMinutes":30,"todayReturns":2,"longestFocusMinutesToday":25,"threads":[]}"#)
        #expect(try await client.world().growthPoints == 42.5)
        reply(200, """
        {"userName":"Charles","sampleIntervalSec":3,"awayAfterIdleSec":300,"shortDriftMaxSec":120,
         "annoyedAfterSec":60,"standUpAfterSec":240,"askAfterSec":600,"smileEverySec":900,"drinkEverySec":1000000,
         "proudAfterSec":2700,"breakAfterSec":3000,"evidenceWindowSec":60,"longAwaySec":600,
         "ignoredNudgeAfterSec":600,"threadLabelGapSec":1800,"teaBreakMaxSec":1200,"graceSec":10}
        """)
        #expect(try await client.config() == .charles)
        let thread = #"{"id":"t1","title":"DSA · Trees","summary":"","focusMinutesToday":5,"focusMinutesTotal":50,"lastActiveAt":1790000000000}"#
        reply(200, "[\(thread)]")
        #expect(try await client.threads().map(\.title) == ["DSA · Trees"])
        reply(200, #"{"threads":[\#(thread)]}"#)
        #expect(try await client.threads().map(\.id) == ["t1"])
        #expect(seen.map(\.method) == ["GET", "GET", "GET", "GET"])
        #expect(seen.map(\.path) == ["/v1/world", "/v1/config", "/v1/threads", "/v1/threads"])
    }

    @Test func todayAsksForTheLocalDayAndDecodesTheSummary() async throws {
        reply(200, #"""
        {"date":"2026-09-23","note":"A steady day.","focusedMinutes":94,"longestFocusMinutes":47,"returns":6,
         "unitsToday":9,"segments":[],"built":[],"wandered":[],"quickCheckMinutes":3,"comebacks":[],
         "bestComeback":null,"completions":[],"byCategory":[{"category":"building","minutes":60}],
         "goals":[{"id":"t1","title":"building Moku","summary":"The settings screen, then the Stripe docs","minutes":80,
                   "longestMinutes":47,"apps":[{"app":"Cursor","bundleId":"com.todesktop.230313mzl4w4u92","host":null,"name":"Cursor","minutes":60,
                   "activities":["building Moku"],"titles":["SettingsWindow.swift"],"segmentIds":["seg-a"],"firstAt":1790000000000}],"detours":2,
                   "detourMinutes":9,"detourPlace":"youtube.com","firstAt":1790000000000,"lastAt":1790005000000,
                   "workflow":[{"kind":"app","appId":"app:com.todesktop.230313mzl4w4u92","minutes":60,"count":0,"place":null},
                               {"kind":"detour","appId":"","minutes":9,"count":2,"place":"YouTube"}],
                   "sittings":2,"steps":["edited SettingsWindow.swift","ran swift test"]},
                  {"id":"other","title":"Other work","summary":null,"minutes":14,"longestMinutes":6,"apps":[],"detours":0,
                   "detourMinutes":0,"detourPlace":null,"firstAt":1790006000000,"lastAt":1790007000000}]}
        """#)
        let summary = try await client.today(date: nil)
        #expect(summary.goals.map(\.id) == ["t1", "other"] && summary.goals.last?.isOther == true)
        #expect(summary.goals.first?.apps.first?.titles == ["SettingsWindow.swift"] && summary.goals.first?.detourPlace == "youtube.com")
        #expect(summary.goals.first?.workflow == [.app("app:com.todesktop.230313mzl4w4u92", 60), .detour("YouTube", 9, count: 2)])
        #expect(summary.goals.first?.steps == ["edited SettingsWindow.swift", "ran swift test"] && summary.goals.first?.sittings == 2)
        #expect(summary.goals.first?.apps.first?.firstAt == Date(timeIntervalSince1970: 1_790_000_000))
        // A brain from before Your day by task: no workflow, steps or names, and the goal still reads.
        #expect(summary.goals.last?.workflow == [] && summary.goals.last?.steps == [] && summary.goals.last?.sittings == 1)
        #expect(summary.returns == 6)
        #expect(summary.note == "A steady day.")
        #expect(summary.byCategory == [CategoryTotal(category: .building, minutes: 60)])
        var noon = DateComponents()
        (noon.year, noon.month, noon.day, noon.hour) = (2026, 9, 21, 12)
        _ = try await client.today(date: Calendar.current.date(from: noon)!)
        #expect(seen.map(\.path) == ["/v1/today", "/v1/today"])
        #expect(seen.map(\.query) == [nil, "date=2026-09-21"])
        #expect(seen.map(\.timeout) == [8, 8])  // Moku's note may need Luna
    }

    @Test func daysAsksForTheLocalRangeAndDecodesTheTotals() async throws {
        reply(200, #"{"firstDay":"2026-09-21","days":[{"date":"2026-09-21","focusedMinutes":0,"longestFocusMinutes":0,"returns":0,"lanterns":0,"pieces":0},{"date":"2026-09-22","focusedMinutes":94,"longestFocusMinutes":47,"returns":6,"lanterns":2,"pieces":9}]}"#)
        func noon(_ day: Int) -> Date { var c = DateComponents(); (c.year, c.month, c.day, c.hour) = (2026, 9, day, 12); return Calendar.current.date(from: c)! }
        let response = try await client.days(from: noon(21), to: noon(27))
        #expect(response.firstDay == "2026-09-21")
        #expect(response.days.map(\.focusedMinutes) == [0, 94] && response.days.last?.lanterns == 2)
        #expect(seen.map(\.path) == ["/v1/days"])
        #expect(seen.map(\.query) == ["from=2026-09-21&to=2026-09-27"])
    }

    @Test func failuresAreThrownNeverCrashes() async {
        reply(400, #"{"error":"invalid body"}"#)
        await #expect(throws: BrainError.status(path: "/v1/events", code: 400, body: #"{"error":"invalid body"}"#)) {
            try await client.sendEvent(CompanionEvent(ts: Date(), type: .patted))
        }
        reply(200, "not json")
        await #expect(throws: BrainError.self) { try await client.world() }
        reply(failWith: .timedOut)
        await #expect(throws: BrainError.timedOut(path: "/v1/judge")) { try await client.judge(Samples.sample("s")) }
        reply(failWith: .cannotConnectToHost)
        await #expect(throws: BrainError.self) { try await client.config() }
    }

    /// What goes wrong is reported too (`ErrorReports`, as `app_error`), named by the call that failed: never the path's
    /// query, the body or the error's text. A 404 isn't (an older brain without an endpoint).
    @MainActor
    @Test func failuresAreReportedByKindAndTheCallThatFailed() async {
        var got: [ErrorReport] = []
        ErrorReports.sink = { got.append($0) }
        defer { ErrorReports.sink = nil }
        reply(502, #"{"error":"internal error"}"#)
        _ = try? await client.days(from: Date(), to: Date())
        reply(409, #"{"error":"no"}"#)
        _ = try? await client.updateConfig(CompanionConfigPatch(companion: "moku"))
        reply(200, #"{"not":"a day"}"#)
        _ = try? await client.today(date: Date())
        reply(failWith: .cannotFindHost)
        _ = try? await client.voice(VoiceRequest(kind: .nudge, userName: "Priya"))
        reply(failWith: .timedOut)
        _ = try? await client.sendFeedback(Feedback(ts: Date(), kind: .pat))
        reply(404, #"{"error":"not found"}"#)
        _ = try? await client.threads()
        for _ in 0..<100 where got.count < 5 { await Task.yield() }
        let expected = [
            ErrorReport(kind: .brain5xx, domain: "http", code: 502, place: "BrainClient.swift:days"),
            ErrorReport(kind: .brainRefused, domain: "http", code: 409, place: "BrainClient.swift:updateConfig"),
            ErrorReport(kind: .brainDecode, domain: "decoding", code: 3, place: "BrainClient.swift:today"),
            ErrorReport(kind: .brainUnreachable, domain: "url", code: URLError.cannotFindHost.rawValue, place: "BrainClient.swift:voice"),
            ErrorReport(kind: .brainTimeout, domain: "url", code: URLError.timedOut.rawValue, place: "BrainClient.swift:sendFeedback"),
        ]
        for report in expected { #expect(got.contains(report), "\(report)") }  // other tests' failures may be here too
        #expect(!got.contains { $0.place == "BrainClient.swift:threads" })
    }
}
