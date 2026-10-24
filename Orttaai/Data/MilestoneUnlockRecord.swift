// MilestoneUnlockRecord.swift
// Orttaai

import Foundation
import GRDB

/// A badge this Mac has earned. `unlockedAt` is when the dictation that
/// crossed its threshold was made; `celebratedAt` is set once the person has
/// seen its celebration.
struct MilestoneUnlock: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    var badgeID: String
    var unlockedAt: Date
    var celebratedAt: Date?

    static let databaseTableName = "milestone_unlock"
}
