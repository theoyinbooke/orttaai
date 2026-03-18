// PermissionStepView.swift
// Orttaai

import SwiftUI
import Cocoa
import Combine
import AVFoundation
import ApplicationServices
import os

struct PermissionStepView: View {
    @Binding var allGranted: Bool

    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false
    @State private var accessibilityCheckCount = 0
    @State private var showAccessibilityTroubleshooting = false
    @State private var inputMonitoringCheckCount = 0
    @State private var showInputMonitoringTroubleshooting = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let appDidBecomeActive = NotificationCenter.default.publisher(
        for: NSApplication.didBecomeActiveNotification
    )

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
                action: requestAccessibilityPermission
            )

            // Accessibility troubleshooting tip
            if showAccessibilityTroubleshooting && !accessibilityGranted {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Label("Permission not detected", systemImage: "exclamationmark.triangle.fill")
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.accent)

                    Text("macOS has stale permission records from a previous version. Click the button below to clear them, then grant access again.")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Reset & Grant Access") {
                        resetAndRequestAccessibility()
                    }
                    .buttonStyle(OrttaaiButtonStyle(.primary))
                    .padding(.top, Spacing.xs)
                }
                .padding(Spacing.lg)
                .background(Color.Orttaai.accent.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.card)
                        .stroke(Color.Orttaai.accent.opacity(0.25), lineWidth: BorderWidth.standard)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Input Monitoring
            PermissionRow(
                icon: "keyboard",
                stepNumber: nil,
                title: "Input Monitoring (Optional)",
                description: "Useful as a fallback on some macOS setups",
                status: inputMonitoringGranted ? .granted : .notGranted,
                action: requestInputMonitoringPermission
            )

            // Input Monitoring troubleshooting tip
            if showInputMonitoringTroubleshooting && !inputMonitoringGranted {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Label("Permission not detected", systemImage: "exclamationmark.triangle.fill")
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.accent)

                    Text("macOS has stale permission records. Click below to clear them, then grant access again. This permission is optional — you can skip it.")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Reset & Grant Access") {
                        resetAndRequestInputMonitoring()
                    }
                    .buttonStyle(OrttaaiButtonStyle(.primary))
                    .padding(.top, Spacing.xs)
                }
                .padding(Spacing.lg)
                .background(Color.Orttaai.accent.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.card)
                        .stroke(Color.Orttaai.accent.opacity(0.25), lineWidth: BorderWidth.standard)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

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
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Orttaai.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
        }
        .onReceive(timer) { _ in
            checkPermissions()
        }
        .onReceive(appDidBecomeActive) { _ in
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

        // Track consecutive failed accessibility checks to show troubleshooting tip.
        // After ~8 seconds of polling (8 checks at 1s interval) with accessibility
        // still not detected, show the toggle-off/on workaround. This covers the
        // common macOS issue where the TCC entry is stale after an app update.
        if !accessibilityGranted {
            accessibilityCheckCount += 1
            if accessibilityCheckCount >= 8 && !showAccessibilityTroubleshooting {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showAccessibilityTroubleshooting = true
                }
            }
        } else {
            accessibilityCheckCount = 0
            if showAccessibilityTroubleshooting {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showAccessibilityTroubleshooting = false
                }
            }
        }

        // Input Monitoring is optional.
        checkInputMonitoring()

        allGranted = micGranted && accessibilityGranted
    }

    private func checkInputMonitoring() {
        // CGPreflightListenEventAccess() can return stale results after app
        // updates (same TCC issue as accessibility). Fall back to actually
        // attempting a passive event tap — if it succeeds, we have permission.
        var granted = CGPreflightListenEventAccess()
        if !granted {
            if let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .tailAppendEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                callback: { _, _, event, _ in Unmanaged.passRetained(event) },
                userInfo: nil
            ) {
                // Tap created successfully — permission is actually granted.
                // The tap is never installed on a run loop, so it has no side effects.
                _ = tap
                granted = true
            }
        }

        inputMonitoringGranted = granted

        // Show troubleshooting tip after ~8 seconds of failed checks.
        if !inputMonitoringGranted {
            inputMonitoringCheckCount += 1
            if inputMonitoringCheckCount >= 8 && !showInputMonitoringTroubleshooting {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showInputMonitoringTroubleshooting = true
                }
            }
        } else {
            inputMonitoringCheckCount = 0
            if showInputMonitoringTroubleshooting {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showInputMonitoringTroubleshooting = false
                }
            }
        }
    }

    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                micGranted = granted
                allGranted = micGranted && accessibilityGranted
            }
        }
    }

    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)

        accessibilityGranted = isTrusted
        allGranted = micGranted && accessibilityGranted

        guard !isTrusted else { return }

        openSystemSettings("Privacy_Accessibility")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            checkPermissions()
        }
    }

    /// Clears all stale TCC entries for this bundle, then re-requests permission.
    /// This fixes the common post-update issue where macOS has conflicting records
    /// from previous builds and toggling off/on in System Settings doesn't help.
    private func resetAndRequestAccessibility() {
        resetTCCEntries(service: "Accessibility")
        accessibilityCheckCount = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            requestAccessibilityPermission()
        }
    }

    private func requestInputMonitoringPermission() {
        _ = CGRequestListenEventAccess()
        openSystemSettings("Privacy_ListenEvent")
    }

    private func resetAndRequestInputMonitoring() {
        resetTCCEntries(service: "ListenEvent")
        inputMonitoringCheckCount = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            requestInputMonitoringPermission()
        }
    }

    private func resetTCCEntries(service: String) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleID]
        try? process.run()
        process.waitUntilExit()
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
