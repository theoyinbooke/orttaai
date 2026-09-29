// HandsFreeAutoStopTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class HandsFreeAutoStopTests: XCTestCase {
    private let sampleRate = HandsFreeAutoStopPolicy.sampleRate

    private func speech(seconds: Double) -> [Float] {
        [Float](repeating: 0.1, count: Int(seconds * Double(sampleRate)))
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(sampleRate)))
    }

    private func policy(scanning samples: [Float]) -> HandsFreeAutoStopPolicy {
        var policy = HandsFreeAutoStopPolicy()
        policy.advance(totalSampleCount: samples.count, samplesFrom: { Array(samples.dropFirst($0)) })
        return policy
    }

    private func shouldStop(
        _ samples: [Float],
        window: TimeInterval = 2.0,
        duration: TimeInterval = 30,
        minimumDuration: TimeInterval = 0.5
    ) -> Bool {
        policy(scanning: samples).shouldStop(
            silenceWindow: window,
            recordingDuration: duration,
            minimumDuration: minimumDuration
        )
    }

    // MARK: - Stop decision

    func testStopsAfterSustainedSpeechThenSilenceWindow() {
        XCTAssertTrue(shouldStop(speech(seconds: 1.0) + silence(seconds: 2.5)))
    }

    func testStopsAtExactSilenceBoundary() {
        XCTAssertTrue(shouldStop(speech(seconds: 1.0) + silence(seconds: 2.0)))
    }

    func testDoesNotStopWhenSilenceTooShort() {
        XCTAssertFalse(shouldStop(speech(seconds: 1.0) + silence(seconds: 1.5)))
    }

    func testDoesNotStopWhenSpeechResumesInsideWindow() {
        let samples = speech(seconds: 1.0) + silence(seconds: 2.5) + speech(seconds: 0.2)
        XCTAssertFalse(shouldStop(samples), "Speech after the pause restarts the trailing-silence window")
    }

    func testSilenceOnlyNeverStops() {
        XCTAssertFalse(
            shouldStop(silence(seconds: 20)),
            "A user still gathering their thoughts keeps the mic open; the cap bounds the session"
        )
    }

    func testSingleTransientFrameDoesNotArm() {
        let samples = speech(seconds: 0.1) + silence(seconds: 6)
        let scanned = policy(scanning: samples)
        XCTAssertEqual(scanned.speechFrameCount, 1)
        XCTAssertFalse(scanned.isArmed)
        XCTAssertFalse(shouldStop(samples))
    }

    func testTwoSpeechFramesStillDoNotArm() {
        XCTAssertFalse(shouldStop(speech(seconds: 0.2) + silence(seconds: 6)))
    }

    func testThreeSpeechFramesArm() {
        XCTAssertTrue(shouldStop(speech(seconds: 0.3) + silence(seconds: 6)))
    }

    func testSpeechFramesAccumulateAcrossPauses() {
        // Two short bursts, each under 300ms, add up to sustained speech.
        let samples = speech(seconds: 0.2) + silence(seconds: 0.5) + speech(seconds: 0.2) + silence(seconds: 3)
        XCTAssertTrue(shouldStop(samples))
    }

    func testQuietButVoicedTailKeepsRecording() {
        // 0.03 RMS is above the 0.02 EnergyVAD threshold: quiet speech, not silence.
        let quietSpeech = [Float](repeating: 0.03, count: sampleRate * 3)
        XCTAssertFalse(shouldStop(speech(seconds: 1.0) + quietSpeech))
    }

    func testHonorsMinimumDuration() {
        let samples = speech(seconds: 0.5) + silence(seconds: 2.5)
        XCTAssertFalse(shouldStop(samples, duration: 0.4))
        XCTAssertTrue(shouldStop(samples, duration: 0.5))
    }

    func testNonPositiveWindowNeverStops() {
        let samples = speech(seconds: 1.0) + silence(seconds: 3.0)
        XCTAssertFalse(shouldStop(samples, window: 0))
        XCTAssertFalse(shouldStop(samples, window: -1))
    }

    // MARK: - Incremental accounting

    func testIncrementalScanMatchesSingleScan() {
        let samples = speech(seconds: 0.7) + silence(seconds: 1.3) + speech(seconds: 0.4) + silence(seconds: 0.9)
        var incremental = HandsFreeAutoStopPolicy()
        var total = 0
        // Uneven chunks that split frames: partial frames must carry over.
        for chunk in [1_000, 5_000, 333, 9_000, 4_100, 20_000] {
            total = min(samples.count, total + chunk)
            incremental.advance(totalSampleCount: total, samplesFrom: { Array(samples.prefix(total).dropFirst($0)) })
        }
        incremental.advance(totalSampleCount: samples.count, samplesFrom: { Array(samples.dropFirst($0)) })

        XCTAssertEqual(incremental, policy(scanning: samples))
    }

    func testAdvanceRequestsOnlyUnscannedSamples() {
        let samples = speech(seconds: 1.0)
        var requestedStarts: [Int] = []
        var policy = HandsFreeAutoStopPolicy()
        policy.advance(totalSampleCount: samples.count, samplesFrom: { start in
            requestedStarts.append(start)
            return Array(samples.dropFirst(start))
        })
        let more = samples + silence(seconds: 1.0)
        policy.advance(totalSampleCount: more.count, samplesFrom: { start in
            requestedStarts.append(start)
            return Array(more.dropFirst(start))
        })
        XCTAssertEqual(requestedStarts, [0, 16_000], "Each poll copies only what was recorded since the last one")
    }

    func testShrunkBufferRestartsAccounting() {
        var policy = policy(scanning: speech(seconds: 1.0) + silence(seconds: 1.0))
        XCTAssertTrue(policy.isArmed)

        let restarted = silence(seconds: 0.5)
        policy.advance(totalSampleCount: restarted.count, samplesFrom: { Array(restarted.dropFirst($0)) })

        XCTAssertFalse(policy.isArmed, "A restarted capture is a fresh buffer")
        XCTAssertEqual(policy.speechFrameCount, 0)
    }

    func testDiagnosticNumbers() {
        let scanned = policy(scanning: speech(seconds: 1.0) + silence(seconds: 2.0))
        XCTAssertEqual(scanned.speechFrameCount, 10)
        XCTAssertEqual(scanned.peakFrameRMS, 0.1, accuracy: 0.001)
        XCTAssertEqual(scanned.trailingSilenceMs, 2_000)
        XCTAssertEqual(policy(scanning: silence(seconds: 1.0)).trailingSilenceMs, 1_000)
    }
}
