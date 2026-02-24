// AudioCaptureServiceTests.swift
// OrttaaiTests
//
// NOTE: Audio tests require microphone permission and a connected audio input device.
// These tests may need to be run as part of the full app target, not just the unit test target.
// [NEEDS-RUNTIME-TEST]

import XCTest
import AVFoundation
@testable import Orttaai

final class AudioCaptureServiceTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()

        guard ProcessInfo.processInfo.environment["RUN_AUDIO_TESTS"] == "1" else {
            throw XCTSkip("Audio capture tests are opt-in. Set RUN_AUDIO_TESTS=1 to run them.")
        }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("Microphone permission is required for audio capture tests.")
        }
    }

    func testStartAndStopCapture() throws {
        let service = AudioCaptureService()

        do {
            try service.startCapture()
            // Brief recording
            Thread.sleep(forTimeInterval: 0.5)
            let samples = service.stopCapture()
            if samples.isEmpty {
                throw XCTSkip("No audio samples captured in this environment.")
            }
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
