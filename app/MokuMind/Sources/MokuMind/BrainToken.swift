import Foundation
import MokuKit
import Security

/// The secret Moku and its brain share, so nothing else on this Mac can talk to the brain on 127.0.0.1:8020: not a
/// web page (the brain refuses those anyway), and not another macOS user or a sandboxed app, which could otherwise read
/// Your day, change settings or delete everything. It lives in ~/.moku/brain-token (owner-only); the brain reads the same
/// file (brain-go env.go, LoadBrainToken), and whichever of the two starts first makes it.
public enum BrainToken {
    /// The token in `home`/brain-token, made if there's none (or it's damaged). Also makes `home` owner-only: it holds
    /// screen text, the relay token and this one. Nil only if `home` can't be written.
    public static func loadOrCreate(home: URL) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        } catch { return nil }
        let file = home.appendingPathComponent("brain-token")
        if let existing = read(file) { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let temporary = home.appendingPathComponent(".brain-token-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: Data((token + "\n").utf8), attributes: [.posixPermissions: 0o600]) else {
            ErrorReports.report(.writeFailed, domain: "posix", code: Int(errno))
            return nil
        }
        // A link never replaces a file: if the brain got there first, its token is the one.
        if (try? fm.linkItem(at: temporary, to: file)) != nil { return token }
        if let existing = read(file) { return existing }
        guard (try? fm.replaceItemAt(file, withItemAt: temporary)) != nil else { return nil }
        return token
    }

    static func read(_ file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.count == 64 && token.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }) ? token : nil
    }
}
