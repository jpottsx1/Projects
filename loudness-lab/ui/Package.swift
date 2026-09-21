// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LoudnessLabUI",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "LoudnessLabUI", path: "Sources/LoudnessLabUI")
    ]
)
