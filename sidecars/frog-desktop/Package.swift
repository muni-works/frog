// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "frog-desktop",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "frog-desktop", path: "Sources/frog-desktop"),
    ]
)
