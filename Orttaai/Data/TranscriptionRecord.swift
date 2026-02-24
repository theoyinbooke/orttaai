// TranscriptionRecord.swift
// Orttaai

import Foundation
import GRDB

struct Transcription: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var createdAt: Date
    var text: String
    var targetAppName: String?
    var targetAppBundleID: String?
    var recordingDurationMs: Int
    var processingDurationMs: Int
    var settingsSyncDurationMs: Int?
    var transcriptionDurationMs: Int?
    var textProcessingDurationMs: Int?
    var injectionDurationMs: Int?
    var appActivationDurationMs: Int?
    var clipboardRestoreDelayMs: Int?
    var modelId: String
    var audioDevice: String?

    static let databaseTableName = "transcription"
}

extension Transcription {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
