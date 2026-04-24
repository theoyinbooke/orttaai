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
    private var cachedDictionaryEntries: [DictionaryEntry] = []
    private var cachedSnippetEntries: [SnippetEntry] = []
    private var memoryCacheIsDirty = true
    private var memoryChangeObserver: NSObjectProtocol?

    init(databaseManager: DatabaseManager, settings: AppSettings) {
        self.databaseManager = databaseManager
        self.settings = settings
        memoryChangeObserver = NotificationCenter.default.addObserver(
            forName: .personalMemoryDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.memoryCacheIsDirty = true
        }
    }

    deinit {
        if let memoryChangeObserver {
            NotificationCenter.default.removeObserver(memoryChangeObserver)
        }
    }

    func process(_ input: TextProcessorInput) async throws -> TextProcessorOutput {
        let trimmedInput = input.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            return TextProcessorOutput(text: input.rawTranscript, changes: [])
        }

        var resolvedText = trimmedInput
        var changes: [String] = []
        let shouldApplyDictionary = settings.dictionaryEnabled
        let shouldApplySnippets = settings.snippetsEnabled
        let activeRules = (shouldApplyDictionary || shouldApplySnippets)
            ? try loadActiveRulesIfNeeded()
            : ActivePersonalMemoryRules(dictionaryEntries: [], snippetEntries: [])

        if shouldApplyDictionary {
            let result = applyDictionary(to: resolvedText, entries: activeRules.dictionaryEntries)
            resolvedText = result.text
            changes.append(contentsOf: result.changes)
            for entryID in result.appliedEntryIDs {
                try? databaseManager.incrementDictionaryUsage(id: entryID)
            }
        }

        if shouldApplySnippets {
            if let matchedSnippet = resolveSnippet(for: resolvedText, snippets: activeRules.snippetEntries) {
                let previousText = resolvedText
                resolvedText = matchedSnippet.expansion
                changes.append("Snippet expanded: '\(previousText)' -> '\(matchedSnippet.expansion)'")
                if let entryID = matchedSnippet.id {
                    try? databaseManager.incrementSnippetUsage(id: entryID)
                }
            }
        }

        if settings.spokenFormattingEnabled {
            let formattingResult = SpokenFormattingFormatter.format(resolvedText)
            resolvedText = formattingResult.text
            changes.append(contentsOf: formattingResult.changes)
        }

        return TextProcessorOutput(text: resolvedText, changes: changes)
    }

    func isAvailable() -> Bool {
        true
    }

    private func loadActiveRulesIfNeeded() throws -> ActivePersonalMemoryRules {
        if memoryCacheIsDirty {
            cachedDictionaryEntries = try databaseManager.fetchDictionaryEntries(includeInactive: false)
            cachedSnippetEntries = try databaseManager.fetchSnippetEntries(includeInactive: false)
            memoryCacheIsDirty = false
        }
        return ActivePersonalMemoryRules(
            dictionaryEntries: cachedDictionaryEntries,
            snippetEntries: cachedSnippetEntries
        )
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

private struct ActivePersonalMemoryRules {
    let dictionaryEntries: [DictionaryEntry]
    let snippetEntries: [SnippetEntry]
}

private enum SpokenFormattingFormatter {
    private struct OrderedMarker {
        let range: Range<String.Index>
        let number: Int
    }

    private struct TextMarker {
        let range: Range<String.Index>
    }

    private enum MarkerKind {
        case ordered
        case bullet
    }

    private static let orderedMarkerPattern = #"""
    (?<![\p{L}\p{N}_])(?:number|item)\s+(one|two|three|four|five|six|seven|eight|nine|ten|1|2|3|4|5|6|7|8|9|10)(?![\p{L}\p{N}_])
    """#

    private static let bulletMarkerPattern = #"""
    (?<![\p{L}\p{N}_])bullet\s+point(?![\p{L}\p{N}_])
    """#

    static func format(_ text: String) -> (text: String, changes: [String]) {
        if let formattedText = formatOrderedList(text) {
            return (formattedText, ["Spoken formatting: numbered list"])
        }

        if let formattedText = formatBulletList(text) {
            return (formattedText, ["Spoken formatting: bullet list"])
        }

        return (text, [])
    }

    private static func formatOrderedList(_ text: String) -> String? {
        let markers = orderedMarkers(in: text)
        guard let run = orderedRun(from: markers, in: text) else { return nil }

        var lines: [String] = []
        for index in run.indices {
            let marker = run[index]
            let itemStart = marker.range.upperBound
            let itemEnd = index == run.index(before: run.endIndex)
                ? text.endIndex
                : run[run.index(after: index)].range.lowerBound
            let item = cleanedItemContent(String(text[itemStart..<itemEnd]))
            guard !item.isEmpty else { return nil }
            lines.append("\(marker.number). \(capitalizedFirstContentWord(item))")
        }

        return joinedFormattedText(
            prefix: String(text[..<run[run.startIndex].range.lowerBound]),
            lines: lines
        )
    }

    private static func formatBulletList(_ text: String) -> String? {
        let markers = bulletMarkers(in: text)
        guard let run = bulletRun(from: markers, in: text) else { return nil }

        var lines: [String] = []
        for index in run.indices {
            let marker = run[index]
            let itemStart = marker.range.upperBound
            let itemEnd = index == run.index(before: run.endIndex)
                ? text.endIndex
                : run[run.index(after: index)].range.lowerBound
            let item = cleanedItemContent(String(text[itemStart..<itemEnd]))
            guard !item.isEmpty else { return nil }
            lines.append("- \(capitalizedFirstContentWord(item))")
        }

        return joinedFormattedText(
            prefix: String(text[..<run[run.startIndex].range.lowerBound]),
            lines: lines
        )
    }

    private static func orderedRun(from markers: [OrderedMarker], in text: String) -> [OrderedMarker]? {
        guard let firstMarker = markers.first else { return nil }

        var bestRun: [OrderedMarker] = []
        var currentRun = [firstMarker]

        for marker in markers.dropFirst() {
            if marker.number == currentRun[currentRun.count - 1].number + 1 {
                currentRun.append(marker)
            } else {
                if currentRun.count > bestRun.count {
                    bestRun = currentRun
                }
                currentRun = [marker]
            }
        }

        if currentRun.count > bestRun.count {
            bestRun = currentRun
        }

        if bestRun.count >= 2 {
            return bestRun
        }

        if firstMarker.number == 1, isLikelySingleMarkerCommand(firstMarker.range, in: text, kind: .ordered) {
            return [firstMarker]
        }

        return nil
    }

    private static func bulletRun(from markers: [TextMarker], in text: String) -> [TextMarker]? {
        guard let firstMarker = markers.first else { return nil }
        if markers.count >= 2 {
            return markers
        }
        if isLikelySingleMarkerCommand(firstMarker.range, in: text, kind: .bullet) {
            return [firstMarker]
        }
        return nil
    }

    private static func orderedMarkers(in text: String) -> [OrderedMarker] {
        guard let regex = try? NSRegularExpression(
            pattern: orderedMarkerPattern,
            options: [.caseInsensitive, .allowCommentsAndWhitespace]
        ) else {
            return []
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: nsRange).compactMap { match in
            guard let fullRange = Range(match.range, in: text),
                  let numberRange = Range(match.range(at: 1), in: text),
                  let number = numberValue(String(text[numberRange])) else {
                return nil
            }
            return OrderedMarker(range: fullRange, number: number)
        }
    }

    private static func bulletMarkers(in text: String) -> [TextMarker] {
        guard let regex = try? NSRegularExpression(
            pattern: bulletMarkerPattern,
            options: [.caseInsensitive, .allowCommentsAndWhitespace]
        ) else {
            return []
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return TextMarker(range: range)
        }
    }

    private static func isLikelySingleMarkerCommand(
        _ range: Range<String.Index>,
        in text: String,
        kind: MarkerKind
    ) -> Bool {
        let prefix = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.isEmpty else { return false }

        let item = cleanedItemContent(
            String(text[range.upperBound...]),
            stripLeadingLinkingVerb: false
        )
        guard wordCount(in: item) >= 2 else { return false }

        guard let firstWord = firstWord(in: item) else { return false }
        let blockedWords = blockedSingleMarkerFollowers(for: kind)
        return !blockedWords.contains(firstWord)
    }

    private static func blockedSingleMarkerFollowers(for kind: MarkerKind) -> Set<String> {
        var words: Set<String> = [
            "are",
            "can",
            "could",
            "is",
            "means",
            "refers",
            "should",
            "was",
            "were",
            "will",
            "would"
        ]

        if kind == .ordered {
            words.formUnion([
                "candidate",
                "choice",
                "position",
                "rank",
                "ranking",
                "reason",
                "reasons",
                "spot"
            ])
        }

        return words
    }

    private static func cleanedItemContent(
        _ rawValue: String,
        stripLeadingLinkingVerb shouldStripLeadingLinkingVerb: Bool = true
    ) -> String {
        var value = rawValue
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")

        value = value.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        value = trimmingLeadingDelimiters(from: value)
        value = stripBoundaryLineCommands(from: value)
        if shouldStripLeadingLinkingVerb {
            value = stripLeadingLinkingVerb(from: value)
        }
        value = stripTrailingConnector(from: value)
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " ,:;"))
        return value
    }

    private static func trimmingLeadingDelimiters(from text: String) -> String {
        text.replacingOccurrences(
            of: #"^[\s,:;.\-]+"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func stripBoundaryLineCommands(from text: String) -> String {
        var value = text
        let boundaryCommandPatterns = [
            #"(?i)^(new line|new paragraph)\b\s*"#,
            #"(?i)\s*\b(new line|new paragraph)$"#
        ]

        for pattern in boundaryCommandPatterns {
            value = value.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripLeadingLinkingVerb(from text: String) -> String {
        text.replacingOccurrences(
            of: #"(?i)^(is|are|was|were)\s+"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func stripTrailingConnector(from text: String) -> String {
        text.replacingOccurrences(
            of: #"(?i)(?:,?\s+)?(?:and|then|next)$"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func joinedFormattedText(prefix: String, lines: [String]) -> String {
        let cleanedPrefix = prefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))

        let listText = lines.joined(separator: "\n")
        guard !cleanedPrefix.isEmpty else {
            return listText
        }
        return "\(cleanedPrefix)\n\(listText)"
    }

    private static func capitalizedFirstContentWord(_ text: String) -> String {
        guard let firstIndex = text.firstIndex(where: { !$0.isWhitespace }) else {
            return text
        }

        let firstCharacter = text[firstIndex]
        guard firstCharacter.isLowercase else {
            return text
        }

        let nextIndex = text.index(after: firstIndex)
        if nextIndex < text.endIndex, text[nextIndex].isUppercase {
            return text
        }

        var result = text
        result.replaceSubrange(firstIndex...firstIndex, with: String(firstCharacter).uppercased())
        return result
    }

    private static func numberValue(_ rawValue: String) -> Int? {
        let value = rawValue.lowercased()
        if let number = Int(value) {
            return number
        }

        return [
            "one": 1,
            "two": 2,
            "three": 3,
            "four": 4,
            "five": 5,
            "six": 6,
            "seven": 7,
            "eight": 8,
            "nine": 9,
            "ten": 10
        ][value]
    }

    private static func wordCount(in text: String) -> Int {
        text.split { !$0.isLetter && !$0.isNumber }.count
    }

    private static func firstWord(in text: String) -> String? {
        text.split { !$0.isLetter && !$0.isNumber }
            .first
            .map { String($0).lowercased() }
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
