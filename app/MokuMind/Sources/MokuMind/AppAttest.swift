import DeviceCheck
import Foundation

/// Apple App Attest as the install flow needs it (docs/specs/app-attest.md): this Mac makes a key in its Secure Enclave
/// and Apple signs a statement that the key is real and that Moku, signed by our team, asked for it. The relay checks
/// the statement before it hands out a trial, so only a genuine Moku on a genuine Mac can get one.
///
/// Behind a protocol so tests can stand in for Apple. Nothing here leaves the Mac except what `RelayAccess.install`
/// sends: the key's id and Apple's statement, which hold no name, no file and nothing about the screen.
public protocol AppAttesting: Sendable {
    /// Whether this Mac and this build can attest at all: macOS 27 or later, and a Moku signed with the App Attest
    /// entitlement and its provisioning profile. When not, the install goes on without a statement.
    var isSupported: Bool { get }
    /// A fresh key, attested over `clientDataHash` (SHA-256 of what the relay asked to be signed). A key can be attested
    /// once, so every call makes its own; nothing is kept. Throws when Apple or the Mac refuses.
    func attest(clientDataHash: Data) async throws -> (keyId: String, object: Data)
}

/// The real thing: `DCAppAttestService`.
public struct AppleAppAttest: AppAttesting {
    public init() {}
    public var isSupported: Bool { DCAppAttestService.shared.isSupported }
    public func attest(clientDataHash: Data) async throws -> (keyId: String, object: Data) {
        let service = DCAppAttestService.shared
        let keyId = try await service.generateKey()
        return (keyId, try await service.attestKey(keyId, clientDataHash: clientDataHash))
    }
}
