// RecordCodec.swift
// OrttaaiSync
//
// SyncEnvelope ⇄ CKRecord. The text goes in the encrypted `payload` field;
// the plain fields carry only what routing and ordering need. The field
// names match CloudKit/OrttaaiCloudSchemaV2.ckdb.

import CloudKit
import Foundation
import OrttaaiSyncCore

public enum RecordField {
    public static let schemaVersion = "schemaVersion"
    public static let revisionCounter = "revCounter"
    public static let revisionModifiedAt = "revModifiedAt"
    public static let revisionWriter = "revWriter"
    public static let deleted = "deleted"
    public static let generation = "generation"
    public static let deletedAt = "deletedAt"
    public static let createdAt = "createdAt"
    public static let originDeviceID = "originDeviceID"
    public static let originKind = "originKind"
    /// Encrypted.
    public static let payload = "payload"
}

public enum RecordCodec {
    // MARK: IDs

    public static func zoneID(_ zone: SyncZone) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zone.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    public static func zone(_ zoneID: CKRecordZone.ID) -> SyncZone? {
        SyncZone(zoneName: zoneID.zoneName)
    }

    public static func recordID(_ id: SyncRecordID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.recordName, zoneID: zoneID(id.zone))
    }

    public static func syncID(_ recordID: CKRecord.ID) -> SyncRecordID? {
        guard let zone = zone(recordID.zoneID) else { return nil }
        let id = SyncRecordID(zone: zone, recordName: recordID.recordName)
        return id.kind == nil ? nil : id
    }

    // MARK: Encoding

    /// The record to save. Starts from the saved system fields when there
    /// are any, so the save carries the change tag the server expects.
    public static func record(for outgoing: OutgoingRecord) -> CKRecord {
        let envelope = outgoing.envelope
        let id = recordID(envelope.id)
        let recordType = envelope.kind?.recordType ?? ""
        let record: CKRecord
        if let systemFields = outgoing.systemFields,
           let restored = unarchiveRecord(systemFields),
           restored.recordID == id,
           restored.recordType == recordType {
            record = restored
        } else {
            record = CKRecord(recordType: recordType, recordID: id)
        }

        record[RecordField.schemaVersion] = Int64(envelope.schemaVersion)
        record[RecordField.revisionCounter] = envelope.revision.counter
        record[RecordField.revisionModifiedAt] = envelope.revision.modifiedAt
        record[RecordField.revisionWriter] = envelope.revision.writerDeviceID
        record[RecordField.deleted] = Int64(envelope.isDeleted ? 1 : 0)
        record[RecordField.generation] = envelope.generation
        record[RecordField.deletedAt] = envelope.deletedAt
        record[RecordField.createdAt] = envelope.createdAt
        record[RecordField.originDeviceID] = envelope.origin?.deviceID
        record[RecordField.originKind] = envelope.origin?.kind.rawValue
        // Set or explicitly cleared: a deleted dictation keeps no text in iCloud.
        record.encryptedValues[RecordField.payload] = envelope.payload
        return record
    }

    // MARK: Decoding

    /// A fetched record, or why it can't be read.
    public static func decode(_ record: CKRecord, receivedAt: Date = Date()) -> FetchedRecord {
        func unreadable(_ problem: EnvelopeProblem) -> FetchedRecord {
            .unreadable(QuarantinedRecord(
                zoneName: record.recordID.zoneID.zoneName,
                recordName: record.recordID.recordName,
                recordType: record.recordType,
                problem: problem,
                archivedRecord: archiveFullRecord(record),
                receivedAt: receivedAt
            ))
        }

        guard let id = syncID(record.recordID), id.kind?.recordType == record.recordType else {
            return unreadable(.malformedID)
        }
        guard let schemaVersion = int(record[RecordField.schemaVersion]),
              let counter = int(record[RecordField.revisionCounter]),
              let modifiedAt = record[RecordField.revisionModifiedAt] as? Date,
              let writer = record[RecordField.revisionWriter] as? String,
              let deletedFlag = int(record[RecordField.deleted]) else {
            return unreadable(.undecodableRecord)
        }

        var origin: DictationOrigin?
        if id.kind == .dictation {
            let kind = (record[RecordField.originKind] as? String).flatMap(DeviceKind.init(rawValue:)) ?? .unknown
            origin = DictationOrigin(deviceID: record[RecordField.originDeviceID] as? String, kind: kind)
        }

        let envelope = SyncEnvelope(
            id: id,
            schemaVersion: Int(schemaVersion),
            revision: Revision(counter: counter, modifiedAt: modifiedAt, writerDeviceID: writer),
            generation: int(record[RecordField.generation]) ?? 0,
            isDeleted: deletedFlag != 0,
            deletedAt: record[RecordField.deletedAt] as? Date,
            payload: record.encryptedValues[RecordField.payload] as? Data,
            origin: origin,
            createdAt: record[RecordField.createdAt] as? Date
        )
        return .record(InboundRecord(
            envelope: envelope,
            systemFields: archiveSystemFields(record),
            archivedRecord: envelope.problem == nil ? nil : archiveFullRecord(record),
            serverModifiedAt: record.modificationDate
        ))
    }

    /// The revision a saved record carried, for acknowledging exactly it.
    public static func revision(of record: CKRecord) -> Revision? {
        guard let counter = int(record[RecordField.revisionCounter]),
              let modifiedAt = record[RecordField.revisionModifiedAt] as? Date,
              let writer = record[RecordField.revisionWriter] as? String else { return nil }
        return Revision(counter: counter, modifiedAt: modifiedAt, writerDeviceID: writer)
    }

    private static func int(_ value: (any CKRecordValueProtocol)?) -> Int64? {
        switch value {
        case let value as Int64: value
        case let value as Int: Int64(value)
        case let value as NSNumber: value.int64Value
        default: nil
        }
    }

    // MARK: Archiving

    public static func archiveSystemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    /// The whole record, fields included, for quarantine.
    public static func archiveFullRecord(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encode(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    public static func unarchiveRecord(_ data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
}
