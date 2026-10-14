import Foundation
import Testing
@testable import MokuKit

/// macOS flagged Moku 0.1.11 for 2.1 GB of disk writes in 18 hours (2026-10-10, over its limit of about 2 GB a day):
/// `URLSession.shared` saved every answer from the brain on 127.0.0.1 (`/v1/world`, every few seconds) in
/// ~/Library/Caches/ai.lightslips.moku/Cache.db, and kept the relay's install answer, token and all, in plain text.
@Suite struct MokuNetworkTests {
    @Test func mokusCallsKeepNothing() {
        let configuration = MokuNetwork.session.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.httpCookieStorage == nil || configuration.httpCookieStorage !== HTTPCookieStorage.shared)
    }

    /// Every call goes through `MokuNetwork.session`: a new `URLSession.shared` would bring the cache back.
    @Test func noSourceUsesTheSharedSession() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()  // …/app
        var offenders: [String] = []
        for package in ["Moku", "MokuKit", "MokuMind", "MokuSense", "MokuVisual"] {
            let sources = app.appendingPathComponent(package).appendingPathComponent("Sources")
            guard let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in files where file.pathExtension == "swift" && !file.path.contains("/mokumind-qa/") {
                let text = try String(contentsOf: file, encoding: .utf8)
                for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                    && (line.contains("URLSession.shared") || line.contains("session: URLSession = .shared")) {
                    offenders.append("\(package)/\(file.lastPathComponent):\(number + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "use MokuNetwork.session: \(offenders.joined(separator: ", "))")
    }
}
