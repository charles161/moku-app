import Foundation
import Testing
@testable import MokuMind

@Suite("Brain token")
struct BrainTokenTests {
    func home() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("moku-token-\(UUID().uuidString)/.moku") }
    func mode(_ url: URL) -> Int? { (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int }

    @Test func madeOnceOwnerOnlyAndKeptAcrossLaunches() throws {
        let dir = home(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let first = try #require(BrainToken.loadOrCreate(home: dir))
        #expect(first.count == 64 && first.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(mode(dir.appendingPathComponent("brain-token")) == 0o600)
        #expect(mode(dir) == 0o700)
        #expect(BrainToken.loadOrCreate(home: dir) == first)
        // No temporary files left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["brain-token"])
    }

    @Test func usesTheBrainsTokenWhenItMadeOneFirstAndReplacesADamagedOne() throws {
        let dir = home(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("brain-token")
        let brains = String(repeating: "0f", count: 32)
        try (brains + "\n").write(to: file, atomically: true, encoding: .utf8)
        #expect(BrainToken.loadOrCreate(home: dir) == brains)
        try "short\n".write(to: file, atomically: true, encoding: .utf8)
        let fixed = try #require(BrainToken.loadOrCreate(home: dir))
        #expect(fixed != brains && fixed.count == 64 && BrainToken.read(file) == fixed)
    }

    @Test func tightensAnExistingOpenFolder() throws {
        let dir = home(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        _ = BrainToken.loadOrCreate(home: dir)
        #expect(mode(dir) == 0o700)
    }
}
