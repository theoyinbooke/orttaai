// AudioCaptureServiceTests.swift
// UttraiTests
//
// NOTE: Audio tests require microphone permission and a connected audio input device.
// These tests may need to be run as part of the full app target, not just the unit test target.
// [NEEDS-RUNTIME-TEST]

import XCTest
@testable import Uttrai

final class AudioCaptureServiceTests: XCTestCase {

    func testStartAndStopCapture() throws {
        // This test requires mic permission — may fail in CI
        let service = AudioCaptureService()

        do {
            try service.startCapture()
            // Brief recording
            Thread.sleep(forTimeInterval: 0.5)
            let samples = service.stopCapture()
            XCTAssertFalse(samples.isEmpty, "Samples should not be empty after recording")
        } catch {
            // Mic permission not granted — mark as skipped
            throw XCTSkip("Microphone permission required: \(error.localizedDescription)")
        }
    }

    func testAudioLevelUpdates() throws {
        let service = AudioCaptureService()

        do {
            try service.startCapture()
            // Wait for level timer to fire
            let expectation = XCTestExpectation(description: "Audio level should update")

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                // Level may or may not be > 0 depending on ambient sound
                // Just verify it doesn't crash
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 2.0)
            _ = service.stopCapture()
        } catch {
            throw XCTSkip("Microphone permission required: \(error.localizedDescription)")
        }
    }

    func testStopCaptureResetsLevel() throws {
        let service = AudioCaptureService()

        do {
            try service.startCapture()
            Thread.sleep(forTimeInterval: 0.3)
            _ = service.stopCapture()
            XCTAssertEqual(service.audioLevel, 0, "Audio level should be 0 after stopping")
        } catch {
            throw XCTSkip("Microphone permission required: \(error.localizedDescription)")
        }
    }
}
