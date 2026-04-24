// HomeBannerView.swift
// Orttaai

import SwiftUI

struct HomeBannerView: View {
    let title: String
    let subtitle: String
    let buttonTitle: String
    let showsArtwork: Bool
    let isButtonDisabled: Bool
    let onButtonTap: () -> Void

    var body: some View {
        HStack(spacing: Spacing.xl) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.Orttaai.textPrimary)

                HStack(alignment: .center, spacing: Spacing.lg) {
                    subtitleText
                        .layoutPriority(1)

                    bannerButton
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsArtwork {
                bannerArtwork
                    .frame(width: 220, height: 120)
                    .accessibilityHidden(true)
            }
        }
        .padding(Spacing.lg)
        .dashboardCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Banner. \(title). \(subtitle)")
        .accessibilityHint("Primary action: \(buttonTitle).")
    }

    private var subtitleText: some View {
        Text(subtitle)
            .font(.Orttaai.body)
            .foregroundStyle(Color.Orttaai.textSecondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bannerButton: some View {
        Button(buttonTitle, action: onButtonTap)
            .buttonStyle(OrttaaiButtonStyle(.primary))
            .disabled(isButtonDisabled)
            .accessibilityHint("Opens the suggested next action.")
    }

    private var bannerArtwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CornerRadius.card)
                .fill(Color.Orttaai.accentSubtle)

            VStack(spacing: Spacing.md) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Color.Orttaai.accent)

                HStack(spacing: Spacing.md) {
                    Image(systemName: "mic.fill")
                    Image(systemName: "bolt.fill")
                    Image(systemName: "text.bubble.fill")
                }
                .font(.system(size: 14))
                .foregroundStyle(Color.Orttaai.textSecondary)
            }
            .padding(Spacing.lg)
        }
    }
}
