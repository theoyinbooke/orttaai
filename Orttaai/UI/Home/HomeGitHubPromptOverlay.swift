// HomeGitHubPromptOverlay.swift
// Orttaai

import SwiftUI

struct HomeGitHubPromptOverlay: View {
    let step: GitHubStarPromptStep
    let onEnjoying: () -> Void
    let onMaybeLater: () -> Void
    let onStar: () -> Void
    let onDismissPermanently: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.48)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(eyebrow)
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.accent)

                    Text(title)
                        .font(.Orttaai.heading)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                }

                Text(message)
                    .font(.Orttaai.body)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                buttonLayout
            }
            .padding(Spacing.xxl)
            .frame(width: 420)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.Orttaai.bgSecondary.opacity(0.98),
                                Color.Orttaai.bgPrimary.opacity(0.96)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .stroke(Color.Orttaai.border.opacity(0.9), lineWidth: BorderWidth.standard)
            )
            .shadow(color: .black.opacity(0.28), radius: 22, y: 18)
            .padding(Spacing.xxl)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    @ViewBuilder
    private var buttonLayout: some View {
        switch step {
        case .enjoyment:
            HStack(spacing: Spacing.md) {
                Button("Not now") {
                    onMaybeLater()
                }
                .frame(minWidth: 152)
                .buttonStyle(OrttaaiButtonStyle(.secondary))

                Button("Yes, I am") {
                    onEnjoying()
                }
                .frame(minWidth: 152)
                .buttonStyle(OrttaaiButtonStyle(.primary))
            }
            .frame(maxWidth: .infinity, alignment: .center)
        case .star:
            VStack(spacing: Spacing.md) {
                Button("Star on GitHub") {
                    onStar()
                }
                .frame(minWidth: 192)
                .buttonStyle(OrttaaiButtonStyle(.primary))

                HStack(spacing: Spacing.md) {
                    Button("Maybe later") {
                        onMaybeLater()
                    }
                    .frame(minWidth: 152)
                    .buttonStyle(OrttaaiButtonStyle(.secondary))

                    Button("No thanks") {
                        onDismissPermanently()
                    }
                    .frame(minWidth: 152)
                    .buttonStyle(OrttaaiButtonStyle(.secondary, destructive: true))
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var eyebrow: String {
        switch step {
        case .enjoyment:
            return "Community"
        case .star:
            return "GitHub"
        }
    }

    private var title: String {
        switch step {
        case .enjoyment:
            return "Enjoying Orttaai?"
        case .star:
            return "Support the project"
        }
    }

    private var message: String {
        switch step {
        case .enjoyment:
            return "If Orttaai is helping your workflow, a GitHub star is the simplest way to support the project."
        case .star:
            return "Your star helps more people discover Orttaai and tells me the product is worth pushing further."
        }
    }
}
