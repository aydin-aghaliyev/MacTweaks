// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacTweaks",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacTweaks",
            path: "Sources/MacTweaks",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        )
    ]
)
