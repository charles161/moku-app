import Foundation
import Testing
@testable import MokuMind

@Suite("History logs")
struct HistoryLogsTests {
    func home() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moku-logs-\(UUID().uuidString)/.moku")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func deleteMyDataEmptiesTheLogsAndTheirOlderCopies() throws {
        let dir = try home(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let goal = "working \"Quarterly plan\" [jev, 900 ms] Cursor (drafting the hiring post)\n"
        for name in HistoryLogs.names {
            try String(repeating: goal, count: 50).write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            try goal.write(to: dir.appendingPathComponent(name + ".1"), atomically: true, encoding: .utf8)
        }
        try "keep me".write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        HistoryLogs.forget(in: dir)

        for name in HistoryLogs.names {
            #expect(try Data(contentsOf: dir.appendingPathComponent(name)).isEmpty, "\(name) still holds the history")
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(name + ".1").path), "\(name).1 is still there")
        }
        // Only the logs: settings stay.
        #expect(try String(contentsOf: dir.appendingPathComponent("config.json"), encoding: .utf8) == "keep me")
    }

    @Test func theBrainKeepsWritingToItsEmptiedLog() throws {
        let dir = try home(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let log = dir.appendingPathComponent("brain.log")
        // The brain's stdout: opened for appending, the way BrainSupervisor opens it.
        let descriptor = open(log.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        #expect(descriptor >= 0)
        let brain = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        brain.write(Data(String(repeating: "a goal's title\n", count: 100).utf8))

        HistoryLogs.forget(in: dir)
        brain.write(Data("after\n".utf8))

        // The next line lands at the start: no hole of zeros where the old lines were.
        #expect(try String(contentsOf: log, encoding: .utf8) == "after\n")
    }

    @Test func missingLogsAreFine() throws {
        let dir = try home(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        HistoryLogs.forget(in: dir)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}
