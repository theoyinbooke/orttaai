// AudioSettingsView.swift
// Uttrai

import SwiftUI

struct AudioSettingsView: View {
    @AppStorage("selectedAudioDeviceID") private var selectedDeviceID = ""
    @State private var audioDeviceManager = AudioDeviceManager()
    @State private var audioLevel: Float = 0
    @State private var testCapture: AudioCaptureService?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            Text("Audio")
                .font(.Uttrai.heading)
                .foregroundStyle(Color.Uttrai.textPrimary)

            // Microphone selector
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Microphone")
                    .font(.Uttrai.subheading)
                    .foregroundStyle(Color.Uttrai.textPrimary)

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

            // Audio level meter
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Input Level")
                    .font(.Uttrai.subheading)
                    .foregroundStyle(Color.Uttrai.textPrimary)

                AudioLevelMeter(level: audioLevel)

                if let device = currentDevice {
                    Text(device.name)
                        .font(.Uttrai.secondary)
                        .foregroundStyle(Color.Uttrai.textSecondary)
                }
            }

            Text("Changing the microphone here only affects Uttrai. Other apps are not affected.")
                .font(.Uttrai.caption)
                .foregroundStyle(Color.Uttrai.textTertiary)

            Spacer()
        }
        .padding(Spacing.xxl)
        .onAppear {
            startLevelMonitoring()
        }
        .onDisappear {
            stopLevelMonitoring()
        }
    }

    private var currentDevice: AudioInputDevice? {
        if selectedDeviceID.isEmpty {
            return audioDeviceManager.defaultInputDevice()
        }
        return audioDeviceManager.devices.first { String($0.id) == selectedDeviceID }
    }

    private func startLevelMonitoring() {
        let capture = AudioCaptureService()
        testCapture = capture
        do {
            if selectedDeviceID.isEmpty {
                try capture.startCapture()
            } else if let deviceID = AudioDeviceID(selectedDeviceID) {
                try capture.startCapture(deviceID: deviceID)
            }
            // Update level from capture service
            Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
                audioLevel = capture.audioLevel
            }
        } catch {
            Logger.audio.error("Failed to start level monitoring: \(error.localizedDescription)")
        }
    }

    private func stopLevelMonitoring() {
        _ = testCapture?.stopCapture()
        testCapture = nil
    }
}
