// LinkedDeviceKindTests.swift
// OrttaaiTests
//
// Dictations from devices that sync through Orttaai Link (Windows, Linux,
// Android) are labelled as theirs and never taken for this Mac's.

import XCTest
@testable import Orttaai

final class LinkedDeviceKindTests: XCTestCase {
    func testUntaggedDictationsFromLinkedDevicesAreNeverThisMacs() {
        let devices = DictationDevices(currentDeviceID: "this-mac")
        for kind in ["windows", "linux", "android", "iphone", "ipad"] {
            XCTAssertFalse(devices.isThisMac(deviceID: nil, kind: kind), kind)
            XCTAssertEqual(devices.filter(deviceID: nil, kind: kind) == .thisMac, false, kind)
        }
        XCTAssertTrue(devices.isThisMac(deviceID: nil, kind: nil))
        XCTAssertTrue(devices.isThisMac(deviceID: nil, kind: "mac"))
        XCTAssertTrue(devices.isThisMac(deviceID: nil, kind: "unknown"))
    }

    func testTaggedLinuxDictationIsAnotherDevice() {
        let devices = DictationDevices(currentDeviceID: "this-mac")
        XCTAssertFalse(devices.isThisMac(deviceID: "linux-box", kind: "linux"))
        XCTAssertEqual(devices.filter(deviceID: "linux-box", kind: "linux"), .linux)
        XCTAssertEqual(devices.filter(deviceID: "pc", kind: "windows"), .windows)
        XCTAssertEqual(devices.filter(deviceID: "pixel", kind: "android"), .android)
        XCTAssertEqual(DictationDeviceFilter.linux.title, "Linux")
    }

    func testLinkedDevicesHaveTheirOwnSymbols() {
        XCTAssertEqual(DeviceLabel.symbol(kindName: "windows"), "pc")
        XCTAssertEqual(DeviceLabel.symbol(kindName: "linux"), "pc")
        XCTAssertEqual(DeviceLabel.symbol(kindName: "android"), "smartphone")
        XCTAssertEqual(DeviceLabel.symbol(kindName: "toaster"), "questionmark.square.dashed")
    }
}
