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
    private func makePackage(_ contents: [String: String]) throws -> (source: URL, package: ExpressModelPackage) {
        let source = try makeDirectory()
        var files: [ExpressModelPackage.File] = []
        for (path, text) in contents.sorted(by: { $0.key < $1.key }) {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(text.utf8)
            try data.write(to: url)
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let localPath = path.replacingOccurrences(of: "JointDecision.mlmodelc/", with: "JointDecisionv3.mlmodelc/")
            files.append(.init(remotePath: path, localPath: localPath, size: Int64(data.count), sha256: sha))
        }
        let package = ExpressModelPackage(
            name: "Test Model",
            repository: "TestOrg/test-model",
            revision: String(repeating: "a", count: 40),
            files: files
        )
        return (source, package)
    }

    func testSpeechManifestCoversEveryComponentFluidAudioLoads() {
        let localPaths = Set(ExpressModelStore.speech.files.map(\.localPath))
        for component in ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"] {
            XCTAssertTrue(
                localPaths.contains("\(component).mlmodelc/weights/weight.bin"),
                "\(component) weights missing from the manifest"
            )
        }
        XCTAssertTrue(localPaths.contains("parakeet_vocab.json"))
        XCTAssertFalse(localPaths.contains { $0.hasPrefix("JointDecision.mlmodelc/") })
        XCTAssertEqual(ExpressModelStore.speech.files.count, localPaths.count, "duplicate paths")
        XCTAssertEqual(ExpressModelStore.speech.totalBytes, 252_730_493)
    }

    func testWordBoostManifestCoversWhatTheCTCLoaderReads() {
        let localPaths = Set(ExpressModelStore.wordBoost.files.map(\.localPath))
        for required in [
            "MelSpectrogram.mlmodelc/weights/weight.bin",
            "AudioEncoder.mlmodelc/weights/weight.bin",
            "vocab.json",
            "tokenizer.json",
        ] {
            XCTAssertTrue(localPaths.contains(required), "\(required) missing from the manifest")
        }
        XCTAssertEqual(ExpressModelStore.wordBoost.totalBytes, 102_810_906)
        XCTAssertEqual(ExpressModelStore.totalBytes, 252_730_493 + 102_810_906)
    }

    func testPackagesArePinnedToFullCommitHashes() {
        for package in ExpressModelStore.packages {
            XCTAssertEqual(package.revision.count, 40, "\(package.name) must be pinned to a full commit hash")
            XCTAssertTrue(package.sourceBase.absoluteString.contains(package.revision))
        }
    }

    func testFoldersSitBesideWhisperModelsInTheStorageBase() {
        let base = URL(fileURLWithPath: "/Volumes/Models", isDirectory: true)
        XCTAssertEqual(
            ExpressModelStore.folder(for: ExpressModelStore.speech, in: base).path,
            "/Volumes/Models/models/FluidVoice-Labs/fluid-speech-mini-coreml"
        )
        XCTAssertEqual(
            ExpressModelStore.folder(for: ExpressModelStore.wordBoost, in: base).path,
            "/Volumes/Models/models/FluidInference/parakeet-ctc-110m-coreml"
        )
    }

    func testInstallVerifiesAndMovesThePackageIntoPlace() async throws {
        let (source, package) = try makePackage([
            "Encoder.mlmodelc/weights/weight.bin": "encoder",
            "JointDecision.mlmodelc/weights/weight.bin": "joint",
            "parakeet_vocab.json": "{}",
        ])
        let base = try makeDirectory()
        XCTAssertFalse(ExpressModelStore.isInstalled(package, in: base))

        let progressValues = ProgressRecorder()
        try await ExpressModelStore.install(package, into: base, sourceBase: source) { progressValues.record($0) }

        XCTAssertTrue(ExpressModelStore.isInstalled(package, in: base))
        let folder = ExpressModelStore.folder(for: package, in: base)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("JointDecisionv3.mlmodelc/weights/weight.bin").path
        ))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["test-model"], "no staging folder may remain")
        XCTAssertEqual(progressValues.last, 1)
    }

    func testChecksumMismatchInstallsNothing() async throws {
        let (source, good) = try makePackage(["Encoder.mlmodelc/weights/weight.bin": "encoder"])
        let file = good.files[0]
        let corrupted = ExpressModelPackage(
            name: good.name,
            repository: good.repository,
            revision: good.revision,
            files: [.init(remotePath: file.remotePath, localPath: file.localPath, size: file.size, sha256: String(repeating: "0", count: 64))]
        )
        let base = try makeDirectory()

        do {
            try await ExpressModelStore.install(corrupted, into: base, sourceBase: source) { _ in }
            XCTFail("a corrupted file must not install")
        } catch let error as ExpressModelStoreError {
            XCTAssertEqual(error, .verificationFailed(file: "Encoder.mlmodelc/weights/weight.bin"))
        }
        let parent = ExpressModelStore.folder(for: corrupted, in: base).deletingLastPathComponent()
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        XCTAssertTrue(contents.isEmpty, "neither the package nor a staging folder may remain: \(contents)")
    }

    func testRemoveDeletesOnlyTheExpressFolders() async throws {
        let base = try makeDirectory()
        let whisper = ModelProbeTestSupport.repositoryRoot(under: base)
        try FileManager.default.createDirectory(at: whisper, withIntermediateDirectories: true)
        for package in ExpressModelStore.packages {
            try FileManager.default.createDirectory(
                at: ExpressModelStore.folder(for: package, in: base),
                withIntermediateDirectories: true
            )
        }

        try await ExpressModelStore.remove(from: base)

        for package in ExpressModelStore.packages {
            XCTAssertFalse(FileManager.default.fileExists(atPath: ExpressModelStore.folder(for: package, in: base).path))
        }
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
