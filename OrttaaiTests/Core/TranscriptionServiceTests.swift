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

    func testNoTranscriptionResultErrorUsesExpectedDescription() {
        let error = TranscriptionService.noTranscriptionResultError()

        guard case .transcriptionFailed(let underlying) = error else {
            return XCTFail("Expected transcriptionFailed error")
        }

        XCTAssertEqual(underlying.localizedDescription, "No transcription result")
    }
}
