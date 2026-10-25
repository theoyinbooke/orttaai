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
    /// Allows specialized callers to skip the optional polish providers.
    /// Normal dictation keeps this false so the configured final cleanup runs.
    var deferPolish: Bool = false
}

struct TextProcessorOutput {
    let text: String
    let changes: [String]
}

protocol TextProcessor {
    func process(_ input: TextProcessorInput) async throws -> TextProcessorOutput
    func isAvailable() -> Bool
}

/// Supplies the user's personal vocabulary (dictionary targets and snippet
/// triggers) for recognizer-level bias conditioning. Snapshotted once per
/// dictation session — never queried on the audio hot path.
protocol VocabularyBiasProviding {
    func vocabularyBiasTerms() -> [String]
}

final class RuleBasedTextProcessor: TextProcessor, VocabularyBiasProviding {
    private let databaseManager: DatabaseManager
    private let settings: AppSettings
    private var cachedDictionaryEntries: [DictionaryEntry] = []
    private var cachedSnippetEntries: [SnippetEntry] = []
    /// Built lazily from the dictionary targets and dropped with them, so
    /// the per-target caches are recomputed only when the dictionary changes.
    private var cachedFuzzyMatcher: FuzzyDictionaryMatcher?
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

            // Fuzzy hits never bump usage counts: those order the recognizer
            // bias prompt, and a near-miss is not evidence of demand. The
            // word list that guards real words is English only, so any other
            // (or auto-detected) language skips the pass, like the cleaner below.
            if settings.fuzzyDictionaryEnabled, settings.effectiveDictationLanguage == "en" {
                let fuzzyResult = fuzzyMatcher(for: activeRules.dictionaryEntries).apply(to: resolvedText)
                resolvedText = fuzzyResult.text
                changes.append(contentsOf: fuzzyResult.replacements.map {
                    "Dictionary (fuzzy): '\($0.original)' -> '\($0.target)'"
                })
            }
        }

        var expandedSnippet = false
        if shouldApplySnippets {
            if let matchedSnippet = resolveSnippet(for: resolvedText, snippets: activeRules.snippetEntries) {
                let previousText = resolvedText
                resolvedText = matchedSnippet.expansion
                expandedSnippet = true
                changes.append("Snippet expanded: '\(previousText)' -> '\(matchedSnippet.expansion)'")
                if let entryID = matchedSnippet.id {
                    try? databaseManager.incrementSnippetUsage(id: entryID)
                }
            }
        }

        // Runs before spoken formatting so "um, new line" still reaches the
        // line-break command with the filler already gone. A snippet
        // expansion is the user's own text and is never edited.
        if settings.disfluencyCleanupEnabled, !expandedSnippet, settings.effectiveDictationLanguage == "en" {
            let cleanupResult = DisfluencyCleaner.clean(resolvedText)
            resolvedText = cleanupResult.text
            changes.append(contentsOf: cleanupResult.changes)
        }

        if settings.spokenFormattingEnabled {
            let formattingResult = SpokenFormattingFormatter.format(resolvedText)
            resolvedText = formattingResult.text
            changes.append(contentsOf: formattingResult.changes)
        }

        let speakerSetBreaks = changes.contains { $0.hasPrefix("Spoken formatting:") && $0.contains("line break") }
        if settings.autoParagraphsEnabled, !expandedSnippet, !speakerSetBreaks,
           AutoParagraphFormatter.appliesTo(targetApp: input.targetApp) {
            let paragraphResult = AutoParagraphFormatter.format(resolvedText)
            resolvedText = paragraphResult.text
            changes.append(contentsOf: paragraphResult.changes)
        }

        return TextProcessorOutput(text: resolvedText, changes: changes)
    }

    func isAvailable() -> Bool {
        true
    }

    /// Active dictionary targets and snippet triggers, reusing the same
    /// cached rules the replacement pass keeps warm. Dictionary targets are
    /// the corrected spellings the recognizer should produce; snippet
    /// triggers are the phrases the user actually speaks.
    func vocabularyBiasTerms() -> [String] {
        guard let rules = try? loadActiveRulesIfNeeded() else { return [] }
        // Called once per dictation session before decoding: builds the fuzzy
        // matcher (and loads the word list) here instead of on the finalize path.
        if settings.fuzzyDictionaryEnabled, settings.effectiveDictationLanguage == "en" {
            _ = fuzzyMatcher(for: rules.dictionaryEntries)
        }
        // Most-used terms first: the bias prompt has a tight token budget
        // (prefill costs ~35ms/token on the ANE — measured in
        // gauntlet/asr_eval), so when a large dictionary overflows it, the
        // names the user actually dictates must be the ones that fit.
        let targets = rules.dictionaryEntries.filter(\.isActive)
            .sorted { $0.usageCount > $1.usageCount }
            .map(\.target)
        let triggers = rules.snippetEntries.filter(\.isActive)
            .sorted { $0.usageCount > $1.usageCount }
            .map(\.trigger)
        return targets + triggers
    }

    private func loadActiveRulesIfNeeded() throws -> ActivePersonalMemoryRules {
        if memoryCacheIsDirty {
            cachedDictionaryEntries = try databaseManager.fetchDictionaryEntries(includeInactive: false)
            cachedSnippetEntries = try databaseManager.fetchSnippetEntries(includeInactive: false)
            cachedFuzzyMatcher = nil
            memoryCacheIsDirty = false
        }
        return ActivePersonalMemoryRules(
            dictionaryEntries: cachedDictionaryEntries,
            snippetEntries: cachedSnippetEntries
        )
    }

    private func fuzzyMatcher(for entries: [DictionaryEntry]) -> FuzzyDictionaryMatcher {
        if let cachedFuzzyMatcher { return cachedFuzzyMatcher }
        let matcher = FuzzyDictionaryMatcher(targets: entries.filter(\.isActive).map(\.target))
        cachedFuzzyMatcher = matcher
        return matcher
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

enum SpokenFormattingFormatter {
    private struct OrderedMarker {
        let range: Range<String.Index>
        let number: Int
        /// "First," is ordinary prose on its own; only "number one" and
        /// "item one" may start a one-item list.
        var isOrdinal = false
        /// Written as a digit ("2."), which prose has too ("I bought 2."):
        /// a list of these must start at 1.
        var isInline = false
    }

    private struct TextMarker {
        let range: Range<String.Index>
    }

    private struct LetterMarker {
        let range: Range<String.Index>
        /// 1 for a, 2 for b…
        let index: Int
    }

    /// One item's lines, and for the last item the prose that follows the
    /// list (its own paragraph).
    private typealias ItemLayout = (lines: [String], trailingProse: String?)

    private enum MarkerKind {
        case ordered
        case bullet
    }

    private static let orderedMarkerPattern = #"""
    (?<![\p{L}\p{N}_])(?:number|item)\s+(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|20|1[0-9]|[1-9])(?![\p{L}\p{N}_])
    """#

    private static let inlineOrderedMarkerPattern = #"""
    (?<![\p{L}\p{N}_])(20|1[0-9]|[1-9])[\.\)](?=\s+)
    """#

    /// "First, … Second, …" and "Firstly: …": an ordinal opening a clause
    /// (or following ", and") and followed by a comma or colon. Mid-sentence
    /// ordinals ("the first time") never match, and one alone is not a list.
    /// Spaces are written \x20 because these patterns are compiled ignoring
    /// literal whitespace.
    private static let ordinalMarkerPattern = #"""
    (?:^|(?<=[.!?:;,][\x20\t])|(?<=,[\x20\t]and[\x20\t]))(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)(?:ly)?(?=[\x20\t]*[,:])
    """#

    private static let bulletMarkerPattern = #"""
    (?<![\p{L}\p{N}_])bullet\s+point(?![\p{L}\p{N}_])
    """#

    /// "letter a, … letter b, …" as said, "a) … b) …" / "(a) … (b) …" as
    /// transcribed, and "a. …" at the start of a line, the way a formatted
    /// list writes them. "a." mid-sentence is left alone: it's an initial or
    /// the article more often than a list.
    private static let spokenLetterPattern = #"(?<![\p{L}\p{N}_])letter\s+([a-j])(?![\p{L}\p{N}_])"#
    private static let writtenLetterPattern = #"(?:(?<![\p{L}\p{N}_])\(?([a-j])\)|^[ \t]*([a-j])[.)])(?=[ \t])"#
    private static let lineStartsWithLetterPattern = #"^[ \t]*(?:\(?[a-j][.)](?=[ \t])|letter\s+[a-j](?![\p{L}\p{N}_]))"#

    /// Guards that keep break commands from firing inside noun phrases:
    /// "add [a] new paragraph [about pricing]" is prose, "new paragraph" alone
    /// is a command.
    private static let breakCommandArticleGuard = #"(?<!\b(?:a|the|another|every|each|this|that|per|one) )"#
    private static let breakCommandFollowerGuard = #"(?![ \t]+(?:of|for|to|in|on|at|with|from|about|between|into)\b)"#

    private static var paragraphBreakPattern: String {
        #"[ \t]*[,;:]?[ \t]*(?<![\p{L}\p{N}_])"# + breakCommandArticleGuard
            + #"(?:new|next)[ \t]+paragraph(?![\p{L}\p{N}_])"# + breakCommandFollowerGuard
            + #"[.,;:]?"#
    }

    private static var lineBreakPattern: String {
        #"[ \t]*[,;:]?[ \t]*(?<![\p{L}\p{N}_])"# + breakCommandArticleGuard
            + #"(?:new[ \t]+line|newline|next[ \t]+line)(?![\p{L}\p{N}_])"# + breakCommandFollowerGuard
            + #"[.,;:]?"#
    }

    static func format(_ text: String) -> (text: String, changes: [String]) {
        let lineBreakResult = applyLineBreakCommands(to: text)
        var changes = lineBreakResult.changes

        // One paragraph at a time: a list ends where its paragraph does, and
        // a list already laid out (by Polish, or an earlier pass) comes
        // through as it is.
        let formatters: [(format: (String) -> String?, change: String)] = [
            (formatOrderedLists, "Spoken formatting: numbered list"),
            (formatLetteredList, "Spoken formatting: lettered list"),
            (formatBulletList, "Spoken formatting: bullet list"),
        ]
        let blocks = lineBreakResult.text.components(separatedBy: "\n\n").map { block -> String in
            for formatter in formatters {
                guard let formatted = formatter.format(block) else { continue }
                if formatted != block, !changes.contains(formatter.change) { changes.append(formatter.change) }
                return formatted
            }
            return block
        }
        return (blocks.joined(separator: "\n\n"), changes)
    }

    /// Applies spoken "new line" / "new paragraph" commands as real breaks,
    /// consuming the filler punctuation Whisper wraps them in and re-casing
    /// the sentence that follows. Trailing breaks are dropped (a pasted
    /// trailing newline submits in terminals and some chat apps); leading
    /// breaks are kept so dictation can push below the current line.
    static func applyLineBreakCommands(to text: String) -> (text: String, changes: [String]) {
        var replacementCount = 0
        var value = text

        for (pattern, breakText) in [(paragraphBreakPattern, "\n\n"), (lineBreakPattern, "\n")] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            let matches = regex.numberOfMatches(in: value, options: [], range: range)
            guard matches > 0 else { continue }
            replacementCount += matches
            value = regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: breakText)
        }

        guard replacementCount > 0 else { return (text, []) }

        value = value.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        value = capitalizedAfterLineBreaks(value)

        let label = replacementCount == 1 ? "1 line break command" : "\(replacementCount) line break commands"
        return (value, ["Spoken formatting: \(label)"])
    }

    private static func capitalizedAfterLineBreaks(_ text: String) -> String {
        var result = text
        var searchIndex = result.startIndex

        while let newlineIndex = result[searchIndex...].firstIndex(of: "\n") {
            var contentIndex = result.index(after: newlineIndex)
            while contentIndex < result.endIndex, result[contentIndex] == "\n" {
                contentIndex = result.index(after: contentIndex)
            }
            guard contentIndex < result.endIndex else { break }

            let firstCharacter = result[contentIndex]
            let nextIndex = result.index(after: contentIndex)
            // Same guard as capitalizedFirstContentWord: leave mixed-case
            // tokens like "iPhone" alone.
            let followedByUppercase = nextIndex < result.endIndex && result[nextIndex].isUppercase
            if firstCharacter.isLowercase, !followedByUppercase {
                result.replaceSubrange(contentIndex...contentIndex, with: String(firstCharacter).uppercased())
            }
            searchIndex = contentIndex
        }

        return result
    }

    /// Every numbered list in a paragraph. When a second list follows in
    /// the same paragraph, the first one's last item ends at the last
    /// sentence before it, so the sentence that introduces the second list
    /// ("For the afternoon,") stays with it.
    private static func formatOrderedLists(_ text: String) -> String? {
        let runs = orderedRuns(from: orderedMarkers(in: text), in: text)
        guard !runs.isEmpty else { return nil }

        var lists: [String] = []
        var start = text.startIndex
        for (index, run) in runs.enumerated() {
            let end = index + 1 < runs.count
                ? lastSentenceEnd(in: text, from: run[run.count - 1].range.upperBound, to: runs[index + 1][0].range.lowerBound)
                : text.endIndex
            guard let list = laidOutList(run.map(\.range), in: text, from: start, to: end, item: { item, raw, isLast in
                orderedItemLayout(number: run[item].number, raw: raw, isLast: isLast)
            }) else { return nil }
            lists.append(list)
            start = end
        }
        return lists.joined(separator: "\n\n")
    }

    /// "1. Item", and under it "a. …" lines when the item holds its own
    /// lettered points ("letter a, … letter b, …").
    private static func orderedItemLayout(number: Int, raw: String, isLast: Bool) -> ItemLayout? {
        guard let letters = letterRun(in: raw) else {
            return itemLayout(marker: "\(number).", raw: raw, isLast: isLast)
        }
        let head = cleanedItemContent(String(raw[..<letters[0].range.lowerBound]))
        var lines = [head.isEmpty ? "\(number)." : "\(number). \(capitalizedFirstContentWord(head))"]
        var trailingProse: String?
        for index in letters.indices {
            let isLastLetter = index == letters.count - 1
            let end = isLastLetter ? raw.endIndex : letters[index + 1].range.lowerBound
            guard let layout = itemLayout(
                marker: "\(letter(letters[index].index, uppercase: false)).",
                raw: String(raw[letters[index].range.upperBound..<end]),
                isLast: isLast && isLastLetter,
                indent: nestedIndent
            ) else { return nil }
            lines += layout.lines
            trailingProse = layout.trailingProse
        }
        return (lines, trailingProse)
    }

    /// Lettered points under a numbered item sit under its text.
    private static let nestedIndent = "   "

    /// A list of letters on its own: "A. …", "B. …".
    private static func formatLetteredList(_ text: String) -> String? {
        guard let run = letterRun(in: text) else { return nil }
        return laidOutList(run.map(\.range), in: text, from: text.startIndex, to: text.endIndex) { item, raw, isLast in
            itemLayout(marker: "\(letter(run[item].index, uppercase: true)).", raw: raw, isLast: isLast)
        }
    }

    private static func formatBulletList(_ text: String) -> String? {
        guard let run = bulletRun(from: bulletMarkers(in: text), in: text) else { return nil }
        return laidOutList(run.map(\.range), in: text, from: text.startIndex, to: text.endIndex) { _, raw, isLast in
            itemLayout(marker: "-", raw: raw, isLast: isLast)
        }
    }

    /// Lays out one run of markers found in `text[start..<end]`: what comes
    /// before the first marker is the list's introduction, each item runs to
    /// the next marker, and the last one to `end`, or to a line break the
    /// speaker (or Polish) put after it. Nil if an item is empty.
    private static func laidOutList(
        _ markers: [Range<String.Index>],
        in text: String,
        from start: String.Index,
        to end: String.Index,
        item: (_ index: Int, _ raw: String, _ isLast: Bool) -> ItemLayout?
    ) -> String? {
        var lines: [String] = []
        var trailingProse: String?
        var trailingLines: String?
        for index in markers.indices {
            let isLast = index == markers.count - 1
            var raw = String(text[markers[index].upperBound..<(isLast ? end : markers[index + 1].lowerBound)])
            if isLast { (raw, trailingLines) = endOfLastItem(raw) }
            guard let layout = item(index, raw, isLast) else { return nil }
            lines += layout.lines
            if isLast { trailingProse = layout.trailingProse }
        }

        var list = lines.joined(separator: "\n")
        if let trailingProse { list += "\n\n" + trailingProse }
        if let trailingLines { list += "\n" + trailingLines }

        let prefix = text[start..<markers[0].lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
        return prefix.isEmpty ? list : "\(prefix)\n\(list)"
    }

    private static func itemLayout(marker: String, raw: String, isLast: Bool, indent: String = "") -> ItemLayout? {
        var item = cleanedItemContent(raw)
        guard !item.isEmpty else { return nil }
        var trailingProse: String?
        if isLast {
            (item, trailingProse) = splitTrailingProse(fromLastItem: item)
        }
        return (["\(indent)\(marker) \(capitalizedFirstContentWord(item))"], trailingProse)
    }

    /// The last item ends at a line break, unless the next line carries on
    /// with the item's own lettered points. What follows the break is kept
    /// as it was.
    private static func endOfLastItem(_ raw: String) -> (item: String, trailing: String?) {
        var searchStart = raw.startIndex
        while let newline = raw[searchStart...].firstIndex(of: "\n") {
            let rest = String(raw[raw.index(after: newline)...])
            searchStart = raw.index(after: newline)
            // Item text starting on the next line ("number one, new line, …").
            guard !cleanedItemContent(String(raw[..<newline])).isEmpty else { continue }
            if rest.range(of: lineStartsWithLetterPattern, options: [.regularExpression, .caseInsensitive]) != nil { continue }
            let trailing = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            return (String(raw[..<newline]), trailing.isEmpty ? nil : trailing)
        }
        return (raw, nil)
    }

    /// Just after the last sentence end in `text[start..<end]`, or `end`.
    private static func lastSentenceEnd(in text: String, from start: String.Index, to end: String.Index) -> String.Index {
        guard let regex = try? NSRegularExpression(pattern: #"[.!?]["”’)]?\s+"#),
              let match = regex.matches(in: text, range: NSRange(start..<end, in: text)).last,
              let range = Range(match.range, in: text) else {
            return end
        }
        return range.upperBound
    }

    /// Runs of consecutive numbers (1, 2, 3…), each of at least two items,
    /// in order. Digit-only runs must start at 1, so "I bought 2. Then I
    /// bought 3." stays prose. A lone "number one" opening the paragraph is a
    /// one-item list.
    private static func orderedRuns(from markers: [OrderedMarker], in text: String) -> [[OrderedMarker]] {
        var sequences: [[OrderedMarker]] = []
        for marker in markers {
            if let last = sequences.last?.last, marker.number == last.number + 1 {
                sequences[sequences.count - 1].append(marker)
            } else {
                sequences.append([marker])
            }
        }

        let runs = sequences.filter { $0.count >= 2 && !($0[0].isInline && $0[0].number != 1) }
        if !runs.isEmpty {
            return runs
        }

        if let firstMarker = markers.first, firstMarker.number == 1, !firstMarker.isOrdinal,
           isLikelySingleMarkerCommand(firstMarker.range, in: text, kind: .ordered) {
            return [[firstMarker]]
        }

        return []
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
        var markers: [OrderedMarker] = []
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)

        if let regex = try? NSRegularExpression(
            pattern: orderedMarkerPattern,
            options: [.caseInsensitive, .allowCommentsAndWhitespace]
        ) {
            markers.append(contentsOf: regex.matches(in: text, options: [], range: nsRange).compactMap { match in
                guard let fullRange = Range(match.range, in: text),
                      let numberRange = Range(match.range(at: 1), in: text),
                      let number = numberValue(String(text[numberRange])) else {
                    return nil
                }
                return OrderedMarker(range: fullRange, number: number)
            })
        }

        if let ordinalRegex = try? NSRegularExpression(
            pattern: ordinalMarkerPattern,
            options: [.caseInsensitive, .allowCommentsAndWhitespace, .anchorsMatchLines]
        ) {
            markers.append(contentsOf: ordinalRegex.matches(in: text, options: [], range: nsRange).compactMap { match in
                guard let fullRange = Range(match.range, in: text),
                      let ordinalRange = Range(match.range(at: 1), in: text),
                      let number = numberValue(String(text[ordinalRange])) else {
                    return nil
                }
                return OrderedMarker(range: fullRange, number: number, isOrdinal: true)
            })
        }

        if let inlineRegex = try? NSRegularExpression(
            pattern: inlineOrderedMarkerPattern,
            options: [.caseInsensitive, .allowCommentsAndWhitespace]
        ) {
            markers.append(contentsOf: inlineRegex.matches(in: text, options: [], range: nsRange).compactMap { match in
                guard let fullRange = Range(match.range, in: text),
                      let numberRange = Range(match.range(at: 1), in: text),
                      let number = numberValue(String(text[numberRange])) else {
                    return nil
                }
                return OrderedMarker(range: fullRange, number: number, isInline: true)
            })
        }

        // "number 2." matches as a spoken and as a written marker: keep one.
        var kept: [OrderedMarker] = []
        for marker in markers.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if let previous = kept.last, marker.range.lowerBound < previous.range.upperBound { continue }
            kept.append(marker)
        }
        return kept
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

    /// The first run of consecutive letters starting at "a", at least two
    /// long.
    private static func letterRun(in text: String) -> [LetterMarker]? {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var markers: [LetterMarker] = []
        for pattern in [spokenLetterPattern, writtenLetterPattern] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines]) else { continue }
            for match in regex.matches(in: text, range: nsRange) {
                guard let range = Range(match.range, in: text) else { continue }
                let letterRange = (1..<match.numberOfRanges).lazy
                    .compactMap { Range(match.range(at: $0), in: text) }
                    .first
                guard let letterRange, let scalar = text[letterRange].lowercased().unicodeScalars.first else { continue }
                markers.append(LetterMarker(range: range, index: Int(scalar.value) - 96))
            }
        }
        markers.sort { $0.range.lowerBound < $1.range.lowerBound }

        var run: [LetterMarker] = []
        for marker in markers {
            if let last = run.last, marker.range.lowerBound < last.range.upperBound { continue }
            if let last = run.last, marker.index == last.index + 1 {
                run.append(marker)
            } else if run.count >= 2 {
                break
            } else {
                run = marker.index == 1 ? [marker] : []
            }
        }
        return run.count >= 2 ? run : nil
    }

    private static func letter(_ index: Int, uppercase: Bool) -> String {
        let value = String(UnicodeScalar(UInt8(96 + index)))
        return uppercase ? value.uppercased() : value
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
            of: #"(?i)(?:,?\s+)?(?:and|or|then|next)$"#,
            with: "",
            options: .regularExpression
        )
    }

    /// Nothing marks where the last item ends, so a long one keeps its
    /// opening sentences (up to `lastItemMaximumWords`) and the rest of the
    /// dictation follows the list as its own paragraph.
    private static let lastItemMaximumWords = 40
    private static let lastItemMaximumSentences = 3

    private static func splitTrailingProse(fromLastItem item: String) -> (item: String, trailing: String?) {
        let sentences = AutoParagraphFormatter.sentences(in: item)
        guard sentences.count > 1, wordCount(in: item) > lastItemMaximumWords else { return (item, nil) }

        var kept: [String] = [sentences[0]]
        var keptWords = wordCount(in: sentences[0])
        for sentence in sentences.dropFirst() {
            let words = wordCount(in: sentence)
            guard kept.count < lastItemMaximumSentences, keptWords + words <= lastItemMaximumWords else { break }
            kept.append(sentence)
            keptWords += words
        }
        guard kept.count < sentences.count else { return (item, nil) }
        let trailing = sentences.dropFirst(kept.count).joined(separator: " ")
        return (kept.joined(separator: " "), capitalizedFirstContentWord(trailing))
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
            "ten": 10,
            "eleven": 11,
            "twelve": 12,
            "thirteen": 13,
            "fourteen": 14,
            "fifteen": 15,
            "sixteen": 16,
            "seventeen": 17,
            "eighteen": 18,
            "nineteen": 19,
            "twenty": 20,
            "first": 1,
            "second": 2,
            "third": 3,
            "fourth": 4,
            "fifth": 5,
            "sixth": 6,
            "seventh": 7,
            "eighth": 8,
            "ninth": 9,
            "tenth": 10
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

/// Splits a long dictation that came out as one block into paragraphs, the
/// way it would have been typed: at sentence ends, preferring a sentence
/// that opens a new point ("Also", "Another thing", "Finally"). Not used
/// when the speaker laid the text out with "new line" / "new paragraph".
enum AutoParagraphFormatter {
    /// Shorter dictations (about 30 seconds of speech) stay one paragraph.
    static let minimumWords = 80
    /// A paragraph may end at a new point once it has this much...
    private static let minimumSentencesBeforeShift = 2
    private static let minimumWordsBeforeShift = 25
    /// ...and must end by this size even without one.
    private static let maximumParagraphWords = 90
    private static let minimumSentencesPerParagraph = 3
    /// A shorter last sentence joins the paragraph before it.
    private static let minimumTrailingWords = 12

    /// Openers that move to a new point. Matched against the start of a
    /// sentence, case-insensitively, as whole words.
    private static let topicShiftOpeners = [
        "also", "another", "additionally", "in addition", "next", "then",
        "finally", "lastly", "now", "anyway", "so", "however", "on the other hand",
        "the other thing", "the other one", "one more thing", "moving on",
        "secondly", "thirdly", "besides", "meanwhile", "overall", "in summary"
    ]

    /// Apps where a pasted newline runs a command.
    private static let terminalApps: Set<String> = [
        "terminal", "iterm", "iterm2", "ghostty", "warp", "alacritty", "kitty",
        "wezterm", "hyper", "tabby", "cmux"
    ]

    static func appliesTo(targetApp: String?) -> Bool {
        guard let targetApp else { return true }
        return !terminalApps.contains(targetApp.lowercased())
    }

    /// Splits each block of prose (text between blank lines) on its own, so
    /// the paragraph after a list is split too; blocks with line breaks
    /// inside, like the list itself, stay as they are.
    static func format(_ text: String) -> (text: String, changes: [String]) {
        var added = 0
        let blocks = text.components(separatedBy: "\n\n").map { block -> String in
            let split = paragraphs(in: block)
            added += split.count - 1
            return split.joined(separator: "\n\n")
        }
        guard added > 0 else { return (text, []) }
        let label = added == 1 ? "1 paragraph break" : "\(added) paragraph breaks"
        return (blocks.joined(separator: "\n\n"), ["Formatting: added \(label)"])
    }

    private static func paragraphs(in text: String) -> [String] {
        guard !text.contains("\n") else { return [text] }
        let allSentences = sentences(in: text)
        guard allSentences.count >= minimumSentencesPerParagraph * 2,
              wordCount(text) >= minimumWords else { return [text] }

        var paragraphs: [[String]] = [[]]
        var currentWords = 0
        for sentence in allSentences {
            let words = wordCount(sentence)
            let current = paragraphs[paragraphs.count - 1]
            let shiftsTopic = opensNewPoint(sentence)
                && current.count >= minimumSentencesBeforeShift
                && currentWords >= minimumWordsBeforeShift
            let isFull = current.count >= minimumSentencesPerParagraph
                && currentWords + words > maximumParagraphWords
            if !current.isEmpty, shiftsTopic || isFull {
                paragraphs.append([])
                currentWords = 0
            }
            paragraphs[paragraphs.count - 1].append(sentence)
            currentWords += words
        }

        if paragraphs.count > 1,
           let last = paragraphs.last,
           last.count == 1,
           wordCount(last[0]) < minimumTrailingWords {
            paragraphs.removeLast()
            paragraphs[paragraphs.count - 1].append(last[0])
        }
        guard paragraphs.count > 1 else { return [text] }
        return paragraphs.map { $0.joined(separator: " ") }
    }

    /// Sentences end at . ! ? (with any closing quote) before a capital
    /// letter or digit, so "e.g. this" and "3.5 GB" stay whole.
    static func sentences(in text: String) -> [String] {
        let pattern = #"(?<=[.!?][\"”’)]?)\s+(?=[\"“(]?[\p{Lu}\p{N}])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [text] }
        var sentences: [String] = []
        var start = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let sentence = text[start..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty { sentences.append(sentence) }
            start = range.upperBound
        }
        let tail = text[start...].trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    private static func opensNewPoint(_ sentence: String) -> Bool {
        let lowered = sentence.lowercased()
        return topicShiftOpeners.contains { opener in
            guard lowered.hasPrefix(opener) else { return false }
            let next = lowered.dropFirst(opener.count).first
            return next.map { !$0.isLetter } ?? true
        }
    }

    private static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace }.count
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

extension RuleBasedTextProcessor: WordBoostVocabularyProviding {
    /// Active dictionary targets for Express's Word Boost, each with the
    /// spellings the user mapped to it as aliases. Snippet triggers are left
    /// out: they are phrases to expand, not words the recognizer should write.
    func wordBoostTerms() -> [WordBoostTerm] {
        guard let rules = try? loadActiveRulesIfNeeded() else { return [] }
        return Self.wordBoostTerms(from: rules.dictionaryEntries)
    }

    nonisolated static func wordBoostTerms(from entries: [DictionaryEntry]) -> [WordBoostTerm] {
        var order: [String] = []
        var targets: [String: String] = [:]
        var aliases: [String: [String]] = [:]
        for entry in entries where entry.isActive {
            let target = entry.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { continue }
            let key = target.lowercased()
            if targets[key] == nil {
                targets[key] = target
                order.append(key)
            }
            let source = entry.source.trimmingCharacters(in: .whitespacesAndNewlines)
            if !source.isEmpty, source.lowercased() != key,
               !(aliases[key] ?? []).contains(where: { $0.lowercased() == source.lowercased() }) {
                aliases[key, default: []].append(source)
            }
        }
        return order.compactMap { key in
            targets[key].map { WordBoostTerm(text: $0, aliases: aliases[key] ?? []) }
        }
    }
}
