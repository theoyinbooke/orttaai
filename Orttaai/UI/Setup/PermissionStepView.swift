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

            Text("Orttaai needs Microphone and Accessibility permissions. Input Monitoring is optional.")
                .font(.Orttaai.body)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .padding(.bottom, Spacing.sm)

            // Microphone
            PermissionRow(
                icon: "mic.fill",
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
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(statusIconColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Text(description)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
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
}
