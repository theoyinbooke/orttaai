import XCTest
import WhisperKit
@testable import Orttaai

final class DecodeAccuracyTests: XCTestCase {
    private let rate = 16_000

    private func audio(_ seconds: Double, amplitude: Float = 0.1) -> [Float] {
        [Float](repeating: amplitude, count: Int(seconds * Double(rate)))
    }

    func testClipBoundaryUsesLatestPauseAndKeepsPaddingOnBothSides() {
        let samples = audio(12) + audio(0.2, amplitude: 0) + audio(1)
            + audio(0.4, amplitude: 0) + audio(1.4)
        let boundary = TranscriptionService.decodeClipSampleCount(pendingAudio: samples[...])
        XCTAssertEqual(boundary, Int(13.5 * Double(rate)))
        XCTAssertTrue(samples[(boundary - rate / 10)..<(boundary + rate / 10)].allSatisfy { $0 == 0 })
    }

    func testClipBoundaryDoesNotTreatQuietSpeechAsAPause() {
        for amplitude: Float in [0.01, 0.008] {
            let samples = audio(12) + audio(3, amplitude: amplitude)
            XCTAssertEqual(TranscriptionService.decodeClipSampleCount(pendingAudio: samples[...]), 15 * rate)
        }
    }

    func testClipBoundaryIgnoresBriefGapsAndPausesOutsideSearchWindow() {
        let samples = audio(10) + audio(0.5, amplitude: 0) + audio(3)
            + audio(0.1, amplitude: 0) + audio(1.4)
        XCTAssertEqual(TranscriptionService.decodeClipSampleCount(pendingAudio: samples[...]), 15 * rate)
    }

    func testClipBoundaryIsRelativeToAnAlreadyCommittedPrefix() {
        let prefix = audio(2)
        let samples = prefix + audio(13) + audio(0.4, amplitude: 0) + audio(1.6)
        XCTAssertEqual(
            TranscriptionService.decodeClipSampleCount(pendingAudio: samples[prefix.count...]),
            Int(13.3 * Double(rate))
        )
    }

    func testPauseAlignedFinalClipsCoverEverySampleWithoutOverlap() {
        let samples = audio(13) + audio(0.4, amplitude: 0) + audio(14)
            + audio(0.4, amplitude: 0) + audio(4.2)
        let options = TranscriptionService.finalTranscriptionOptions(
            from: DecodingOptions(chunkingStrategy: .vad), audioSamples: samples
        )
        XCTAssertEqual(options.chunkingStrategy, ChunkingStrategy.none)
        XCTAssertEqual(options.clipTimestamps, [0, 13.3, 13.3, 27.7, 27.7, 32])
    }

    func testPauseAlignedClipsStillFoldAnUndecodableRemainder() {
        let samples = audio(13) + audio(0.4, amplitude: 0) + audio(0.6)
            + audio(0.4, amplitude: 0) + audio(1.4)
        // The latest gap gives 14.3s, leaving only 1.5s. It can decode.
        XCTAssertEqual(TranscriptionService.decodeClipTimestamps(audioSamples: samples), [0, 14.3, 14.3, 15.8])
        let shortened = Array(samples.dropLast(rate / 10))
        XCTAssertEqual(TranscriptionService.decodeClipTimestamps(audioSamples: shortened), [0, 15.7])
    }

    func testEmptyLiveDecodeCannotCommitOverLoudOrQuietSpeech() {
        for amplitude: Float in [0.1, 0.01] {
            XCTAssertNil(TranscriptionService.liveCommitText(decodedText: nil, audioSamples: audio(3, amplitude: amplitude)))
            XCTAssertNil(TranscriptionService.liveCommitText(decodedText: "[BLANK_AUDIO]", audioSamples: audio(3, amplitude: amplitude)))
        }
    }

    func testEmptyLiveDecodeCanAdvanceOverDeadSilence() {
        XCTAssertEqual(TranscriptionService.liveCommitText(decodedText: nil, audioSamples: audio(3, amplitude: 0)), "")
        XCTAssertEqual(TranscriptionService.liveCommitText(decodedText: " Hello. ", audioSamples: audio(3)), "Hello.")
    }

    func testPauseCommitWaitsUntilQuietFinalWordHasFinished() {
        let samples = audio(3) + audio(0.6, amplitude: 0.012) + audio(0.3, amplitude: 0)
        XCTAssertNil(TranscriptionService.pauseCommitSampleCount(pendingAudio: samples[...]))
        let finished = samples + audio(0.5, amplitude: 0)
        let boundary = TranscriptionService.pauseCommitSampleCount(pendingAudio: finished[...])
        XCTAssertNotNil(boundary)
        XCTAssertGreaterThanOrEqual(boundary ?? 0, Int(3.6 * Double(rate)))
    }

    func testQuietWordResumingAfterALoudPhraseIsNotDiscardedAsAPause() {
        let samples = audio(3) + audio(0.4, amplitude: 0)
            + audio(0.4, amplitude: 0.01) + audio(0.3, amplitude: 0)
        XCTAssertNil(TranscriptionService.pauseCommitSampleCount(pendingAudio: samples[...]))
    }

    func testPauseCommitDoesNotTreatPotentialQuietSpeechAsProofOfSilence() {
        let samples = audio(3) + audio(1.2, amplitude: 0.012)
        XCTAssertNil(TranscriptionService.pauseCommitSampleCount(pendingAudio: samples[...]))
        XCTAssertNil(TranscriptionService.pauseCommitSampleCount(pendingAudio: audio(5, amplitude: 0.01)[...]))
    }

    func testBackgroundNoiseCanStillProduceAnEarlyPauseCommit() {
        let samples = audio(3) + audio(1.2, amplitude: 0.006)
        XCTAssertNotNil(TranscriptionService.pauseCommitSampleCount(pendingAudio: samples[...]))
        XCTAssertLessThan(TranscriptionService.pauseEnergyThreshold(in: samples[...]), 0.01)
    }

    func testNoiseAwareClipBoundaryPreservesQuietSpeechAfterAPause() {
        let samples = audio(13) + audio(0.4, amplitude: 0.006) + audio(1.6, amplitude: 0.012)
        XCTAssertEqual(TranscriptionService.decodeClipSampleCount(pendingAudio: samples[...]), Int(13.3 * Double(rate)))
    }

    private func preferences(expertOverridesEnabled: Bool) -> DecodingPreferences {
        DecodingPreferences(
            preset: .accuracy, expertOverridesEnabled: expertOverridesEnabled,
            temperature: 0.4, topK: 9, fallbackCount: 4,
            compressionRatioThreshold: 2.9, logProbThreshold: -1.4,
            noSpeechThreshold: 0.45, workerCount: 2
        )
    }

    func testAccuracyStartsGreedilyAndKeepsQualityFallbacks() async {
        let service = TranscriptionService()
        await service.updateSettings(language: "en", computeMode: "cpuAndNeuralEngine", lowLatencyMode: false,
                                     decodingPreferences: preferences(expertOverridesEnabled: false))
        let options = await service.makeDecodingOptions()
        XCTAssertEqual(options.temperature, 0)
        XCTAssertEqual(options.temperatureFallbackCount, 5)
        XCTAssertEqual(options.compressionRatioThreshold, 2.4)
        XCTAssertEqual(options.logProbThreshold, -1)
        XCTAssertEqual(options.noSpeechThreshold, 0.6)
        XCTAssertFalse(options.wordTimestamps)
    }

    func testExplicitExpertSamplingSettingsStillTakePrecedence() async {
        let service = TranscriptionService()
        await service.updateSettings(language: "en", computeMode: "cpuAndNeuralEngine", lowLatencyMode: false,
                                     decodingPreferences: preferences(expertOverridesEnabled: true))
        let options = await service.makeDecodingOptions()
        XCTAssertEqual(options.temperature, 0.4)
        XCTAssertEqual(options.topK, 9)
        XCTAssertEqual(options.temperatureFallbackCount, 4)
        XCTAssertEqual(options.concurrentWorkerCount, 2)
    }
}
