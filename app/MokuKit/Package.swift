// swift-tools-version: 6.0
import PackageDescription

// The shared contract between Moku's lanes: sensors, brain client, behavior engine and visuals.
// Only the integrator edits this package; lanes request changes in lanes/<lane>.md.
let package = Package(
    name: "MokuKit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MokuKit", targets: ["MokuKit"])],
    targets: [
        .target(name: "MokuKit"),
        .testTarget(name: "MokuKitTests", dependencies: ["MokuKit"]),
    ]
)
