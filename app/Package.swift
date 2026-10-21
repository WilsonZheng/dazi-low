// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DaziLow",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DaziLow",
            path: "Sources/DaziLow",
            swiftSettings: [.unsafeFlags(["-O"])]
        ),
        .testTarget(
            name: "DaziLowTests",
            dependencies: ["DaziLow"],
            path: "Tests/DaziLowTests"
        ),
    ]
)
