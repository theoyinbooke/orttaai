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
            if selectedDeviceID.isEmpty {
                try capture.startCapture()
            } else if let rawID = UInt32(selectedDeviceID) {
                try capture.startCapture(deviceID: AudioDeviceID(rawID))
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
}
