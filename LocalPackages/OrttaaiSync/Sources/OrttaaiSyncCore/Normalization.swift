// Normalization.swift
// OrttaaiSync
//
// How a dictionary source or snippet trigger becomes the key two devices
// agree on. Frozen: changing it would give the same word two records. A new
// rule needs a new version and a migration.

import CryptoKit
import Foundation

public enum SyncNormalization {
    /// Bumped only with a migration of every dictionary and snippet name.
    public static let version = 1

    /// Orttaai's `PersonalMemoryNormalizer.normalizedKey`, which both apps
    /// use for their unique index: trimmed, lowercased (Unicode default case
    /// mapping, independent of the device's locale) and inner whitespace
    /// collapsed to one space.
    public static func normalizedKey(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// The record-name part for a normalized key: the SHA-256 of its NFC form
    /// (so "é" typed composed or decomposed is one word), in lowercase hex.
    public static func digest(_ normalizedKey: String) -> String {
        let canonical = normalizedKey.precomposedStringWithCanonicalMapping
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// How words are counted everywhere: Home, summaries, milestones.
public enum WordCount {
    public static func of(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}
