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
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Microphone
            PermissionRow(
                icon: "mic.fill",
                stepNumber: 1,
                title: "Microphone",
                description: "So Orttaai can hear you while you hold the key.",
                status: micGranted ? .granted : .notGranted,
                action: {
                    requestMicrophonePermission()
                }
            )

            // Accessibility
            PermissionRow(
                icon: "cursorarrow.rays",
                stepNumber: 2,
                title: "Accessibility",
                description: "So it can type into the app you're using.",
                status: accessibilityGranted ? .granted : .notGranted,
                action: requestAccessibilityPermission
            )

            // Accessibility troubleshooting tip
            if showAccessibilityTroubleshooting && !accessibilityGranted {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Label("Permission not detected", systemImage: "exclamationmark.triangle.fill")
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.accent)

                    Text("Reset the stale macOS permission, then grant access again.")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Reset & Grant Access") {
                        resetAndRequestAccessibility()
                    }
                    .buttonStyle(OrttaaiButtonStyle(.primary))
                    .padding(.top, Spacing.xs)
                }
                .padding(Spacing.md)
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
                title: "Input Monitoring",
                description: "Helps the hotkey work in a few apps that need it.",
                status: inputMonitoringGranted ? .granted : .notGranted,
                action: requestInputMonitoringPermission
            )

            // Input Monitoring troubleshooting tip
            if showInputMonitoringTroubleshooting && !inputMonitoringGranted {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Label("Permission not detected", systemImage: "exclamationmark.triangle.fill")
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.accent)

                    Text("Reset the stale macOS permission, then grant access again. This is optional.")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Reset & Grant Access") {
                        resetAndRequestInputMonitoring()
                    }
                    .buttonStyle(OrttaaiButtonStyle(.primary))
                    .padding(.top, Spacing.xs)
                }
                .padding(Spacing.md)
                .background(Color.Orttaai.accent.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.card)
                        .stroke(Color.Orttaai.accent.opacity(0.25), lineWidth: BorderWidth.standard)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Trust statement
            Label("Audio is transcribed on this Mac and never uploaded.", systemImage: "lock.fill")
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, Spacing.sm)
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
        let isGranted = status == .granted
        let tint = isGranted ? Color.Orttaai.success : Color.Orttaai.accent
        HStack(spacing: Spacing.md) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                if isGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.Orttaai.success, Color.Orttaai.bgSecondary)
                        .offset(x: 4, y: 4)
                        .transition(.scale.combined(with: .opacity))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text(title)
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                    if stepNumber == nil {
                        Text("Optional")
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.Orttaai.bgTertiary, in: Capsule())
                    }
                }
                Text(description)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Spacing.sm)

            switch status {
            case .notGranted:
                Button("Allow", action: action)
                    .buttonStyle(OrttaaiButtonStyle(stepNumber == nil ? .secondary : .primary, size: .small))
            case .granted:
                Text("Allowed")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.success)
            }
        }
        .padding(Spacing.md)
        .background(
            (isGranted ? Color.Orttaai.success.opacity(0.06) : Color.Orttaai.bgSecondary),
            in: RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .stroke(isGranted ? Color.Orttaai.success.opacity(0.4) : Color.Orttaai.border.opacity(0.6), lineWidth: BorderWidth.standard)
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isGranted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(statusLabel)")
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
