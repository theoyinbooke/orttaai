// LinkFixtureTests.swift
// OrttaaiSyncCoreTests
//
// The sample records in Tests/Fixtures/link: one of every kind a linked
// device sends or receives, as Orttaai Link carries it. Orttaai for Windows
// and Linux (Rust) and Orttakey for Android (Kotlin) read the same files and
// must write the same payload JSON, so the four apps can't drift apart.
//
// To write them again after a deliberate change to a payload:
//   ORTTAAI_WRITE_LINK_FIXTURES=1 swift test --filter LinkFixtureTests

import Foundation
import Testing
@testable import OrttaaiSyncCore

@Suite("Orttaai Link sample records")
struct LinkFixtureTests {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/link", directoryHint: .isDirectory)

    static let mac = "6f1d1c9e-1b7a-4c55-9c39-0d3c1e2a7b10"
    static let linux = "2f0c8a4e-7d21-4b9a-a3f6-5e8d9c1b0a42"
    static let windows = "9a3e5b71-0c4d-4f28-8e16-b2d7f4a9c053"
    static let android = "c47b2e90-5a13-4d6e-9f08-71e3a5d2b6c4"
    static let iphone = "e8d4f1a2-36b9-4c07-b5e1-9a0c2f7d84e3"

    static func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + seconds) }
    static func rev(_ counter: Int64, _ writer: String, _ seconds: TimeInterval = 0) -> Revision {
        Revision(counter: counter, modifiedAt: at(seconds), writerDeviceID: writer)
    }

    struct Case: Sendable, CustomStringConvertible {
        var name: String
        var envelope: SyncEnvelope
        var description: String { name }
    }

    static func cases() throws -> [Case] {
        func encode<T: Encodable>(_ value: T) throws -> Data { try PayloadCoder.encode(value) }

        let linuxDictation = DictationPayload(
            createdAt: at(0), text: "Ship the Linux build on Friday.", rawText: "ship the linux build on friday",
            targetAppName: "Claude Code", targetAppBundleID: "claude", modelID: "parakeet-tdt-0.6b-v3",
            recordingMs: 3_400, processingMs: 410, transcriptionMs: 300, textProcessingMs: 12, injectionMs: 40,
            audioDevice: "Built-in Microphone", injectionMethod: "paste", entryKind: "dictation", timeZoneIdentifier: "Europe/London"
        )
        let windowsEdit = DictationPayload(
            createdAt: at(60), text: "Thanks, see you at nine.", targetAppName: "Outlook", recordingMs: 2_100,
            entryKind: "edit", editInstruction: "make it shorter", timeZoneIdentifier: "Africa/Lagos"
        )
        let androidDictation = DictationPayload(createdAt: at(120), text: "Buy plantain and eggs", targetAppName: "Keep", recordingMs: 1_800)
        let word = DictionaryEntryPayload(source: "orta ai", target: "Orttaai", isCaseSensitive: true, createdAt: at(10))
        let snippet = SnippetPayload(trigger: "my address", expansion: "12 Marina Road, Lagos", createdAt: at(20))
        let linuxDevice = DevicePayload(
            deviceID: linux, kind: .linux, name: "ThinkPad", model: "ThinkPad X1 Carbon", app: "Orttaai",
            appVersion: "0.4.0", osVersion: "Ubuntu 26.04", firstSeenAt: at(0), lastSeenAt: at(3_600),
            totals: DeviceTotals(dictations: 12, words: 340, recordingMs: 61_000, firstAt: at(0), lastAt: at(3_500))
        )
        let androidDevice = DevicePayload(
            deviceID: android, kind: .android, name: "Pixel 10 Pro", model: "Pixel 10 Pro", app: "Orttakey",
            appVersion: "1.0.0", osVersion: "Android 17", firstSeenAt: at(0), lastSeenAt: at(600)
        )
        let summary = MacSummaryPayload(
            publisherDeviceID: mac, publisherName: "Mac Studio", asOf: at(7_200), timeZoneIdentifier: "Europe/London",
            coverage: ["Dictations-\(mac)": 40, "Dictations-\(linux)": 12, "Dictations-\(android)": 3],
            totals: DeviceTotals(dictations: 55, words: 1_420, recordingMs: 240_000, firstAt: at(-86_400), lastAt: at(3_500)),
            perDevice: [mac: DeviceTotals(dictations: 40, words: 1_000, recordingMs: 170_000), linux: DeviceTotals(dictations: 12, words: 340, recordingMs: 61_000), android: DeviceTotals(dictations: 3, words: 80, recordingMs: 9_000)],
            recentDays: [DayCount(day: "2026-09-21", dictations: 20, words: 500), DayCount(day: "2026-09-22", dictations: 35, words: 920)],
            topApps: [AppCount(name: "Claude Code", dictations: 30), AppCount(name: "Slack", dictations: 9)]
        )
        let chat = BlobPayload(data: Data(#"{"title":"Release notes","messages":[{"role":"user","text":"What did I say about Linux?"}]}"#.utf8))
        let suggestion = LearningSuggestionPayload(
            type: "dictionary", candidateSource: "orta ai", candidateTarget: "Orttaai", normalizedSource: "orta ai",
            confidence: 0.92, status: "pending", evidence: "Corrected after dictation in Claude Code", createdAt: at(30)
        )
        let insight = WritingInsightPayload(
            generatedAt: at(40), analyzerName: "local-llm", usedFallback: false, isPinned: true, sampleCount: 25,
            requestJSON: #"{"window":"30d"}"#, snapshotJSON: #"{"tone":"direct"}"#
        )

        let linuxZone = SyncZone.dictations(originDeviceID: linux)
        return [
            Case(name: "dictation-linux", envelope: SyncEnvelope(
                id: .dictation(syncID: "1b0d6c3e-9f57-4a2e-8c11-6a4e2d9f3b70", zone: linuxZone), revision: rev(41, linux),
                payload: try encode(linuxDictation), origin: DictationOrigin(deviceID: linux, kind: .linux), createdAt: at(0))),
            Case(name: "dictation-windows-edit", envelope: SyncEnvelope(
                id: .dictation(syncID: "7c2e9a10-4b6d-4f83-a5e2-1d9c0b7f6e34", zone: .dictations(originDeviceID: windows)), revision: rev(7, windows, 60),
                payload: try encode(windowsEdit), origin: DictationOrigin(deviceID: windows, kind: .windows), createdAt: at(60))),
            Case(name: "dictation-android", envelope: SyncEnvelope(
                id: .dictation(syncID: "e3a91f2c-0d7b-4c56-b8e4-29f6a1c0d785", zone: .dictations(originDeviceID: android)), revision: rev(3, android, 120),
                payload: try encode(androidDictation), origin: DictationOrigin(deviceID: android, kind: .android), createdAt: at(120))),
            Case(name: "dictation-iphone", envelope: SyncEnvelope(
                id: .dictation(syncID: "5d8b2f61-a3c9-4e07-9b14-c6e0f3a82d59", zone: .dictations(originDeviceID: iphone)), revision: rev(12, iphone, 90),
                payload: try encode(DictationPayload(createdAt: at(90), text: "On my way", recordingMs: 900)),
                origin: DictationOrigin(deviceID: iphone, kind: .iphone), createdAt: at(90))),
            Case(name: "dictation-linux-deleted", envelope: SyncEnvelope(
                id: .dictation(syncID: "0f4c7e2a-8b19-4d63-a7f5-3e1b9d6c2a08", zone: linuxZone), revision: rev(44, mac, 300),
                isDeleted: true, deletedAt: at(300), payload: nil,
                origin: DictationOrigin(deviceID: linux, kind: .linux), createdAt: at(5))),
            Case(name: "dictionary-entry", envelope: SyncEnvelope(
                id: .dictionaryEntry(normalizedSource: word.normalizedSource), revision: rev(42, linux, 10), payload: try encode(word))),
            Case(name: "dictionary-entry-deleted", envelope: SyncEnvelope(
                id: .dictionaryEntry(normalizedSource: "tolu"), revision: rev(43, android, 200), generation: 1,
                isDeleted: true, deletedAt: at(200), payload: nil)),
            Case(name: "snippet", envelope: SyncEnvelope(
                id: .snippet(normalizedTrigger: snippet.normalizedTrigger), revision: rev(5, windows, 20), payload: try encode(snippet))),
            Case(name: "device-linux", envelope: SyncEnvelope(
                id: .device(linux), revision: rev(45, linux, 3_600), payload: try encode(linuxDevice))),
            Case(name: "device-android", envelope: SyncEnvelope(
                id: .device(android), revision: rev(4, android, 600), payload: try encode(androidDevice))),
            Case(name: "mac-summary", envelope: SyncEnvelope(
                id: .macSummary(macDeviceID: mac), revision: rev(90, mac, 7_200), payload: try encode(summary))),
            Case(name: "chat-conversation", envelope: SyncEnvelope(
                id: .chatConversation("3a7d0e91-c2f4-4b85-96d1-e8b3f0a5c726"), revision: rev(8, linux, 400), payload: try encode(chat))),
            Case(name: "learning-suggestion", envelope: SyncEnvelope(
                id: .learningSuggestion(syncID: "8e2b4d70-1f9a-4c36-b05e-d7a3c6f1e928"), revision: rev(46, linux, 30), payload: try encode(suggestion))),
            Case(name: "writing-insight", envelope: SyncEnvelope(
                id: .writingInsight(syncID: "4c9f1a3e-6d2b-4e87-a1c5-0b8e7d3f9a61"), revision: rev(47, windows, 40), payload: try encode(insight))),
        ]
    }

    /// The file as written: the record exactly as sent, and the payload
    /// spelled out so a person can read it.
    static func fileData(for record: LinkRecord) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: try LinkWire.encode(["record": record])) as! [String: Any]
        if let payload = record.payload, let bytes = Data(base64Encoded: payload) {
            object["payloadReadable"] = try JSONSerialization.jsonObject(with: bytes)
            object["payloadBytes"] = String(decoding: bytes, as: UTF8.self)
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private struct FixtureFile: Decodable {
        var record: LinkRecord
        var payloadBytes: String?
    }

    @Test func everySampleMatchesThisVersion() throws {
        let write = ProcessInfo.processInfo.environment["ORTTAAI_WRITE_LINK_FIXTURES"] == "1"
        if write { try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true) }
        for sample in try Self.cases() {
            #expect(sample.envelope.problem == nil, "\(sample.name): \(String(describing: sample.envelope.problem))")
            let record = LinkRecord(sample.envelope)
            let url = Self.directory.appending(path: "\(sample.name).json")
            if write {
                try Self.fileData(for: record).write(to: url)
                continue
            }
            let file = try LinkWire.decode(FixtureFile.self, from: try Data(contentsOf: url))
            #expect(file.record == record, "\(sample.name) changed; if that's deliberate, write the samples again")
            #expect(try file.record.envelope() == sample.envelope, "\(sample.name) doesn't read back")
            if let payload = sample.envelope.payload {
                #expect(file.payloadBytes == String(decoding: payload, as: UTF8.self), "\(sample.name) payload bytes")
            }
        }
    }

    @Test func everyKindALinkedDeviceUsesHasASample() throws {
        let kinds = Set(try Self.cases().compactMap(\.envelope.kind))
        let linked: Set<RecordKind> = [.dictation, .dictionaryEntry, .snippet, .device, .macSummary, .chatConversation, .learningSuggestion, .writingInsight]
        #expect(linked.isSubset(of: kinds))
    }

    @Test func aRecordSurvivesTheWire() throws {
        for sample in try Self.cases() {
            let data = try LinkWire.encode(LinkRecord(sample.envelope))
            #expect(try LinkWire.decode(LinkRecord.self, from: data).envelope() == sample.envelope, "\(sample.name)")
        }
    }

    @Test func aBadZoneOrPayloadIsRefused() throws {
        var record = LinkRecord(try Self.cases()[0].envelope)
        record.zone = "Somewhere"
        #expect(throws: LinkWireError.unknownZone("Somewhere")) { try record.envelope() }
        record = LinkRecord(try Self.cases()[0].envelope)
        record.payload = "not base64!"
        #expect(throws: LinkWireError.self) { try record.envelope() }
    }
}
