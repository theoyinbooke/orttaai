// swift-tools-version: 6.2
import PackageDescription

// One iCloud archive for Orttaai on the Mac and Orttakey on iPhone and iPad.
// The core holds every sync decision and has no CloudKit in it, so the
// tests can run it against a simulated iCloud; the CloudKit target maps it
// onto CKSyncEngine. The contract both apps follow is
// orttakey/.claude/handoff/plans/icloud-sync-agreed.md.
let package = Package(
    name: "OrttaaiSync",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "OrttaaiSyncCore", targets: ["OrttaaiSyncCore"]),
        .library(name: "OrttaaiSyncCloudKit", targets: ["OrttaaiSyncCloudKit"]),
    ],
    targets: [
        .target(name: "OrttaaiSyncCore"),
        .target(name: "OrttaaiSyncCloudKit", dependencies: ["OrttaaiSyncCore"]),
        .testTarget(name: "OrttaaiSyncCoreTests", dependencies: ["OrttaaiSyncCore"]),
        .testTarget(name: "OrttaaiSyncCloudKitTests", dependencies: ["OrttaaiSyncCloudKit"]),
    ]
)
