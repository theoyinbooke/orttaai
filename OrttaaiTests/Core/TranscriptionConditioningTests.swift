// TranscriptionConditioningTests.swift
// OrttaaiTests
//
// Fast unit tests (no model, no audio) for the decode-conditioning logic:
// prompt token budgeting/truncation, the drop-conditioning-on-fallback guard,
// the degenerate-repetition detector, and bias-term snapshot normalization.

import XCTest
import WhisperKit
@testable import Orttaai

final class TranscriptionConditioningTests: XCTestCase {
    /// One token per whitespace-separated word; ids count upward from 0.
    /// Deterministic and cheap — the real tokenizer is irrelevant to budget
    /// arithmetic.
    private func wordEncoder(_ text: String) -> [Int] {
        let count = text.split(whereSeparator: { $0 == " " || $0 == "," }).count
        return Array(0..<count)
    }

    private let specialTokenBegin = 50_000

    // MARK: - Bias term normalization (snapshot/dedup/cap)

    func testNormalizedBiasTermsDedupesCaseInsensitivelyKeepingFirstSpelling() {
        let terms = TranscriptionService.normalizedBiasTerms(
            ["WhisperKit", "whisperkit", "GRDB", "grdb", "GRDB"]
        )
        XCTAssertEqual(Set(terms), Set(["WhisperKit", "GRDB"]))
    }

    func testNormalizedBiasTermsDropsEmptyAndTrimsWhitespace() {
        let terms = TranscriptionService.normalizedBiasTerms(["  Olanrewaju  ", "", "   ", "\n"])
        XCTAssertEqual(terms, ["Olanrewaju"])
    }

    func testNormalizedBiasTermsOrdersLongestFirstAndCaps() {
        let input = (1...50).map { String(repeating: "a", count: $0) }
        let terms = TranscriptionService.normalizedBiasTerms(input)
        XCTAssertEqual(terms.count, TranscriptionService.maxBiasTermCount)
        // Longest-first: the longest survives the cap, the shortest do not.
        XCTAssertEqual(terms.first?.count, 50)
        XCTAssertEqual(terms.last?.count, 50 - TranscriptionService.maxBiasTermCount + 1)
    }

    // MARK: - Prompt token budget / truncation

    func testConditioningPromptEmptyInputsProduceNil() {
        let tokens = TranscriptionService.conditioningPromptTokens(
            biasTerms: [],
            contextText: "   ",
            encode: wordEncoder,
            specialTokenBegin: specialTokenBegin
        )
        XCTAssertNil(tokens)
    }

    func testConditioningPromptContextIsTokenSuffixCappedToBudget() {
        let longContext = (1...500).map { "word\($0)" }.joined(separator: " ")
        let tokens = TranscriptionService.conditioningPromptTokens(
            biasTerms: [],
            contextText: longContext,
            encode: wordEncoder,
            specialTokenBegin: specialTokenBegin
        )
        XCTAssertEqual(tokens?.count, TranscriptionService.maxContextPromptTokenCount)
    }

    func testConditioningPromptTotalNeverExceedsBudgetAndStaysUnderWhisperKitCap() throws {
        let manyTerms = (1...60).map { "term\($0)" }
        let longContext = (1...500).map { "word\($0)" }.joined(separator: " ")
        let tokens = TranscriptionService.conditioningPromptTokens(
            biasTerms: manyTerms,
            contextText: longContext,
            encode: wordEncoder,
            specialTokenBegin: specialTokenBegin
        )
        let count = try XCTUnwrap(tokens).count
        XCTAssertLessThanOrEqual(count, TranscriptionService.maxPromptTokenCount)
        // WhisperKit suffix-trims prompts longer than maxTokenContext/2 - 1
        // (111 in the pinned build), which would silently drop the bias terms
        // at the front. The budget must keep us under that cap.
        XCTAssertLessThanOrEqual(count, Constants.maxTokenContext / 2 - 1)
    }

    func testConditioningPromptBiasTermsSurviveLongContext() throws {
        // Bias is fitted before context: even with a huge session transcript
        // the user's vocabulary keeps its budget and the context tail shrinks
        // to whatever remains of the total.
        let biasTerms = (1...10).map { "term\($0)" } // 10 tokens under wordEncoder
        let longContext = (1...500).map { "word\($0)" }.joined(separator: " ")
        let tokens = try XCTUnwrap(TranscriptionService.conditioningPromptTokens(
            biasTerms: biasTerms,
            contextText: longContext,
            encode: wordEncoder,
            specialTokenBegin: specialTokenBegin
        ))
        XCTAssertEqual(tokens.count, TranscriptionService.maxPromptTokenCount)
        let biasOnly = try XCTUnwrap(TranscriptionService.conditioningPromptTokens(
            biasTerms: biasTerms,
            contextText: "",
            encode: wordEncoder,
            specialTokenBegin: specialTokenBegin
        ))
        // All 10 terms fit the bias budget, so the combined prompt is the
        // full bias sentence plus a context suffix filling the remainder.
        XCTAssertEqual(biasOnly.count, 10)
        XCTAssertEqual(
            tokens.count - biasOnly.count,
            TranscriptionService.maxPromptTokenCount - 10
        )
    }

    func testConditioningPromptDropsWholeTermsThatOverflowBiasBudget() {
        // Each term encodes to one token; budget for bias with empty context
        // is the full total. A giant term list gets cut at whole-term
        // boundaries, never mid-term: with a 5-word term in front, the
        // count reflects whole terms only.
        let terms = ["giant term that is five tokens", "small"]
        let tokens = TranscriptionService.conditioningPromptTokens(
            biasTerms: terms,
            contextText: "",
            encode: wordEncoder,
            specialTokenBegin: specialTokenBegin,
            maxTotalTokens: 3,
            maxContextTokens: 0
        )
        // "giant term..." alone is 6 words -> never fits in 3; "small." fits.
        XCTAssertEqual(tokens?.count, 1)
    }

    func testConditioningPromptFiltersSpecialTokens() {
        let encoderWithSpecials: (String) -> [Int] = { text in
            // Simulates a tokenizer that wraps output in special markers.
            [50_257] + self.wordEncoder(text) + [50_256]
        }
        let tokens = TranscriptionService.conditioningPromptTokens(
            biasTerms: ["Orttaai"],
            contextText: "hello world",
            encode: encoderWithSpecials,
            specialTokenBegin: specialTokenBegin
        )
        XCTAssertEqual(tokens?.filter { $0 >= specialTokenBegin }.count, 0)
    }

    // MARK: - Drop-conditioning-on-fallback guard

    func testLivePromptTokensNilWhenPreviousDecodeTrippedFallback() {
        let tokens = TranscriptionService.livePromptTokens(
            biasTerms: ["Orttaai"],
            committedTexts: ["some committed text"],
            lastDecodeTrippedFallback: true,
            encode: wordEncoder,
            specialTokenBegin: specialTokenBegin
        )
        XCTAssertNil(tokens)
    }

    func testLivePromptTokensPresentWhenPreviousDecodeWasClean() {
        let tokens = TranscriptionService.livePromptTokens(
            biasTerms: ["Orttaai"],
            committedTexts: ["some committed text"],
            lastDecodeTrippedFallback: false,
            encode: wordEncoder,
            specialTokenBegin: specialTokenBegin
        )
        XCTAssertNotNil(tokens)
    }

    // MARK: - Fallback detection from decode results

    private func segment(
        temperature: Float = 0,
        avgLogprob: Float = -0.3,
        compressionRatio: Float = 1.4
    ) -> TranscriptionSegment {
        TranscriptionSegment(
            temperature: temperature,
            avgLogprob: avgLogprob,
            compressionRatio: compressionRatio
        )
    }

    func testDecodeTrippedFallbackOnTemperatureBump() {
        XCTAssertTrue(TranscriptionService.decodeTrippedFallback(
            segments: [segment(temperature: 0.2)],
            baseTemperature: 0,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0
        ))
    }

    func testDecodeTrippedFallbackOnCompressionRatio() {
        XCTAssertTrue(TranscriptionService.decodeTrippedFallback(
            segments: [segment(compressionRatio: 2.5)],
            baseTemperature: 0,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0
        ))
    }

    func testDecodeTrippedFallbackOnLowLogProb() {
        XCTAssertTrue(TranscriptionService.decodeTrippedFallback(
            segments: [segment(avgLogprob: -1.4)],
            baseTemperature: 0,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0
        ))
    }

    func testDecodeCleanSegmentsDoNotTripFallback() {
        XCTAssertFalse(TranscriptionService.decodeTrippedFallback(
            segments: [segment(), segment()],
            baseTemperature: 0,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0
        ))
    }

    func testDecodeTrippedFallbackIgnoresDisabledThresholds() {
        XCTAssertFalse(TranscriptionService.decodeTrippedFallback(
            segments: [segment(avgLogprob: -2.5, compressionRatio: 3.0)],
            baseTemperature: 0,
            compressionRatioThreshold: nil,
            logProbThreshold: nil
        ))
    }

    // MARK: - Degenerate repetition detector

    func testRepetitionDetectorFlagsUnigramLoop() {
        XCTAssertTrue(TranscriptionService.hasDegenerateRepetition(
            in: "the the the the the end"
        ))
    }

    func testRepetitionDetectorFlagsBigramLoop() {
        XCTAssertTrue(TranscriptionService.hasDegenerateRepetition(
            in: "I said hello world hello world hello world hello world"
        ))
    }

    func testRepetitionDetectorFlagsTrigramLoop() {
        XCTAssertTrue(TranscriptionService.hasDegenerateRepetition(
            in: "send it now send it now send it now please"
        ))
    }

    func testRepetitionDetectorAllowsDeliberateRepeats() {
        XCTAssertFalse(TranscriptionService.hasDegenerateRepetition(
            in: "No no no, that is not what I meant at all."
        ))
        XCTAssertFalse(TranscriptionService.hasDegenerateRepetition(
            in: "The demo was very very very slow yesterday afternoon."
        ))
        XCTAssertFalse(TranscriptionService.hasDegenerateRepetition(
            in: "We waited and waited and waited for the response, and it never came."
        ))
    }

    func testRepetitionDetectorAllowsNormalProse() {
        XCTAssertFalse(TranscriptionService.hasDegenerateRepetition(
            in: "Good morning team, here is the plan for the week and the priorities."
        ))
    }

    // MARK: - Relaxed retry never carries conditioning

    func testRelaxedDecodingOptionsClearPromptTokens() {
        var options = DecodingOptions()
        options.promptTokens = [1, 2, 3]
        options.prefixTokens = [4]
        let relaxed = TranscriptionService.relaxedDecodingOptions(from: options)
        XCTAssertNil(relaxed.promptTokens)
        XCTAssertNil(relaxed.prefixTokens)
    }
}
