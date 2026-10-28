// AudioOutputRoute.swift
// Orttaai
//
// Where the Mac's sound is going: to the listener's ears only (headphones,
// AirPods) or into the room, where the microphone hears it too.

import CoreAudio
import Foundation

enum AudioOutputRoute {
    /// The default output reaches only the listener's ears, so the microphone
    /// won't pick it up.
    static var isPrivate: Bool {
        guard let device = defaultOutputDevice() else { return false }
        return isPrivate(transport: transportType(of: device), dataSource: dataSource(of: device))
    }

    /// Bluetooth is almost always headphones; built-in output only when
    /// something is in the headphone jack. Anything else (built-in speakers,
    /// displays, USB, AirPlay) may be heard in the room.
    static func isPrivate(transport: UInt32?, dataSource: UInt32?) -> Bool {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return true
        case kAudioDeviceTransportTypeBuiltIn:
            return dataSource == headphones
        default:
            return false
        }
    }

    /// The built-in output's data source when headphones are plugged in.
    static let headphones: UInt32 = 0x6864_706E // 'hdpn'

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func transportType(of device: AudioDeviceID) -> UInt32? {
        value(kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal, of: device)
    }

    private static func dataSource(of device: AudioDeviceID) -> UInt32? {
        value(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput, of: device)
    }

    private static func value(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope, of device: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var result = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &result) == noErr ? result : nil
    }
}
