// ShortAudioDecodeTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

/// WhisperKit only starts a decode window while more than `windowClipTime`
/// (1s) of clip remains. These tests pin the guards that keep short tails and
/// short trailing clip pieces from silently decoding to nothing.
final class ShortAudioDecodeTests: XCTestCase {
    private let rate = 16_000
    private var minSamples: Int { TranscriptionService.minDecodableSampleCount }

    // MARK: - paddedForDecode

    func testPaddingLeavesEmptyAudioEmpty() {
        XCTAssertTrue(TranscriptionService.paddedForDecode([]).isEmpty)
    }

    func testPaddingExtendsShortAudioWithSilenceAndKeepsSpeechIntact() {
        let speech = [Float](repeating: 0.3, count: 4_000)

        let padded = TranscriptionService.paddedForDecode(speech)

        XCTAssertEqual(padded.count, minSamples)
        XCTAssertEqual(Array(padded.prefix(4_000)), speech)
        XCTAssertTrue(padded.dropFirst(4_000).allSatisfy { $0 == 0 })
    }

    func testPaddingClearsWhisperKitsOneSecondWindowPadding() {
        XCTAssertGreaterThan(minSamples, rate, "Padded audio must exceed WhisperKit's 1s window padding")
    }

    func testPaddingLeavesLongEnoughAudioUntouched() {
        let audio = [Float](repeating: 0.1, count: minSamples)
        XCTAssertEqual(TranscriptionService.paddedForDecode(audio), audio)
    }

    // MARK: - fixedDecodeClipTimestamps

    func testClipTimestampsAreEmptyForSingleWindowAudio() {
        XCTAssertTrue(TranscriptionService.fixedDecodeClipTimestamps(sampleCount: 10 * rate).isEmpty)
        XCTAssertTrue(TranscriptionService.fixedDecodeClipTimestamps(sampleCount: 15 * rate).isEmpty)
    }

    func testClipTimestampsSplitOnTheFifteenSecondGrid() {
        XCTAssertEqual(
            TranscriptionService.fixedDecodeClipTimestamps(sampleCount: 30 * rate),
            [0, 15, 15, 30]
        )
    }

    func testTrailingPieceUnderMinimumIsFoldedIntoThePreviousClip() {
        // A 0.4s remainder would be skipped by WhisperKit and its words lost.
        XCTAssertEqual(
            TranscriptionService.fixedDecodeClipTimestamps(sampleCount: 15 * rate + rate * 4 / 10),
            [0, 15.4]
        )
        XCTAssertEqual(
            TranscriptionService.fixedDecodeClipTimestamps(sampleCount: 30 * rate + rate * 9 / 10),
            [0, 15, 15, 30.9]
        )
    }

    func testTrailingPieceAtOrAboveMinimumKeepsItsOwnClip() {
        XCTAssertEqual(
            TranscriptionService.fixedDecodeClipTimestamps(sampleCount: 30 * rate + rate * 8 / 5),
            [0, 15, 15, 30, 30, 31.6]
        )
    }

    func testEveryClipCoversMoreThanTheWindowPaddingAndTheAudioIsFullyCovered() {
        for tenths in stride(from: 150, through: 1_000, by: 7) {
            let sampleCount = tenths * rate / 10
            let stamps = TranscriptionService.fixedDecodeClipTimestamps(sampleCount: sampleCount)
            guard !stamps.isEmpty else { continue }
            XCTAssertEqual(stamps.count % 2, 0)
            XCTAssertEqual(stamps.first, 0)
            XCTAssertEqual(stamps.last!, Float(sampleCount) / Float(rate), accuracy: 0.0001)
            for pair in stride(from: 0, to: stamps.count, by: 2) {
                XCTAssertGreaterThan(stamps[pair + 1] - stamps[pair], 1.0, "clip \(pair / 2) of \(tenths / 10)s audio is too short to decode")
                if pair > 0 {
                    XCTAssertEqual(stamps[pair], stamps[pair - 1], "clips must be contiguous")
                }
            }
        }
    }

    // MARK: - Non-speech tail handling

    func testStockHallucinationPhrasesAreRecognized() {
        for phrase in ["Thank you.", "you", "  Thanks! ", "Thank you for watching.", "thanks for watching", "Bye."] {
            XCTAssertTrue(TranscriptionService.isStockHallucination(phrase), phrase)
        }
    }

    func testRealSentencesAreNotStockHallucinations() {
        for phrase in ["", ".", "Thank you for the report.", "Thanks, Adebayo.", "you can send it", "Thank you very much"] {
            XCTAssertFalse(TranscriptionService.isStockHallucination(phrase), phrase)
        }
    }

    func testTailCanOnlyBeDroppedBehindCommittedTextAndBelowSpeechEnergy() {
        let speech = TranscriptionService.speechEnergyThreshold
        XCTAssertTrue(TranscriptionService.tailCanBeDropped(tailPeakFrameRMS: 0.008, hasCommittedText: true))
        XCTAssertFalse(TranscriptionService.tailCanBeDropped(tailPeakFrameRMS: speech, hasCommittedText: true))
        XCTAssertFalse(TranscriptionService.tailCanBeDropped(tailPeakFrameRMS: 0.3, hasCommittedText: true))
        XCTAssertFalse(TranscriptionService.tailCanBeDropped(tailPeakFrameRMS: 0.008, hasCommittedText: false))
    }

    func testEmptyAcceptedPathEncodesForTraceLog() throws {
        var trace = FinalizeTrace()
        trace.path = .tailEmptyAccepted
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(trace)) as? [String: Any]
        XCTAssertEqual(json?["path"] as? String, "tail_empty_accepted")
    }
}
