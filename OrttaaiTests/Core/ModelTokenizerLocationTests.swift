// ModelTokenizerLocationTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class ModelTokenizerLocationTests: XCTestCase {
    private func base(forModelAt path: String) -> String {
        ModelTokenizerLocation.tokenizerBase(forModelFolder: URL(fileURLWithPath: path)).path
    }

    func testModelUnderDocumentsResolvesTokenizersFromDocumentsHuggingface() {
        XCTAssertEqual(
            base(forModelAt: "/Users/someone/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930"),
            "/Users/someone/Documents/huggingface",
            "Identical to WhisperKit's own default for a model that lives in Documents"
        )
    }

    func testModelOnAnExternalDriveResolvesTokenizersFromThatDrive() {
        XCTAssertEqual(
            base(forModelAt: "/Volumes/ModelSSD/ai/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930"),
            "/Volumes/ModelSSD/ai/huggingface"
        )
    }

    func testCustomBaseAtTheDriveRootResolvesFromTheDriveRoot() {
        XCTAssertEqual(
            base(forModelAt: "/Volumes/ModelSSD/models/argmaxinc/whisperkit-coreml/openai_whisper-small"),
            "/Volumes/ModelSSD"
        )
    }

    func testModelInApplicationSupportResolvesFromItsOwnModelsFolder() {
        XCTAssertEqual(
            base(forModelAt: "/Users/someone/Library/Application Support/Orttaai/Models/openai_whisper-small"),
            "/Users/someone/Library/Application Support/Orttaai/Models",
            "A non-standard layout never falls back to Documents"
        )
    }

    func testHubCacheSnapshotResolvesFromTheSnapshotFolder() {
        XCTAssertEqual(
            base(forModelAt: "/Users/someone/.cache/huggingface/hub/models--argmaxinc--whisperkit-coreml/snapshots/abc123/openai_whisper-small"),
            "/Users/someone/.cache/huggingface/hub/models--argmaxinc--whisperkit-coreml/snapshots/abc123"
        )
    }

    func testTokenizerRepositoryNamesFollowWhisperKitsVariantSelection() {
        let expectations: [(String, String?)] = [
            ("openai_whisper-large-v3-v20240930", "openai/whisper-large-v3"),
            ("openai_whisper-large-v3-v20240930_626MB", "openai/whisper-large-v3"),
            ("openai_whisper-large-v3_turbo", "openai/whisper-large-v3"),
            ("openai_whisper-large-v3_947MB", "openai/whisper-large-v3"),
            ("openai_whisper-large-v3", "openai/whisper-large-v3"),
            ("openai_whisper-large-v2", "openai/whisper-large-v2"),
            ("openai_whisper-small", "openai/whisper-small"),
            ("openai_whisper-small.en", "openai/whisper-small.en"),
            ("openai_whisper-small.en_217MB", "openai/whisper-small.en"),
            ("openai_whisper-tiny", "openai/whisper-tiny"),
            ("openai_whisper-base.en", "openai/whisper-base.en"),
            ("openai_whisper-medium", "openai/whisper-medium"),
            ("distil-whisper_distil-large-v3", nil),
            ("openai_whisper-something-new", nil),
        ]
        for (modelID, expected) in expectations {
            XCTAssertEqual(
                ModelTokenizerLocation.tokenizerRepositoryName(forModelID: modelID),
                expected,
                modelID
            )
        }
    }

    func testHasLocalTokenizerLooksUnderTheModelsOwnRoot() throws {
        let baseFolder = try ModelProbeTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseFolder) }
        let modelFolder = ModelProbeTestSupport.repositoryRoot(under: baseFolder)
            .appendingPathComponent("openai_whisper-small", isDirectory: true)
        try FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)

        XCTAssertFalse(ModelTokenizerLocation.hasLocalTokenizer(modelID: "openai_whisper-small", modelFolder: modelFolder))

        try ModelProbeTestSupport.createFakeTokenizer(named: "openai/whisper-small", under: baseFolder)
        XCTAssertTrue(ModelTokenizerLocation.hasLocalTokenizer(modelID: "openai_whisper-small", modelFolder: modelFolder))
        XCTAssertFalse(
            ModelTokenizerLocation.hasLocalTokenizer(modelID: "openai_whisper-large-v3", modelFolder: modelFolder),
            "Another family's tokenizer does not count"
        )
    }

    func testFamiliesTheMappingDoesNotCoverAreNotBlocked() {
        XCTAssertTrue(
            ModelTokenizerLocation.hasLocalTokenizer(
                modelID: "distil-whisper_distil-large-v3",
                modelFolder: URL(fileURLWithPath: "/nonexistent/models/argmaxinc/whisperkit-coreml/distil-whisper_distil-large-v3")
            ),
            "An unverifiable family keeps WhisperKit's own behaviour rather than failing"
        )
    }
}
