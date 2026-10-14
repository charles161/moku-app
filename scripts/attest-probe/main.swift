// The App Attest probe (scripts/check-attest.sh): what Moku does at install, with nothing else. It asks Apple to attest
// a fresh key over SHA-256("<challenge>:<device>"), exactly as RelayAccess does, and writes what the relay would be sent
// to the file named by argument 3. It has no window and keeps nothing; the key is made for this run and thrown away.
import CryptoKit
import DeviceCheck
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 else { print("usage: probe <challenge> <device> <out.json>"); exit(64) }
let challenge = arguments[1], device = arguments[2], out = URL(fileURLWithPath: arguments[3])

let service = DCAppAttestService.shared
print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("isSupported: \(service.isSupported)")
guard service.isSupported else {
    print("This build can't use App Attest: no entitlement and profile, or a macOS before 27.")
    exit(2)
}
do {
    let keyId = try await service.generateKey()
    print("generateKey: ok")
    let hash = Data(SHA256.hash(data: Data("\(challenge):\(device)".utf8)))
    let object = try await service.attestKey(keyId, clientDataHash: hash)
    print("attestKey: ok (\(object.count) bytes)")
    let sample: [String: Any] = [
        "keyId": keyId, "object": object.base64EncodedString(), "challenge": challenge, "device": device,
        "capturedAt": Int(Date().timeIntervalSince1970 * 1000), "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
    ]
    try JSONSerialization.data(withJSONObject: sample, options: [.prettyPrinted, .sortedKeys]).write(to: out)
    print("wrote \(out.path)")
} catch {
    let e = error as NSError
    print("FAILED: \(e.domain) \(e.code)")
    exit(1)
}
