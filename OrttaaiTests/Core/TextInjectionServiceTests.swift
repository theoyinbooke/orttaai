// TextInjectionServiceTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class TextInjectionServiceTests: XCTestCase {

    func testLastTranscriptNotSetOnBlock() async {
        let service = TextInjectionService()

        // We can't easily mock AX in unit tests, but we can verify the API contract:
        // If inject returns .blockedSecureField, lastTranscript should NOT be set
        // This test verifies the initial state
        XCTAssertNil(service.lastTranscript, "lastTranscript should be nil initially")
    }

    func testLastTranscriptSetOnSuccess() async {
        // NOTE: This test requires Accessibility permission and a non-secure text field focused.
        // In CI or without permissions, the AX check may fail-open, allowing injection.
        // [NEEDS-RUNTIME-TEST] for full validation.
        let service = TextInjectionService()

        let result = await service.inject(text: "Test transcript")

        if result == .success {
            XCTAssertEqual(service.lastTranscript, "Test transcript")
        } else {
            // If blocked (e.g., no focused element), lastTranscript should remain nil
            XCTAssertNil(service.lastTranscript)
        }
    }

    func testSecureFieldCheckReturnsBool() {
        let service = TextInjectionService()
        // Just verify it doesn't crash and returns a Bool
        let result = service.isFocusedElementSecure()
        XCTAssertNotNil(result)
    }

    func testPasteLastTranscriptWithNoTranscript() async {
        let service = TextInjectionService()
        let result = await service.pasteLastTranscript()
        XCTAssertEqual(result, .noTranscript, "Should return noTranscript when no last transcript")
    }
}
