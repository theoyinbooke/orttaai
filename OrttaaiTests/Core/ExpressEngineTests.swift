// ExpressEngineTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class ExpressEngineTests: XCTestCase {

    private func version(_ major: Int, _ minor: Int, _ patch: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    func testExpressIsHiddenBelowMacOS15() {
        XCTAssertFalse(ExpressEngine.isSupported(on: version(14, 6)))
        XCTAssertFalse(ExpressEngine.isSupported(on: version(14, 7, 6)))
    }

    func testExpressIsAvailableFromMacOS15() {
        XCTAssertTrue(ExpressEngine.isSupported(on: version(15, 0)))
        XCTAssertTrue(ExpressEngine.isSupported(on: version(26, 1)))
    }

    func testFluidSpeechMiniLoadsAsUltra() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("Express needs macOS 15") }
        XCTAssertEqual(String(describing: ExpressEngine.modelVersion), "ultra")
    }
}
