// HomeBannerView.swift
// Orttaai

import SwiftUI

struct HomeBannerView: View {
    let title: String
    let buttonTitle: String
    let isButtonDisabled: Bool
    let onButtonTap: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.Orttaai.accent)

            Text(title)
                .font(.Orttaai.heading)
                .foregroundStyle(Color.Orttaai.textPrimary)

            Spacer(minLength: Spacing.md)

            bannerButton
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(Spacing.md)
        .dashboardCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Banner. \(title)")
        .accessibilityHint("Primary action: \(buttonTitle).")
    }

    private var bannerButton: some View {
        Button(buttonTitle, action: onButtonTap)
            .buttonStyle(OrttaaiButtonStyle(.primary))
            .disabled(isButtonDisabled)
            .accessibilityHint("Opens the suggested next action.")
    }
}
