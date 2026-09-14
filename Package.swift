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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "ClaudeSessionWarmer",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/ClaudeSessionWarmer",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "ClaudeSessionWarmerTests",
            dependencies: ["ClaudeSessionWarmer"],
            path: "Tests/ClaudeSessionWarmerTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
