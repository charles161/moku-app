import Darwin
import Foundation
import Testing
@testable import MokuMind

@Suite("Brain adoption")
struct BrainAdoptionTests {
    typealias Listener = BrainAdoption.Listener
    let orphan = Listener(pid: 4242, parent: 1, owner: getuid(), name: "moku-brain")
    let developers = Listener(pid: 4343, parent: 900, owner: getuid(), name: "moku-brain")

    @Test func startsItsOwnBrainWhenNothingAnswers() {
        #expect(BrainAdoption.decide(answersHealth: false, acceptsToken: false, listener: nil) == .start)
    }

    @Test func stopsABrainAnOldAppLeftBehindAndStartsItsOwn() {
        // 0.1.7's brain never noticed its app crashing; it answers without checking any token, and is older code.
        #expect(BrainAdoption.decide(answersHealth: true, acceptsToken: true, listener: orphan) == .replace(pid: 4242))
        #expect(BrainAdoption.decide(answersHealth: true, acceptsToken: false, listener: orphan) == .replace(pid: 4242))
    }

    @Test func leavesADevelopersBrainAloneWhenItTakesTheToken() {
        #expect(BrainAdoption.decide(answersHealth: true, acceptsToken: true, listener: developers) == .adopt)
        #expect(BrainAdoption.decide(answersHealth: true, acceptsToken: true, listener: nil) == .adopt)
    }

    @Test func standsOffFromWhatAnswersWithoutMokusToken() {
        #expect(BrainAdoption.decide(answersHealth: true, acceptsToken: false, listener: developers) == .standOff)
        let otherUser = Listener(pid: 5, parent: 1, owner: getuid() &+ 1, name: "moku-brain")
        #expect(BrainAdoption.decide(answersHealth: true, acceptsToken: false, listener: otherUser) == .standOff)
        let otherProgram = Listener(pid: 6, parent: 1, owner: getuid(), name: "python3")
        #expect(BrainAdoption.decide(answersHealth: true, acceptsToken: false, listener: otherProgram) == .standOff)
    }

    @Test func readsWhoHoldsAPortAndWhoseChildItIs() async throws {
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let port = 41_000 + Int(UInt16.random(in: 0..<2000))
        server.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1"]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        var found: Listener?
        for _ in 0..<40 {
            found = await BrainAdoption.listener(onPort: port)
            if found != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let listener = try #require(found)
        #expect(listener.pid == server.processIdentifier)
        #expect(listener.parent == getpid())
        #expect(listener.owner == getuid())
        #expect(!listener.isOrphanedMokuBrain)
    }

    @Test func nobodyHoldsAFreePort() async {
        #expect(await BrainAdoption.listener(onPort: 41_999) == nil)
    }

    @Test func aProcessWhoseParentExitedHasLaunchdForAParent() async throws {
        let shell = Process(), out = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"]
        shell.standardOutput = out
        try shell.run(); shell.waitUntilExit()
        let pid = try #require(Int32(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGKILL) }
        var info: Listener?
        for _ in 0..<20 {
            info = BrainAdoption.process(pid)
            if info?.parent == 1 && info?.name == "sleep" { break }  // not before the shell has become sleep
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(info?.parent == 1 && info?.name == "sleep")
    }
}
