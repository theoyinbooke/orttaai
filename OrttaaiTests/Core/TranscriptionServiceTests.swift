// TranscriptionServiceTests.swift
// OrttaaiTests

import XCTest
import WhisperKit
@testable import Orttaai

final class TranscriptionServiceTests: XCTestCase {
    func testMergedTranscriptionTextJoinsAllChunks() {
        let timings = TranscriptionTimings()
        let results = [
            TranscriptionResult(
                text: "So my next test is to actually try this out",
                segments: [],
                language: "en",
                timings: timings
            ),
            TranscriptionResult(
                text: "so that I can record for way up to 60 seconds",
                segments: [],
                language: "en",
                timings: timings
            ),
            TranscriptionResult(
                text: "and see whether it gets cut off or not.",
                segments: [],
                language: "en",
                timings: timings
            )
        ]

        let merged = TranscriptionService.mergedTranscriptionText(from: results)

        XCTAssertEqual(
            merged,
            "So my next test is to actually try this out so that I can record for way up to 60 seconds and see whether it gets cut off or not."
        )
    }

    func testMergedTranscriptionTextIgnoresEmptyChunks() {
        let timings = TranscriptionTimings()
        let results = [
            TranscriptionResult(text: "  Hello world  ", segments: [], language: "en", timings: timings),
            TranscriptionResult(text: " ", segments: [], language: "en", timings: timings),
            TranscriptionResult(text: "\nfrom Orttaai\n", segments: [], language: "en", timings: timings)
        ]

        let merged = TranscriptionService.mergedTranscriptionText(from: results)

        XCTAssertEqual(merged, "Hello world from Orttaai")
    }

    func testNormalizedTranscriptionTextRemovesBlankAudioMarker() {
        let normalized = TranscriptionService.normalizedTranscriptionText("[BLANK_AUDIO] you")

        XCTAssertEqual(normalized, "you")
    }

    func testMergedLiveTranscriptJoinsCommittedClipsAndTail() {
        let merged = TranscriptionService.mergedLiveTranscript(
            committedTexts: ["First clip of speech.", "Second clip continues"],
            tailText: "and the tail wraps up."
        )

        XCTAssertEqual(merged, "First clip of speech. Second clip continues and the tail wraps up.")
    }

    func testMergedLiveTranscriptSkipsEmptyClipsAndMissingTail() {
        let merged = TranscriptionService.mergedLiveTranscript(
            committedTexts: ["  Speech before silence  ", " ", "[BLANK_AUDIO]"],
            tailText: nil
        )

        XCTAssertEqual(merged, "Speech before silence")
    }

    func testMergedLiveTranscriptReturnsNilWhenEverythingIsEmpty() {
        let merged = TranscriptionService.mergedLiveTranscript(
            committedTexts: [" ", "[BLANK_AUDIO]"],
            tailText: "  "
        )

        XCTAssertNil(merged)
    }

    func testSpeculativeReuseRejectedForLongAudio() {
        let rejectionReason = TranscriptionService.speculativeReuseRejectionReason(
            for: "This sounded plausible",
            finalSampleCount: 16_000 * 40
        )

        XCTAssertNotNil(rejectionReason)
    }

    func testSpeculativeReuseAllowedForShortPlausibleAudio() {
        let rejectionReason = TranscriptionService.speculativeReuseRejectionReason(
            for: "This sounded plausible",
            finalSampleCount: 16_000 * 6
        )

        XCTAssertNil(rejectionReason)
    }

    func testRelaxedDecodingOptionsDisableSilenceHeuristics() {
        let options = DecodingOptions(
            temperature: 0.0,
            temperatureFallbackCount: 1,
            topK: 3,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            firstTokenLogProbThreshold: -1.5,
            noSpeechThreshold: 0.65,
            chunkingStrategy: .vad
        )

        let relaxed = TranscriptionService.relaxedDecodingOptions(from: options)

        XCTAssertEqual(relaxed.chunkingStrategy, ChunkingStrategy.none)
        XCTAssertNil(relaxed.noSpeechThreshold)
        XCTAssertNil(relaxed.logProbThreshold)
        XCTAssertNil(relaxed.compressionRatioThreshold)
        XCTAssertNil(relaxed.firstTokenLogProbThreshold)
        XCTAssertGreaterThanOrEqual(relaxed.temperatureFallbackCount, 3)
        XCTAssertGreaterThanOrEqual(relaxed.topK, 5)
    }

    func testFinalTranscriptionOptionsUseFixedDecodeClips() {
        let options = DecodingOptions(
            temperature: 0.0,
            temperatureFallbackCount: 1,
            topK: 3,
            chunkingStrategy: .vad
        )

        let finalOptions = TranscriptionService.finalTranscriptionOptions(
            from: options,
            sampleCount: 16_000 * 32
        )

        XCTAssertEqual(finalOptions.chunkingStrategy, ChunkingStrategy.none)
        XCTAssertEqual(finalOptions.clipTimestamps, [0, 15, 15, 30, 30, 32])
    }

    func testShortFinalTranscriptionDoesNotForceClips() {
        let options = DecodingOptions(
            temperature: 0.0,
            temperatureFallbackCount: 1,
            topK: 3,
            chunkingStrategy: .vad
        )

        let finalOptions = TranscriptionService.finalTranscriptionOptions(
            from: options,
            sampleCount: 16_000 * 12
        )

        XCTAssertEqual(finalOptions.chunkingStrategy, ChunkingStrategy.none)
        XCTAssertTrue(finalOptions.clipTimestamps.isEmpty)
    }

    func testNoTranscriptionResultErrorUsesExpectedDescription() {
        let error = TranscriptionService.noTranscriptionResultError()

        guard case .transcriptionFailed(let underlying) = error else {
            return XCTFail("Expected transcriptionFailed error")
        }

        XCTAssertEqual(underlying.localizedDescription, "No transcription result")
    }

    // MARK: - Energy helpers

    private func silence(seconds: Double, amplitude: Float = 0) -> [Float] {
        [Float](repeating: amplitude, count: Int(seconds * 16_000))
    }

    private func speech(seconds: Double, amplitude: Float = 0.1) -> [Float] {
        let count = Int(seconds * 16_000)
        return (0..<count).map { amplitude * sin(Float($0) * 0.1) }
    }

    func testContainsSpeechEnergyDetectsSpeechBurst() {
        let samples = silence(seconds: 1) + speech(seconds: 0.3) + silence(seconds: 1)

        XCTAssertTrue(TranscriptionService.containsSpeechEnergy(samples[...]))
    }

    func testContainsSpeechEnergyIgnoresSilenceAndFaintNoise() {
        XCTAssertFalse(TranscriptionService.containsSpeechEnergy(silence(seconds: 2)[...]))
        XCTAssertFalse(
            TranscriptionService.containsSpeechEnergy(silence(seconds: 2, amplitude: 0.01)[...])
        )
    }

    func testLastSpeechSampleIndexCoversSpeechEnd() {
        let leading = silence(seconds: 1)
        let talk = speech(seconds: 2)
        let samples = leading + talk + silence(seconds: 3)

        let lastIndex = TranscriptionService.lastSpeechSampleIndex(in: samples[...])

        let speechEnd = leading.count + talk.count
        XCTAssertNotNil(lastIndex)
        XCTAssertGreaterThanOrEqual(lastIndex ?? 0, speechEnd)
        XCTAssertLessThan(lastIndex ?? 0, speechEnd + TranscriptionService.energyFrameSampleCount)
    }

    func testLastSpeechSampleIndexWorksOnSlices() {
        let samples = speech(seconds: 1) + silence(seconds: 2)
        let slice = samples[16_000...]

        XCTAssertNil(TranscriptionService.lastSpeechSampleIndex(in: slice))
    }

    // MARK: - Speculative coverage

    func testCoverageSufficientWithinSlack() {
        let samples = speech(seconds: 10)

        XCTAssertTrue(TranscriptionService.speculativeCoverageIsSufficient(
            coveredSampleCount: samples.count - 4_000,
            audioSamples: samples
        ))
    }

    func testCoverageSufficientWhenRemainderIsSilence() {
        let talk = speech(seconds: 8)
        let samples = talk + silence(seconds: 2)

        XCTAssertTrue(TranscriptionService.speculativeCoverageIsSufficient(
            coveredSampleCount: talk.count,
            audioSamples: samples
        ))
    }

    func testCoverageInsufficientWhenRemainderHasSpeech() {
        let covered = speech(seconds: 6)
        let samples = covered + silence(seconds: 1) + speech(seconds: 2)

        XCTAssertFalse(TranscriptionService.speculativeCoverageIsSufficient(
            coveredSampleCount: covered.count,
            audioSamples: samples
        ))
    }

    // MARK: - Tail trimming

    func testTrimmedTailAudioRemovesDeadSilenceAroundSpeech() {
        let talk = speech(seconds: 3)
        let samples = silence(seconds: 2) + talk + silence(seconds: 4)

        let trimmed = TranscriptionService.trimmedTailAudio(from: samples)

        let pad = TranscriptionService.silencePadSampleCount
        let frame = TranscriptionService.energyFrameSampleCount
        XCTAssertLessThanOrEqual(trimmed.count, talk.count + 2 * pad + 2 * frame)
        XCTAssertGreaterThanOrEqual(trimmed.count, talk.count)
    }

    func testTrimmedTailAudioKeepsQuietAudioUnchanged() {
        // Quiet (above the faint floor, below the VAD threshold) audio must
        // never be discarded by trimming.
        let samples = silence(seconds: 4, amplitude: 0.01)

        let trimmed = TranscriptionService.trimmedTailAudio(from: samples)

        XCTAssertEqual(trimmed.count, samples.count)
    }

    func testTrimmedTailAudioReturnsEmptyForDeadSilence() {
        let trimmed = TranscriptionService.trimmedTailAudio(from: silence(seconds: 5))

        XCTAssertTrue(trimmed.isEmpty)
    }

    func testTrimmedTailAudioSkipsTinySavings() {
        let samples = speech(seconds: 3) + silence(seconds: 0.2)

        let trimmed = TranscriptionService.trimmedTailAudio(from: samples)

        XCTAssertEqual(trimmed.count, samples.count)
    }

    // MARK: - Pause commits

    func testPauseCommitAfterSpeechAndSustainedSilence() {
        let talk = speech(seconds: 4)
        let samples = talk + silence(seconds: 1.5)

        let commitCount = TranscriptionService.pauseCommitSampleCount(pendingAudio: samples[...])

        let pad = TranscriptionService.silencePadSampleCount
        let frame = TranscriptionService.energyFrameSampleCount
        XCTAssertNotNil(commitCount)
        XCTAssertGreaterThanOrEqual(commitCount ?? 0, talk.count)
        XCTAssertLessThanOrEqual(commitCount ?? 0, talk.count + pad + frame)
    }

    func testPauseCommitSkippedWhileStillSpeaking() {
        let samples = speech(seconds: 6) + silence(seconds: 0.3)

        XCTAssertNil(TranscriptionService.pauseCommitSampleCount(pendingAudio: samples[...]))
    }

    func testPauseCommitSkippedForShortClips() {
        let samples = speech(seconds: 1) + silence(seconds: 2)

        XCTAssertNil(TranscriptionService.pauseCommitSampleCount(pendingAudio: samples[...]))
    }

    func testPauseCommitSkippedForPureSilence() {
        XCTAssertNil(TranscriptionService.pauseCommitSampleCount(pendingAudio: silence(seconds: 6)[...]))
    }
}
