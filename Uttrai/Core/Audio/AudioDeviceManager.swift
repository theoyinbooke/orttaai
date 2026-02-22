// AudioDeviceManager.swift
// Uttrai

import AVFoundation
import CoreAudio
import os

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let isDefault: Bool
}

@Observable
final class AudioDeviceManager {
    private(set) var devices: [AudioInputDevice] = []
    private var propertyListenerBlock: AudioObjectPropertyListenerBlock?

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
                isDefault: deviceID == defaultID
            )
        }
    }

    func defaultInputDevice() -> AudioInputDevice? {
        devices.first(where: { $0.isDefault })
    }

    // MARK: - Private

    private func defaultInputDeviceID() -> AudioDeviceID {
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

    private func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
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

    private func deviceName(deviceID: AudioDeviceID) -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &name
        )
        return status == noErr ? name as String : "Unknown Device"
    }

    private func startListeningForDeviceChanges() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshDevices()
            }
        }
        propertyListenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
    }

    private func stopListeningForDeviceChanges() {
        guard let block = propertyListenerBlock else { return }
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
    }
}
