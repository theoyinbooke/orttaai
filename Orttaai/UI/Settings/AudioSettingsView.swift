// AudioSettingsView.swift
// Orttaai

import SwiftUI
import CoreAudio
import os

struct AudioSettingsView: View {
    @AppStorage("selectedAudioDeviceID") private var selectedDeviceID = ""
    @State private var audioDeviceManager = AudioDeviceManager()
    @State private var audioLevel: Float = 0
    @State private var testCapture: AudioCaptureService?
    @State private var levelTimer: Timer?
    @State private var isResettingAudioPipeline = false
    @State private var audioResetMessage: String?
    @State private var audioResetSucceeded = true

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Audio")
                    .font(.Orttaai.heading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Text("Control microphone input for dictation.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }

            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Microphone")
                        .font(.Orttaai.subheading)
                        .foregroundStyle(Color.Orttaai.textPrimary)

                    Picker("", selection: $selectedDeviceID) {
                        Text("System Default")
                            .tag("")

                        ForEach(audioDeviceManager.devices) { device in
                            Text(device.name)
                                .tag(String(device.id))
                        }
                    }
                    .pickerStyle(.menu)
                }

                Divider()
                    .background(Color.Orttaai.border)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HStack {
                        Text("Input Level")
                            .font(.Orttaai.subheading)
                            .foregroundStyle(Color.Orttaai.textPrimary)

                        Spacer()

                        Text(audioLevelLabel)
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                    }

                    AudioLevelMeter(level: audioLevel)

                    Text(activeDeviceLabel)
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }

                Text("Changes here affect only Orttaai. Other apps keep using their own audio settings.")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .padding(.top, Spacing.xs)
            }
            .padding(Spacing.lg)
            .dashboardCard()

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Label("Tip", systemImage: "lightbulb")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.warning)

                Text("If input looks flat, check macOS microphone permissions and try selecting a specific device instead of System Default.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Orttaai.warningSubtle.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .stroke(Color.Orttaai.warning.opacity(0.35), lineWidth: BorderWidth.standard)
            )

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Audio Recovery")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Text("Use this when monitoring gets stuck at 0% or the selected mic no longer responds.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)

                Button {
                    requestAudioPipelineReset()
                } label: {
                    HStack(spacing: Spacing.xs) {
                        if isResettingAudioPipeline {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                        }

                        Text(isResettingAudioPipeline ? "Resetting Audio..." : "Reset Audio Pipeline")
                            .lineLimit(1)
                    }
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary))
                .disabled(isResettingAudioPipeline)

                if let audioResetMessage {
                    Text(audioResetMessage)
                        .font(.Orttaai.caption)
                        .foregroundStyle(audioResetSucceeded ? Color.Orttaai.success : Color.Orttaai.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Orttaai.bgSecondary.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .stroke(Color.Orttaai.border.opacity(0.7), lineWidth: BorderWidth.standard)
            )

            if audioDeviceManager.devices.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("No audio input devices detected.")
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.error)
                    Text("Reconnect a microphone and reopen this section.")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }
                .padding(Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.Orttaai.errorSubtle.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
            }
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            startLevelMonitoring()
        }
        .onDisappear {
            stopLevelMonitoring()
        }
        .onChange(of: selectedDeviceID) { _, _ in
            startLevelMonitoring()
        }
        .onReceive(NotificationCenter.default.publisher(for: .audioPipelineResetDidComplete)) { notification in
            let success = notification.userInfo?[AudioPipelineResetNotificationKey.success] as? Bool ?? false
            let message = notification.userInfo?[AudioPipelineResetNotificationKey.message] as? String

            isResettingAudioPipeline = false
            audioResetSucceeded = success
            audioResetMessage = message ?? (success ? "Audio pipeline reset." : "Audio reset failed.")
            audioDeviceManager.refreshDevices()

            if success {
                startLevelMonitoring()
            }
        }
    }

    private var currentDevice: AudioInputDevice? {
        if selectedDeviceID.isEmpty {
            return audioDeviceManager.defaultInputDevice()
        }
        return audioDeviceManager.devices.first { String($0.id) == selectedDeviceID }
    }

    private var activeDeviceLabel: String {
        currentDevice?.name ?? "System Default"
    }

    private var audioLevelLabel: String {
        "\(Int((max(0, min(audioLevel, 1)) * 100).rounded()))%"
    }

    private func startLevelMonitoring() {
        stopLevelMonitoring()

        let capture = AudioCaptureService()
        testCapture = capture
        do {
            let requestedDeviceID = resolvedRequestedDeviceID()
            try capture.startCapture(deviceID: requestedDeviceID)
            if let requestedDeviceID,
               let activeDeviceID = capture.activeInputDeviceID,
               activeDeviceID != requestedDeviceID {
                Logger.audio.warning(
                    "Audio settings monitor requested device \(requestedDeviceID), but active input is \(activeDeviceID)."
                )
            }

            // Update level from capture service
            levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
                audioLevel = capture.audioLevel
            }
        } catch {
            Logger.audio.error("Failed to start level monitoring: \(error.localizedDescription)")
        }
    }

    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil

        _ = testCapture?.stopCapture()
        testCapture = nil
        audioLevel = 0
    }

    private func resolvedRequestedDeviceID() -> AudioDeviceID? {
        let trimmed = selectedDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let rawID = UInt32(trimmed), rawID != 0 else {
            selectedDeviceID = ""
            return nil
        }

        let requested = AudioDeviceID(rawID)
        let stillAvailable = audioDeviceManager.devices.contains(where: { $0.id == requested })
        guard stillAvailable else {
            Logger.audio.warning("Stored audio settings device \(rawID) unavailable; reverting to system default")
            selectedDeviceID = ""
            return nil
        }

        return requested
    }

    private func requestAudioPipelineReset() {
        guard !isResettingAudioPipeline else { return }

        isResettingAudioPipeline = true
        audioResetSucceeded = true
        audioResetMessage = "Resetting audio pipeline..."

        stopLevelMonitoring()
        audioDeviceManager.refreshDevices()

        NotificationCenter.default.post(name: .audioPipelineResetRequested, object: nil)
    }
}
