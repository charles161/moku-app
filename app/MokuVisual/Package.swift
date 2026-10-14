// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MokuVisual",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MokuVisual", targets: ["MokuVisual"]), .executable(name: "MokuVisualDemo", targets: ["MokuVisualDemo"])],
    dependencies: [.package(path: "../MokuKit"), .package(path: "../MokuMind")],
    targets: [
        .target(name: "MokuVisual", dependencies: [.product(name: "MokuKit", package: "MokuKit")], resources: [.process("Resources")]),
        .executableTarget(name: "MokuVisualDemo", dependencies: ["MokuVisual", .product(name: "MokuKit", package: "MokuKit"), .product(name: "MokuMind", package: "MokuMind")]),
        .testTarget(name: "MokuVisualTests", dependencies: ["MokuVisual", .product(name: "MokuMind", package: "MokuMind")])
    ]
)
