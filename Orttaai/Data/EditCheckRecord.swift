// EditCheckRecord.swift
// Orttaai

import Foundation
import GRDB

/// One check of a dictation's field by Learn from My Edits: when, in which
/// app, and how it ended. Never any text. Local to this Mac; the newest 30
/// are kept.
struct EditCheckRecord: Codable, Equatable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var checkedAt: Date
    var appName: String?
    var outcome: String
    var learnedCount: Int

    static let databaseTableName = "edit_check"

    var checkOutcome: EditCheckOutcome? { EditCheckOutcome(rawValue: outcome) }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Notification.Name {
    /// Posted after Learn from My Edits records a check.
    static let editChecksDidChange = Notification.Name("Orttaai.editChecksDidChange")
}
