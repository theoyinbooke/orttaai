// HardwareDetectorTests.swift
// UttraiTests

import XCTest
@testable import Uttrai

final class HardwareDetectorTests: XCTestCase {

    func testDetectReturnValidTier() {
        let info = HardwareDetector.detect()
        // Running on Apple Silicon M4 Mac Mini — should not be intel_unsupported
        XCTAssertNotEqual(info.tier, .intel_unsupported)
        XCTAssertTrue(info.isAppleSilicon)
    }

    func testRecommendedModelForEachTier() {
        let m3 = HardwareDetector.recommendedModel(for: .m3_16gb)
        XCTAssertEqual(m3, "openai_whisper-large-v3_turbo")

        let m1_16 = HardwareDetector.recommendedModel(for: .m1_16gb)
        XCTAssertEqual(m1_16, "openai_whisper-large-v3_turbo")

        let m1_8 = HardwareDetector.recommendedModel(for: .m1_8gb)
        XCTAssertEqual(m1_8, "openai_whisper-small")

        let intel = HardwareDetector.recommendedModel(for: .intel_unsupported)
        XCTAssertEqual(intel, "")
    }

    func testRAMDetectionPositive() {
        let ram = HardwareDetector.getRAMInGB()
        XCTAssertGreaterThan(ram, 0)
    }

    func testChipNameNotEmpty() {
        let chipName = HardwareDetector.getChipName()
        XCTAssertFalse(chipName.isEmpty)
    }

    func testDiskSpacePositive() {
        let diskSpace = HardwareDetector.getAvailableDiskSpaceGB()
        XCTAssertGreaterThan(diskSpace, 0)
    }

    func testDetermineTierIntel() {
        let tier = HardwareDetector.determineTier(isAppleSilicon: false, ramGB: 16, chipName: "Intel Core i7")
        XCTAssertEqual(tier, .intel_unsupported)
    }

    func testDetermineTierM4() {
        let tier = HardwareDetector.determineTier(isAppleSilicon: true, ramGB: 16, chipName: "Apple M4")
        XCTAssertEqual(tier, .m3_16gb)
    }
}
