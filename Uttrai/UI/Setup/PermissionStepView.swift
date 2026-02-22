// PermissionStepView.swift
// Uttrai

import SwiftUI
import AVFoundation
import os

struct PermissionStepView: View {
    @Binding var allGranted: Bool

    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false
    @State private var needsRestart = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Permissions")
                .font(.Uttrai.title)
                .foregroundStyle(Color.Uttrai.textPrimary)

            Text("Uttrai needs three permissions to work. All processing stays on your Mac.")
                .font(.Uttrai.body)
                .foregroundStyle(Color.Uttrai.textSecondary)
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
                title: "Input Monitoring",
                description: "Detects your push-to-talk hotkey",
                status: inputMonitoringStatus,
                action: {
                    if needsRestart {
                        restartApp()
                    } else {
                        openSystemSettings("Privacy_ListenEvent")
                    }
                }
            )

            // Trust statement
            HStack(spacing: Spacing.md) {
                Rectangle()
                    .fill(Color.Uttrai.accent)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Your privacy is protected")
                        .font(.Uttrai.bodyMedium)
                        .foregroundStyle(Color.Uttrai.textPrimary)
                    Text("Your voice and text never leave your Mac. All transcription is processed locally using WhisperKit. No data is sent to any server.")
                        .font(.Uttrai.secondary)
                        .foregroundStyle(Color.Uttrai.textSecondary)
                }
            }
            .padding(Spacing.lg)
            .background(Color.Uttrai.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
        }
        .onReceive(timer) { _ in
            checkPermissions()
        }
        .onAppear {
            checkPermissions()
        }
    }

    private var inputMonitoringStatus: PermissionRow.PermissionStatus {
        if needsRestart { return .needsRestart }
        if inputMonitoringGranted { return .granted }
        return .notGranted
    }

    private func checkPermissions() {
        // Microphone
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        // Accessibility
        accessibilityGranted = AXIsProcessTrusted()

        // Input Monitoring — try creating a tap
        checkInputMonitoring()

        allGranted = micGranted && accessibilityGranted && inputMonitoringGranted
    }

    private func checkInputMonitoring() {
        let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, _, event, _ in Unmanaged.passRetained(event) },
            userInfo: nil
        )

        if let tap = tap {
            inputMonitoringGranted = true
            // Clean up the test tap
            let port = tap
            CFMachPortInvalidate(port)
        } else if accessibilityGranted {
            // If accessibility is granted but tap fails, might need restart
            needsRestart = true
        }
    }

    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                micGranted = granted
            }
        }
    }

    private func openSystemSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func restartApp() {
        let url = URL(fileURLWithPath: Bundle.main.resourcePath!)
        let path = url.deletingLastPathComponent().deletingLastPathComponent().absoluteString
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [path]

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            task.launch()
            NSApp.terminate(nil)
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
        case needsRestart
    }

    var body: some View {
        HStack(spacing: Spacing.lg) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(statusIconColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(.Uttrai.subheading)
                    .foregroundStyle(Color.Uttrai.textPrimary)
                Text(description)
                    .font(.Uttrai.secondary)
                    .foregroundStyle(Color.Uttrai.textSecondary)
            }

            Spacer()

            switch status {
            case .notGranted:
                Button("Grant Access", action: action)
                    .buttonStyle(UttraiButtonStyle(.primary))
            case .granted:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.Uttrai.success)
            case .needsRestart:
                Button("Restart Now", action: action)
                    .buttonStyle(UttraiButtonStyle(.primary))
            }
        }
        .padding(Spacing.lg)
        .background(Color.Uttrai.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
    }

    private var statusIconColor: Color {
        switch status {
        case .notGranted: return Color.Uttrai.textSecondary
        case .granted: return Color.Uttrai.success
        case .needsRestart: return Color.Uttrai.warning
        }
    }
}
