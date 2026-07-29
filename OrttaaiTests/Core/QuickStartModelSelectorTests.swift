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

    func testEnglishSmallSelectionUsesHigherQualityEnglishCheckpoint() {
        XCTAssertEqual(
            TranscriptionModelSelectionPolicy.resolvedModelID(
                selectedModelID: "openai_whisper-small",
                dictationLanguage: "en-GB"
            ),
            "openai_whisper-small.en"
        )
    }

    func testAutoDetectAndNonEnglishKeepMultilingualSmallCheckpoint() {
        XCTAssertEqual(
            TranscriptionModelSelectionPolicy.resolvedModelID(
                selectedModelID: "openai_whisper-small",
                dictationLanguage: "auto"
            ),
            "openai_whisper-small"
        )
        XCTAssertEqual(
            TranscriptionModelSelectionPolicy.resolvedModelID(
                selectedModelID: "openai_whisper-small",
                dictationLanguage: "fr"
            ),
            "openai_whisper-small"
        )
    }

    func testPolicyDoesNotReplaceOtherOrExactVariantSelections() {
        XCTAssertEqual(
            TranscriptionModelSelectionPolicy.resolvedModelID(
                selectedModelID: "openai_whisper-small.en",
                dictationLanguage: "en"
            ),
            "openai_whisper-small.en"
        )
        XCTAssertEqual(
            TranscriptionModelSelectionPolicy.resolvedModelID(
                selectedModelID: "openai_whisper-small_216MB",
                dictationLanguage: "en"
            ),
            "openai_whisper-small_216MB"
        )
        XCTAssertEqual(
            TranscriptionModelSelectionPolicy.resolvedModelID(
                selectedModelID: "openai_whisper-large-v3",
                dictationLanguage: "en"
            ),
            "openai_whisper-large-v3"
        )
    }
}
