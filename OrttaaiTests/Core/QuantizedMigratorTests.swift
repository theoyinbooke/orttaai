// QuantizedMigratorTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class QuantizedMigratorTests: XCTestCase {
    private enum TestError: Error {
        case downloadFailed
        case deleteFailed
        case restoreFailed
    }

    /// Records every operation in call order and simulates outcomes.
    private final class MockOperations: QuantizedMigrationOperating {
        var calls: [String] = []
        var downloadError: Error?
        var deleteError: Error?
        var restoreError: Error?
        /// What `loadedModelID` reports; defaults to echoing the last
        /// successfully downloaded variant.
        var loadedModelIDOverride: String??
        private var lastDownloaded: String?

        func downloadAndWarmQuantized(variantID: String) async throws {
            calls.append("download(\(variantID))")
            if let downloadError { throw downloadError }
            lastDownloaded = variantID
        }

        func loadedModelID() async -> String? {
            calls.append("loadedModelID")
            if let loadedModelIDOverride { return loadedModelIDOverride }
            return lastDownloaded
        }

        func deleteFullPrecisionVariant(named variantID: String) throws {
            calls.append("delete(\(variantID))")
            if let deleteError { throw deleteError }
        }

        func activateModel(variantID: String) async {
            calls.append("activate(\(variantID))")
        }

        func restorePreviousModel(variantID: String) async throws {
            calls.append("restore(\(variantID))")
            if let restoreError { throw restoreError }
        }
    }

    private let offer = QuantizedMigrationOffer(
        familyID: "openai_whisper-large-v3",
        fullPrecisionVariantID: "openai_whisper-large-v3",
        fullPrecisionBytes: 2_900_000_000,
        quantizedVariantID: "openai_whisper-large-v3_947MB",
        quantizedEstimateMB: 947
    )

    // MARK: - Ordering: verify BEFORE delete

    func testHappyPathForCurrentFamilyVerifiesBeforeDeletingThenActivates() async throws {
        let ops = MockOperations()
        let migrator = QuantizedMigrator(operations: ops)

        let steps = try await migrator.migrate(
            offer: offer,
            previousActiveModelID: "openai_whisper-large-v3"
        )

        XCTAssertEqual(ops.calls, [
            "download(openai_whisper-large-v3_947MB)",
            "loadedModelID",
            "delete(openai_whisper-large-v3)",
            "activate(openai_whisper-large-v3_947MB)",
        ])
        XCTAssertEqual(steps, [
            .downloadedAndWarmed("openai_whisper-large-v3_947MB"),
            .verifiedLoaded("openai_whisper-large-v3_947MB"),
            .deletedFullPrecision("openai_whisper-large-v3"),
            .activatedQuantized("openai_whisper-large-v3_947MB"),
        ])
    }

    func testNoActiveModelTreatsFamilyAsCurrent() async throws {
        let ops = MockOperations()
        let migrator = QuantizedMigrator(operations: ops)

        _ = try await migrator.migrate(offer: offer, previousActiveModelID: nil)

        XCTAssertTrue(ops.calls.contains("activate(openai_whisper-large-v3_947MB)"))
        XCTAssertFalse(ops.calls.contains(where: { $0.hasPrefix("restore(") }))
    }

    // MARK: - Failure: download

    func testDownloadFailureLeavesDiskUntouchedAndRestoresPrevious() async {
        let ops = MockOperations()
        ops.downloadError = TestError.downloadFailed
        let migrator = QuantizedMigrator(operations: ops)

        do {
            _ = try await migrator.migrate(offer: offer, previousActiveModelID: "openai_whisper-small")
            XCTFail("Expected download failure to propagate")
        } catch {
            XCTAssertFalse(ops.calls.contains(where: { $0.hasPrefix("delete(") }),
                           "Nothing may be deleted after a failed download")
            XCTAssertFalse(ops.calls.contains(where: { $0.hasPrefix("activate(") }))
            XCTAssertTrue(ops.calls.contains("restore(openai_whisper-small)"),
                          "Best-effort restore of the previously loaded model")
        }
    }

    // MARK: - Failure: verification

    func testVerificationMismatchAbortsBeforeDeleteWithHonestError() async {
        let ops = MockOperations()
        // Simulate the loader silently loading the full-precision build.
        ops.loadedModelIDOverride = "openai_whisper-large-v3"
        let migrator = QuantizedMigrator(operations: ops)

        do {
            _ = try await migrator.migrate(offer: offer, previousActiveModelID: "openai_whisper-large-v3")
            XCTFail("Expected verification mismatch to throw")
        } catch let error as QuantizedMigrationError {
            XCTAssertEqual(error, .loadedModelMismatch(
                expected: "openai_whisper-large-v3_947MB",
                actuallyLoaded: "openai_whisper-large-v3"
            ))
            XCTAssertFalse(ops.calls.contains(where: { $0.hasPrefix("delete(") }),
                           "Verification failure must leave the full-precision build untouched")
            XCTAssertNotNil(error.errorDescription)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testNothingLoadedAfterDownloadAbortsBeforeDelete() async {
        let ops = MockOperations()
        ops.loadedModelIDOverride = String??.some(nil)
        let migrator = QuantizedMigrator(operations: ops)

        do {
            _ = try await migrator.migrate(offer: offer, previousActiveModelID: nil)
            XCTFail("Expected verification mismatch to throw")
        } catch {
            XCTAssertFalse(ops.calls.contains(where: { $0.hasPrefix("delete(") }))
        }
    }

    // MARK: - Failure: delete (after verification)

    func testDeleteFailurePropagatesWithoutActivation() async {
        let ops = MockOperations()
        ops.deleteError = TestError.deleteFailed
        let migrator = QuantizedMigrator(operations: ops)

        do {
            _ = try await migrator.migrate(offer: offer, previousActiveModelID: "openai_whisper-large-v3")
            XCTFail("Expected delete failure to propagate")
        } catch {
            XCTAssertTrue(ops.calls.contains("delete(openai_whisper-large-v3)"))
            XCTAssertFalse(ops.calls.contains(where: { $0.hasPrefix("activate(") }))
        }
    }

    // MARK: - Non-current family

    func testNonCurrentFamilyRestoresPreviousModelInsteadOfActivating() async throws {
        let ops = MockOperations()
        let migrator = QuantizedMigrator(operations: ops)
        let smallOffer = QuantizedMigrationOffer(
            familyID: "openai_whisper-small",
            fullPrecisionVariantID: "openai_whisper-small",
            fullPrecisionBytes: 487_000_000,
            quantizedVariantID: "openai_whisper-small_216MB",
            quantizedEstimateMB: 216
        )

        let steps = try await migrator.migrate(
            offer: smallOffer,
            previousActiveModelID: "openai_whisper-large-v3"
        )

        XCTAssertEqual(ops.calls.last, "restore(openai_whisper-large-v3)")
        XCTAssertFalse(ops.calls.contains(where: { $0.hasPrefix("activate(") }))
        XCTAssertEqual(steps.last, .restoredPreviousModel("openai_whisper-large-v3"))
    }

    func testRestoreFailureFallsBackToActivatingQuantizedHonestly() async throws {
        let ops = MockOperations()
        ops.restoreError = TestError.restoreFailed
        let migrator = QuantizedMigrator(operations: ops)
        let smallOffer = QuantizedMigrationOffer(
            familyID: "openai_whisper-small",
            fullPrecisionVariantID: "openai_whisper-small",
            fullPrecisionBytes: 487_000_000,
            quantizedVariantID: "openai_whisper-small_216MB",
            quantizedEstimateMB: 216
        )

        let steps = try await migrator.migrate(
            offer: smallOffer,
            previousActiveModelID: "openai_whisper-large-v3"
        )

        XCTAssertEqual(ops.calls.last, "activate(openai_whisper-small_216MB)",
                       "If restore fails, the id must reflect what is actually loaded")
        XCTAssertEqual(steps.last, .activatedQuantized("openai_whisper-small_216MB"))
    }
}
