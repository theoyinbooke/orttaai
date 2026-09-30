// ConceptExtractor.swift
// Orttaai

import Foundation
import NaturalLanguage

/// What a concept is. Drives color, ranking weight, and how aliases merge.
nonisolated enum ConceptKind: String, Codable, Sendable, CaseIterable {
    case person
    case organization
    case place
    /// Products, projects, tools, and other proper names: the capitalized
    /// names NER does not know ("Orttaai", "Vercel") and dictionary terms.
    case product
    case topic

    var displayName: String {
        switch self {
        case .person: return "Person"
        case .organization: return "Organization"
        case .place: return "Place"
        case .product: return "Project or product"
        case .topic: return "Topic"
        }
    }

    /// Named things outrank generic topics when they tie on mentions.
    var rankBoost: Double {
        switch self {
        case .person: return 1.45
        case .product: return 1.35
        case .organization: return 1.3
        case .place: return 1.1
        case .topic: return 1.0
        }
    }

    /// Precedence when the same key is tagged with different kinds.
    var precedence: Int {
        switch self {
        case .person: return 4
        case .product: return 3
        case .organization: return 2
        case .place: return 1
        case .topic: return 0
        }
    }
}

/// One concept found in one dictation.
nonisolated struct ExtractedConcept: Codable, Hashable, Sendable {
    /// Normalized identity: lowercased, possessives and "app" suffixes removed.
    let key: String
    /// Surface form as spoken, for display.
    let title: String
    let kind: ConceptKind
}

/// Deterministic, on-device concept extraction for a single dictation, built
/// on Apple's NaturalLanguage framework. Results are cached per dictation
/// (see `ConceptGraphStore`), so this runs once per dictation, ever.
nonisolated enum ConceptExtractor {
    /// Bump when extraction output changes so cached results are recomputed.
    static let version = 3

    static let maxTopicsPerDictation = 6
    static let maxNamesPerDictation = 8

    static func concepts(in text: String) -> [ExtractedConcept] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var byKey: [String: ExtractedConcept] = [:]
        func add(_ title: String, kind: ConceptKind, lemmaKey: String? = nil) {
            guard let trimmedName = kind == .topic ? title : trimmedName(title) else { return }
            let cleanedTitle = displayTitle(trimmedName)
            let key = lemmaKey.map { normalizedKey($0, kind: kind) } ?? normalizedKey(cleanedTitle, kind: kind)
            guard key.count >= 2, !stopKeys.contains(key) else { return }
            if let existing = byKey[key], existing.kind.precedence >= kind.precedence {
                return
            }
            byKey[key] = ExtractedConcept(key: key, title: cleanedTitle, kind: kind)
        }

        for entity in SemanticTextAnalyzer.namedEntities(in: trimmed, limit: maxNamesPerDictation) {
            switch entity.category {
            case "Person": add(entity.title, kind: .person)
            case "Organization": add(entity.title, kind: .organization)
            case "Place": add(entity.title, kind: .place)
            default: add(entity.title, kind: .product)
            }
        }

        for name in properNames(in: trimmed).prefix(maxNamesPerDictation) {
            add(name, kind: .product)
        }

        // Ask for extra topics: the filters below discard the vague ones.
        for topic in SemanticTextAnalyzer.topicConcepts(in: trimmed, limit: maxTopicsPerDictation * 2) {
            let tokens = topic.key.split(separator: " ").map(String.init)
            // A single generic noun ("button", "page") says nothing on its
            // own, and neither does a phrase made only of them ("hand side").
            guard tokens.contains(where: { !lowSignalNouns.contains($0) }) else { continue }
            // The analyzer's key is the lemma ("insights" → "insight"), so
            // plural and singular mentions stay one concept.
            add(topic.title, kind: .topic, lemmaKey: topic.key)
        }

        // A phrase covers its words: "design system" makes "design" and
        // "system" redundant in the same dictation.
        let phraseTokens = Set(byKey.keys.filter { $0.contains(" ") }.flatMap { $0.split(separator: " ").map(String.init) })
        for (key, concept) in byKey where concept.kind == .topic && !key.contains(" ") && phraseTokens.contains(key) {
            byKey[key] = nil
        }
        let topics = byKey.values.filter { $0.kind == .topic }
            .sorted { ($0.key.contains(" ") ? 0 : 1, $0.key) < ($1.key.contains(" ") ? 0 : 1, $1.key) }
        for extra in topics.dropFirst(maxTopicsPerDictation) {
            byKey[extra.key] = nil
        }

        return byKey.values.sorted { lhs, rhs in
            if lhs.kind.precedence == rhs.kind.precedence { return lhs.key < rhs.key }
            return lhs.kind.precedence > rhs.kind.precedence
        }
    }

    // MARK: - Normalization

    /// Identity for a concept. Case, possessives, and a trailing "app" never
    /// split one thing into two ("Meetumo app", "meetumo's" → "meetumo").
    static func normalizedKey(_ title: String, kind: ConceptKind) -> String {
        var key = title
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"'s\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if kind != .topic, key.hasSuffix(" app"), key.count > 5 {
            key = String(key.dropLast(4))
        }
        return key
    }

    static func displayTitle(_ raw: String) -> String {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard let first = trimmed.first, first.isLowercase else { return trimmed }
        return first.uppercased() + trimmed.dropFirst()
    }

    /// Name taggers glue neighbors onto names ("Twitter it", "MCP can",
    /// "Groq g r o q"). Trim function words and stray letters from both ends.
    static func trimmedName(_ raw: String) -> String? {
        var tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        func isJunk(_ token: String) -> Bool {
            let lower = token.lowercased().trimmingCharacters(in: .punctuationCharacters)
            return lower.count <= 1 || nameEdgeWords.contains(lower)
        }
        while let last = tokens.last, isJunk(last) { tokens.removeLast() }
        while let first = tokens.first, isJunk(first) { tokens.removeFirst() }
        // Spelled-out letters inside ("g r o q") are dictation, not a name.
        tokens = tokens.filter { $0.count > 1 }
        guard !tokens.isEmpty else { return nil }
        let joined = tokens.joined(separator: " ")
        return commonCapitalized.contains(joined.lowercased()) ? nil : joined
    }

    private static let nameEdgeWords: Set<String> = [
        "it", "its", "can", "could", "you", "your", "we", "they", "he", "she", "i",
        "is", "are", "was", "be", "make", "made", "do", "does", "did", "what", "how",
        "why", "when", "where", "which", "who", "the", "a", "an", "and", "or", "but",
        "so", "to", "of", "in", "on", "at", "for", "with", "from", "by", "as", "that",
        "this", "these", "those", "there", "then", "now", "just", "also", "please",
        "okay", "ok", "yes", "no", "nope", "yeah", "hey", "let", "lets", "let's",
        "will", "would", "should", "have", "has", "had", "get", "got", "go", "going"
    ]

    // MARK: - Proper names

    /// Capitalized words that are not at the start of a sentence, which in
    /// dictated text are almost always names: "we shipped Orttaai to Vercel".
    /// Multi-word runs are left to `SemanticTextAnalyzer`; this catches the
    /// single-word names NER misses. Aggregation later requires a name to
    /// recur before it is trusted.
    static func properNames(in text: String) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sentence, _, _, _ in
            guard let sentence else { return }
            let words = sentence.split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" || $0 == "-") }
            for (index, raw) in words.enumerated() where index > 0 {
                let word = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "'’-"))
                guard word.count >= 3,
                      let first = word.first, first.isUppercase,
                      word.dropFirst().contains(where: \.isLowercase) || word.count <= 5,
                      !commonCapitalized.contains(word.lowercased()),
                      seen.insert(word.lowercased()).inserted else { continue }
                // Skip the first word of a multi-word name; the run extractor
                // already reports the whole name.
                let next = index + 1 < words.count ? words[index + 1] : nil
                if let next, let nextFirst = next.first, nextFirst.isUppercase { continue }
                let previous = words[index - 1]
                if let prevFirst = previous.first, prevFirst.isUppercase, index - 1 > 0 { continue }
                names.append(word)
            }
        }
        return names
    }

    /// Capitalized mid-sentence words that are not names.
    private static let commonCapitalized: Set<String> = [
        "i'm", "i've", "i'll", "i'd", "okay", "ok", "the", "and", "but",
        "you", "your", "yours", "we", "they", "he", "she", "it", "this", "that",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december", "english", "mac", "macos",
        "ios", "api", "url", "pdf", "ui", "ux", "ai", "usa", "god", "mr", "mrs", "ms", "dr",
        "svg", "png", "jpg", "json", "css", "html", "xml", "sdk", "cli", "vps", "llm",
        "ide", "os", "id", "faq", "csv", "http", "https", "www", "com", "app", "what"
    ]

    /// Nouns that are everyday vocabulary rather than a subject, especially
    /// when dictating to software and AI tools. Kept inside phrases
    /// ("design system", "video generation"), dropped on their own.
    static let lowSignalNouns: Set<String> = [
        "app", "application", "experience", "button", "page", "card", "user", "change", "code",
        "mode", "model", "agent", "line", "area", "rest", "detail", "look", "space", "goal",
        "text", "date", "job", "error", "file", "image", "menu", "issue", "feature", "option",
        "description", "action", "row", "screen", "component", "system", "plan", "base",
        "message", "chart", "color", "colour", "setting", "icon", "content", "template",
        "person", "people", "form", "banner", "test", "data", "scenario", "hand", "side",
        "default", "clip", "check", "ticket", "platform", "drop", "tab", "generation", "device",
        "update", "list", "view", "section", "window", "field", "item", "name", "word",
        "sentence", "question", "answer", "problem", "solution", "result", "step", "process",
        "work", "task", "context", "information", "info", "level", "value", "status", "state",
        "flow", "part", "term", "note", "link", "title", "label", "box", "input", "output",
        "response", "request", "prompt", "version", "build", "feedback", "support", "help",
        "need", "use", "number", "reason", "sense", "idea", "point", "fact", "case", "example",
        "end", "top", "bottom", "middle", "front", "back", "left", "right", "stuff", "way",
        "thing", "lot", "bit", "kind", "sort", "type", "bunch", "couple", "guy", "man", "woman",
        "folk", "everybody", "anybody", "somebody", "nobody", "month", "year", "minute",
        "second", "hour", "week", "day", "time", "moment", "today", "tomorrow", "yesterday",
        "morning", "night", "while", "place", "size", "shape", "style", "tool", "function",
        "method", "class", "variable", "string", "object", "property", "logic", "structure",
        "approach", "choice", "quality", "attempt", "instance", "mistake", "fix", "bug"
    ]

    /// Keys too vague to be a concept even when tagged as one.
    private static let stopKeys: Set<String> = [
        "you", "your", "we", "they", "he", "she", "it", "this", "that", "what", "how",
        "svg", "png", "jpg", "json", "css", "html", "xml", "sdk", "cli", "api", "url",
        "pdf", "ui", "ux", "ai", "vps", "llm", "ide", "id", "csv",
        "i", "im", "ive", "okay", "ok", "yeah", "hey", "hello", "hi", "thanks",
        "thank", "please", "sorry", "sure", "right", "well", "so", "um", "uh",
        "number", "sense", "reason", "end", "side", "top", "bottom", "level", "type",
        "stuff", "anything", "everything", "something", "nothing", "someone"
    ]
}
