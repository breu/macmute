// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BruteApp",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "BruteApp",
            path: "Sources/BruteApp"
        ),
        .testTarget(
            name: "BruteAppTests",
            dependencies: ["BruteApp"]
        )
    ],
    swiftLanguageModes: [.v6]
)
