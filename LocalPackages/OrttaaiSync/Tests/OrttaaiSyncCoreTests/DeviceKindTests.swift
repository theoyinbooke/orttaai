// DeviceKindTests.swift
// OrttaaiSyncCoreTests
//
// The device kinds Orttaai Link adds (Windows, Linux, Android) and how they
// reach apps that were built before them.

import Foundation
import Testing
@testable import OrttaaiSyncCore

@Suite("Device kinds and schema versions")
struct DeviceKindTests {
    private let now = SyncDate.rounded(Date(timeIntervalSince1970: 1_790_000_000))

    private func device(_ kind: DeviceKind, id: String = DeviceID.make()) throws -> SyncEnvelope {
        let payload = DevicePayload(deviceID: id, kind: kind, name: kind.displayName, app: "Orttaai", firstSeenAt: now, lastSeenAt: now)
        return SyncEnvelope(
            id: .device(id),
            revision: Revision(counter: 1, modifiedAt: now, writerDeviceID: id),
            payload: try PayloadCoder.encode(payload)
        )
    }

    private func dictation(from kind: DeviceKind) throws -> SyncEnvelope {
        let origin = DeviceID.make()
        let payload = DictationPayload(createdAt: now, text: "Ship it on Friday", targetAppName: "Claude Code")
        return SyncEnvelope(
            id: .dictation(syncID: UUID().uuidString.lowercased(), zone: .dictations(originDeviceID: origin)),
            revision: Revision(counter: 1, modifiedAt: now, writerDeviceID: origin),
            payload: try PayloadCoder.encode(payload),
            origin: DictationOrigin(deviceID: origin, kind: kind),
            createdAt: now
        )
    }

    @Test func newKindsRoundTrip() throws {
        for kind in [DeviceKind.windows, .linux, .android] {
            let data = try PayloadCoder.encode(DictationOrigin(deviceID: nil, kind: kind))
            #expect(try PayloadCoder.decode(DictationOrigin.self, from: data).kind == kind)
            #expect(String(decoding: data, as: UTF8.self).contains("\"\(kind.rawValue)\""))
        }
    }

    @Test func aKindFromTheFutureReadsAsUnknown() throws {
        let id = DeviceID.make()
        let json = """
        {"app":"Orttaai","deviceID":"\(id)","firstSeenAt":1790000000000,"kind":"visionpro","lastSeenAt":1790000000000,"name":"Headset","totals":{"dictations":0,"recordingMs":0,"words":0}}
        """
        let decoded = try PayloadCoder.decode(DevicePayload.self, from: Data(json.utf8))
        #expect(decoded.kind == .unknown)
        #expect(decoded.name == "Headset")
    }

    @Test func recordsNamingANewKindAreSchemaTwo() throws {
        for kind in [DeviceKind.windows, .linux, .android] {
            #expect(try device(kind).schemaVersion == 2)
            #expect(try dictation(from: kind).schemaVersion == 2)
            #expect(try device(kind).problem == nil)
            #expect(try dictation(from: kind).problem == nil)
        }
    }

    @Test func everythingElseStaysSchemaOneForOlderApps() throws {
        for kind in [DeviceKind.mac, .iphone, .ipad] {
            #expect(try device(kind).schemaVersion == 1)
            #expect(try dictation(from: kind).schemaVersion == 1)
        }
        let word = DictionaryEntryPayload(source: "orta", target: "Orttaai", createdAt: now)
        let entry = SyncEnvelope(
            id: .dictionaryEntry(normalizedSource: word.normalizedSource),
            revision: Revision(counter: 1, modifiedAt: now, writerDeviceID: DeviceID.make()),
            payload: try PayloadCoder.encode(word)
        )
        #expect(entry.schemaVersion == 1)
    }

    @Test func aDecodedRecordKeepsTheVersionItWasWrittenWith() throws {
        let written = try device(.linux)
        let read = SyncEnvelope(id: written.id, schemaVersion: 2, revision: written.revision, payload: written.payload)
        #expect(read.schemaVersion == 2)
        let deleted = SyncEnvelope(id: written.id, revision: written.revision, isDeleted: true, deletedAt: now, payload: nil)
        #expect(deleted.schemaVersion == 1)
    }

    @Test func anOlderAppHoldsSchemaTwoUntilItUpdates() {
        // What a schema-1 app decides about a schema-2 record: set aside,
        // and tried again after an update, never dropped.
        let problem = EnvelopeProblem.unsupportedSchemaVersion(2)
        #expect(problem.mayResolveAfterUpdate)
    }

    @Test func linkedDevicesGetTheRightRules() {
        #expect(DeviceKind.windows.syncPlatform == .mac)
        #expect(DeviceKind.linux.syncPlatform == .mac)
        #expect(DeviceKind.android.syncPlatform == .mobile)
        #expect(DeviceKind.unknown.syncPlatform == .mobile)
        #expect(DeviceKind.allCases.filter(\.linksThroughMac) == [.windows, .linux, .android])
    }
}
