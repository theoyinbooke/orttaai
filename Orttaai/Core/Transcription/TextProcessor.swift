// TextProcessor.swift
// Orttaai

import Foundation

enum ProcessingMode: String, Codable {
    case raw
    case clean
    case formal
    case casual
}

struct TextProcessorInput {
    let rawTranscript: String
    let targetApp: String?
    let mode: ProcessingMode
}

struct TextProcessorOutput {
    let text: String
    let changes: [String]
}

protocol TextProcessor {
    func process(_ input: TextProcessorInput) async throws -> TextProcessorOutput
    func isAvailable() -> Bool
}

final class RuleBasedTextProcessor: TextProcessor {
    private let databaseManager: DatabaseManager
    private let settings: AppSettings

    init(databaseManager: DatabaseManager, settings: AppSettings) {
        self.databaseManager = databaseManager
        self.settings = settings
    }

    func process(_ input: TextProcessorInput) async throws -> TextProcessorOutput {
        let trimmedInput = input.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            return TextProcessorOutput(text: input.rawTranscript, changes: [])
        }

        var resolvedText = trimmedInput
        var changes: [String] = []

        if settings.dictionaryEnabled {
            let dictionaryEntries = try databaseManager.fetchDictionaryEntries(includeInactive: false)
            let result = applyDictionary(to: resolvedText, entries: dictionaryEntries)
            resolvedText = result.text
            changes.append(contentsOf: result.changes)
            for entryID in result.appliedEntryIDs {
                try? databaseManager.incrementDictionaryUsage(id: entryID)
            }
        }

        if settings.snippetsEnabled {
            let snippets = try databaseManager.fetchSnippetEntries(includeInactive: false)
            if let matchedSnippet = resolveSnippet(for: resolvedText, snippets: snippets) {
                let previousText = resolvedText
                resolvedText = matchedSnippet.expansion
                changes.append("Snippet expanded: '\(previousText)' -> '\(matchedSnippet.expansion)'")
                if let entryID = matchedSnippet.id {
                    try? databaseManager.incrementSnippetUsage(id: entryID)
                }
            }
        }

        return TextProcessorOutput(text: resolvedText, changes: changes)
    }

    func isAvailable() -> Bool {
        true
    }

    private func applyDictionary(
        to text: String,
        entries: [DictionaryEntry]
    ) -> (text: String, changes: [String], appliedEntryIDs: [Int64]) {
        var transformedText = text
        var changes: [String] = []
        var appliedEntryIDs: [Int64] = []

        let orderedEntries = entries.sorted { lhs, rhs in
            if lhs.source.count == rhs.source.count {
                return lhs.source < rhs.source
            }
            return lhs.source.count > rhs.source.count
        }

        for entry in orderedEntries where entry.isActive {
            let source = entry.source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { continue }

            let escapedSource = NSRegularExpression.escapedPattern(for: source)
            let pattern = "(?<![\\p{L}\\p{N}_])\(escapedSource)(?![\\p{L}\\p{N}_])"
            let regexOptions: NSRegularExpression.Options = entry.isCaseSensitive ? [] : [.caseInsensitive]

            guard let regex = try? NSRegularExpression(pattern: pattern, options: regexOptions) else { continue }
            let searchRange = NSRange(transformedText.startIndex..<transformedText.endIndex, in: transformedText)
            let matchCount = regex.numberOfMatches(in: transformedText, options: [], range: searchRange)
            guard matchCount > 0 else { continue }

            transformedText = regex.stringByReplacingMatches(
                in: transformedText,
                options: [],
                range: searchRange,
                withTemplate: entry.target
            )
            changes.append("Dictionary: '\(entry.source)' -> '\(entry.target)' (\(matchCount)x)")

            if let entryID = entry.id {
                for _ in 0..<matchCount {
                    appliedEntryIDs.append(entryID)
                }
            }
        }

        return (transformedText, changes, appliedEntryIDs)
    }

    private func resolveSnippet(for text: String, snippets: [SnippetEntry]) -> SnippetEntry? {
        let normalizedInput = PersonalMemoryNormalizer.normalizedKey(text)
        guard !normalizedInput.isEmpty else { return nil }

        let activeSnippets = snippets.filter(\.isActive)
        var byTrigger: [String: SnippetEntry] = [:]
        for snippet in activeSnippets {
            byTrigger[snippet.normalizedTrigger] = snippet
        }

        if let exactMatch = byTrigger[normalizedInput] {
            return exactMatch
        }

        let commandPrefixes = ["insert ", "use ", "expand ", "snippet "]
        for prefix in commandPrefixes where normalizedInput.hasPrefix(prefix) {
            let key = PersonalMemoryNormalizer.normalizedKey(String(normalizedInput.dropFirst(prefix.count)))
            if let match = byTrigger[key] {
                return match
            }
        }

        return nil
    }
}

final class PassthroughProcessor: TextProcessor {
    func process(_ input: TextProcessorInput) async throws -> TextProcessorOutput {
        TextProcessorOutput(text: input.rawTranscript, changes: [])
    }

    func isAvailable() -> Bool {
        true
    }
}
