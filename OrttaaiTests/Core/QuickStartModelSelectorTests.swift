// QuickStartModelSelectorTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class QuickStartModelSelectorTests: XCTestCase {
    func testUsesEnglishVariantForEnglishLanguage() {
        XCTAssertEqual(QuickStartModelSelector.modelId(for: "en"), "openai_whisper-tiny.en")
        XCTAssertEqual(QuickStartModelSelector.modelId(for: "en-US"), "openai_whisper-tiny.en")
    }

    func testUsesMultilingualVariantForNonEnglishLanguage() {
        XCTAssertEqual(QuickStartModelSelector.modelId(for: "auto"), "openai_whisper-tiny")
        XCTAssertEqual(QuickStartModelSelector.modelId(for: "es"), "openai_whisper-tiny")
    }
}
