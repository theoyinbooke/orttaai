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
        VStack(alignment: .leading, spacing: Spacing.md) {
            SettingsCard("Microphone") {
                SettingsRow(
                    title: "Input Device",
                    info: "The microphone Orttaai records from. System Default follows the input chosen in macOS Sound settings."
                ) {
                    OrttaaiDropdown(
                        selection: $selectedDeviceID,
                        options: [.init("", "System Default")]
                            + audioDeviceManager.devices.map { .init(String($0.id), $0.name) },
                        width: SettingsLayout.controlWidth
                    )
                }

                SettingsDivider()

                SettingsRow(
                    title: "Input Level",
                    info: "Speak to check the level moves. If it stays flat, check microphone permission in System Settings or choose another device."
                ) {
                    HStack(spacing: Spacing.sm) {
                        AudioLevelMeter(level: audioLevel)
                            .frame(width: SettingsLayout.sliderWidth)
                        Text(audioLevelLabel)
                            .font(.Orttaai.mono)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Input level for \(activeDeviceLabel)")
                    .accessibilityValue(audioLevelLabel)
                }

                if audioDeviceManager.devices.isEmpty {
                    SettingsNotice(
                        kind: .error,
                        message: "No audio input devices detected. Reconnect a microphone and reopen this section."
                    )
                }
            }

            SettingsCard("Troubleshooting") {
                SettingsRow(
                    title: "Reset Audio",
                    info: "Restarts audio capture. Use it if recording stops picking up sound, for example after your Mac wakes from sleep or a microphone reconnects."
                ) {
                    Button {
                        requestAudioPipelineReset()
                    } label: {
                        HStack(spacing: Spacing.xs) {
                            if isResettingAudioPipeline {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(isResettingAudioPipeline ? "Resetting…" : "Reset")
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
                    .disabled(isResettingAudioPipeline)
                }

                if let audioResetMessage, !isResettingAudioPipeline {
                    SettingsNotice(
                        kind: audioResetSucceeded ? .success : .error,
                        message: audioResetMessage
                    )
                }
            }
        }
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
