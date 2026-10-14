// swift-tools-version: 6.0
import PackageDescription

// The Moku app shell: wires the lanes together. Build a signed Moku.app with scripts/build-app.sh.
let package = Package(
    name: "Moku",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../MokuKit"),
        .package(path: "../MokuSense"),
        .package(path: "../MokuMind"),
        .package(path: "../MokuVisual"),
        // Auto-update: Sparkle 2 (EdDSA-signed appcast; scripts/release.sh).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(name: "Moku", dependencies: [
            .product(name: "MokuKit", package: "MokuKit"),
            .product(name: "MokuSense", package: "MokuSense"),
            .product(name: "MokuMind", package: "MokuMind"),
            .product(name: "MokuVisual", package: "MokuVisual"),
            .product(name: "Sparkle", package: "Sparkle"),
        ]),
    ]
)
