// AudioInputTransport.swift
// Orttaai
//
// How a microphone is connected. A Bluetooth headset mic behaves very
// differently from the rest: opening it switches the headphones to their
// call profile, which takes a moment and changes the audio format.

import CoreAudio

nonisolated enum AudioInputTransport: String, Sendable, Equatable {
    case builtIn = "built_in"
    case bluetooth
    case usb
    case wireless
    case other

    init(transportType: UInt32?) {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            self = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            self = .bluetooth
        case kAudioDeviceTransportTypeUSB:
            self = .usb
        case kAudioDeviceTransportTypeAirPlay, kAudioDeviceTransportTypeContinuityCaptureWireless:
            self = .wireless
        default:
            self = .other
        }
    }

    static func of(_ device: AudioDeviceID) -> AudioInputTransport {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard device != 0, AudioObjectHasProperty(device, &address) else { return .other }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return AudioInputTransport(transportType: status == noErr ? value : nil)
    }

    /// The Mac's current default input.
    static var systemDefaultInput: AudioInputTransport? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != 0 else { return nil }
        return of(device)
    }
}
