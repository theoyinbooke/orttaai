// ExpressModelStoreTests.swift
// OrttaaiTests

import CryptoKit
import XCTest
@testable import Orttaai

final class ExpressModelStoreTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDownWithError() throws {
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        directories = []
    }

    private func makeDirectory() throws -> URL {
        let directory = try ModelProbeTestSupport.makeTemporaryDirectory()
        directories.append(directory)
        return directory
    }

    /// A small stand-in repository: real files with real checksums.
    private func makeSource(_ contents: [String: String]) throws -> (source: URL, files: [ExpressModelStore.File]) {
        let source = try makeDirectory()
        var files: [ExpressModelStore.File] = []
        for (path, text) in contents.sorted(by: { $0.key < $1.key }) {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(text.utf8)
            try data.write(to: url)
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let localPath = path.replacingOccurrences(of: "JointDecision.mlmodelc/", with: "JointDecisionv3.mlmodelc/")
            files.append(.init(remotePath: path, localPath: localPath, size: Int64(data.count), sha256: sha))
        }
        return (source, files)
    }

    func testManifestCoversEveryComponentFluidAudioLoads() {
        let localPaths = Set(ExpressModelStore.files.map(\.localPath))
        for component in ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"] {
            XCTAssertTrue(
                localPaths.contains("\(component).mlmodelc/weights/weight.bin"),
                "\(component) weights missing from the manifest"
            )
        }
        XCTAssertTrue(localPaths.contains("parakeet_vocab.json"))
        XCTAssertFalse(localPaths.contains { $0.hasPrefix("JointDecision.mlmodelc/") })
        XCTAssertEqual(ExpressModelStore.files.count, localPaths.count, "duplicate paths")
        XCTAssertEqual(ExpressModelStore.totalBytes, 252_730_493)
        XCTAssertEqual(ExpressModelStore.revision.count, 40, "pinned to a full commit hash")
    }

    func testFolderSitsBesideWhisperModelsInTheStorageBase() {
        let base = URL(fileURLWithPath: "/Volumes/Models", isDirectory: true)
        XCTAssertEqual(
            ExpressModelStore.folder(in: base).path,
            "/Volumes/Models/models/FluidVoice-Labs/fluid-speech-mini-coreml"
        )
    }

    func testInstallVerifiesAndMovesThePackageIntoPlace() async throws {
        let (source, files) = try makeSource([
            "Encoder.mlmodelc/weights/weight.bin": "encoder",
            "JointDecision.mlmodelc/weights/weight.bin": "joint",
            "parakeet_vocab.json": "{}",
        ])
        let base = try makeDirectory()
        XCTAssertFalse(ExpressModelStore.isInstalled(in: base, files: files))

        let progressValues = ProgressRecorder()
        try await ExpressModelStore.install(
            into: base,
            files: files,
            sourceBase: source,
            progress: { progressValues.record($0) }
        )

        XCTAssertTrue(ExpressModelStore.isInstalled(in: base, files: files))
        let folder = ExpressModelStore.folder(in: base)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("JointDecisionv3.mlmodelc/weights/weight.bin").path
        ))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["fluid-speech-mini-coreml"], "no staging folder may remain")
        XCTAssertEqual(progressValues.last, 1)
    }

    func testChecksumMismatchInstallsNothing() async throws {
        var (source, files) = try makeSource(["Encoder.mlmodelc/weights/weight.bin": "encoder"])
        files[0] = .init(
            remotePath: files[0].remotePath,
            localPath: files[0].localPath,
            size: files[0].size,
            sha256: String(repeating: "0", count: 64)
        )
        let base = try makeDirectory()

        do {
            try await ExpressModelStore.install(into: base, files: files, sourceBase: source, progress: { _ in })
            XCTFail("a corrupted file must not install")
        } catch let error as ExpressModelStoreError {
            XCTAssertEqual(error, .verificationFailed(file: "Encoder.mlmodelc/weights/weight.bin"))
        }
        let parent = ExpressModelStore.folder(in: base).deletingLastPathComponent()
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        XCTAssertTrue(contents.isEmpty, "neither the package nor a staging folder may remain: \(contents)")
    }

    func testRemoveDeletesOnlyTheExpressFolder() async throws {
        let base = try makeDirectory()
        let express = ExpressModelStore.folder(in: base)
        let whisper = ModelProbeTestSupport.repositoryRoot(under: base)
        try FileManager.default.createDirectory(at: express, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: whisper, withIntermediateDirectories: true)

        try await ExpressModelStore.remove(from: base)

        XCTAssertFalse(FileManager.default.fileExists(atPath: express.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: whisper.path))
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var last: Double? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }
}
