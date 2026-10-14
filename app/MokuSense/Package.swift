// swift-tools-version: 6.0
import PackageDescription

// Moku's senses: what the user is doing on screen, turned into MokuKit `SenseEvent`s.
let package = Package(
    name: "MokuSense",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MokuSense", targets: ["MokuSense"]),
        .executable(name: "moku-sense", targets: ["moku-sense"]),
    ],
    dependencies: [.package(path: "../MokuKit")],
    targets: [
        .target(name: "MokuSense", dependencies: ["MokuKit"]),
        .executableTarget(name: "moku-sense", dependencies: ["MokuSense", "MokuKit"]),
        .testTarget(name: "MokuSenseTests", dependencies: ["MokuSense", "MokuKit"]),
    ]
)
