// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LoudnessLab",
    platforms: [.macOS(.v14)],
    targets: [
        // The measurement and processing, with no UI in it, so it can be
        // tested against the Python's own numbers without launching anything.
        .target(name: "LoudnessKit", path: "Sources/LoudnessKit"),

        .executableTarget(name: "LoudnessLabUI",
                          dependencies: ["LoudnessKit"],
                          path: "Sources/LoudnessLabUI"),

        .testTarget(name: "LoudnessKitTests",
                    dependencies: ["LoudnessKit"],
                    path: "Tests/LoudnessKitTests",
                    resources: [.copy("Golden")]),
    ]
)
