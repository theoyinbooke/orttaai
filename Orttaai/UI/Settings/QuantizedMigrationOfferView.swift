// QuantizedMigrationOfferView.swift
// Orttaai
//
// Components for variant truth in the model list: a precision chip matching
// the Supported/Recommended/English chip language, and the one-tap
// "Switch to quantized" offer shown under a family row whose full-precision
// build is on disk.

import SwiftUI

/// Capsule chip that says which build of a model family the row represents:
/// quantized (size-suffixed ids like "_947MB") vs full precision.
struct ModelPrecisionChip: View {
    let precision: ModelVariantPrecision
    var compact: Bool = false

    private var title: String {
        switch precision {
        case .quantized:
            return compact ? "Quant" : "Quantized"
        case .fullPrecision:
            return compact ? "Full" : "Full precision"
        }
    }

    private var tint: Color {
        switch precision {
        case .quantized:
            return Color.Orttaai.success
        case .fullPrecision:
            return Color.Orttaai.warning
        }
    }

    var body: some View {
        Text(title)
            .font(.Orttaai.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, compact ? 6 : Spacing.sm)
            .padding(.vertical, compact ? 1 : 2)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
            .lineLimit(1)
            .accessibilityLabel(precision == .quantized ? "Quantized build" : "Full-precision build")
    }
}

/// One-tap, user-initiated offer to replace a downloaded full-precision build
/// with the curated quantized variant. Dismissible per family; the deletion
/// only happens after the replacement is verified loaded.
struct QuantizedMigrationOfferView: View {
    let offer: QuantizedMigrationOffer
    let isMigrating: Bool
    let isDisabled: Bool
    let onMigrate: () -> Void
    let onDismiss: () -> Void

    private var reclaimText: String {
        ModelSizeFormatter.text(forBytes: offer.estimatedReclaimedBytes)
    }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            Image(systemName: "arrow.down.right.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.Orttaai.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text("Quantized build available")
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Text("Smaller, faster, and verified before replacement.")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Spacing.sm)

            if isMigrating {
                HStack(spacing: Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Migrating...")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.accent)
                }
            } else {
                Button("Keep full precision", action: onDismiss)
                    .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
                    .disabled(isDisabled)
                    .help("Dismiss this suggestion")

                Button("Switch to quantized (~\(reclaimText) reclaimed)", action: onMigrate)
                    .buttonStyle(OrttaaiButtonStyle(.primary, size: .small))
                    .disabled(isDisabled)
                    .help("Verify the quantized build before replacement")
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                .fill(Color.Orttaai.accentSubtle.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                .stroke(Color.Orttaai.accent.opacity(0.25), lineWidth: BorderWidth.standard)
        )
    }
}
