// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "kiln-desktop",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "kiln-desktop", path: "Sources/kiln-desktop"),
    ]
)
