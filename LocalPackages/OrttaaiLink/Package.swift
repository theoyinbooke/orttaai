// swift-tools-version: 6.0
import PackageDescription

// Orttaai Link: Orttaai on the Mac serving the devices that sync through it
// (Orttaai for Windows and Linux, Orttakey for Android) over HTTPS, on Wi-Fi
// and Tailscale. The contract is docs/orttaai-link-protocol.md. Built on the
// same pieces as My Local AI Link (mylokai/Link).
let package = Package(
    name: "OrttaaiLink",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OrttaaiLink", targets: ["OrttaaiLink"]),
    ],
    dependencies: [
        .package(path: "../OrttaaiSync"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.5.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
    ],
    targets: [
        .target(
            name: "OrttaaiLink",
            dependencies: [
                .product(name: "OrttaaiSyncCore", package: "OrttaaiSync"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTLS", package: "hummingbird"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .testTarget(
            name: "OrttaaiLinkTests",
            dependencies: [
                "OrttaaiLink",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
