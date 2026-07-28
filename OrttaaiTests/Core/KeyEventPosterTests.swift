// KeyEventPosterTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class KeyEventPosterTests: XCTestCase {
    private func isHighSurrogate(_ unit: UInt16) -> Bool {
        (0xD800...0xDBFF).contains(unit)
    }

    private func isLowSurrogate(_ unit: UInt16) -> Bool {
        (0xDC00...0xDFFF).contains(unit)
    }

    func testAsciiChunksAtFixedLength() {
        let text = String(repeating: "a", count: 45)
        let chunks = CGKeyEventPoster.typedTextChunks(text)
        XCTAssertEqual(chunks.map(\.count), [20, 20, 5])
    }

    func testChunksConcatenateToOriginalUTF16() {
        let text = "Hello 😀 world — 👨‍👩‍👧‍👦 café ﷺ 𝒜𝓁𝑔𝑒𝒷𝓇𝒶 🇳🇬 done."
        let chunks = CGKeyEventPoster.typedTextChunks(text)
        XCTAssertEqual(chunks.flatMap { $0 }, Array(text.utf16))
    }

    func testSurrogatePairAtOldChunkBoundaryIsNotSplit() {
        // 19 ASCII units followed by a 2-unit emoji: the old fixed-20 slicing
        // put the high surrogate at index 19 and the low surrogate in the
        // next chunk, producing U+FFFD in the target app.
        let text = String(repeating: "a", count: 19) + "😀"
        let chunks = CGKeyEventPoster.typedTextChunks(text)
        XCTAssertEqual(chunks.map(\.count), [19, 2])
        for chunk in chunks {
            XCTAssertFalse(isHighSurrogate(chunk.last!), "No chunk may end with an unpaired high surrogate")
            XCTAssertFalse(isLowSurrogate(chunk.first!), "No chunk may start with an unpaired low surrogate")
        }
    }

    func testEmojiRunNeverSplitsSurrogatePairs() {
        let text = String(repeating: "😀", count: 15) // 30 UTF-16 units
        let chunks = CGKeyEventPoster.typedTextChunks(text)
        for chunk in chunks {
            XCTAssertFalse(isHighSurrogate(chunk.last!))
            XCTAssertFalse(isLowSurrogate(chunk.first!))
            let decoded = String(decoding: chunk, as: UTF16.self)
            XCTAssertFalse(decoded.contains("\u{FFFD}"), "Chunk must decode cleanly on its own")
        }
        XCTAssertEqual(chunks.flatMap { $0 }, Array(text.utf16))
    }

    func testGraphemeClusterLargerThanLimitStaysWhole() {
        // Family emoji is an 11-unit ZWJ sequence — larger than a limit of 4.
        let family = "👨‍👩‍👧‍👦"
        let text = "ab\(family)cd"
        let chunks = CGKeyEventPoster.typedTextChunks(text, maxUTF16Length: 4)
        XCTAssertTrue(
            chunks.contains { $0 == Array(family.utf16) },
            "An oversized cluster is emitted whole as its own chunk, never split"
        )
        XCTAssertEqual(chunks.flatMap { $0 }, Array(text.utf16))
    }

    func testEmptyStringProducesNoChunks() {
        XCTAssertTrue(CGKeyEventPoster.typedTextChunks("").isEmpty)
    }

    func testEveryChunkRespectsLimitExceptOversizedClusters() {
        let text = "The quick brown 🦊 jumps over the lazy 🐶 — 12345 👍🏽"
        let chunks = CGKeyEventPoster.typedTextChunks(text)
        for chunk in chunks {
            if chunk.count > CGKeyEventPoster.typedChunkLength {
                // Only allowed when the chunk is a single grapheme cluster.
                let decoded = String(decoding: chunk, as: UTF16.self)
                XCTAssertEqual(decoded.count, 1, "Only a single oversized cluster may exceed the limit")
            }
        }
    }
}
