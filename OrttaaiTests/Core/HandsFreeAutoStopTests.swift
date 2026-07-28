// HandsFreeAutoStopTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class HandsFreeAutoStopTests: XCTestCase {
    private let sampleRate = HandsFreeAutoStop.sampleRate

    private func speech(seconds: Double) -> [Float] {
        [Float](repeating: 0.1, count: Int(seconds * Double(sampleRate)))
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(sampleRate)))
    }

    func testTriggersAfterSustainedTrailingSilence() {
        let samples = speech(seconds: 1.0) + silence(seconds: 2.5)
        XCTAssertTrue(HandsFreeAutoStop.shouldAutoStop(samples: samples, silenceDuration: 2.0))
    }

    func testTriggersAtExactSilenceBoundary() {
        let samples = speech(seconds: 1.0) + silence(seconds: 2.0)
        XCTAssertTrue(HandsFreeAutoStop.shouldAutoStop(samples: samples, silenceDuration: 2.0))
    }

    func testDoesNotTriggerWhenSilenceTooShort() {
        let samples = speech(seconds: 1.0) + silence(seconds: 1.0)
        XCTAssertFalse(HandsFreeAutoStop.shouldAutoStop(samples: samples, silenceDuration: 2.0))
    }

    func testDoesNotTriggerWhenSpeechResumes() {
        let samples = speech(seconds: 1.0) + silence(seconds: 2.5) + speech(seconds: 0.2)
        XCTAssertFalse(
            HandsFreeAutoStop.shouldAutoStop(samples: samples, silenceDuration: 2.0),
            "Speech after the pause resets the trailing-silence window"
        )
    }

    func testDoesNotTriggerBeforeAnySpeech() {
        let samples = silence(seconds: 4.0)
        XCTAssertFalse(
            HandsFreeAutoStop.shouldAutoStop(samples: samples, silenceDuration: 2.0),
            "A user still gathering their thoughts keeps the mic open; the cap bounds the session"
        )
    }

    func testDoesNotTriggerWithNonPositiveDuration() {
        let samples = speech(seconds: 1.0) + silence(seconds: 3.0)
        XCTAssertFalse(HandsFreeAutoStop.shouldAutoStop(samples: samples, silenceDuration: 0))
        XCTAssertFalse(HandsFreeAutoStop.shouldAutoStop(samples: samples, silenceDuration: -1))
    }

    func testDoesNotTriggerWhenBufferShorterThanWindow() {
        let samples = silence(seconds: 0.5)
        XCTAssertFalse(HandsFreeAutoStop.shouldAutoStop(samples: samples, silenceDuration: 2.0))
    }

    func testQuietButVoicedTailDoesNotTrigger() {
        // 0.03 RMS is above the 0.02 EnergyVAD threshold: quiet speech, not silence.
        let quietSpeech = [Float](repeating: 0.03, count: sampleRate * 3)
        let samples = speech(seconds: 1.0) + quietSpeech
        XCTAssertFalse(HandsFreeAutoStop.shouldAutoStop(samples: samples, silenceDuration: 2.0))
    }
}
