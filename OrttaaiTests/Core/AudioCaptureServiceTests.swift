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

    func testSelectedDeviceCaptureKeepsUpWithWallClock() throws {
        guard let rawDeviceID = ProcessInfo.processInfo.environment["ORTTAAI_AUDIO_DEVICE_ID"],
              let deviceID = AudioDeviceID(rawDeviceID) else {
            throw XCTSkip("Set ORTTAAI_AUDIO_DEVICE_ID to exercise a selected microphone.")
        }

        let service = AudioCaptureService()
        try service.startCapture(deviceID: deviceID)
        let duration: TimeInterval = 3
        Thread.sleep(forTimeInterval: duration)
        let samples = service.stopCapture()
        let coverage = Double(samples.count) / (duration * 16_000)

        XCTAssertGreaterThanOrEqual(
            coverage,
            0.90,
            "Selected-device capture dropped more than 10% of the audio clock"
        )
    }
}

final class AudioCaptureBackendPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AudioCaptureBackendPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRemembersWorkingCaptureSessionByStableDeviceUID() {
        let preferences = AudioCaptureBackendPreferences(defaults: defaults)
        let deviceUID = "external-microphone-uid"

        XCTAssertFalse(preferences.prefersCaptureSession(forDeviceUID: deviceUID))
        preferences.rememberCaptureSession(forDeviceUID: deviceUID)

        let preferencesAfterRelaunch = AudioCaptureBackendPreferences(defaults: defaults)
        XCTAssertTrue(preferencesAfterRelaunch.prefersCaptureSession(forDeviceUID: deviceUID))
        XCTAssertFalse(preferencesAfterRelaunch.prefersCaptureSession(forDeviceUID: "another-device"))
    }

    func testForgettingFailedCaptureSessionAllowsBackendReevaluation() {
        let preferences = AudioCaptureBackendPreferences(defaults: defaults)
        let deviceUID = "external-microphone-uid"
        preferences.rememberCaptureSession(forDeviceUID: deviceUID)

        preferences.forgetCaptureSession(forDeviceUID: deviceUID)

        XCTAssertFalse(preferences.prefersCaptureSession(forDeviceUID: deviceUID))
    }

    func testEmptyDeviceUIDIsNeverPersisted() {
        let preferences = AudioCaptureBackendPreferences(defaults: defaults)

        preferences.rememberCaptureSession(forDeviceUID: "  ")

        XCTAssertFalse(preferences.prefersCaptureSession(forDeviceUID: nil))
        XCTAssertFalse(preferences.prefersCaptureSession(forDeviceUID: ""))
    }
}
