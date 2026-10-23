// swift-tools-version: 6.2
import PackageDescription

// The app depends on FluidAudio through this package because Xcode project
// package references cannot choose package traits. Express only runs speech
// recognition, so every trait is off. Measured on stripped Release builds of
// the app: all default traits would add about 23 MB, NemoTextProcessing
// (inverse text normalization) alone about 9.9 MB, and speech recognition
// only adds 3.7 MB. Turn NemoTextProcessing back on only if tracker task P3.2
// adopts FluidAudio's number normalizer over hand-written rules.
let package = Package(
    name: "ExpressAudio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ExpressAudio", targets: ["ExpressAudio"]),
    ],
    dependencies: [
        // The revision every gauntlet/asr_eval benchmark ran on.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "c79c4106b954f81205113c3343e5a7e59a1089b5",
            traits: []
        ),
    ],
    targets: [
        .target(
            name: "ExpressAudio",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ]
)
