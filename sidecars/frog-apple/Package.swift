// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "frog-apple",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "frog-apple", path: "Sources/frog-apple"),
    ]
)
