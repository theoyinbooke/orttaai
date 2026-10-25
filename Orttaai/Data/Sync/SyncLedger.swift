// SyncLedger.swift
// Orttaai
//
// Records local changes for sync, inside the transaction that makes them:
// the record gets a new revision and an outbox entry in the same commit as
// the row, so no change can be saved and never sent. Called from
// DatabaseManager's touchSyncMetadata (after an insert or edit) and
// recordTombstone (before a delete), which every synced write goes through.
// Usage counts never pass through here and so never sync.

import Foundation
import GRDB
import OrttaaiSyncCore

nonisolated enum SyncLedger {
    private static let revisionCounterKey = "revisionCounter"

    // MARK: Revisions

    static func nextRevision(_ db: Database, at date: Date = Date()) throws -> Revision {
        var clock = RevisionClock(counter: try currentCounter(db), deviceID: DeviceIdentity.currentID)
        let revision = clock.next(at: date)
        try setCounter(db, clock.counter)
        return revision
    }

    /// Moves this device's counter past a revision seen from another device.
    static func observe(_ revision: Revision, in db: Database) throws {
        let counter = try currentCounter(db)
        if revision.counter > counter { try setCounter(db, revision.counter) }
    }

    private static func currentCounter(_ db: Database) throws -> Int64 {
        guard let data = try Data.fetchOne(db, sql: "SELECT value FROM sync_kv WHERE key = ?", arguments: [revisionCounterKey]),
              let text = String(data: data, encoding: .utf8), let value = Int64(text) else { return 0 }
        return value
    }

    private static func setCounter(_ db: Database, _ value: Int64) throws {
        try db.execute(
            sql: "INSERT INTO sync_kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [revisionCounterKey, Data(String(value).utf8)]
        )
    }

    // MARK: Content rows

    /// A row of a synced table was inserted or edited.
    static func noteChange(in db: Database, table: String, localID: Int64) throws {
        guard let identity = try identity(of: table, localID: localID, in: db) else { return }
        let revision = try nextRevision(db)

        // Renaming a dictionary source or snippet trigger moves the row to
        // another record: the old one becomes a tombstone.
        if let previous = try Row.fetchOne(
            db,
            sql: "SELECT recordName FROM sync_record WHERE localTable = ? AND localID = ? AND recordName <> ?",
            arguments: [table, localID, identity.recordID.recordName]
        ), let previousName: String = previous["recordName"] {
            try markDeleted(db, recordName: previousName, revision: try nextRevision(db))
        }

        let existing = try Row.fetchOne(db, sql: "SELECT isDeleted, generation FROM sync_record WHERE recordName = ?", arguments: [identity.recordID.recordName])
        if let existing {
            // Origin and zone never change once set. Writing a deleted word
            // or snippet again is an explicit re-add: its next life.
            let revives = existing["isDeleted"] as Bool && !identity.kind.deletionIsTerminal
            try db.execute(
                sql: """
                UPDATE sync_record
                SET localTable = ?, localID = ?, revCounter = ?, revModifiedAtMs = ?, revWriter = ?, isDeleted = 0, deletedAt = NULL,
                    generation = generation + ?
                WHERE recordName = ?
                """,
                arguments: [table, localID, revision.counter, SyncSchema.milliseconds(revision.modifiedAt), revision.writerDeviceID, revives ? 1 : 0, identity.recordID.recordName]
            )
        } else {
            try db.execute(
                sql: """
                INSERT INTO sync_record (recordName, zoneName, kind, localTable, localID, revCounter, revModifiedAtMs, revWriter, isDeleted, originDeviceID, originKind, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
                """,
                arguments: [
                    identity.recordID.recordName, identity.recordID.zone.zoneName, identity.kind.rawValue, table, localID,
                    revision.counter, SyncSchema.milliseconds(revision.modifiedAt), revision.writerDeviceID,
                    identity.origin?.deviceID, identity.origin?.kind.rawValue, identity.createdAt,
                ]
            )
        }
        try enqueue(db, recordName: identity.recordID.recordName, revision: revision)
    }

    /// A row of a synced table is about to be deleted.
    static func noteDeletion(in db: Database, table: String, localID: Int64) throws {
        let linked = try String.fetchOne(db, sql: "SELECT recordName FROM sync_record WHERE localTable = ? AND localID = ?", arguments: [table, localID])
        if let linked {
            try markDeleted(db, recordName: linked, revision: try nextRevision(db))
            return
        }
        // A row that never got a sync record (it shouldn't happen after the
        // migration): record its tombstone from the row before it goes.
        guard let identity = try identity(of: table, localID: localID, in: db) else { return }
        let revision = try nextRevision(db)
        try db.execute(
            sql: """
            INSERT INTO sync_record (recordName, zoneName, kind, localTable, localID, revCounter, revModifiedAtMs, revWriter, isDeleted, deletedAt, originDeviceID, originKind, createdAt)
            VALUES (?, ?, ?, NULL, NULL, ?, ?, ?, 1, ?, ?, ?, ?)
            ON CONFLICT(recordName) DO NOTHING
            """,
            arguments: [
                identity.recordID.recordName, identity.recordID.zone.zoneName, identity.kind.rawValue,
                revision.counter, SyncSchema.milliseconds(revision.modifiedAt), revision.writerDeviceID, Date(),
                identity.origin?.deviceID, identity.origin?.kind.rawValue, identity.createdAt,
            ]
        )
        try enqueue(db, recordName: identity.recordID.recordName, revision: revision)
    }

    private static func markDeleted(_ db: Database, recordName: String, revision: Revision) throws {
        try db.execute(
            sql: """
            UPDATE sync_record
            SET isDeleted = 1, deletedAt = ?, localTable = NULL, localID = NULL, payload = NULL,
                revCounter = ?, revModifiedAtMs = ?, revWriter = ?
            WHERE recordName = ?
            """,
            arguments: [Date(), revision.counter, SyncSchema.milliseconds(revision.modifiedAt), revision.writerDeviceID, recordName]
        )
        try enqueue(db, recordName: recordName, revision: revision)
    }

    // MARK: Records kept only here

    /// A device, summary or Mac settings record changed; its payload lives in
    /// sync_record itself.
    static func noteRecordChange(in db: Database, recordID: SyncRecordID, payload: Data?) throws {
        guard let kind = recordID.kind else { return }
        let revision = try nextRevision(db)
        try db.execute(
            sql: """
            INSERT INTO sync_record (recordName, zoneName, kind, revCounter, revModifiedAtMs, revWriter, isDeleted, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(recordName) DO UPDATE SET
                revCounter = excluded.revCounter, revModifiedAtMs = excluded.revModifiedAtMs, revWriter = excluded.revWriter,
                generation = sync_record.generation + (sync_record.isDeleted AND NOT excluded.isDeleted),
                isDeleted = excluded.isDeleted, deletedAt = NULL, payload = excluded.payload
            """,
            arguments: [
                recordID.recordName, recordID.zone.zoneName, kind.rawValue,
                revision.counter, SyncSchema.milliseconds(revision.modifiedAt), revision.writerDeviceID,
                payload == nil, payload,
            ]
        )
        try enqueue(db, recordName: recordID.recordName, revision: revision)
    }

    static func enqueue(_ db: Database, recordName: String, revision: Revision) throws {
        try db.execute(
            sql: """
            INSERT INTO sync_outbox (recordName, revCounter, revModifiedAtMs, revWriter, failedReason, enqueuedAt)
            VALUES (?, ?, ?, ?, NULL, ?)
            ON CONFLICT(recordName) DO UPDATE SET
                revCounter = excluded.revCounter, revModifiedAtMs = excluded.revModifiedAtMs,
                revWriter = excluded.revWriter, failedReason = NULL, enqueuedAt = excluded.enqueuedAt
            """,
            arguments: [recordName, revision.counter, SyncSchema.milliseconds(revision.modifiedAt), revision.writerDeviceID, Date()]
        )
    }

    // MARK: Identity

    struct Identity {
        var recordID: SyncRecordID
        var kind: RecordKind
        var origin: DictationOrigin?
        var createdAt: Date?
    }

    /// The record a content row maps to.
    static func identity(of table: String, localID: Int64, in db: Database) throws -> Identity? {
        switch table {
        case "transcription":
            guard let row = try Row.fetchOne(db, sql: "SELECT syncID, sourceDeviceID, sourceDeviceKind, createdAt FROM transcription WHERE id = ?", arguments: [localID]),
                  let syncID: String = row["syncID"], !syncID.isEmpty else { return nil }
            // An existing record keeps its zone and origin.
            let recordName = SyncRecordID.dictation(syncID: syncID, zone: .legacyDictations).recordName
            if let existing = try Row.fetchOne(db, sql: "SELECT zoneName, originDeviceID, originKind FROM sync_record WHERE recordName = ?", arguments: [recordName]),
               let zoneName: String = existing["zoneName"], let zone = SyncZone(zoneName: zoneName) {
                let kind = (existing["originKind"] as String?).flatMap(DeviceKind.init(rawValue:)) ?? .unknown
                return Identity(
                    recordID: .dictation(syncID: syncID, zone: zone),
                    kind: .dictation,
                    origin: DictationOrigin(deviceID: existing["originDeviceID"], kind: kind),
                    createdAt: row["createdAt"]
                )
            }
            let sourceDeviceID: String? = row["sourceDeviceID"]
            let zone = SyncRecordID.dictationZone(originDeviceID: sourceDeviceID)
            let kind: DeviceKind = (row["sourceDeviceKind"] as String?).flatMap(DeviceKind.init(rawValue:))
                ?? (sourceDeviceID == DeviceIdentity.currentID ? .mac : .unknown)
            return Identity(
                recordID: .dictation(syncID: syncID, zone: zone),
                kind: .dictation,
                origin: DictationOrigin(deviceID: zone == .legacyDictations ? nil : sourceDeviceID, kind: kind),
                createdAt: row["createdAt"]
            )

        case "dictionary_entry":
            guard let key = try String.fetchOne(db, sql: "SELECT normalizedSource FROM dictionary_entry WHERE id = ?", arguments: [localID]) else { return nil }
            return Identity(recordID: .dictionaryEntry(normalizedSource: key), kind: .dictionaryEntry)

        case "snippet_entry":
            guard let key = try String.fetchOne(db, sql: "SELECT normalizedTrigger FROM snippet_entry WHERE id = ?", arguments: [localID]) else { return nil }
            return Identity(recordID: .snippet(normalizedTrigger: key), kind: .snippet)

        case "learning_suggestion":
            guard let syncID = try String.fetchOne(db, sql: "SELECT syncID FROM learning_suggestion WHERE id = ?", arguments: [localID]), !syncID.isEmpty else { return nil }
            return Identity(recordID: .learningSuggestion(syncID: syncID), kind: .learningSuggestion)

        case "writing_insight_snapshot":
            guard let syncID = try String.fetchOne(db, sql: "SELECT syncID FROM writing_insight_snapshot WHERE id = ?", arguments: [localID]), !syncID.isEmpty else { return nil }
            return Identity(recordID: .writingInsight(syncID: syncID), kind: .writingInsight)

        default:
            return nil
        }
    }
}
