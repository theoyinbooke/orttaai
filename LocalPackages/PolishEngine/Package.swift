// swift-tools-version: 6.2
import PackageDescription

// S1-mini by Superwhisper as Orttaai's Polish, in-process with llama.cpp, the
// same model Orttakey runs on the iPhone. No server to keep running.
let package = Package(
    name: "PolishEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PolishEngine", targets: ["PolishEngine"]),
    ],
    targets: [
        // llama.cpp b11552 (MIT), unmodified, built with its own script for
        // macOS, iOS and the iOS Simulator; pinned to the public release and
        // its checksum (theoyinbooke/llama-xcframework says how it was built).
        .binaryTarget(
            name: "llama",
            url: "https://github.com/theoyinbooke/llama-xcframework/releases/download/b11552/llama-b11552-xcframework.zip",
            checksum: "9e969e402a5f11d8174861e40dcaf3b7760abb1aaed4c2d654bfc55de4d81522"
        ),
        .target(name: "PolishEngine", dependencies: ["llama"]),
        .testTarget(name: "PolishEngineTests", dependencies: ["PolishEngine"]),
    ]
)
