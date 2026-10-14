import Foundation
import MokuKit
import MokuMind

// Launch QA, lens 2: realistic sessions through the real engine and a real brain, on simulated time.
//
//   swift run mokumind-qa --brain http://127.0.0.1:18731 --home <the QA brain's home> --catalog <screens.json> --out <dir> [--sessions writer,coder] [--commands <file>]
//
// The brain is the QA brain (brain-go/internal/brain/qa_serve_test.go): the real brain with a Jev that replays the answers
// the real Jev gave. scripts/qa-behaviour.sh starts it, runs this and stops it.

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

@MainActor
func run() async {
    guard let catalogPath = argument("--catalog"), let homePath = argument("--home") else {
        print("usage: mokumind-qa --brain URL --home DIR --catalog screens.json --out DIR [--sessions a,b] [--list]")
        exit(2)
    }
    if CommandLine.arguments.contains("--list") {
        for session in Personas.all { print("\(session.name): \(session.summary)") }
        return
    }
    let brainURL = URL(string: argument("--brain") ?? "http://127.0.0.1:18731")!
    let port = brainURL.port ?? 18731
    let control = URL(string: "http://127.0.0.1:\(port + 1)/")!
    let out = URL(fileURLWithPath: argument("--out") ?? "qa-out")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    guard let token = BrainToken.loadOrCreate(home: URL(fileURLWithPath: homePath)) else {
        print("no brain token in \(homePath)")
        exit(1)
    }
    let catalog: [String: QAScreen]
    do { catalog = try Catalog.load(catalogPath) } catch {
        print("catalog: \(error)")
        exit(1)
    }
    let client = BrainClient(baseURL: brainURL, token: token)
    let served: CompanionConfig
    do { served = try await client.config() } catch {
        print("the brain isn't answering: \(error)")
        exit(1)
    }
    do {
        let a = (try? JSONSerialization.jsonObject(with: MokuJSON.encoder().encode(served))) as? [String: Any] ?? [:]
        let b = (try? JSONSerialization.jsonObject(with: MokuJSON.encoder().encode(CompanionConfig.standard))) as? [String: Any] ?? [:]
        let differing = Set(a.keys).union(b.keys).subtracting(["companion"]).filter { "\(a[$0] ?? "-")" != "\(b[$0] ?? "-")" }.sorted()
        if !differing.isEmpty { print("!! the brain's served config differs from CompanionConfig.standard: " + differing.map { "\($0) brain=\(a[$0] ?? "-") app=\(b[$0] ?? "-")" }.joined(separator: ", ")) }
    }
    let driver = Driver(brain: client, control: control, catalog: catalog, config: served)
    if let tracePath = argument("--trace") {
        FileManager.default.createFile(atPath: tracePath, contents: nil)
        driver.trace = FileHandle(forWritingAtPath: tracePath)
    }
    let names = (argument("--sessions") ?? "").split(separator: ",").map(String.init)
    for session in Personas.named(names) {
        let began = Date()
        do {
            let report = try await driver.play(session)
            if let path = argument("--commands") { try driver.exportCommands(to: URL(fileURLWithPath: path)) }  // the last session's stage commands (the visual demo's --soak plays them)
            let data = try JSONEncoder().encode(report)
            try data.write(to: out.appendingPathComponent("\(session.name).json"))
            print(Summary.text(report))
            print(String(format: "   (%.1f s of wall time)\n", Date().timeIntervalSince(began)))
        } catch {
            print("== \(session.name): failed: \(error)")
        }
    }
}

await run()
