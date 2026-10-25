// AudioDeviceManager.swift
// Orttaai

import AVFoundation
import CoreAudio
import os

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let isDefault: Bool
    /// Core Audio's persistent identifier. Unlike `id`, it survives the
    /// device disconnecting and reconnecting.
    var uid: String? = nil
}

/// Resolves the microphone the user chose to the device to record from.
/// Core Audio reassigns a device's numeric ID whenever it reconnects
/// (AirPods get a new one every time), so the choice is remembered by UID
/// and looked up for each recording. A chosen mic that is not connected
/// means System Default, never a failed recording.
enum AudioInputSelection {
    static func deviceID(
        selectedUID: String,
        legacyID: String?,
        devices: () -> [AudioInputDevice]
    ) -> AudioDeviceID? {
        let uid = selectedUID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !uid.isEmpty {
            return devices().first { $0.uid == uid }?.id
        }
        // Chosen before UIDs were remembered. Capture falls back to System
        // Default if this ID no longer exists.
        guard let trimmed = legacyID?.trimmingCharacters(in: .whitespacesAndNewlines),
              let rawID = UInt32(trimmed), rawID != 0 else { return nil }
        return AudioDeviceID(rawID)
    }

    /// The picker value (the device's current ID as text) for the
    /// remembered mic, or nil when it is not connected.
    static func pickerValue(selectedUID: String, devices: [AudioInputDevice]) -> String? {
        guard !selectedUID.isEmpty,
              let device = devices.first(where: { $0.uid == selectedUID }) else { return nil }
        return String(device.id)
    }

    /// The UID to remember for a picker value; empty for System Default.
    static func uid(forPickerValue value: String, devices: [AudioInputDevice]) -> String {
        devices.first { String($0.id) == value }?.uid ?? ""
    }
}

@Observable
final class AudioDeviceManager {
    private(set) var devices: [AudioInputDevice] = []
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        refreshDevices()
        startListeningForDeviceChanges()
    }

    deinit {
        stopListeningForDeviceChanges()
    }

    func refreshDevices() {
        devices = availableInputDevices()
    }

    func availableInputDevices() -> [AudioInputDevice] {
        Self.currentInputDevices()
    }

    /// The connected input devices, read fresh from Core Audio.
    static func currentInputDevices() -> [AudioInputDevice] {
        let defaultID = defaultInputDeviceID()

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else { return [] }

        return deviceIDs.compactMap { deviceID -> AudioInputDevice? in
            guard hasInputStreams(deviceID: deviceID) else { return nil }
            let name = deviceName(deviceID: deviceID)
            return AudioInputDevice(
                id: deviceID,
                name: name,
                isDefault: deviceID == defaultID,
                uid: deviceUID(deviceID: deviceID)
            )
        }
    }

    func defaultInputDevice() -> AudioInputDevice? {
        devices.first(where: { $0.isDefault })
    }

    // MARK: - Private

    private static func defaultInputDeviceID() -> AudioDeviceID {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        return deviceID
    }

    private static func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        return status == noErr && dataSize > 0
    }

    private static func deviceUID(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedUID: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &unmanagedUID
        )
        guard status == noErr else { return nil }
        return unmanagedUID?.takeRetainedValue() as String?
    }

    private static func deviceName(deviceID: AudioDeviceID) -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedName: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &unmanagedName
        )
        guard status == noErr else { return "Unknown Device" }
        return unmanagedName?.takeRetainedValue() as String? ?? "Unknown Device"
    }

    private func startListeningForDeviceChanges() {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshDevices()
            }
        }
        deviceListenerBlock = block
        defaultInputListenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main,
            block
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            DispatchQueue.main,
            block
        )
    }

    private func stopListeningForDeviceChanges() {
        guard let deviceListenerBlock else { return }
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main,
            deviceListenerBlock
        )

        if let defaultInputListenerBlock {
            var defaultInputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultInputAddress,
                DispatchQueue.main,
                defaultInputListenerBlock
            )
        }
    }
}
