// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "kiln-apple",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "kiln-apple", path: "Sources/kiln-apple"),
    ]
)
