// InsightFindingRecord.swift
// Orttaai

import Foundation
import GRDB

/// A typed, pre-computed pattern about the user's dictated life. Findings are
/// produced deterministically by InsightPatternEngine; language models only
/// ever rephrase them. Persisted so insights have memory: novelty ranking,
/// resolve/dismiss state, and trends across runs.
struct InsightFinding: Codable, Identifiable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    var id: Int64?
    /// One of InsightFindingKind's raw values.
    var kind: String
    /// Stable identity for dedup across recomputes (e.g. "area:codex",
    /// "commitment:412:0").
    var subjectKey: String
    var title: String
    var detail: String
    /// Strength of the pattern in kind-specific units (share, z-score, count).
    var magnitude: Double
    var confidence: Double
    var windowStart: Date?
    var windowEnd: Date?
    /// JSON-encoded [Int64] of supporting chunk IDs.
    var evidenceChunkIDs: String
    var firstSeenAt: Date
    var lastComputedAt: Date
    var lastShownAt: Date?
    /// "active", "expired", "resolved", or "dismissed".
    var status: String

    static let databaseTableName = "insight_finding"

    var evidenceIDs: [Int64] {
        (try? JSONDecoder().decode([Int64].self, from: Data(evidenceChunkIDs.utf8))) ?? []
    }
}

enum InsightFindingKind: String, Sendable, CaseIterable {
    case lifeArea = "life_area"
    case rhythm
    case emergingTheme = "emerging_theme"
    case fadingTheme = "fading_theme"
    case resurfacingTheme = "resurfacing_theme"
    case openCommitment = "open_commitment"
    case openQuestion = "open_question"
    case anomaly
}

enum InsightFindingStatus: String, Sendable {
    case active
    case expired
    case resolved
    case dismissed
}

/// Engine output before persistence identity is attached.
struct InsightFindingDraft: Sendable, Hashable {
    let kind: InsightFindingKind
    let subjectKey: String
    let title: String
    let detail: String
    let magnitude: Double
    let confidence: Double
    let windowStart: Date?
    let windowEnd: Date?
    let evidenceChunkIDs: [Int64]
}
