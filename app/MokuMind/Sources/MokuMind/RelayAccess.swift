import CryptoKit
import Foundation
import IOKit
import MokuKit

/// This Mac's access to Moku's cloud brain through the relay (proxy/): on first launch a Mac with no model access
/// quietly gets a 21-day trial; an invite code (typed in Settings or opened as moku://invite/CODE) makes it a
/// tester. The relay's token goes into $MOKU_HOME/credentials.env, which the brain reads on every call, so it
/// takes effect at once. The relay only ever sees a hash of the Mac's hardware id.
@MainActor
public final class RelayAccess {
    public typealias Post = @Sendable (_ url: URL, _ body: Data) async throws -> (Data, Int)
    /// A request with this Mac's token (renew, checkout).
    public typealias AuthorizedPost = @Sendable (_ url: URL, _ body: Data, _ token: String) async throws -> (Data, Int)

    public enum AccessError: Error, Equatable, CustomStringConvertible {
        case unknownInvite, inviteFull, unverified, unreachable, refused(Int)
        public var description: String {
            switch self {
            case .unknownInvite: "That invite code didn’t work. Check it and try again?"
            case .inviteFull: "That invite is already in use on other Macs. Ask for one of your own?"
            case .unverified: "Moku couldn’t confirm this Mac to start a trial. An invite code from Charles will get you in."
            case .unreachable: "Couldn’t reach Moku’s servers. Check your connection and try again?"
            case let .refused(code): "Moku’s servers said no (\(code)). Try again in a little while?"
            }
        }
    }

    public static let defaultRelay = URL(string: "https://moku-proxy.vercel.app")!
    private let home: URL
    private let relay: URL
    private let post: Post
    private let authorizedPost: AuthorizedPost
    private let device: String
    private let attester: any AppAttesting
    /// The relay refused this Mac a trial because it couldn't confirm it: asking again can't change that, so the hourly
    /// retries stop until the next launch (each one would use up the network's 20 installs a day for everyone on it).
    private var refusedAsUnverified = false

    public init(home: URL, relay: URL = RelayAccess.defaultRelay, device: String = RelayAccess.deviceHash(),
                attester: any AppAttesting = AppleAppAttest(), post: Post? = nil, authorizedPost: AuthorizedPost? = nil) {
        self.home = home; self.relay = relay; self.device = device; self.attester = attester
        self.authorizedPost = authorizedPost ?? { url, body, token in
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization"); request.httpBody = body
            let (data, response) = try await MokuNetwork.session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        self.post = post ?? { url, body in
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "content-type"); request.httpBody = body
            let (data, response) = try await MokuNetwork.session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// SHA-256 of the Mac's hardware id (IOPlatformUUID), salted for Moku: the same across reinstalls, useless elsewhere.
    public nonisolated static func deviceHash() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let uuid = (IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String) ?? "unknown-\(ProcessInfo.processInfo.hostName)"
        return SHA256.hash(data: Data("moku-device:\(uuid)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private var credentials: URL { home.appendingPathComponent("credentials.env") }

    /// What this Mac has now: the relay token's plan, or the developer's own key, or nothing.
    /// `brainModels` is the brain's /health "models" ("key", "proxy" or "none"), when known.
    public func status(brainModels: String? = nil) -> AccessStatus {
        let values = Self.parse((try? String(contentsOf: credentials, encoding: .utf8)) ?? "")
        if let token = values["MOKU_ACCESS_TOKEN"], !token.isEmpty {
            guard let claims = Self.claims(of: token) else { return AccessStatus(plan: .tester) }  // a tester's static token
            let plan = AccessStatus.Plan(rawValue: claims.plan) ?? .tester
            return AccessStatus(plan: plan, expiresAt: plan == .trial || plan == .pro ? Date(timeIntervalSince1970: claims.exp / 1000) : nil)
        }
        if values["JEV_VERCEL"] != nil || brainModels == "key" { return AccessStatus(plan: .ownKey) }
        return AccessStatus(plan: .none)
    }

    /// The relay token in credentials.env (a trial's or a tester's), or nil when this Mac has none. Usage events carry it
    /// so the relay can say which plan and friend they came from.
    public func currentToken() -> String? {
        guard let token = Self.parse((try? String(contentsOf: credentials, encoding: .utf8)) ?? "")["MOKU_ACCESS_TOKEN"], !token.isEmpty else { return nil }
        return token
    }

    /// First launch: a Mac the brain says has no model access gets its trial. Quietly; a failure is tried next launch
    /// (and hourly meanwhile, except a Mac the relay couldn't verify: that waits for the next launch).
    @discardableResult public func ensureTrial(brainModels: String?) async -> AccessStatus? {
        guard brainModels == "none", !refusedAsUnverified, status(brainModels: brainModels).plan == .none else { return nil }
        do { return try await install(invite: nil) }
        catch AccessError.unverified { refusedAsUnverified = true; return nil }
        catch { return nil }
    }

    /// Asks the relay for this Mac's token (a trial, or a tester with `invite`) and saves it for the brain.
    @discardableResult public func install(invite: String?) async throws -> AccessStatus {
        var body: [String: Any] = ["device": device]
        if let invite, !invite.trimmingCharacters(in: .whitespaces).isEmpty { body["invite"] = invite.trimmingCharacters(in: .whitespaces) }
        // A trial asks Apple to vouch for this Mac (an invite is a friend the relay already knows).
        else if let attestation = await attestation() { body["attestation"] = attestation }
        let data: Data, code: Int
        do { (data, code) = try await post(relay.appendingPathComponent("v1/install"), try JSONSerialization.data(withJSONObject: body)) }
        catch { throw AccessError.unreachable }
        // The relay says which: a code it doesn't know, or one already used on as many Macs as it allows.
        if code == 403 {
            switch (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String {
            case "invite_full": throw AccessError.inviteFull
            case "attestation_required": throw AccessError.unverified
            default: throw AccessError.unknownInvite
            }
        }
        guard code == 200, let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let token = answer["token"] as? String else {
            if code == 200 { ErrorReports.report(.relayDecode, domain: "http", code: code) }
            throw AccessError.refused(code)
        }
        do { try save(token: token) } catch { ErrorReports.report(.writeFailed, error); throw error }
        return status()
    }

    /// A fresh token from the relay for this Mac's (POST /v1/renew): a Pro one once a payment has landed, a tester's with
    /// another month, a trial's as it was. Saved for the brain when it changed. Nil when there's no install token, or the
    /// relay said no or couldn't be reached: the token this Mac has stays.
    @discardableResult public func renew() async -> AccessStatus? {
        guard let token = currentToken(), token.hasPrefix("moku1."),
              let (data, code) = try? await authorizedPost(relay.appendingPathComponent("v1/renew"), Data("{}".utf8), token), code == 200,
              let fresh = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["token"] as? String, fresh.hasPrefix("moku1.") else { return nil }
        if fresh != token {
            do { try save(token: fresh) } catch { ErrorReports.report(.writeFailed, error); return nil }
        }
        return status()
    }

    /// Dodo's hosted checkout for Moku Pro (`monthly` or `yearly`), made by the relay with this Mac in it: the page to open
    /// in the browser. Only an https page is ever returned.
    public func checkout(plan: String) async throws -> URL {
        guard let token = currentToken(), token.hasPrefix("moku1.") else { throw AccessError.refused(401) }
        let body = try JSONSerialization.data(withJSONObject: ["plan": plan == "yearly" ? "yearly" : "monthly"])
        let data: Data, code: Int
        do { (data, code) = try await authorizedPost(relay.appendingPathComponent("v1/checkout"), body, token) }
        catch { throw AccessError.unreachable }
        guard code == 200, let page = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["url"] as? String,
              let url = URL(string: page), url.scheme == "https" else { throw AccessError.refused(code) }
        return url
    }

    /// Apple's statement for this install, or nil: the relay didn't ask (its `attestation` switch is off), this Mac or build
    /// can't attest, or something failed on the way. Never throws and never stops the install: the relay decides what a
    /// missing statement costs. A failure after the Mac said it could attest is reported (`attest_failed`), so a build
    /// whose profile is wrong shows in PostHog before it shows as lost trials.
    private func attestation() async -> [String: String]? {
        guard attester.isSupported,
              let (data, code) = try? await post(relay.appendingPathComponent("v1/attest/challenge"), Data("{}".utf8)), code == 200,
              let challenge = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["challenge"] as? String else { return nil }
        // What the relay checks: this challenge, for this Mac. A genuine Moku can only vouch for its own.
        let hash = Data(SHA256.hash(data: Data("\(challenge):\(device)".utf8)))
        do {
            let made = try await attester.attest(clientDataHash: hash)
            return ["keyId": made.keyId, "object": made.object.base64EncodedString(), "challenge": challenge]
        } catch {
            ErrorReports.report(.attestFailed, error)
            return nil
        }
    }

    /// Writes the relay's address and the token into credentials.env (owner-only), keeping any other lines.
    private func save(token: String) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let kept = ((try? String(contentsOf: credentials, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("MOKU_GATEWAY_URL=") && !$0.hasPrefix("MOKU_ACCESS_TOKEN=") }.joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
        let lines = [kept, "MOKU_GATEWAY_URL=\(relay.appendingPathComponent("v4/ai").absoluteString)", "MOKU_ACCESS_TOKEN=\(token)"].filter { !$0.isEmpty }
        try (lines.joined(separator: "\n") + "\n").write(to: credentials, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentials.path)
    }

    /// KEY=VALUE lines.
    nonisolated static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        }
        return values
    }

    /// The claims in a relay token (moku1.<payload>.<sig>); the signature is the relay's to check, not ours.
    nonisolated static func claims(of token: String) -> (plan: String, exp: Double)? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, parts[0] == "moku1" else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plan = object["plan"] as? String else { return nil }
        return (plan, (object["exp"] as? Double) ?? 0)
    }
}
