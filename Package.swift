// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ClaudeSessionWarmer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "ClaudeSessionWarmer",
            targets: ["ClaudeSessionWarmer"]
        )
    ],
    targets: [
        .executableTarget(
            name: "ClaudeSessionWarmer",
            path: "Sources/ClaudeSessionWarmer"
        ),
        .testTarget(
            name: "ClaudeSessionWarmerTests",
            dependencies: ["ClaudeSessionWarmer"],
            path: "Tests/ClaudeSessionWarmerTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
