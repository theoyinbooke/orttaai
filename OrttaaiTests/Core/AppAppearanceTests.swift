// AppAppearanceTests.swift
// OrttaaiTests
//
// Every colour token has a light and a dark value, and the Appearance setting
// picks which one the app draws with.

import AppKit
import XCTest
@testable import Orttaai

@MainActor
final class AppAppearanceTests: XCTestCase {
    private func hex(_ color: NSColor, in name: NSAppearance.Name) -> String {
        var resolved = color
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return String(format: "%02X%02X%02X", Int(round(resolved.redComponent * 255)), Int(round(resolved.greenComponent * 255)), Int(round(resolved.blueComponent * 255)))
    }

    func testTokensFollowTheLook() {
        XCTAssertEqual(hex(NSColor.Orttaai.bgPrimary, in: .darkAqua), "1C1C1E", "Dark is unchanged")
        XCTAssertEqual(hex(NSColor.Orttaai.bgPrimary, in: .aqua), "F5F3F0", "Light is cream")
        XCTAssertEqual(hex(NSColor.Orttaai.textPrimary, in: .aqua), "1C1C1E")
        XCTAssertEqual(hex(NSColor.Orttaai.accent, in: .darkAqua), "D4952A")
        XCTAssertEqual(hex(NSColor.Orttaai.accent, in: .aqua), "9A6210", "A deeper gold, so text on it reads")
    }

    func testTheSettingPicksTheAppearance() {
        XCTAssertNil(AppAppearance.system.nsAppearance, "Follows the Mac")
        XCTAssertEqual(AppAppearance.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(AppAppearance.dark.nsAppearance?.name, .darkAqua)
        XCTAssertEqual(AppAppearance(rawValue: "nonsense"), nil)
    }
}
