// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UnearthKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "UnearthCore", targets: ["UnearthCore"]),
        .executable(name: "unearth-scan", targets: ["UnearthScanCLI"]),
    ],
    targets: [
        .target(name: "UnearthCore", resources: [.process("Resources")]),
        .executableTarget(name: "UnearthScanCLI", dependencies: ["UnearthCore"]),
        .testTarget(name: "UnearthCoreTests", dependencies: ["UnearthCore"], resources: [.copy("Fixtures")]),
    ]
)
