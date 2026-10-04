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

    /// Constant-level audio; a frame of it has exactly this RMS.
    private func level(_ rms: Float, seconds: Double) -> [Float] {
        [Float](repeating: rms, count: Int((seconds * Double(sampleRate)).rounded()))
    }

    /// Soft speech below the 0.02 VAD threshold: 300ms syllables at `rms`
    /// separated by 100ms gaps at room noise.
    private func softSpeech(seconds: Double, rms: Float = 0.012, room: Float = 0.002) -> [Float] {
        var samples: [Float] = []
        while Double(samples.count) < seconds * Double(sampleRate) {
            samples += level(rms, seconds: 0.3) + level(room, seconds: 0.1)
        }
        return samples
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

    // MARK: - Quiet speakers

    func testSoftSpeechBelowVADThresholdKeepsRecording() {
        // The 2026-10-04 report: a hands-free session armed on louder speech,
        // then stopped at 52s while the speaker kept talking softly because
        // no frame reached 0.02 RMS for 6s.
        let samples = level(0.002, seconds: 1) + speech(seconds: 1) + softSpeech(seconds: 20)
        XCTAssertFalse(shouldStop(samples, window: 6), "Soft continuous speech is not silence")
    }

    func testSilenceAfterSoftSpeechStillStops() {
        let samples = level(0.002, seconds: 1) + speech(seconds: 1) + softSpeech(seconds: 10)
            + level(0.002, seconds: 6.5)
        XCTAssertTrue(shouldStop(samples, window: 6))
    }

    func testSteadyRoomNoiseStillStops() {
        // Noise below 0.02 but well above the quiet-room threshold: the
        // threshold rises with the measured background, as before.
        let samples = speech(seconds: 1) + level(0.012, seconds: 8)
        XCTAssertTrue(shouldStop(samples, window: 6))
    }

    func testIsolatedClicksDoNotHoldRecordingOpen() {
        var samples = speech(seconds: 1)
        for _ in 0..<7 {
            samples += level(0.012, seconds: 0.1) + silence(seconds: 0.9)
        }
        XCTAssertTrue(shouldStop(samples, window: 6), "One-frame bumps are not voice")
    }

    func testSoftSpeechAloneNeverArms() {
        let scanned = policy(scanning: softSpeech(seconds: 3) + silence(seconds: 6))
        XCTAssertFalse(scanned.isArmed, "Arming still needs speech at the VAD threshold")
    }

    func testSilenceThresholdTracksRoomNoise() {
        XCTAssertEqual(
            policy(scanning: speech(seconds: 1) + silence(seconds: 9)).silenceThresholdRMS,
            TranscriptionService.faintEnergyFloor,
            "Dead silence keeps the floor"
        )
        let quietRoom = policy(scanning: speech(seconds: 1) + level(0.003, seconds: 9)).silenceThresholdRMS
        XCTAssertEqual(quietRoom, 0.003 * 1.8, accuracy: 0.0005)
        XCTAssertEqual(
            policy(scanning: speech(seconds: 1) + level(0.015, seconds: 9)).silenceThresholdRMS,
            TranscriptionService.speechEnergyThreshold,
            "Never stricter than the VAD threshold"
        )
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
