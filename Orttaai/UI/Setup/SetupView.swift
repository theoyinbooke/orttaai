// SetupView.swift
// Orttaai

import SwiftUI

struct SetupView: View {
    @State private var currentStep = 0
    @State private var permissionsGranted = false
    @State private var modelReady = false
    @State private var didActivateReadyTest = false

    var onComplete: (() -> Void)?
    var onReadyForTesting: (() -> Void)?

    private let steps = ["About", "Permissions", "Download", "Ready"]
    private var canContinue: Bool {
        switch currentStep {
        case 0:
            return true
        case 1:
            return permissionsGranted
        case 2:
            return modelReady
        default:
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            HStack(spacing: Spacing.sm) {
                ForEach(0..<steps.count, id: \.self) { index in
                    HStack(spacing: Spacing.xs) {
                        Circle()
                            .fill(index <= currentStep ? Color.Orttaai.accent : Color.Orttaai.bgTertiary)
                            .frame(width: 8, height: 8)
                        if index == currentStep {
                            Text(steps[index])
                                .font(.Orttaai.secondary)
                                .foregroundStyle(Color.Orttaai.textPrimary)
                        }
                    }
                }
            }
            .padding(.top, Spacing.xxl)
            .padding(.bottom, Spacing.xl)

            Text("Step \(currentStep + 1) of \(steps.count)")
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
                .padding(.bottom, Spacing.lg)

            ScrollView(showsIndicators: false) {
                stepContent
                    .padding(.bottom, Spacing.lg)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation {
                            currentStep -= 1
                        }
                    }
                    .buttonStyle(OrttaaiButtonStyle(.secondary))
                }

                Spacer()

                if currentStep < steps.count - 1 {
                    Button("Continue") {
                        withAnimation {
                            currentStep += 1
                        }
                    }
                    .buttonStyle(OrttaaiButtonStyle(.primary))
                    .disabled(!canContinue)
                    .opacity(canContinue ? 1.0 : 0.55)
                    .animation(.easeInOut(duration: 0.15), value: canContinue)
                }
            }
            .padding(.bottom, Spacing.xxl)
        }
        .padding(.horizontal, Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Orttaai.bgPrimary)
        .onChange(of: currentStep) { _, newValue in
            guard newValue == 3 else { return }
            activateReadyTestIfNeeded()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case 0:
            AboutSetupStepView()
        case 1:
            PermissionStepView(allGranted: $permissionsGranted)
        case 2:
            DownloadStepView(isModelReady: $modelReady)
        case 3:
            ReadyStepView(onStart: {
                onComplete?()
            })
            .onAppear {
                activateReadyTestIfNeeded()
            }
        default:
            EmptyView()
        }
    }

    private func activateReadyTestIfNeeded() {
        guard !didActivateReadyTest else { return }
        didActivateReadyTest = true
        onReadyForTesting?()
    }
}

private struct AboutSetupStepView: View {
    private let emailURL = URL(string: "mailto:Oyinbookeola@outlook.com")!
    private let githubURL = AppLinks.githubProfileURL
    private let repoURL = AppLinks.githubRepositoryURL

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("About Orttaai")
                .font(.Orttaai.title)
                .foregroundStyle(Color.Orttaai.textPrimary)

            Text("Orttaai is a local-first voice keyboard for macOS. Hold your hotkey to speak, release to transcribe, and Orttaai pastes text back into your active app.")
                .font(.Orttaai.body)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            featureCard(
                icon: "mic.fill",
                title: "Fast Dictation",
                description: "Press-and-hold to record, release to transcribe and inject text at your cursor."
            )

            featureCard(
                icon: "lock.shield.fill",
                title: "Privacy First",
                description: "Whisper transcription runs locally on your Mac. Your voice and transcript stay on-device."
            )

            featureCard(
                icon: "cpu.fill",
                title: "Model Control",
                description: "Choose the model that fits your hardware and optionally use local LLM polish/insights."
            )

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Creator")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Text("Built by Olanrewaju Oyinbooke.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Spacing.sm) {
                    Link(destination: emailURL) {
                        Label("Email", systemImage: "envelope")
                    }
                    .buttonStyle(OrttaaiButtonStyle(.secondary))

                    Link(destination: githubURL) {
                        Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .buttonStyle(OrttaaiButtonStyle(.secondary))

                    Link(destination: repoURL) {
                        Label("Project", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(OrttaaiButtonStyle(.secondary))
                }
            }
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Orttaai.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
        }
    }

    private func featureCard(icon: String, title: String, description: String) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.Orttaai.accent)
                .frame(width: 40, height: 40)
                .background(Color.Orttaai.bgPrimary.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Text(description)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Orttaai.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
    }
}
