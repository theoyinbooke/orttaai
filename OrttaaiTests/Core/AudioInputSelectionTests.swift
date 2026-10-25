// AudioInputSelectionTests.swift
// OrttaaiTests

import CoreAudio
import XCTest
@testable import Orttaai

final class AudioInputSelectionTests: XCTestCase {
    private let airPodsUID = "14-1A-97-3C-B6-0F:input"
    private var devices: [AudioInputDevice] {
        [
            AudioInputDevice(id: 112, name: "AirPods Pro", isDefault: true, uid: airPodsUID),
            AudioInputDevice(id: 94, name: "Wireless microphone", isDefault: false, uid: "usb-mic"),
        ]
    }

    /// AirPods were chosen as device 344; after reconnecting they are 112.
    func testRememberedMicIsFoundUnderItsNewID() {
        let id = AudioInputSelection.deviceID(selectedUID: airPodsUID, legacyID: "344", devices: { self.devices })
        XCTAssertEqual(id, 112)
    }

    func testDisconnectedRememberedMicMeansSystemDefault() {
        let id = AudioInputSelection.deviceID(selectedUID: airPodsUID, legacyID: "344", devices: { [] })
        XCTAssertNil(id)
    }

    func testChoiceFromBeforeUIDsUsesTheStoredID() {
        XCTAssertEqual(AudioInputSelection.deviceID(selectedUID: "", legacyID: "94", devices: { [] }), 94)
        XCTAssertNil(AudioInputSelection.deviceID(selectedUID: "", legacyID: "", devices: { [] }))
        XCTAssertNil(AudioInputSelection.deviceID(selectedUID: "", legacyID: "not-a-device", devices: { [] }))
    }

    func testPickerShowsTheRememberedMicAndRemembersChoices() {
        XCTAssertEqual(AudioInputSelection.pickerValue(selectedUID: airPodsUID, devices: devices), "112")
        XCTAssertNil(AudioInputSelection.pickerValue(selectedUID: airPodsUID, devices: []))
        XCTAssertEqual(AudioInputSelection.uid(forPickerValue: "94", devices: devices), "usb-mic")
        XCTAssertEqual(AudioInputSelection.uid(forPickerValue: "", devices: devices), "", "System Default")
    }
}
