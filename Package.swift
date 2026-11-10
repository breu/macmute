// swift-tools-version:5.9
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
    ]
)
