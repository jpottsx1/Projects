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
        //
        // `AudioDecoder.decode` lives here, and the waveform is its only
        // runtime caller now that Analyzer/Processor are set aside -- so
        // Debug's -Onone was landing on it too: 5.6s to decode a six-minute
        // file that a raw, optimized AVAudioFile read does in 0.86s, same
        // code path. Same fix as LoudnessLabUI below, same reasoning.
        .target(name: "LoudnessKit", path: "Sources/LoudnessKit",
               swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),

        .executableTarget(name: "LoudnessLabUI",
                          dependencies: ["LoudnessKit"],
                          path: "Sources/LoudnessLabUI",
                          resources: [.copy("Resources/SplashLogo.png")],
                          // Debug's -Onone leaves bounds-checking in the
                          // waveform's sample-by-sample filtering, which is
                          // the difference between 9s and 0.4s over a
                          // six-minute track. Release already optimizes;
                          // this just brings Cmd-R's everyday debug build
                          // in line with it.
                          swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),

        .testTarget(name: "LoudnessKitTests",
                    dependencies: ["LoudnessKit"],
                    path: "Tests/LoudnessKitTests",
                    resources: [.copy("Golden")]),
    ]
)
