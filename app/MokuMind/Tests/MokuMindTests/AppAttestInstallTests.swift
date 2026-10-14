import CryptoKit
import Foundation
import Testing
import MokuKit
@testable import MokuMind

/// A trial asks Apple to vouch for the Mac when the relay wants that (docs/specs/app-attest.md); nothing else changes.
@MainActor
@Suite("App Attest at install")
struct AppAttestInstallTests {
    let device = String(repeating: "d", count: 64)
    func home() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("moku-attest-\(UUID().uuidString)") }
    nonisolated static func trial() -> Data {
        let exp = Date().addingTimeInterval(21 * 86_400).timeIntervalSince1970 * 1000
        return try! JSONSerialization.data(withJSONObject: ["token": RelayAccessTests.token(plan: "trial", exp: exp), "plan": "trial"])
    }

    /// A relay that hands out `challenge` (null: its switch is off) and keeps what install sent.
    func relay(challenge: String?, installAnswer: (Data, Int)? = nil, log: LockedBox<[String]>, installs: LockedBox<[[String: Any]]>) -> RelayAccess.Post {
        { url, body in
            log.mutate { $0.append(url.path) }
            if url.path == "/v1/attest/challenge" { return (Data(#"{"challenge":\#(challenge.map { "\"\($0)\"" } ?? "null")}"#.utf8), 200) }
            installs.mutate { $0.append((try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]) }
            return installAnswer ?? (Self.trial(), 200)
        }
    }

    @Test func aTrialSendsApplesStatementOverTheChallengeAndThisMac() async throws {
        let dir = home(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = LockedBox<[String]>([]), installs = LockedBox<[[String: Any]]>([])
        let apple = FakeAttester()
        let access = RelayAccess(home: dir, relay: URL(string: "https://relay.example")!, device: device, attester: apple,
                                 post: relay(challenge: "c1.t1.mac", log: log, installs: installs))
        #expect(try await access.install(invite: nil).plan == .trial)
        #expect(log.value == ["/v1/attest/challenge", "/v1/install"])
        let sent = try #require(installs.value.first?["attestation"] as? [String: String])
        #expect(sent == ["keyId": "a2V5LWlk", "object": Data("statement".utf8).base64EncodedString(), "challenge": "c1.t1.mac"])
        // What Apple signed is this challenge for this Mac (proxy attest.js clientData): a genuine Moku vouches only for its own.
        #expect(apple.asked == [Data(SHA256.hash(data: Data("c1.t1.mac:\(device)".utf8)))])
    }

    @Test func whenTheRelaysSwitchIsOffAppleIsNeverCalled() async throws {
        let dir = home(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = LockedBox<[String]>([]), installs = LockedBox<[[String: Any]]>([])
        let apple = FakeAttester()
        let access = RelayAccess(home: dir, relay: URL(string: "https://relay.example")!, device: device, attester: apple,
                                 post: relay(challenge: nil, log: log, installs: installs))
        _ = try await access.install(invite: nil)
        #expect(apple.asked.isEmpty)
        #expect(installs.value.first?["attestation"] == nil)
    }

    @Test func aMacThatCannotAttestInstallsWithoutAskingAnything() async throws {
        let dir = home(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = LockedBox<[String]>([]), installs = LockedBox<[[String: Any]]>([])
        let access = RelayAccess(home: dir, relay: URL(string: "https://relay.example")!, device: device, attester: FakeAttester(supported: false),
                                 post: relay(challenge: "c", log: log, installs: installs))
        _ = try await access.install(invite: nil)
        #expect(log.value == ["/v1/install"])  // not even a challenge: a Mac before macOS 27 loses nothing
    }

    @Test func anInviteIsNeverAskedToAttest() async throws {
        let dir = home(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = LockedBox<[String]>([]), installs = LockedBox<[[String: Any]]>([])
        let apple = FakeAttester()
        let tester = try JSONSerialization.data(withJSONObject: ["token": RelayAccessTests.token(plan: "tester", exp: 0)])
        let access = RelayAccess(home: dir, relay: URL(string: "https://relay.example")!, device: device, attester: apple,
                                 post: relay(challenge: "c", installAnswer: (tester, 200), log: log, installs: installs))
        #expect(try await access.install(invite: "MOKU-GOOD").plan == .tester)
        #expect(log.value == ["/v1/install"] && apple.asked.isEmpty)
    }

    @Test func appleSayingNoDoesNotStopTheInstall() async throws {
        let dir = home(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = LockedBox<[String]>([]), installs = LockedBox<[[String: Any]]>([])
        let access = RelayAccess(home: dir, relay: URL(string: "https://relay.example")!, device: device, attester: FakeAttester(fails: true),
                                 post: relay(challenge: "c", log: log, installs: installs))
        #expect(try await access.install(invite: nil).plan == .trial)
        #expect(installs.value.first?["attestation"] == nil)
        #expect(ErrorReport.Kind.attestFailed.rawValue == "attest_failed")  // the word the relay lets through (events.js)
    }

    @Test func aRelayThatCannotBeAskedForAChallengeStillInstalls() async throws {
        let dir = home(); defer { try? FileManager.default.removeItem(at: dir) }
        let installs = LockedBox<[[String: Any]]>([])
        let access = RelayAccess(home: dir, relay: URL(string: "https://relay.example")!, device: device, attester: FakeAttester()) { url, body in
            if url.path == "/v1/attest/challenge" { return (Data("oops".utf8), 500) }
            installs.mutate { $0.append((try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]) }
            return (Self.trial(), 200)
        }
        #expect(try await access.install(invite: nil).plan == .trial)
        #expect(installs.value.first?["attestation"] == nil)
    }

    @Test func aRefusalForAnUnverifiedMacSaysSoPlainly() async throws {
        let dir = home(); defer { try? FileManager.default.removeItem(at: dir) }
        let refused = (Data(#"{"error":"this Mac could not be verified as a Mac running Moku","code":"attestation_required"}"#.utf8), 403)
        let access = RelayAccess(home: dir, relay: URL(string: "https://relay.example")!, device: device, attester: FakeAttester(supported: false)) { _, _ in refused }
        await #expect(throws: RelayAccess.AccessError.unverified) { try await access.install(invite: nil) }
        #expect(RelayAccess.AccessError.unverified.description.contains("invite"))
        // …and that is not an unknown invite: the trial path says it differently from a mistyped code.
        #expect(RelayAccess.AccessError.unverified != .unknownInvite)
    }

    @Test func aRefusedMacIsNotAskedAgainHourlyUntilTheNextLaunch() async throws {
        let dir = home(); defer { try? FileManager.default.removeItem(at: dir) }
        let calls = LockedBox<Int>(0)
        let refused = (Data(#"{"code":"attestation_required"}"#.utf8), 403)
        let access = RelayAccess(home: dir, relay: URL(string: "https://relay.example")!, device: device, attester: FakeAttester(supported: false)) { _, _ in
            calls.mutate { $0 += 1 }
            return refused
        }
        #expect(await access.ensureTrial(brainModels: "none") == nil)
        #expect(await access.ensureTrial(brainModels: "none") == nil)
        #expect(await access.ensureTrial(brainModels: "none") == nil)
        #expect(calls.value == 1)
        // A relaunch is a new RelayAccess: it asks once more (the Mac may have a fixed profile by then).
        let next = RelayAccess(home: dir, relay: URL(string: "https://relay.example")!, device: device, attester: FakeAttester(supported: false)) { _, _ in
            calls.mutate { $0 += 1 }
            return refused
        }
        _ = await next.ensureTrial(brainModels: "none")
        #expect(calls.value == 2)
    }

    @Test func aTimeoutIsStillRetriedAsBefore() async throws {
        let dir = home(); defer { try? FileManager.default.removeItem(at: dir) }
        let calls = LockedBox<Int>(0)
        let access = RelayAccess(home: dir, relay: URL(string: "https://relay.example")!, device: device, attester: FakeAttester(supported: false)) { _, _ in
            calls.mutate { $0 += 1 }
            return (Data(), 502)
        }
        _ = await access.ensureTrial(brainModels: "none"); _ = await access.ensureTrial(brainModels: "none")
        #expect(calls.value == 2)
    }
}
