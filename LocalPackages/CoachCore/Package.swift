// swift-tools-version: 6.2
import PackageDescription

// What Coach counts, for Orttaai on the Mac and Orttakey on iPhone and iPad,
// so both apps measure a dictation the same way. Foundation only: no UI, no
// storage, no models. The rules started in Orttakey's App/Coach/CoachStats
// and are pinned here by tests.
let package = Package(
    name: "CoachCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CoachCore", targets: ["CoachCore"]),
    ],
    targets: [
        .target(name: "CoachCore"),
        .testTarget(name: "CoachCoreTests", dependencies: ["CoachCore"]),
    ]
)
