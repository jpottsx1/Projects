// swift-tools-version: 5.9
import PackageDescription

// The parts of Stash with no interface in them -- link parsing, the search
// query syntax, Markdown blocks, web page text -- so they can be tested on
// their own (`swift test`, or open this folder in Xcode and press Cmd-U)
// without launching the app.
let package = Package(
    name: "StashCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "StashCore", targets: ["StashCore"]),
    ],
    targets: [
        .target(name: "StashCore"),
        .testTarget(name: "StashCoreTests", dependencies: ["StashCore"]),
    ]
)
