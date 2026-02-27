// PersonalMemoryRecord.swift
// Orttaai

import Foundation
import GRDB

enum LearningSuggestionType: String, Codable, CaseIterable {
    case dictionary
    case snippet
}

enum LearningSuggestionStatus: String, Codable, CaseIterable {
    case pending
    case accepted
    case rejected
}

struct LearningSuggestionDraft: Sendable {
    let type: LearningSuggestionType
    let candidateSource: String
    let candidateTarget: String
    let confidence: Double
    let evidence: String?
}

struct DictionaryEntry: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var source: String
    var target: String
    var normalizedSource: String
    var isCaseSensitive: Bool
    var isActive: Bool
    var usageCount: Int
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "dictionary_entry"
}

struct SnippetEntry: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var trigger: String
    var expansion: String
    var normalizedTrigger: String
    var isActive: Bool
    var usageCount: Int
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "snippet_entry"
}

struct LearningSuggestion: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var type: String
    var candidateSource: String
    var candidateTarget: String
    var normalizedSource: String
    var confidence: Double
    var status: String
    var evidence: String?
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "learning_suggestion"

    var suggestionType: LearningSuggestionType {
        LearningSuggestionType(rawValue: type) ?? .dictionary
    }

    var suggestionStatus: LearningSuggestionStatus {
        LearningSuggestionStatus(rawValue: status) ?? .pending
    }
}

extension DictionaryEntry {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension SnippetEntry {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension LearningSuggestion {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

enum PersonalMemoryNormalizer {
    static func normalizedKey(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
