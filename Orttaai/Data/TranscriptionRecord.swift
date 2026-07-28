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
    // NULL on rows created before device tagging or synced from older app
    // versions; readers treat NULL as belonging to this device.
    var sourceDeviceID: String?
    // How the text landed in the target app ("paste", "ax", "typed",
    // "failed"). NULL on rows written before verified injection shipped.
    var injectionMethod: String?
    // "edit" for voice edit commands; NULL means a plain dictation (rows
    // written before edit commands shipped included).
    var entryKind: String?
    // The spoken instruction that produced an edit entry; NULL on dictations.
    var editInstruction: String?

    static let databaseTableName = "transcription"

    /// entryKind value for voice edit command rows.
    static let editEntryKind = "edit"

    var isEditCommand: Bool {
        entryKind == Self.editEntryKind
    }
}

extension Transcription {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
