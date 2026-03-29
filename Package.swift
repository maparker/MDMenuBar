// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MDMenuBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MDMenuBar",
            path: "Sources/MDMenuBar"
        )
    ]
)
