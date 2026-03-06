// QuickStartModelSelectorTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class QuickStartModelSelectorTests: XCTestCase {
    func testUsesEnglishVariantForEnglishLanguage() {
        XCTAssertEqual(QuickStartModelSelector.modelId(for: "en"), "openai_whisper-small.en")
        XCTAssertEqual(QuickStartModelSelector.modelId(for: "en-US"), "openai_whisper-small.en")
    }

    func testUsesMultilingualVariantForNonEnglishLanguage() {
        XCTAssertEqual(QuickStartModelSelector.modelId(for: "auto"), "openai_whisper-small")
        XCTAssertEqual(QuickStartModelSelector.modelId(for: "es"), "openai_whisper-small")
    }
}
