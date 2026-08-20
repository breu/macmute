// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacMuteApp",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "MacMuteApp",
            path: "Sources/MacMuteApp"
        )
    ]
)
