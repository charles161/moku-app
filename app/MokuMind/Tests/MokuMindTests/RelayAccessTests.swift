import Foundation
import Testing
import MokuKit
@testable import MokuMind

@MainActor
@Suite("Relay access")
struct RelayAccessTests {
    nonisolated static func token(plan: String, exp: Double) -> String {
        let json = try! JSONSerialization.data(withJSONObject: ["sub": "d", "plan": plan, "exp": exp, "iat": 0])
        let payload = json.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "moku1.\(payload).sig"
    }
    func home() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("moku-access-\(UUID().uuidString)") }

    @Test func aMacWithNoModelsGetsItsTrialQuietlyAndTheBrainSeesTheTokenAtOnce() async throws {
        let dir = home(); defer { try? FileManager.default.removeItem(at: dir) }
        let exp = Date().addingTimeInterval(21 * 86_400).timeIntervalSince1970 * 1000
        let sent = LockedBox<[String]>([])
        let access = RelayAccess(home: dir, relay: URL(string: "https://relay.example")!, device: String(repeating: "a", count: 64)) { url, body in
            sent.mutate { $0.append("\(url.path) \(String(decoding: body, as: UTF8.self))") }
            return (try JSONSerialization.data(withJSONObject: ["token": Self.token(plan: "trial", exp: exp), "plan": "trial"]), 200)
        }
        #expect(await access.ensureTrial(brainModels: "key") == nil)  // the developer's own key: nothing to do
        let status = try #require(await access.ensureTrial(brainModels: "none"))
        #expect(status.plan == .trial && status.daysLeft() == 21)
        #expect(sent.value.count == 1 && sent.value[0].hasPrefix("/v1/install") && sent.value[0].contains(String(repeating: "a", count: 64)))
        let file = try String(contentsOf: dir.appendingPathComponent("credentials.env"), encoding: .utf8)
        #expect(file.contains("MOKU_GATEWAY_URL=https://relay.example/v4/ai") && file.contains("MOKU_ACCESS_TOKEN=moku1."))
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("credentials.env").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(await access.ensureTrial(brainModels: "none") == nil)  // it has one now
    }

    @Test func anInviteMakesATesterKeepsOtherLinesAndAWrongCodeSaysSo() async throws {
        let dir = home(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "JEV_VERCEL=dev-key\nMOKU_ACCESS_TOKEN=old\n".write(to: dir.appendingPathComponent("credentials.env"), atomically: true, encoding: .utf8)
        let access = RelayAccess(home: dir, relay: URL(string: "https://relay.example")!, device: String(repeating: "b", count: 64)) { _, body in
            let invite = (try JSONSerialization.jsonObject(with: body) as? [String: String])?["invite"]
            if invite == "MOKU-FULL" { return (Data(#"{"error":"this invite is already in use on other Macs","code":"invite_full"}"#.utf8), 403) }
            return invite == "MOKU-GOOD-CODE" ? (try JSONSerialization.data(withJSONObject: ["token": Self.token(plan: "tester", exp: 0)]), 200) : (Data(#"{"error":"unknown invite"}"#.utf8), 403)
        }
        await #expect(throws: RelayAccess.AccessError.unknownInvite) { try await access.install(invite: "MOKU-BAD") }
        await #expect(throws: RelayAccess.AccessError.inviteFull) { try await access.install(invite: "MOKU-FULL") }
        #expect(try await access.install(invite: "MOKU-GOOD-CODE").plan == .tester)
        let file = try String(contentsOf: dir.appendingPathComponent("credentials.env"), encoding: .utf8)
        #expect(file.contains("JEV_VERCEL=dev-key") && !file.contains("MOKU_ACCESS_TOKEN=old") && file.components(separatedBy: "MOKU_ACCESS_TOKEN=").count == 2)
    }

    @Test func statusReadsTheTokenOrTheOwnKeyOrNothing() {
        #expect(RelayAccess.claims(of: Self.token(plan: "pro", exp: 0))?.plan == "pro")
        #expect(RelayAccess.claims(of: "moku_static") == nil)
        let access = RelayAccess(home: home(), device: String(repeating: "c", count: 64)) { _, _ in (Data(), 500) }
        #expect(access.status(brainModels: "key").plan == .ownKey)
        #expect(access.status(brainModels: "none").plan == .none)
    }

    @Test func theCurrentTokenIsTheOneInCredentialsOrNone() throws {
        let dir = home(); defer { try? FileManager.default.removeItem(at: dir) }
        let access = RelayAccess(home: dir, device: String(repeating: "c", count: 64)) { _, _ in (Data(), 500) }
        #expect(access.currentToken() == nil)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "JEV_VERCEL=dev-key\nMOKU_ACCESS_TOKEN=\n".write(to: dir.appendingPathComponent("credentials.env"), atomically: true, encoding: .utf8)
        #expect(access.currentToken() == nil)
        try "JEV_VERCEL=dev-key\nMOKU_ACCESS_TOKEN=moku1.abc.sig\n".write(to: dir.appendingPathComponent("credentials.env"), atomically: true, encoding: .utf8)
        #expect(access.currentToken() == "moku1.abc.sig")
    }
}

/// A tiny thread-safe box for the fake relay's call log.
final class LockedBox<T>: @unchecked Sendable {
    private var stored: T; private let lock = NSLock()
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ change: (inout T) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}

/// Apple stands in: it can attest or not, and says what it was asked.
final class FakeAttester: AppAttesting, Sendable {
    let isSupported: Bool
    let fails: Bool
    private let hashes = LockedBox<[Data]>([])
    init(supported: Bool = true, fails: Bool = false) { isSupported = supported; self.fails = fails }
    var asked: [Data] { hashes.value }
    struct Refused: Error {}
    func attest(clientDataHash: Data) async throws -> (keyId: String, object: Data) {
        hashes.mutate { $0.append(clientDataHash) }
        if fails { throw Refused() }
        return ("a2V5LWlk", Data("statement".utf8))
    }
}
