// AudioOutputRouteTests.swift
// OrttaaiTests
//
// Talking over a scene partner is only safe when the microphone can't hear
// them: headphones yes, speakers no.

import CoreAudio
import XCTest
@testable import Orttaai

final class AudioOutputRouteTests: XCTestCase {
    func testHeadphonesArePrivate() {
        XCTAssertTrue(AudioOutputRoute.isPrivate(transport: kAudioDeviceTransportTypeBluetooth, dataSource: nil))
        XCTAssertTrue(AudioOutputRoute.isPrivate(transport: kAudioDeviceTransportTypeBluetoothLE, dataSource: nil))
        XCTAssertTrue(AudioOutputRoute.isPrivate(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: AudioOutputRoute.headphones))
    }

    func testSpeakersAndUnknownOutputsAreNot() {
        let internalSpeakers: UInt32 = 0x6973_706B // 'ispk'
        XCTAssertFalse(AudioOutputRoute.isPrivate(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: internalSpeakers))
        XCTAssertFalse(AudioOutputRoute.isPrivate(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: nil))
        XCTAssertFalse(AudioOutputRoute.isPrivate(transport: kAudioDeviceTransportTypeHDMI, dataSource: nil))
        XCTAssertFalse(AudioOutputRoute.isPrivate(transport: kAudioDeviceTransportTypeUSB, dataSource: nil))
        XCTAssertFalse(AudioOutputRoute.isPrivate(transport: kAudioDeviceTransportTypeAirPlay, dataSource: nil))
        XCTAssertFalse(AudioOutputRoute.isPrivate(transport: nil, dataSource: nil))
    }
}
