// WritingInsightSnapshotRecord.swift
// Orttaai

import Foundation
import GRDB

struct WritingInsightSnapshotRecord: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var generatedAt: Date
    var analyzerName: String
    var usedFallback: Bool
    var isPinned: Bool
    var sampleCount: Int
    var requestJSON: String
    var snapshotJSON: String

    static let databaseTableName = "writing_insight_snapshot"
}

extension WritingInsightSnapshotRecord {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
