// ExpressLongRecordingTests.swift
// OrttaaiTests

import ExpressAudio
import XCTest
@testable import Orttaai

final class ExpressLongRecordingTests: XCTestCase {
    private let second = 16_000

    // MARK: - Quiet final word

    /// One second of room-level sound, speech at `level`, then the last
    /// `tailSeconds` at `tailLevel`.
    private func recording(seconds: Double, level: Float, tailSeconds: Double, tailLevel: Float) -> [Float] {
        let count = Int(seconds * Double(second))
        let tailStart = count - Int(tailSeconds * Double(second))
        return (0..<count).map { index in
            let amplitude = index < second ? 0.004 : index < tailStart ? level : tailLevel
            return amplitude * sin(Float(index) * 0.07)
        }
    }

    func testEvenRecordingIsUntouched() {
        let audio = recording(seconds: 5, level: 0.2, tailSeconds: 1, tailLevel: 0.2)
        XCTAssertEqual(ExpressAudioConditioner.liftingQuietTail(audio), audio)
    }

    func testQuietLastWordIsLiftedTowardTheRest() {
        let audio = recording(seconds: 5, level: 0.2, tailSeconds: 1, tailLevel: 0.04)
        let lifted = ExpressAudioConditioner.liftingQuietTail(audio)

        XCTAssertEqual(lifted.count, audio.count)
        XCTAssertEqual(Array(lifted.prefix(3 * second)), Array(audio.prefix(3 * second)), "only the last 1.5 s may change")
        let before = audio.suffix(second / 2).map(abs).max() ?? 0
        let after = lifted.suffix(second / 2).map(abs).max() ?? 0
        XCTAssertEqual(after / before, 4, accuracy: 0.01, "lifted by the 4x ceiling")
    }

    func testLiftNeverClips() {
        let audio = recording(seconds: 5, level: 0.9, tailSeconds: 1, tailLevel: 0.3)
        let lifted = ExpressAudioConditioner.liftingQuietTail(audio)
        XCTAssertLessThanOrEqual(lifted.map(abs).max() ?? 0, 1)
        XCTAssertGreaterThan(lifted.suffix(second / 2).map(abs).max() ?? 0, 0.3)
    }

    func testSilenceAndShortRecordingsAreUntouched() {
        let silence = [Float](repeating: 0, count: 4 * second)
        XCTAssertEqual(ExpressAudioConditioner.liftingQuietTail(silence), silence)
        let short = recording(seconds: 1, level: 0.2, tailSeconds: 0.5, tailLevel: 0.02)
        XCTAssertEqual(ExpressAudioConditioner.liftingQuietTail(short), short)
    }

    // MARK: - Word Boost chunks

    func testChunkSizesMatchFluidAudio() {
        if #available(macOS 15, *) {
            XCTAssertEqual(WordBoostChunks.chunkSampleCount, ASRConstants.maxModelSamples)
        }
    }

    func testShortRecordingIsOneChunk() {
        XCTAssertEqual(WordBoostChunks.chunks(forSampleCount: 5 * second), [0..<(5 * second)])
        XCTAssertEqual(WordBoostChunks.chunks(forSampleCount: 15 * second), [0..<(15 * second)])
        XCTAssertEqual(WordBoostChunks.chunks(forSampleCount: 0), [])
    }

    func testLongRecordingIsFifteenSecondChunksEveryThirteen() {
        XCTAssertEqual(
            WordBoostChunks.chunks(forSampleCount: 30 * second),
            [0..<(15 * second), (13 * second)..<(28 * second), (26 * second)..<(30 * second)]
        )
    }

    func testEveryCompleteChunkDuringRecordingIsAChunkOfTheFinishedRecording() {
        for recorded in stride(from: 0, through: 90 * second, by: 3_333) {
            let complete = WordBoostChunks.completeChunks(inPrefixOf: recorded)
            for finished in [recorded, recorded + 1, recorded + 20 * second] {
                let final = Set(WordBoostChunks.chunks(forSampleCount: finished))
                for chunk in complete {
                    XCTAssertTrue(final.contains(chunk), "\(chunk) recorded at \(recorded), finished at \(finished)")
                }
            }
        }
        XCTAssertEqual(WordBoostChunks.completeChunks(inPrefixOf: 15 * second - 1), [])
        XCTAssertEqual(WordBoostChunks.completeChunks(inPrefixOf: 28 * second), [0..<(15 * second), (13 * second)..<(28 * second)])
    }

    func testStitchAveragesOverlappingFramesInProbabilitySpace() {
        // 0.5 s frames: the 2 s overlap is 4 frames.
        let first = (0..<6).map { [Float(-$0), -1] }
        let second = (0..<5).map { [Float(-10 - $0), -2] }
        let stitched = WordBoostChunks.stitch([first, second], frameDuration: 0.5)

        XCTAssertEqual(stitched.count, 6 + 5 - 4)
        XCTAssertEqual(stitched[0], first[0])
        XCTAssertEqual(stitched[1], first[1])
        for offset in 0..<4 {
            let merged = stitched[2 + offset]
            let expected = log((exp(first[2 + offset][0]) + exp(second[offset][0])) / 2)
            XCTAssertEqual(merged[0], expected, accuracy: 1e-5)
            XCTAssertEqual(merged[1], log((exp(Float(-1)) + exp(Float(-2))) / 2), accuracy: 1e-5)
        }
        XCTAssertEqual(stitched[6], second[4])
    }

    func testStitchKeepsASingleChunkAsIs() {
        let frames = (0..<3).map { [Float($0)] }
        XCTAssertEqual(WordBoostChunks.stitch([frames], frameDuration: 0.08), frames)
        XCTAssertEqual(WordBoostChunks.stitch([], frameDuration: 0.08), [])
    }

    func testFingerprintTellsChangedAudioApart() {
        let audio = recording(seconds: 2, level: 0.2, tailSeconds: 1, tailLevel: 0.2)
        var changed = audio
        changed[changed.count - 1] += 0.001
        XCTAssertEqual(WordBoostChunks.fingerprint(audio[...]), WordBoostChunks.fingerprint(Array(audio)[...]))
        XCTAssertNotEqual(WordBoostChunks.fingerprint(audio[...]), WordBoostChunks.fingerprint(changed[...]))
    }
}
