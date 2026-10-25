// RecordCodecTests.swift
// OrttaaiSyncCloudKitTests

import CloudKit
import Foundation
import Testing
@testable import OrttaaiSyncCloudKit
import OrttaaiSyncCore

@Suite("CKRecord codec")
struct RecordCodecTests {
    let device = DeviceID.make()

    func dictationEnvelope(deleted: Bool = false) throws -> SyncEnvelope {
        let zone = SyncZone.dictations(originDeviceID: device)
        let payload = try PayloadCoder.encode(DictationPayload(createdAt: SyncDate.rounded(Date()), text: "Encrypted words", rawText: "encrypted words"))
        return SyncEnvelope(
            id: .dictation(syncID: "abc", zone: zone),
            revision: Revision(counter: 4, modifiedAt: SyncDate.rounded(Date()), writerDeviceID: device),
            isDeleted: deleted,
            deletedAt: deleted ? SyncDate.rounded(Date()) : nil,
            payload: deleted ? nil : payload,
            origin: DictationOrigin(deviceID: device, kind: .iphone),
            createdAt: SyncDate.rounded(Date())
        )
    }

    @Test func roundTripsAnEnvelope() throws {
        let envelope = try dictationEnvelope()
        let record = RecordCodec.record(for: OutgoingRecord(envelope: envelope, systemFields: nil))
        #expect(record.recordType == "Dictation")
        #expect(record.recordID.zoneID.zoneName == "Dictations-\(device)")
        // The text is never in a plain field.
        #expect(record["payload"] == nil)
        #expect(record.encryptedValues["payload"] as? Data == envelope.payload)

        guard case .record(let inbound) = RecordCodec.decode(record) else {
            Issue.record("Expected a readable record")
            return
        }
        #expect(inbound.envelope == envelope)
        #expect(inbound.systemFields != nil)
        #expect(RecordCodec.revision(of: record) == envelope.revision)
    }

    @Test func aDeletedDictationCarriesNoText() throws {
        let live = try dictationEnvelope()
        let first = RecordCodec.record(for: OutgoingRecord(envelope: live, systemFields: nil))
        let systemFields = RecordCodec.archiveSystemFields(first)
        let deleted = try dictationEnvelope(deleted: true)
        let record = RecordCodec.record(for: OutgoingRecord(envelope: deleted, systemFields: systemFields))
        #expect(record.encryptedValues["payload"] == nil)
        #expect(record["deleted"] as? Int64 == 1)
        guard case .record(let inbound) = RecordCodec.decode(record) else {
            Issue.record("Expected a readable record")
            return
        }
        #expect(inbound.envelope.isDeleted)
        #expect(inbound.envelope.payload == nil)
        #expect(inbound.envelope.problem == nil)
    }

    @Test func systemFieldsRestoreTheSameRecord() throws {
        let envelope = try dictationEnvelope()
        let record = RecordCodec.record(for: OutgoingRecord(envelope: envelope, systemFields: nil))
        let archived = RecordCodec.archiveSystemFields(record)
        let restored = try #require(RecordCodec.unarchiveRecord(archived))
        #expect(restored.recordID == record.recordID)
        #expect(restored.recordType == record.recordType)
        // Restored system fields carry no user fields.
        #expect(restored.encryptedValues["payload"] == nil)
    }

    @Test func systemFieldsForAnotherRecordAreIgnored() throws {
        let other = CKRecord(recordType: "Dictation", recordID: CKRecord.ID(recordName: "dictation.other", zoneID: RecordCodec.zoneID(.dictations(originDeviceID: device))))
        let envelope = try dictationEnvelope()
        let record = RecordCodec.record(for: OutgoingRecord(envelope: envelope, systemFields: RecordCodec.archiveSystemFields(other)))
        #expect(record.recordID.recordName == "dictation.abc")
    }

    @Test func unreadableRecordsAreQuarantinedNotDropped() {
        let zone = RecordCodec.zoneID(.library)
        let wrongType = CKRecord(recordType: "Dictation", recordID: CKRecord.ID(recordName: "dict.123", zoneID: zone))
        guard case .unreadable(let quarantined) = RecordCodec.decode(wrongType) else {
            Issue.record("A dict. record typed Dictation must not be accepted")
            return
        }
        #expect(quarantined.problem == .malformedID)
        #expect(quarantined.archivedRecord != nil)

        let missingFields = CKRecord(recordType: "DictionaryEntry", recordID: CKRecord.ID(recordName: "dict.123", zoneID: zone))
        guard case .unreadable(let missing) = RecordCodec.decode(missingFields) else {
            Issue.record("A record without its fields must not be accepted")
            return
        }
        #expect(missing.problem == .undecodableRecord)
    }

    @Test func zonesMapBothWays() {
        for zone in [SyncZone.library, .macOnly, .legacyDictations, .dictations(originDeviceID: device)] {
            #expect(RecordCodec.zone(RecordCodec.zoneID(zone)) == zone)
        }
        #expect(RecordCodec.zone(CKRecordZone.ID(zoneName: CKRecordZone.ID.defaultZoneName, ownerName: CKCurrentUserDefaultName)) == nil)
    }

    @Test func errorsMapToTheContract() {
        #expect(CloudSyncEngineHost.saveFailure(CKError(.zoneNotFound)) == .zoneNotFound)
        #expect(CloudSyncEngineHost.saveFailure(CKError(.unknownItem)) == .unknownItem)
        #expect(CloudSyncEngineHost.saveFailure(CKError(.quotaExceeded)) == .quotaExceeded)
        #expect(CloudSyncEngineHost.saveFailure(CKError(.networkFailure)) == .transient)
        #expect(CloudSyncEngineHost.saveFailure(CKError(.serverRecordChanged)) == .serverRecordChanged(nil))
        if case .permanent = CloudSyncEngineHost.saveFailure(CKError(.invalidArguments)) {} else {
            Issue.record("invalidArguments should be permanent")
        }
    }
}
