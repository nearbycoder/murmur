// swift-tools-version: 6.0
// MurmurKit: the BitTorrent engine behind Murmur, written in Swift with no dependencies.
import PackageDescription

let package = Package(
    name: "MurmurKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MurmurKit", targets: ["MurmurKit"]),
        .executable(name: "murmur-cli", targets: ["murmur-cli"]),
    ],
    targets: [
        .target(name: "MurmurKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "murmur-cli", dependencies: ["MurmurKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MurmurKitTests", dependencies: ["MurmurKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
