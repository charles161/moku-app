import Darwin
import Foundation
import Testing
@testable import MokuMind

@Suite("Brain ports", .serialized)
struct BrainPortsTests {
    @Test func usesTheFirstPortWhenItIsFree() async {
        let choice = await BrainPorts.choose { _ in .free }
        #expect(choice == .start(port: 8020))
    }

    @Test func movesOnWhenSomethingElseHoldsThePort() async {
        // 8020: a developer's server. 8021: a program that answers no one. 8022: free.
        let choice = await BrainPorts.choose { port in port < 8022 ? .taken : .free }
        #expect(choice == .start(port: 8022))
    }

    @Test func adoptsAnOwnBrainBeforeStartingAnother() async {
        let choice = await BrainPorts.choose { port in port == 8020 ? .taken : (port == 8021 ? .ours : .free) }
        #expect(choice == .adopt(port: 8021))
    }

    @Test func replacesALeftBehindBrainOnTheFirstPortItFinds() async {
        let choice = await BrainPorts.choose { port in port == 8020 ? .orphan(pid: 99) : .free }
        #expect(choice == .replace(port: 8020, pid: 99))
    }

    @Test func givesUpOnlyWhenAllTenPortsAreTaken() async {
        var asked: [Int] = []
        let choice = await BrainPorts.choose { port in asked.append(port); return .taken }
        #expect(choice == .none)
        #expect(asked == Array(8020...8029))
    }

    @Test func aPortSomeoneListensOnIsNotFreeAndOneNobodyListensOnIs() async throws {
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let port = 43_000 + Int(UInt16.random(in: 0..<2000))
        server.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1"]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        #expect(BrainPorts.isFree(port))
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        var taken = false
        for _ in 0..<40 {
            if !BrainPorts.isFree(port) { taken = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(taken, "a port with a server on it counts as free")
        #expect(BrainPorts.isFree(port + 5))
    }

    @Test func theClientFollowsToAnotherPort() throws {
        let client = BrainClient(token: "t")
        let request = try client.makeRequest("/v1/config", method: "GET", body: nil as Never?, timeout: 3)
        #expect(request.url?.absoluteString == "http://127.0.0.1:8020/v1/config")
        client.use(port: 8023)
        let moved = try client.makeRequest("/v1/config", method: "GET", body: nil as Never?, timeout: 3)
        #expect(moved.url?.absoluteString == "http://127.0.0.1:8023/v1/config")
        #expect(moved.value(forHTTPHeaderField: "Authorization") == "Bearer t")
    }
}
