// TranscriptionRecord.swift
// Uttrai

import Foundation
import GRDB

struct Transcription: Codable, Identifiable {
    var id: Int64?
    var createdAt: Date
    var text: String
    var targetAppName: String?
    var targetAppBundleID: String?
    var recordingDurationMs: Int
    var processingDurationMs: Int
    var modelId: String
    var audioDevice: String?

    static let databaseTableName = "transcription"
}

extension Transcription: FetchableRecord, PersistableRecord {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
