// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fluidbench",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", branch: "main")
    ],
    targets: [
        .executableTarget(name: "fluidbench", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")])
    ]
)
