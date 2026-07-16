// QuickStartModelSelectorTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class QuickStartModelSelectorTests: XCTestCase {
    func testUsesEnglishVariantForEnglishLanguage() {
        XCTAssertEqual(QuickStartModelSelector.modelId(for: "en"), "openai_whisper-small.en_217MB")
        XCTAssertEqual(QuickStartModelSelector.modelId(for: "en-US"), "openai_whisper-small.en_217MB")
    }

    func testUsesMultilingualVariantForNonEnglishLanguage() {
        XCTAssertEqual(QuickStartModelSelector.modelId(for: "auto"), "openai_whisper-small_216MB")
        XCTAssertEqual(QuickStartModelSelector.modelId(for: "es"), "openai_whisper-small_216MB")
    }
}
