// swift-tools-version: 6.0
import PackageDescription

// Moku's mind: the behavior engine (what Moku does about what the user is doing), world growth rules,
// the brain client and the runtime that wires senses, brain, character and world together.
let package = Package(
    name: "MokuMind",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MokuMind", targets: ["MokuMind"]),
        .executable(name: "mokumind-sim", targets: ["mokumind-sim"]),
    ],
    dependencies: [.package(path: "../MokuKit")],
    targets: [
        .target(name: "MokuMind", dependencies: ["MokuKit"]),
        // The scripted day shared by the simulator and the day-scenario tests. Not shipped in the app.
        .target(name: "MokuMindReplay", dependencies: ["MokuMind", "MokuKit"]),
        .executableTarget(name: "mokumind-sim", dependencies: ["MokuMindReplay"]),
        // Launch QA, lens 2: realistic sessions (a writer, a designer, a coder, a student, calls, dictation, drifts) played
        // through the real engine and a real brain over HTTP, on simulated time. Not shipped in the app.
        .executableTarget(name: "mokumind-qa", dependencies: ["MokuMind", "MokuKit"]),
        .testTarget(name: "MokuMindTests", dependencies: ["MokuMind", "MokuMindReplay", "MokuKit"]),
    ]
)
