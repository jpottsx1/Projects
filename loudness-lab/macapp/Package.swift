// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LoudnessLab",
    platforms: [.macOS(.v14)],
    // Declared explicitly. Without products Xcode generates a scheme for the
    // executable alone, and a scheme with no test target in it greys out the
    // Test menu -- which is exactly the command that matters most here.
    products: [
        .library(name: "LoudnessKit", targets: ["LoudnessKit"]),
        .executable(name: "LoudnessLabUI", targets: ["LoudnessLabUI"]),
    ],
    targets: [
        // The measurement and processing, with no UI in it, so it can be
        // tested against the Python's own numbers without launching anything.
        .target(name: "LoudnessKit", path: "Sources/LoudnessKit"),

        .executableTarget(name: "LoudnessLabUI",
                          dependencies: ["LoudnessKit"],
                          path: "Sources/LoudnessLabUI",
                          resources: [.copy("Resources/SplashLogo.jpg")]),

        .testTarget(name: "LoudnessKitTests",
                    dependencies: ["LoudnessKit"],
                    path: "Tests/LoudnessKitTests",
                    resources: [.copy("Golden")]),
    ]
)
