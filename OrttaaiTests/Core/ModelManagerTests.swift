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

    func testCanonicalModelListIDMapsOfficialTurboReleaseIntoTurboFamily() {
        // v20240930 is the official large-v3-turbo release, not an alias of large-v3.
        XCTAssertEqual(
            ModelManager.canonicalModelListID("openai_whisper-large-v3-v20240930"),
            "openai_whisper-large-v3_turbo"
        )
        XCTAssertEqual(
            ModelManager.canonicalModelListID("openai_whisper-large-v3-v20240930_626MB"),
            "openai_whisper-large-v3_turbo"
        )
        XCTAssertEqual(
            ModelManager.canonicalModelListID("openai_whisper-large-v3-v20240930_turbo_632MB"),
            "openai_whisper-large-v3_turbo"
        )
    }

    func testCanonicalModelListIDLeavesPlainLargeV3Alone() {
        XCTAssertEqual(
            ModelManager.canonicalModelListID("openai_whisper-large-v3_947MB"),
            "openai_whisper-large-v3"
        )
    }

    func testDeduplicationPrefersCuratedQuantizedVariant() {
        let deduplicated = ModelManager.deduplicateModelsByNormalizedID([
            makeModel(id: "openai_whisper-large-v3_turbo", name: "Whisper Large V3 Turbo", sizeMB: 3_047),
            makeModel(id: "openai_whisper-large-v3-v20240930", name: "Whisper Large V3 Turbo", sizeMB: 1_544),
            makeModel(id: "openai_whisper-large-v3-v20240930_626MB", name: "Whisper Large V3 Turbo", sizeMB: 626),
        ])

        XCTAssertEqual(deduplicated.count, 1)
        XCTAssertEqual(deduplicated.first?.id, "openai_whisper-large-v3-v20240930_626MB")
        XCTAssertEqual(deduplicated.first?.downloadSizeMB, 626)
    }

    func testDeduplicationShowsPreferredVariantSizeNotMinimum() {
        // Without a curated variant in the group, the canonical id wins and
        // its size must be shown — not the smallest size across aliases.
        let deduplicated = ModelManager.deduplicateModelsByNormalizedID([
            makeModel(id: "openai_whisper-medium", name: "Whisper Medium", sizeMB: 1_450),
            makeModel(id: "openai_whisper-medium_500MB", name: "Whisper Medium", sizeMB: 500),
        ])

        XCTAssertEqual(deduplicated.count, 1)
        XCTAssertEqual(deduplicated.first?.id, "openai_whisper-medium")
        XCTAssertEqual(deduplicated.first?.downloadSizeMB, 1_450)
    }

    func testParsedSizeSuffixMB() {
        XCTAssertEqual(ModelManager.parsedSizeSuffixMB("openai_whisper-large-v3-v20240930_626MB"), 626)
        XCTAssertEqual(ModelManager.parsedSizeSuffixMB("openai_whisper-large-v3_turbo_1GB"), 1_024)
        XCTAssertNil(ModelManager.parsedSizeSuffixMB("openai_whisper-large-v3"))
        XCTAssertNil(ModelManager.parsedSizeSuffixMB("openai_whisper-small.en"))
    }

    func testEstimateSizeUsesExplicitSuffixWhenPresent() {
        XCTAssertEqual(ModelManager.estimateSize("openai_whisper-small_216MB"), 216)
        XCTAssertEqual(ModelManager.estimateSize("openai_whisper-large-v3-v20240930_626MB"), 626)
    }

    func testFormatDisplayNameCollapsesVariantSuffixes() {
        XCTAssertEqual(
            ModelManager.formatDisplayName("openai_whisper-large-v3-v20240930_626MB"),
            "Whisper Large V3 Turbo"
        )
        XCTAssertEqual(
            ModelManager.formatDisplayName("openai_whisper-large-v3_947MB"),
            "Whisper Large V3"
        )
        XCTAssertEqual(
            ModelManager.formatDisplayName("openai_whisper-small_216MB"),
            "Whisper Small"
        )
    }

    func testIsTurboFamily() {
        XCTAssertTrue(ModelManager.isTurboFamily("openai_whisper-large-v3_turbo"))
        XCTAssertTrue(ModelManager.isTurboFamily("openai_whisper-large-v3-v20240930_626MB"))
        XCTAssertFalse(ModelManager.isTurboFamily("openai_whisper-large-v3_947MB"))
        XCTAssertFalse(ModelManager.isTurboFamily("openai_whisper-small"))
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

    func testSetupDownloadedModelResolverPrefersSelectedDownloadedModel() {
        let resolved = SetupDownloadedModelResolver.resolveInstalledModelID(
            downloadedModelIDs: ["openai_whisper-small.en", "openai_whisper-large-v3_turbo"],
            selectedModelID: "openai_whisper-large-v3_turbo",
            preferredModelIDs: ["openai_whisper-small.en", "openai_whisper-large-v3_turbo"]
        )

        XCTAssertEqual(resolved, "openai_whisper-large-v3_turbo")
    }

    func testSetupDownloadedModelResolverFallsBackToPreferredDownloadedModel() {
        let resolved = SetupDownloadedModelResolver.resolveInstalledModelID(
            downloadedModelIDs: ["openai_whisper-small.en"],
            selectedModelID: "openai_whisper-large-v3_turbo",
            preferredModelIDs: ["openai_whisper-small.en", "openai_whisper-large-v3_turbo"]
        )

        XCTAssertEqual(resolved, "openai_whisper-small.en")
    }

    func testSetupDownloadedModelResolverReturnsNilWithoutMatchingDownloadedModel() {
        let resolved = SetupDownloadedModelResolver.resolveInstalledModelID(
            downloadedModelIDs: ["openai_whisper-medium"],
            selectedModelID: "openai_whisper-large-v3_turbo",
            preferredModelIDs: ["openai_whisper-small.en", "openai_whisper-large-v3_turbo"]
        )

        XCTAssertNil(resolved)
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
        recommended: Bool = false,
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
