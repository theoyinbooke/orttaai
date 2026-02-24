// ModelManagerTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class ModelManagerTests: XCTestCase {
    func testSortModelsBySizePrioritizesSizeOverRecommendationFlags() {
        let sorted = ModelManager.sortModelsBySize([
            makeModel(id: "openai_whisper-large-v3", name: "Whisper Large", sizeMB: 1_500, recommended: true),
            makeModel(id: "openai_whisper-tiny", name: "Whisper Tiny", sizeMB: 70, recommended: false),
            makeModel(id: "openai_whisper-small", name: "Whisper Small", sizeMB: 300, recommended: false),
        ])

        XCTAssertEqual(sorted.map(\.id), [
            "openai_whisper-tiny",
            "openai_whisper-small",
            "openai_whisper-large-v3",
        ])
    }

    func testSortModelsByRecommendationPrioritizesRecommendedThenSupported() {
        let recommendedHeavy = makeModel(
            id: "openai_whisper-large-v3",
            name: "Whisper Large",
            sizeMB: 1_500,
            recommended: true,
            supported: true
        )
        let supportedTiny = makeModel(
            id: "openai_whisper-tiny",
            name: "Whisper Tiny",
            sizeMB: 70,
            recommended: false,
            supported: true
        )
        let unsupportedBase = makeModel(
            id: "openai_whisper-base",
            name: "Whisper Base",
            sizeMB: 140,
            recommended: false,
            supported: false
        )

        let sorted = ModelManager.sortModelsByRecommendation([supportedTiny, unsupportedBase, recommendedHeavy])
        XCTAssertEqual(sorted.map(\.id), [
            "openai_whisper-large-v3",
            "openai_whisper-tiny",
            "openai_whisper-base",
        ])
    }

    func testNormalizedModelIDStripsSizeSuffix() {
        XCTAssertEqual(
            ModelManager.normalizedModelID("openai_whisper-large-v3_turbo_954MB"),
            "openai_whisper-large-v3_turbo"
        )
        XCTAssertEqual(
            ModelManager.normalizedModelID("openai_whisper-large-v3_turbo_1GB"),
            "openai_whisper-large-v3_turbo"
        )
    }

    func testNormalizedModelIDKeepsRegularModelIDUnchanged() {
        XCTAssertEqual(
            ModelManager.normalizedModelID("openai_whisper-tiny.en"),
            "openai_whisper-tiny.en"
        )
    }

    func testDetectDownloadedModelMetricsFindsNestedModelDirectories() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let modelDir = tempRoot
            .appendingPathComponent("models--argmaxinc--whisperkit-coreml/snapshots/hash123/openai_whisper-tiny.en", isDirectory: true)
        let invalidModelDir = tempRoot
            .appendingPathComponent("models--argmaxinc--whisperkit-coreml/snapshots/hash123/openai_whisper-base", isDirectory: true)

        try fileManager.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: invalidModelDir, withIntermediateDirectories: true)
        try createFakeModelFiles(at: modelDir)

        let metrics = ModelManager.detectDownloadedModelMetrics(in: [tempRoot])
        XCTAssertTrue(metrics.downloadedModelIDs.contains("openai_whisper-tiny.en"))
        XCTAssertFalse(metrics.downloadedModelIDs.contains("openai_whisper-base"))
        XCTAssertGreaterThan(metrics.totalBytes, 0)
    }

    func testDetectDownloadedModelMetricsDeduplicatesDuplicateModelIds() throws {
        let fileManager = FileManager.default
        let tempRootA = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tempRootB = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? fileManager.removeItem(at: tempRootA)
            try? fileManager.removeItem(at: tempRootB)
        }

        let modelPathA = tempRootA.appendingPathComponent("openai_whisper-small", isDirectory: true)
        let modelPathB = tempRootB.appendingPathComponent("nested/openai_whisper-small", isDirectory: true)
        try fileManager.createDirectory(at: modelPathA, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: modelPathB, withIntermediateDirectories: true)
        try createFakeModelFiles(at: modelPathA)
        try createFakeModelFiles(at: modelPathB)

        let metrics = ModelManager.detectDownloadedModelMetrics(in: [tempRootA, tempRootB])
        XCTAssertEqual(metrics.downloadedModelIDs.count, 1)
        XCTAssertTrue(metrics.downloadedModelIDs.contains("openai_whisper-small"))
    }

    func testDetectDownloadedModelMetricsCanonicalizesSizeSuffixedModelDirectory() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let modelDir = tempRoot.appendingPathComponent("openai_whisper-large-v3_turbo_954MB", isDirectory: true)
        try fileManager.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try createFakeModelFiles(at: modelDir)

        let metrics = ModelManager.detectDownloadedModelMetrics(in: [tempRoot])
        XCTAssertTrue(metrics.downloadedModelIDs.contains("openai_whisper-large-v3_turbo"))
    }

    private func createFakeModelFiles(at modelDirectory: URL) throws {
        let fileManager = FileManager.default
        let payload = Data(repeating: 0x1, count: 1_024)
        for component in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let compiledDir = modelDirectory.appendingPathComponent("\(component).mlmodelc", isDirectory: true)
            try fileManager.createDirectory(at: compiledDir, withIntermediateDirectories: true)
            let payloadURL = compiledDir.appendingPathComponent("weights.bin")
            try payload.write(to: payloadURL)
        }
    }

    private func makeModel(
        id: String,
        name: String,
        sizeMB: Int,
        recommended: Bool,
        supported: Bool = true
    ) -> ModelInfo {
        ModelInfo(
            id: id,
            name: name,
            downloadSizeMB: sizeMB,
            description: "",
            minimumTier: .m1_8gb,
            speedLabel: .fast,
            accuracyLabel: .good,
            isDeviceRecommended: recommended,
            isDeviceSupported: supported,
            isEnglishOnly: false
        )
    }
}
