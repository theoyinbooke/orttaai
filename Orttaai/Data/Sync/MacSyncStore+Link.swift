// MacSyncStore+Link.swift
// Orttaai
//
// The Mac's archive as Orttaai Link serves it (docs/orttaai-link-protocol.md
// §6, §7). Records a linked device sends go through the same conflict policy
// as records from iCloud; the ones accepted are queued for iCloud at the
// device's own revision, so this Mac uploads them as they are. The change
// feed hands devices the current version of every record that changed.

import Foundation
import GRDB
import OrttaaiSyncCore

nonisolated extension MacSyncStore {
    struct LinkApplyResult: Equatable {
        /// Saved (or already held) at the revision the device sent.
        var accepted: [SyncRecordID: Revision] = [:]
        /// This Mac's version is newer; the device should take it.
        var newer: [SyncEnvelope] = []
        /// Records whose content changed here, to refresh what's on screen.
        var changed: [SyncRecordID] = []
    }

    struct LinkChanges: Equatable {
        var records: [SyncEnvelope]
        var cursor: Int64
        var more: Bool
    }

    /// Which of these records this Mac holds, live or deleted.
    func existingRecordNames(_ names: [String]) throws -> Set<String> {
        guard !names.isEmpty else { return [] }
        return try dbQueue.read { db in
            var found = Set<String>()
            // SQLite allows a few hundred parameters at a time.
            for chunk in stride(from: 0, to: names.count, by: 400).map({ Array(names[$0..<min($0 + 400, names.count)]) }) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                found.formUnion(try String.fetchAll(db, sql: "SELECT recordName FROM sync_record WHERE recordName IN (\(marks))", arguments: StatementArguments(chunk)))
            }
            return found
        }
    }

    /// Applies records from a linked device in one transaction. They are
    /// checked by Orttaai Link's rules before they get here.
    func applyFromLinkedDevice(_ envelopes: [SyncEnvelope]) throws -> LinkApplyResult {
        try dbQueue.write { db in
            var result = LinkApplyResult()
            for envelope in envelopes {
                let local = try Row.fetchOne(db, sql: "SELECT revCounter, revModifiedAtMs, revWriter, isDeleted, generation FROM sync_record WHERE recordName = ?", arguments: [envelope.id.recordName])
                let localState = local.map {
                    LocalRecordState(revision: Self.revision($0, counter: "revCounter", ms: "revModifiedAtMs", writer: "revWriter"), isDeleted: $0["isDeleted"], generation: $0["generation"])
                }
                try SyncLedger.observe(envelope.revision, in: db)

                switch ConflictPolicy.decide(local: localState, remote: envelope) {
                case .acceptRemote:
                    try applyContent(envelope, in: db)
                    try upsertSyncRecord(envelope, systemFields: nil, in: db)
                    // iCloud hasn't seen it: this Mac uploads it, at the
                    // device's revision.
                    try SyncLedger.enqueue(db, recordName: envelope.id.recordName, revision: envelope.revision)
                    result.accepted[envelope.id] = envelope.revision
                    result.changed.append(envelope.id)
                case .alreadyCurrent:
                    result.accepted[envelope.id] = envelope.revision
                case .keepLocal:
                    if let mine = try currentRecord(for: envelope.id, in: db) {
                        result.newer.append(mine.envelope)
                    }
                }
            }
            return result
        }
    }

    /// One page of the change feed: the current version of each record
    /// changed after `cursor` that `reads` lets the device have.
    func linkChanges(after cursor: Int64, limit: Int, reads: (SyncRecordID) -> Bool) throws -> LinkChanges {
        // A write: building this Mac's own device record or summary reads
        // through the same path as sending them to iCloud.
        try dbQueue.write { db in
            let rows = try SyncSchema.changes(after: cursor, limit: limit, in: db)
            var records: [SyncEnvelope] = []
            for row in rows {
                guard let zone = SyncZone(zoneName: row.zoneName) else { continue }
                let id = SyncRecordID(zone: zone, recordName: row.recordName)
                guard reads(id), let record = try currentRecord(for: id, in: db) else { continue }
                // A record this version can't send whole is left out rather
                // than sent broken.
                guard record.envelope.problem == nil else { continue }
                records.append(record.envelope)
            }
            return LinkChanges(records: records, cursor: rows.last?.changeSeq ?? cursor, more: rows.count == limit)
        }
    }

    /// Each device's own dictations, words and time, for the Devices page.
    func deviceTotals(_ deviceIDs: [String]) throws -> [String: DeviceTotals] {
        try dbQueue.read { db in
            var totals: [String: DeviceTotals] = [:]
            for id in deviceIDs { totals[id] = try self.totals(in: db, sourceDeviceID: id) }
            return totals
        }
    }
}
