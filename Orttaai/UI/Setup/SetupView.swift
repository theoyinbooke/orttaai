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

    private let steps = ["Permissions", "Download", "Ready"]
    private var canContinue: Bool {
        switch currentStep {
        case 0:
            return permissionsGranted
        case 1:
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

            // Step content
            switch currentStep {
            case 0:
                PermissionStepView(allGranted: $permissionsGranted)
            case 1:
                DownloadStepView(isModelReady: $modelReady)
            case 2:
                ReadyStepView(onStart: {
                    onComplete?()
                })
                .onAppear {
                    activateReadyTestIfNeeded()
                }
            default:
                EmptyView()
            }

            Spacer()

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
            guard newValue == 2 else { return }
            activateReadyTestIfNeeded()
        }
    }

    private func activateReadyTestIfNeeded() {
        guard !didActivateReadyTest else { return }
        didActivateReadyTest = true
        onReadyForTesting?()
    }
}
