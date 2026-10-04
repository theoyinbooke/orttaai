// FinalizeTraceTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class FinalizeTraceTests: XCTestCase {
    private let frame = TranscriptionService.energyFrameSampleCount

    // MARK: - Frame RMS statistics

    func testFrameRMSStatisticsOfEmptyInputIsZero() {
        let stats = TranscriptionService.frameRMSStatistics(of: [])

        XCTAssertEqual(stats.peak, 0)
        XCTAssertEqual(stats.median, 0)
    }

    func testFrameRMSStatisticsOfConstantAmplitude() {
        let samples = [Float](repeating: 0.02, count: frame * 5)

        let stats = TranscriptionService.frameRMSStatistics(of: samples)

        XCTAssertEqual(stats.peak, 0.02, accuracy: 1e-6)
        XCTAssertEqual(stats.median, 0.02, accuracy: 1e-6)
    }

    func testFrameRMSStatisticsMedianIgnoresSingleLoudFrame() {
        var samples = [Float](repeating: 0.004, count: frame * 5)
        for index in (frame * 2)..<(frame * 3) {
            samples[index] = 0.5
        }

        let stats = TranscriptionService.frameRMSStatistics(of: samples)

        XCTAssertEqual(stats.peak, 0.5, accuracy: 1e-6)
        XCTAssertEqual(stats.median, 0.004, accuracy: 1e-6)
    }

    func testFrameRMSStatisticsMedianAveragesMiddlePairForEvenFrameCount() {
        let samples = [Float](repeating: 0.01, count: frame)
            + [Float](repeating: 0.03, count: frame)

        let stats = TranscriptionService.frameRMSStatistics(of: samples)

        XCTAssertEqual(stats.peak, 0.03, accuracy: 1e-6)
        XCTAssertEqual(stats.median, 0.02, accuracy: 1e-6)
    }

    func testFrameRMSStatisticsIgnoresTrailingPartialFrame() {
        let samples = [Float](repeating: 0.01, count: frame * 2)
            + [Float](repeating: 0.9, count: frame / 4)

        let stats = TranscriptionService.frameRMSStatistics(of: samples)

        XCTAssertEqual(stats.peak, 0.01, accuracy: 1e-6)
    }

    func testFrameRMSStatisticsMeasuresInputShorterThanOneFrame() {
        let samples = [Float](repeating: 0.25, count: frame / 2)

        let stats = TranscriptionService.frameRMSStatistics(of: samples)

        XCTAssertEqual(stats.peak, 0.25, accuracy: 1e-6)
        XCTAssertEqual(stats.median, 0.25, accuracy: 1e-6)
    }

    // MARK: - Trace encoding

    private func jsonObject(for trace: FinalizeTrace) throws -> [String: Any] {
        let data = try JSONEncoder().encode(trace)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTraceEncodesSimplePathAndFields() throws {
        var trace = FinalizeTrace(totalAudioSeconds: 61.5)
        trace.path = .tailDecoded
        trace.tailSampleCount = 48_000
        trace.tailPeakFrameRMS = 0.03
        trace.relaxedRetryRan = true
        trace.msTailDecode = 812
        trace.msTotal = 900
        trace.committedClipCount = 4
        trace.speculativeCancelled = true

        let object = try jsonObject(for: trace)

        XCTAssertEqual(object["path"] as? String, "tail_decoded")
        XCTAssertNil(object["fallback_reason"])
        XCTAssertEqual(object["tail_sample_count"] as? Int, 48_000)
        XCTAssertEqual(object["relaxed_retry_ran"] as? Bool, true)
        XCTAssertEqual(object["ms_tail_decode"] as? Int, 812)
        XCTAssertEqual(object["ms_total"] as? Int, 900)
        XCTAssertEqual(object["committed_clip_count"] as? Int, 4)
        XCTAssertEqual(object["total_audio_seconds"] as? Double, 61.5)
        XCTAssertEqual(object["speculative_cancelled"] as? Bool, true)
    }

    func testTraceEncodesFallbackReasons() throws {
        var trace = FinalizeTrace()

        trace.path = .wholeFallback(.tailNoResult)
        var object = try jsonObject(for: trace)
        XCTAssertEqual(object["path"] as? String, "whole_fallback")
        XCTAssertEqual(object["fallback_reason"] as? String, "tail_no_result")
        XCTAssertNil(object["integrity_reason"])

        trace.path = .wholeFallback(.integrityRejected("transcript was implausibly short for the recording"))
        object = try jsonObject(for: trace)
        XCTAssertEqual(object["fallback_reason"] as? String, "integrity_rejected")
        XCTAssertEqual(
            object["integrity_reason"] as? String,
            "transcript was implausibly short for the recording"
        )

        trace.path = .wholeFallback(.nothingCommitted)
        object = try jsonObject(for: trace)
        XCTAssertEqual(object["fallback_reason"] as? String, "nothing_committed")
    }

    func testTraceEncodesRemainingPaths() throws {
        var trace = FinalizeTrace()
        let expected: [(FinalizePath, String)] = [
            (.reusedSpeculative, "reused_speculative"),
            (.tailEmptyNoAudio, "tail_empty_no_audio"),
            (.noLiveSession, "no_live_session"),
        ]
        for (path, name) in expected {
            trace.path = path
            XCTAssertEqual(try jsonObject(for: trace)["path"] as? String, name)
        }
    }

    // MARK: - Trace log

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("finalize-trace-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func lines(in url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
    }

    func testLogAppendsOneFlatJSONLinePerTrace() throws {
        let directory = try makeTemporaryDirectory()
        let log = FinalizeTraceLog(directory: directory)
        var trace = FinalizeTrace()
        trace.path = .wholeFallback(.tailNoResult)
        trace.msTotal = 5_400

        log.append(trace, at: Date(timeIntervalSince1970: 0))
        log.append(trace, at: Date(timeIntervalSince1970: 60))

        let written = try lines(in: directory.appendingPathComponent(FinalizeTraceLog.fileName))
        XCTAssertEqual(written.count, 2)
        let first = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(written[0].utf8)) as? [String: Any]
        )
        XCTAssertNotNil(first["ts"] as? String)
        XCTAssertEqual(first["path"] as? String, "whole_fallback")
        XCTAssertEqual(first["ms_total"] as? Int, 5_400)
        XCTAssertEqual(first["kind"] as? String, "finalize")
    }

    func testLogWritesRecordingEndLinesBesideFinalizeLines() throws {
        let directory = try makeTemporaryDirectory()
        let log = FinalizeTraceLog(directory: directory)
        let end = RecordingEndTrace(
            reason: .silenceAutoStop,
            recordingDurationMs: 31_250,
            isHandsFree: true,
            silenceStopSeconds: 4,
            speechFrameCount: 212,
            peakFrameRMS: 0.31,
            trailingSilenceMs: 4_100,
            handsFreeArmed: true,
            silenceThresholdRMS: 0.006
        )

        log.append(FinalizeTrace(), at: Date(timeIntervalSince1970: 0))
        log.append(end, at: Date(timeIntervalSince1970: 60))

        let written = try lines(in: directory.appendingPathComponent(FinalizeTraceLog.fileName))
        XCTAssertEqual(written.count, 2)
        let objects = try written.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(objects[0]["kind"] as? String, "finalize")
        XCTAssertEqual(objects[1]["kind"] as? String, "recording_end")
        XCTAssertEqual(objects[1]["reason"] as? String, "silence_auto_stop")
        XCTAssertEqual(objects[1]["recording_duration_ms"] as? Int, 31_250)
        XCTAssertEqual(objects[1]["mode"] as? String, "hands_free")
        XCTAssertEqual(objects[1]["silence_stop_seconds"] as? Double, 4)
        XCTAssertEqual(objects[1]["speech_frame_count"] as? Int, 212)
        XCTAssertEqual(objects[1]["trailing_silence_ms"] as? Int, 4_100)
        XCTAssertEqual(objects[1]["hands_free_armed"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(objects[1]["silence_threshold_rms"] as? Double), 0.006, accuracy: 0.0001)
        XCTAssertEqual(
            Set(objects[1].keys),
            ["ts", "kind", "reason", "recording_duration_ms", "mode", "silence_stop_seconds",
             "speech_frame_count", "peak_frame_rms", "trailing_silence_ms", "hands_free_armed",
             "silence_threshold_rms"],
            "A recording-end line carries numbers and enums only"
        )
    }

    func testPushToTalkRecordingEndEncodesNullSilenceWindow() throws {
        let end = RecordingEndTrace(
            reason: .holdRelease,
            recordingDurationMs: 8_000,
            isHandsFree: false,
            silenceStopSeconds: nil,
            speechFrameCount: 40,
            peakFrameRMS: 0.2,
            trailingSilenceMs: 300,
            handsFreeArmed: false
        )
        let data = try JSONEncoder().encode(end)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["mode"] as? String, "push_to_talk")
        XCTAssertTrue(object["silence_stop_seconds"] is NSNull)
        XCTAssertTrue(object["silence_threshold_rms"] is NSNull)
    }

    func testLogRotatesOnceSizeCapIsReached() throws {
        let directory = try makeTemporaryDirectory()
        let log = FinalizeTraceLog(directory: directory, maxBytes: 600)
        let trace = FinalizeTrace()

        for index in 0..<12 {
            log.append(trace, at: Date(timeIntervalSince1970: Double(index)))
        }

        let current = directory.appendingPathComponent(FinalizeTraceLog.fileName)
        let rotated = directory.appendingPathComponent(FinalizeTraceLog.rotatedFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path))
        let currentSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: current.path)[.size] as? Int
        )
        let rotatedSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: rotated.path)[.size] as? Int
        )
        XCTAssertLessThanOrEqual(currentSize, 600)
        XCTAssertLessThanOrEqual(rotatedSize, 600)
        // Only the two most recent generations are kept.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    func testLogSwallowsWriteFailures() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("finalize-trace-missing-\(UUID().uuidString)", isDirectory: true)
        let log = FinalizeTraceLog(directory: missing)

        log.append(FinalizeTrace(), at: Date())
        log.record(FinalizeTrace())
        log.flush()

        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}
