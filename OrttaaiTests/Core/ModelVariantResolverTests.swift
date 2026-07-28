// ModelVariantResolverTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class ModelVariantResolverTests: XCTestCase {
    // MARK: - Variant resolution: downloaded full-precision

    func testDownloadedFullPrecisionRowShowsMeasuredSizeAndFullPrecisionBadge() {
        // The user-caught bug: full-precision large-v3 (2.9GB) on disk while
        // the row said "947MB" (the curated quantized alias).
        let row = ModelVariantResolver.resolveRow(
            family: makeFamily(id: "openai_whisper-large-v3_947MB", sizeMB: 947),
            downloadedVariants: [
                makeRecord(variantID: "openai_whisper-large-v3", bytes: 2_900_000_000)
            ],
            activeModelID: nil
        )

        XCTAssertEqual(row.familyID, "openai_whisper-large-v3")
        XCTAssertEqual(row.displayVariantID, "openai_whisper-large-v3")
        XCTAssertEqual(row.measuredBytes, 2_900_000_000)
        XCTAssertTrue(row.isSizeMeasured)
        XCTAssertEqual(row.precision, .fullPrecision)
        XCTAssertTrue(row.isDownloaded)

        let offer = try? XCTUnwrap(row.migrationOffer)
        XCTAssertEqual(offer?.fullPrecisionVariantID, "openai_whisper-large-v3")
        XCTAssertEqual(offer?.quantizedVariantID, "openai_whisper-large-v3_947MB")
        XCTAssertEqual(offer?.quantizedEstimateMB, 947)
        XCTAssertEqual(offer?.fullPrecisionBytes, 2_900_000_000)
    }

    // MARK: - Variant resolution: downloaded quantized

    func testDownloadedQuantizedRowShowsQuantizedBadgeAndNoMigrationOffer() {
        let row = ModelVariantResolver.resolveRow(
            family: makeFamily(id: "openai_whisper-large-v3_947MB", sizeMB: 947),
            downloadedVariants: [
                makeRecord(variantID: "openai_whisper-large-v3_947MB", bytes: 993_000_000)
            ],
            activeModelID: nil
        )

        XCTAssertEqual(row.displayVariantID, "openai_whisper-large-v3_947MB")
        XCTAssertEqual(row.measuredBytes, 993_000_000)
        XCTAssertEqual(row.precision, .quantized)
        XCTAssertNil(row.migrationOffer, "No full-precision build on disk means nothing to migrate")
    }

    // MARK: - Variant resolution: not downloaded

    func testNotDownloadedRowShowsExactFullPrecisionChoice() {
        let row = ModelVariantResolver.resolveRow(
            family: makeFamily(id: "openai_whisper-small", sizeMB: 465),
            downloadedVariants: [],
            activeModelID: nil
        )

        XCTAssertEqual(row.displayVariantID, "openai_whisper-small")
        XCTAssertNil(row.measuredBytes)
        XCTAssertFalse(row.isSizeMeasured)
        XCTAssertEqual(row.estimatedSizeMB, 465)
        XCTAssertEqual(row.precision, .fullPrecision)
        XCTAssertFalse(row.isDownloaded)
        XCTAssertNil(row.migrationOffer)
    }

    // MARK: - Current-row truth

    func testCurrentRowReflectsLoadedFullPrecisionVariantNotCuratedAlias() {
        // Both builds on disk, the FULL one loaded: the row must show the
        // full build's measured size, never the curated 947MB alias.
        let row = ModelVariantResolver.resolveRow(
            family: makeFamily(id: "openai_whisper-large-v3_947MB", sizeMB: 947),
            downloadedVariants: [
                makeRecord(variantID: "openai_whisper-large-v3", bytes: 2_900_000_000),
                makeRecord(variantID: "openai_whisper-large-v3_947MB", bytes: 993_000_000),
            ],
            activeModelID: "openai_whisper-large-v3"
        )

        XCTAssertEqual(row.displayVariantID, "openai_whisper-large-v3")
        XCTAssertEqual(row.measuredBytes, 2_900_000_000)
        XCTAssertEqual(row.precision, .fullPrecision)
    }

    func testCurrentRowReflectsLoadedQuantizedVariant() {
        let row = ModelVariantResolver.resolveRow(
            family: makeFamily(id: "openai_whisper-large-v3_947MB", sizeMB: 947),
            downloadedVariants: [
                makeRecord(variantID: "openai_whisper-large-v3_947MB", bytes: 993_000_000)
            ],
            activeModelID: "openai_whisper-large-v3_947MB"
        )

        XCTAssertEqual(row.displayVariantID, "openai_whisper-large-v3_947MB")
        XCTAssertEqual(row.measuredBytes, 993_000_000)
        XCTAssertEqual(row.precision, .quantized)
    }

    func testLoadedModelFromAnotherFamilyDoesNotHijackRow() {
        let row = ModelVariantResolver.resolveRow(
            family: makeFamily(id: "openai_whisper-small_216MB", sizeMB: 216),
            downloadedVariants: [
                makeRecord(variantID: "openai_whisper-small", bytes: 487_000_000)
            ],
            activeModelID: "openai_whisper-large-v3"
        )

        XCTAssertEqual(row.displayVariantID, "openai_whisper-small")
        XCTAssertEqual(row.measuredBytes, 487_000_000)
    }

    // MARK: - Size source selection

    func testLoadedVariantWithoutDirectoryFallsBackToHonestEstimate() {
        // Loaded full-precision id with no matching directory: estimate must
        // be the full-precision size (~2950MB), never the quantized 947.
        let row = ModelVariantResolver.resolveRow(
            family: makeFamily(id: "openai_whisper-large-v3_947MB", sizeMB: 947),
            downloadedVariants: [],
            activeModelID: "openai_whisper-large-v3"
        )

        XCTAssertNil(row.measuredBytes)
        XCTAssertEqual(row.estimatedSizeMB, 2_950)
        XCTAssertEqual(row.precision, .fullPrecision)
    }

    func testMeasuredSizeWinsOverEstimateWhenDownloaded() {
        let row = ModelVariantResolver.resolveRow(
            family: makeFamily(id: "openai_whisper-small_216MB", sizeMB: 216),
            downloadedVariants: [
                makeRecord(variantID: "openai_whisper-small_216MB", bytes: 226_000_000)
            ],
            activeModelID: nil
        )

        XCTAssertTrue(row.isSizeMeasured)
        XCTAssertEqual(ModelSizeFormatter.text(for: row), ModelSizeFormatter.text(forBytes: 226_000_000))
    }

    func testEstimateSizeStaysHonestForUnsuffixedFullPrecisionIDs() {
        // Bar 4: the un-suffixed family ids must never display quantized sizes.
        XCTAssertEqual(ModelManager.estimateSize("openai_whisper-large-v3"), 2_950)
        XCTAssertEqual(ModelManager.estimateSize("openai_whisper-large-v3_turbo"), 1_550)
        XCTAssertEqual(ModelManager.estimateSize("openai_whisper-small"), 465)
        XCTAssertEqual(ModelManager.estimateSize("openai_whisper-large-v3_947MB"), 947)
    }

    // MARK: - Migration offer conditions

    func testTurboFamilyFullBuildOffersCuratedTurboVariant() {
        let row = ModelVariantResolver.resolveRow(
            family: makeFamily(id: "openai_whisper-large-v3-v20240930_626MB", sizeMB: 626),
            downloadedVariants: [
                makeRecord(variantID: "openai_whisper-large-v3_turbo", bytes: 3_200_000_000)
            ],
            activeModelID: nil
        )

        XCTAssertEqual(row.familyID, "openai_whisper-large-v3_turbo")
        let offer = try? XCTUnwrap(row.migrationOffer)
        XCTAssertEqual(offer?.fullPrecisionVariantID, "openai_whisper-large-v3_turbo")
        XCTAssertEqual(offer?.quantizedVariantID, "openai_whisper-large-v3-v20240930_626MB")
    }

    func testFamilyWithoutCuratedVariantGetsNoOffer() {
        // base.en has no curated quantized variant; keep today's behavior.
        let row = ModelVariantResolver.resolveRow(
            family: makeFamily(id: "openai_whisper-base.en", sizeMB: 145),
            downloadedVariants: [
                makeRecord(variantID: "openai_whisper-base.en", bytes: 147_000_000)
            ],
            activeModelID: nil
        )

        XCTAssertNil(row.migrationOffer)
        XCTAssertEqual(row.precision, .fullPrecision)
        XCTAssertTrue(row.isSizeMeasured)
    }

    func testMigrationOfferSuppressedAfterDismissal() {
        let row = ModelVariantResolver.resolveRow(
            family: makeFamily(id: "openai_whisper-large-v3_947MB", sizeMB: 947),
            downloadedVariants: [
                makeRecord(variantID: "openai_whisper-large-v3", bytes: 2_900_000_000)
            ],
            activeModelID: nil,
            dismissedMigrationFamilies: ["openai_whisper-large-v3"]
        )

        XCTAssertNil(row.migrationOffer, "Dismissed families must never be nagged again")
        XCTAssertEqual(row.precision, .fullPrecision, "Dismissal hides the offer, not the truth")
    }

    func testEstimatedReclaimedBytesSubtractsQuantizedEstimate() {
        let offer = QuantizedMigrationOffer(
            familyID: "openai_whisper-large-v3",
            fullPrecisionVariantID: "openai_whisper-large-v3",
            fullPrecisionBytes: 2_900_000_000,
            quantizedVariantID: "openai_whisper-large-v3_947MB",
            quantizedEstimateMB: 947
        )

        XCTAssertEqual(offer.estimatedReclaimedBytes, 2_900_000_000 - 947_000_000)
    }

    // MARK: - Dismissal persistence codec

    func testDismissalsRoundTrip() {
        let raw = QuantizedMigrationDismissals.encode(["openai_whisper-large-v3", "openai_whisper-small"])
        XCTAssertEqual(
            QuantizedMigrationDismissals.parse(raw),
            ["openai_whisper-large-v3", "openai_whisper-small"]
        )
    }

    func testDismissalsAddingIsIdempotentAndPreservesExisting() {
        var raw = ""
        raw = QuantizedMigrationDismissals.adding("openai_whisper-small", to: raw)
        raw = QuantizedMigrationDismissals.adding("openai_whisper-large-v3", to: raw)
        raw = QuantizedMigrationDismissals.adding("openai_whisper-large-v3", to: raw)

        XCTAssertEqual(
            QuantizedMigrationDismissals.parse(raw),
            ["openai_whisper-small", "openai_whisper-large-v3"]
        )
    }

    // MARK: - Language labels

    func testLanguageBadgeTitlesAreMutuallyExclusive() {
        XCTAssertEqual(ModelVariantResolver.languageBadgeTitle(isEnglishOnly: true), "English")
        XCTAssertEqual(ModelVariantResolver.languageBadgeTitle(isEnglishOnly: false), "Multilingual")
        XCTAssertEqual(ModelVariantResolver.compactLanguageBadgeTitle(isEnglishOnly: true), "EN")
        XCTAssertEqual(ModelVariantResolver.compactLanguageBadgeTitle(isEnglishOnly: false), "Multi")
        XCTAssertNotEqual(
            ModelVariantResolver.languageBadgeTitle(isEnglishOnly: true),
            ModelVariantResolver.languageBadgeTitle(isEnglishOnly: false)
        )
    }

    // MARK: - Real-machine verification (read-only)

    func testRealDiskInventoryResolvesTruthfullyOnThisMachine() throws {
        // Read-only walk of the actual model storage roots. Skips cleanly on
        // machines without downloaded models; on a machine with the original
        // bug's state (full-precision openai_whisper-large-v3 on disk) it
        // proves the row resolves to the full build with its measured size.
        let metrics = ModelManager.detectDownloadedModelMetrics()
        try XCTSkipIf(metrics.variants.isEmpty, "No downloaded models on this machine")

        for record in metrics.variants {
            XCTAssertGreaterThan(record.bytes, 0, "Measured size missing for \(record.variantID)")
        }

        // Footer consistency: total equals the sum of every variant build.
        XCTAssertEqual(metrics.totalBytes, metrics.variants.reduce(Int64(0)) { $0 + $1.bytes })

        guard let fullLargeV3 = metrics.variants.first(where: { $0.variantID == "openai_whisper-large-v3" }) else {
            throw XCTSkip("Full-precision openai_whisper-large-v3 not present on this machine")
        }

        let row = ModelVariantResolver.resolveRow(
            family: makeFamily(id: "openai_whisper-large-v3_947MB", sizeMB: 947),
            downloadedVariants: metrics.variants,
            activeModelID: "openai_whisper-large-v3"
        )

        XCTAssertEqual(row.displayVariantID, "openai_whisper-large-v3")
        XCTAssertEqual(row.measuredBytes, fullLargeV3.bytes)
        XCTAssertEqual(row.precision, .fullPrecision)
        XCTAssertNotNil(row.migrationOffer)
        XCTAssertGreaterThan(fullLargeV3.bytes, 2_000_000_000, "Full-precision large-v3 should measure ~2.9GB")
    }

    // MARK: - Helpers

    private func makeFamily(id: String, sizeMB: Int) -> ModelInfo {
        ModelInfo(
            id: id,
            name: ModelManager.formatDisplayName(id),
            downloadSizeMB: sizeMB,
            description: "",
            minimumTier: .m1_8gb,
            speedLabel: .fast,
            accuracyLabel: .good,
            isDeviceRecommended: false,
            isDeviceSupported: true,
            isEnglishOnly: false
        )
    }

    private func makeRecord(variantID: String, bytes: Int64) -> DownloadedVariantRecord {
        DownloadedVariantRecord(
            variantID: variantID,
            directoryURL: URL(fileURLWithPath: "/tmp/models/\(variantID)"),
            bytes: bytes
        )
    }
}
