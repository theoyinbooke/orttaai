// ModelVariantResolver.swift
// Orttaai
//
// Pure resolution of what a model-family row must display so the list never
// contradicts what is on disk or loaded. A family row (deduplicated by
// `ModelManager.canonicalModelListID`) can stand for several concrete builds:
//   - the curated quantized variant we prefer for new downloads,
//   - a full-precision build already on disk,
//   - the variant actually loaded right now.
// The resolver picks the truthful one: loaded variant first, then what is
// downloaded, and only for not-yet-downloaded rows the curated estimate.

import Foundation

/// Whether a concrete build id names a quantized (mixed-bit palettized,
/// size-suffixed like "_947MB") or full-precision build.
enum ModelVariantPrecision: String, Sendable, Equatable {
    case quantized = "Quantized"
    case fullPrecision = "Full precision"

    static func forVariantID(_ variantID: String) -> ModelVariantPrecision {
        ModelManager.parsedSizeSuffixMB(variantID) != nil ? .quantized : .fullPrecision
    }
}

/// A user-initiated, verify-before-delete swap of a downloaded full-precision
/// build for the family's curated quantized variant.
struct QuantizedMigrationOffer: Equatable, Sendable {
    let familyID: String
    /// Exact on-disk directory name of the full-precision build to reclaim.
    let fullPrecisionVariantID: String
    let fullPrecisionBytes: Int64
    /// Exact variant id to download, load, and verify before deleting.
    let quantizedVariantID: String
    let quantizedEstimateMB: Int

    var estimatedReclaimedBytes: Int64 {
        max(0, fullPrecisionBytes - Int64(quantizedEstimateMB) * 1_000_000)
    }
}

/// Everything a list row needs to tell the truth about one model family.
struct ResolvedModelRow: Equatable {
    let familyID: String
    /// The concrete build the row represents: the loaded variant when this
    /// family is current, otherwise the downloaded build, otherwise the
    /// curated download target.
    let displayVariantID: String
    /// Measured on-disk bytes of `displayVariantID`, when it is downloaded.
    let measuredBytes: Int64?
    /// Estimate for `displayVariantID` (not the curated alias) — used only
    /// when no measurement exists.
    let estimatedSizeMB: Int
    /// Set only when the display variant is downloaded or loaded; rows for
    /// models that are not on this Mac carry no precision claim.
    let precision: ModelVariantPrecision?
    let isDownloaded: Bool
    let migrationOffer: QuantizedMigrationOffer?

    var isSizeMeasured: Bool { measuredBytes != nil }
}

enum ModelVariantResolver {
    /// - Parameters:
    ///   - family: the deduplicated family row (its id is the preferred /
    ///     curated download variant).
    ///   - downloadedVariants: full on-disk inventory
    ///     (`DownloadedModelMetrics.variants`); the resolver filters to this
    ///     family itself.
    ///   - activeModelID: the id actually loaded
    ///     (`AppSettings.activeModelId` / `ModelManager.currentModelId`);
    ///     pass nil when nothing is loaded.
    ///   - dismissedMigrationFamilies: families whose quantized-migration
    ///     offer the user dismissed ("Keep full precision").
    static func resolveRow(
        family: ModelInfo,
        downloadedVariants: [DownloadedVariantRecord],
        activeModelID: String?,
        dismissedMigrationFamilies: Set<String> = []
    ) -> ResolvedModelRow {
        let familyID = ModelManager.canonicalModelListID(family.id)
        let familyRecords = downloadedVariants.filter {
            ModelManager.canonicalModelListID($0.variantID) == familyID
        }
        let curatedVariantID = ModelManager.curatedDownloadVariantID(forFamily: familyID)

        let loadedVariantID: String? = {
            guard let trimmed = activeModelID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  ModelManager.canonicalModelListID(trimmed) == familyID else {
                return nil
            }
            return trimmed
        }()

        // Display variant: loaded > downloaded-curated > largest downloaded
        // build > the curated download target for not-yet-downloaded rows.
        let displayVariantID: String
        if let loadedVariantID {
            displayVariantID = loadedVariantID
        } else if let curatedVariantID,
                  familyRecords.contains(where: { $0.variantID == curatedVariantID }) {
            displayVariantID = curatedVariantID
        } else if let largestRecord = familyRecords.max(by: { $0.bytes < $1.bytes }) {
            displayVariantID = largestRecord.variantID
        } else {
            displayVariantID = family.id
        }

        // Size: measured on disk beats any estimate. Matching is by exact
        // directory name — normalized matching would let a quantized build's
        // size stand in for a full-precision one, which is the original bug.
        let matchingRecord = familyRecords.first { $0.variantID == displayVariantID }

        let precision: ModelVariantPrecision?
        if matchingRecord != nil || loadedVariantID != nil {
            precision = ModelVariantPrecision.forVariantID(displayVariantID)
        } else {
            precision = nil
        }

        var migrationOffer: QuantizedMigrationOffer?
        if let curatedVariantID,
           !dismissedMigrationFamilies.contains(familyID),
           let fullPrecisionRecord = familyRecords.first(where: { !$0.isQuantized }) {
            migrationOffer = QuantizedMigrationOffer(
                familyID: familyID,
                fullPrecisionVariantID: fullPrecisionRecord.variantID,
                fullPrecisionBytes: fullPrecisionRecord.bytes,
                quantizedVariantID: curatedVariantID,
                quantizedEstimateMB: ModelManager.estimateSize(curatedVariantID)
            )
        }

        return ResolvedModelRow(
            familyID: familyID,
            displayVariantID: displayVariantID,
            measuredBytes: matchingRecord?.bytes,
            estimatedSizeMB: ModelManager.estimateSize(displayVariantID),
            precision: precision,
            isDownloaded: !familyRecords.isEmpty,
            migrationOffer: migrationOffer
        )
    }

    // MARK: - Language labels

    /// English-only and Multilingual are mutually exclusive by construction:
    /// one call site, one boolean, one chip.
    static func languageBadgeTitle(isEnglishOnly: Bool) -> String {
        isEnglishOnly ? "English" : "Multilingual"
    }

    static func compactLanguageBadgeTitle(isEnglishOnly: Bool) -> String {
        isEnglishOnly ? "EN" : "Multi"
    }
}

/// Formats row sizes the same way as the disk-usage footer
/// (`ByteCountFormatter`, `.file`), so both always agree.
enum ModelSizeFormatter {
    static func text(forBytes bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static func text(for row: ResolvedModelRow) -> String {
        if let measuredBytes = row.measuredBytes {
            return text(forBytes: measuredBytes)
        }
        return "\(row.estimatedSizeMB)MB"
    }
}

/// Persistence codec for per-family "Keep full precision" dismissals.
/// Stored as a sorted, comma-separated string in `@AppStorage`.
enum QuantizedMigrationDismissals {
    static func parse(_ raw: String) -> Set<String> {
        Set(
            raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    static func encode(_ families: Set<String>) -> String {
        families.sorted().joined(separator: ",")
    }

    static func adding(_ familyID: String, to raw: String) -> String {
        var families = parse(raw)
        families.insert(familyID)
        return encode(families)
    }
}
