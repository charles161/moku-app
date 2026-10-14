import Foundation
import Testing
import MokuKit
@testable import MokuMind

/// Moku Pro (docs/specs/payments.md): the app opens Dodo's checkout from the relay, then renews its token until the
/// payment has landed and the relay answers with a Pro one. No account: the token names the Mac.
@MainActor
@Suite("Moku Pro")
struct RelayProTests {
    func home() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("moku-pro-\(UUID().uuidString)") }

    /// A Mac with a trial token already saved (as the install leaves it).
    func installed(_ dir: URL, authorized: @escaping RelayAccess.AuthorizedPost) async throws -> RelayAccess {
        let exp = Date().addingTimeInterval(5 * 86_400).timeIntervalSince1970 * 1000
        let access = RelayAccess(home: dir, relay: URL(string: "https://relay.example")!, device: "abcdef123456", post: { _, _ in
            (try JSONSerialization.data(withJSONObject: ["token": RelayAccessTests.token(plan: "trial", exp: exp)]), 200)
        }, authorizedPost: authorized)
        _ = try await access.install(invite: nil)
        return access
    }

    @Test func checkoutAsksTheRelayWithThisMacsTokenAndOpensOnlyAnHttpsPage() async throws {
        let dir = home(); defer { try? FileManager.default.removeItem(at: dir) }
        let asked = LockedBox<[(path: String, body: String, token: String)]>([])
        let access = try await installed(dir) { url, body, token in
            asked.mutate { $0.append((url.path, String(decoding: body, as: UTF8.self), token)) }
            return (try JSONSerialization.data(withJSONObject: ["url": "https://checkout.dodopayments.com/session/cks_1"]), 200)
        }
        let url = try await access.checkout(plan: "yearly")
        #expect(url.absoluteString == "https://checkout.dodopayments.com/session/cks_1")
        #expect(asked.value.count == 1 && asked.value[0].path == "/v1/checkout" && asked.value[0].body.contains("yearly"))
        #expect(asked.value[0].token == access.currentToken())
        let plain = try await installed(home()) { _, _, _ in (try JSONSerialization.data(withJSONObject: ["url": "http://example.com"]), 200) }
        await #expect(throws: RelayAccess.AccessError.self) { _ = try await plain.checkout(plan: "monthly") }
    }

    @Test func renewingAfterThePaymentSavesTheProTokenForTheBrain() async throws {
        let dir = home(); defer { try? FileManager.default.removeItem(at: dir) }
        let paidUntil = Date().addingTimeInterval(33 * 86_400).timeIntervalSince1970 * 1000
        let paid = LockedBox(false)
        let access = try await installed(dir) { url, _, _ in
            guard url.path == "/v1/renew" else { return (Data(), 404) }
            let plan = paid.value ? "pro" : "trial"
            let exp = paid.value ? paidUntil : Date().addingTimeInterval(5 * 86_400).timeIntervalSince1970 * 1000
            return (try JSONSerialization.data(withJSONObject: ["token": RelayAccessTests.token(plan: plan, exp: exp), "plan": plan]), 200)
        }
        #expect(await access.renew()?.plan == .trial)  // not paid yet
        paid.mutate { $0 = true }
        let status = try #require(await access.renew())
        #expect(status.plan == .pro)
        #expect(status.expiresAt.map { abs($0.timeIntervalSince1970 * 1000 - paidUntil) < 1 } == true)
        // Saved for the brain: credentials.env now holds the Pro token.
        #expect(access.currentToken().flatMap { RelayAccess.claims(of: $0)?.plan } == "pro")
    }

    @Test func aRefusedOrUnreachableRenewalKeepsTheTokenItHas() async throws {
        let dir = home(); defer { try? FileManager.default.removeItem(at: dir) }
        let access = try await installed(dir) { _, _, _ in (try JSONSerialization.data(withJSONObject: ["error": "trial ended"]), 402) }
        let before = access.currentToken()
        #expect(await access.renew() == nil)
        #expect(access.currentToken() == before)
    }

    @Test func settingsSaysWhatProIsAndAnEndedTrialPointsToIt() {
        #expect(AccessStatus(plan: .pro, expiresAt: Date()).line().contains("Moku Pro"))
        #expect(AccessStatus(plan: .trial, expiresAt: Date().addingTimeInterval(-60)).line().contains("Moku Pro"))
        #expect(AccessStatus(plan: .trial, expiresAt: Date().addingTimeInterval(86_400 * 3)).offersPro)
        #expect(!AccessStatus(plan: .tester).offersPro && !AccessStatus(plan: .pro, expiresAt: Date()).offersPro)
    }
}
