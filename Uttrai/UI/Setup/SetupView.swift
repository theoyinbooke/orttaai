// SetupView.swift
// Uttrai

import SwiftUI

struct SetupView: View {
    @State private var currentStep = 0
    @State private var permissionsGranted = false

    var onComplete: (() -> Void)?

    private let steps = ["Permissions", "Download", "Ready"]

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            HStack(spacing: Spacing.sm) {
                ForEach(0..<steps.count, id: \.self) { index in
                    HStack(spacing: Spacing.xs) {
                        Circle()
                            .fill(index <= currentStep ? Color.Uttrai.accent : Color.Uttrai.bgTertiary)
                            .frame(width: 8, height: 8)
                        if index == currentStep {
                            Text(steps[index])
                                .font(.Uttrai.secondary)
                                .foregroundStyle(Color.Uttrai.textPrimary)
                        }
                    }
                }
            }
            .padding(.top, Spacing.xxl)
            .padding(.bottom, Spacing.xl)

            Text("Step \(currentStep + 1) of \(steps.count)")
                .font(.Uttrai.caption)
                .foregroundStyle(Color.Uttrai.textTertiary)
                .padding(.bottom, Spacing.lg)

            // Step content
            switch currentStep {
            case 0:
                PermissionStepView(allGranted: $permissionsGranted)
            case 1:
                DownloadStepView()
            case 2:
                ReadyStepView(onStart: {
                    onComplete?()
                })
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
                    .buttonStyle(UttraiButtonStyle(.secondary))
                }

                Spacer()

                if currentStep < steps.count - 1 {
                    Button("Continue") {
                        withAnimation {
                            currentStep += 1
                        }
                    }
                    .buttonStyle(UttraiButtonStyle(.primary))
                    .disabled(currentStep == 0 && !permissionsGranted)
                }
            }
            .padding(.bottom, Spacing.xxl)
        }
        .padding(.horizontal, Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Uttrai.bgPrimary)
    }
}
