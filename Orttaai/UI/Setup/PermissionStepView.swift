// PermissionStepView.swift
// Orttaai

import SwiftUI
import Cocoa
import Combine
import AVFoundation
import os

struct PermissionStepView: View {
    @Binding var allGranted: Bool

    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Permissions")
                .font(.Orttaai.title)
                .foregroundStyle(Color.Orttaai.textPrimary)

            Text("Grant the two required permissions first, then continue to model download. Input Monitoring stays optional.")
                .font(.Orttaai.body)
                .foregroundStyle(Color.Orttaai.textSecondary)

            progressCard
                .padding(.bottom, Spacing.xs)

            // Microphone
            PermissionRow(
                icon: "mic.fill",
                stepNumber: 1,
                title: "Microphone",
                description: "Captures your voice for on-device transcription",
                status: micGranted ? .granted : .notGranted,
                action: {
                    requestMicrophonePermission()
                }
            )

            // Accessibility
            PermissionRow(
                icon: "accessibility",
                stepNumber: 2,
                title: "Accessibility",
                description: "Simulates paste to inject text at your cursor",
                status: accessibilityGranted ? .granted : .notGranted,
                action: {
                    openSystemSettings("Privacy_Accessibility")
                }
            )

            // Input Monitoring
            PermissionRow(
                icon: "keyboard",
                stepNumber: nil,
                title: "Input Monitoring (Optional)",
                description: "Useful as a fallback on some macOS setups",
                status: inputMonitoringGranted ? .granted : .notGranted,
                action: requestInputMonitoringPermission
            )

            // Trust statement
            HStack(spacing: Spacing.md) {
                Rectangle()
                    .fill(Color.Orttaai.accent)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Your privacy is protected")
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                    Text("Your voice and text never leave your Mac. All transcription is processed locally using WhisperKit. No data is sent to any server.")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }
            }
            .padding(Spacing.lg)
            .background(Color.Orttaai.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
        }
        .onReceive(timer) { _ in
            checkPermissions()
        }
        .onAppear {
            checkPermissions()
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Label("\(requiredPermissionCount)/2 required permissions ready", systemImage: allGranted ? "checkmark.seal.fill" : "flag.fill")
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(allGranted ? Color.Orttaai.success : Color.Orttaai.accent)

                Spacer()

                Text(allGranted ? "Ready to continue" : "Recommended next step")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
            }

            Text(nextStepMessage)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
        }
        .padding(Spacing.lg)
        .background(Color.Orttaai.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card)
                .stroke(allGranted ? Color.Orttaai.success.opacity(0.35) : Color.Orttaai.border, lineWidth: BorderWidth.standard)
        )
    }

    private var requiredPermissionCount: Int {
        [micGranted, accessibilityGranted].filter { $0 }.count
    }

    private var nextStepMessage: String {
        if !micGranted {
            return "Start with Microphone so Orttaai can hear you when you hold the hotkey."
        }
        if !accessibilityGranted {
            return "Open Accessibility next so Orttaai can paste text back where you started recording."
        }
        return "Required permissions are complete. Continue to download a model and run your first dictation test."
    }

    private func checkPermissions() {
        // Microphone
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        // Accessibility
        accessibilityGranted = AXIsProcessTrusted()

        // Input Monitoring is optional.
        checkInputMonitoring()

        allGranted = micGranted && accessibilityGranted
    }

    private func checkInputMonitoring() {
        inputMonitoringGranted = CGPreflightListenEventAccess()
    }

    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                micGranted = granted
            }
        }
    }

    private func requestInputMonitoringPermission() {
        _ = CGRequestListenEventAccess()
        openSystemSettings("Privacy_ListenEvent")
    }

    private func openSystemSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

}

struct PermissionRow: View {
    let icon: String
    let stepNumber: Int?
    let title: String
    let description: String
    let status: PermissionStatus
    let action: () -> Void

    enum PermissionStatus {
        case notGranted
        case granted
    }

    var body: some View {
        HStack(spacing: Spacing.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.Orttaai.bgPrimary.opacity(0.65))
                    .frame(width: 42, height: 42)

                if let stepNumber {
                    Text("\(stepNumber)")
                        .font(.Orttaai.secondary.monospacedDigit())
                        .foregroundStyle(status == .granted ? Color.Orttaai.success : Color.Orttaai.textSecondary)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(statusIconColor)
                }
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Text(description)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                Text(statusLabel)
                    .font(.Orttaai.caption)
                    .foregroundStyle(status == .granted ? Color.Orttaai.success : Color.Orttaai.textTertiary)
            }

            Spacer()

            switch status {
            case .notGranted:
                Button("Grant Access", action: action)
                    .buttonStyle(OrttaaiButtonStyle(.primary))
            case .granted:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.Orttaai.success)
            }
        }
        .padding(Spacing.lg)
        .background(Color.Orttaai.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
    }

    private var statusIconColor: Color {
        switch status {
        case .notGranted: return Color.Orttaai.textSecondary
        case .granted: return Color.Orttaai.success
        }
    }

    private var statusLabel: String {
        switch status {
        case .notGranted:
            return stepNumber == nil ? "Optional" : "Required before continuing"
        case .granted:
            return "Granted"
        }
    }
}
