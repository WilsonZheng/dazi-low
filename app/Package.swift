// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Kaikou",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Kaikou",
            path: "Sources/Kaikou",
            swiftSettings: [.unsafeFlags(["-O"])]
        ),
        .testTarget(
            name: "KaikouTests",
            dependencies: ["Kaikou"],
            path: "Tests/KaikouTests"
        ),
    ]
)
