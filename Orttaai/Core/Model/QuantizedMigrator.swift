// QuantizedMigrator.swift
// Orttaai
//
// User-initiated swap of a downloaded full-precision build for the family's
// curated quantized variant. Hard invariant: the full-precision files are
// deleted only AFTER the quantized replacement has been downloaded, loaded,
// warmed, and verified as the actually-loaded model. Any failure before that
// point leaves the disk untouched and surfaces an honest error.

import Foundation
import os

/// Seam over the real model operations so the migration ordering is fully
/// unit-testable without touching disk or WhisperKit.
protocol QuantizedMigrationOperating: AnyObject {
    /// Download (if needed), load, and warm the exact quantized variant.
    func downloadAndWarmQuantized(variantID: String) async throws
    /// The model id the transcription service currently has loaded.
    func loadedModelID() async -> String?
    /// Delete only this build's directory; other family variants stay.
    func deleteFullPrecisionVariant(named variantID: String) throws
    /// Persist the given variant as active + selected model.
    func activateModel(variantID: String) async
    /// Reload the model that was current before migration started (used when
    /// a non-current family was migrated).
    func restorePreviousModel(variantID: String) async throws
}

enum QuantizedMigrationStep: Equatable, Sendable {
    case downloadedAndWarmed(String)
    case verifiedLoaded(String)
    case deletedFullPrecision(String)
    case activatedQuantized(String)
    case restoredPreviousModel(String)
}

enum QuantizedMigrationError: LocalizedError, Equatable {
    case loadedModelMismatch(expected: String, actuallyLoaded: String?)

    var errorDescription: String? {
        switch self {
        case .loadedModelMismatch(let expected, let actuallyLoaded):
            let loadedText = actuallyLoaded ?? "no model"
            return "Verification failed: expected \(expected) to be loaded, but \(loadedText) is. "
                + "The full-precision files were left untouched."
        }
    }
}

struct QuantizedMigrator {
    let operations: any QuantizedMigrationOperating

    /// Runs the migration and returns the ordered steps that actually
    /// happened. Throws (leaving disk untouched) unless the quantized
    /// variant was verified loaded before any deletion.
    @discardableResult
    func migrate(
        offer: QuantizedMigrationOffer,
        previousActiveModelID: String?
    ) async throws -> [QuantizedMigrationStep] {
        var steps: [QuantizedMigrationStep] = []
        let previousID = previousActiveModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // 1. Download + load + warm the quantized replacement. On failure,
        //    best-effort restore of the previous model, then rethrow — the
        //    full-precision build has not been touched.
        do {
            try await operations.downloadAndWarmQuantized(variantID: offer.quantizedVariantID)
        } catch {
            await restorePreviousBestEffort(previousID, into: &steps)
            throw error
        }
        steps.append(.downloadedAndWarmed(offer.quantizedVariantID))

        // 2. Verify the replacement is genuinely the loaded model. Exact id
        //    match — a normalized match could confuse the full-precision
        //    build with its quantized sibling.
        let loadedID = await operations.loadedModelID()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard loadedID == offer.quantizedVariantID else {
            await restorePreviousBestEffort(previousID, into: &steps)
            throw QuantizedMigrationError.loadedModelMismatch(
                expected: offer.quantizedVariantID,
                actuallyLoaded: loadedID
            )
        }
        steps.append(.verifiedLoaded(offer.quantizedVariantID))

        // 3. Only now delete the full-precision build.
        try operations.deleteFullPrecisionVariant(named: offer.fullPrecisionVariantID)
        steps.append(.deletedFullPrecision(offer.fullPrecisionVariantID))

        // 4. Point the app at a truthful model id. If the migrated family was
        //    current (or nothing was loaded), the quantized variant becomes
        //    active; otherwise reload whatever the user had loaded before.
        let familyWasCurrent = previousID.isEmpty
            || ModelManager.canonicalModelListID(previousID) == offer.familyID
        if familyWasCurrent {
            await operations.activateModel(variantID: offer.quantizedVariantID)
            steps.append(.activatedQuantized(offer.quantizedVariantID))
        } else {
            do {
                try await operations.restorePreviousModel(variantID: previousID)
                steps.append(.restoredPreviousModel(previousID))
            } catch {
                // Restore failed: the quantized model is what's loaded, so
                // record that honestly instead of a stale id.
                await operations.activateModel(variantID: offer.quantizedVariantID)
                steps.append(.activatedQuantized(offer.quantizedVariantID))
            }
        }

        return steps
    }

    private func restorePreviousBestEffort(
        _ previousID: String,
        into steps: inout [QuantizedMigrationStep]
    ) async {
        guard !previousID.isEmpty else { return }
        if (try? await operations.restorePreviousModel(variantID: previousID)) != nil {
            steps.append(.restoredPreviousModel(previousID))
        }
    }
}

/// Production implementation backed by ModelManager + AppSettings.
final class ModelManagerQuantizedMigrationOperations: QuantizedMigrationOperating {
    private let manager: ModelManager
    private let settings: AppSettings

    init(manager: ModelManager, settings: AppSettings = AppSettings()) {
        self.manager = manager
        self.settings = settings
    }

    func downloadAndWarmQuantized(variantID: String) async throws {
        // Exact-variant path: never let family-row substitution redirect the
        // download to a different build than the one we verify.
        try await manager.switchModel(to: manager.modelInfo(forExactVariantID: variantID))
    }

    func loadedModelID() async -> String? {
        await manager.runtimeTranscriptionService.loadedModelID()
    }

    func deleteFullPrecisionVariant(named variantID: String) throws {
        try ModelManager.deleteDownloadedVariant(named: variantID)
    }

    func activateModel(variantID: String) async {
        settings.activeModelId = variantID
        settings.selectedModelId = variantID
    }

    func restorePreviousModel(variantID: String) async throws {
        try await manager.switchModel(to: manager.modelInfo(forExactVariantID: variantID))
    }
}
