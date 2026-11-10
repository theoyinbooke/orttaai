// EditInstructionClassifier.swift
// Orttaai

import Foundation

/// Decides whether words spoken on the dictation key, with text selected,
/// are an instruction for that text ("make this shorter") or new text meant
/// to replace it. Fixed rules, so the same words always go the same way, and
/// strict on purpose: a missed instruction only types the words (one Cmd+Z),
/// while a sentence mistaken for an instruction rewrites the selection.
/// "It", "this" and "that" alone never count, since everyday sentences are
/// full of them ("put it on the calendar"). English only: other languages
/// use the edit key.
nonisolated enum EditInstructionClassifier {
    /// Longer than this is dictation, not a command.
    static let maxWords = 14

    /// Verbs that only mean "change this text". They count alone ("shorten")
    /// or followed by a word that points at the text or says how ("rewrite
    /// this…", "translate to French", "summarize in three bullets").
    static let editVerbs: Set<String> = [
        "rewrite", "rephrase", "reword", "paraphrase", "shorten", "lengthen", "summarize", "summarise",
        "translate", "proofread", "simplify", "condense", "capitalize", "capitalise", "reformat"
    ]

    /// Words that may follow an edit verb.
    static let editVerbFollowers: Set<String> = [
        "this", "it", "that", "these", "those", "them", "everything", "all",
        "to", "into", "as", "in", "for"
    ]

    /// Nouns that name the text itself, after "the" ("summarize the text").
    static let textNouns: Set<String> = [
        "text", "selection", "paragraph", "paragraphs", "sentence", "sentences", "wording", "above"
    ]

    /// Everyday verbs that also start ordinary sentences.
    static let commonVerbs: Set<String> = [
        "make", "fix", "change", "turn", "convert", "format", "add", "remove", "delete", "replace", "correct",
        "clean", "put", "expand", "improve", "tighten", "polish", "soften", "trim", "write", "cut"
    ]

    /// What about the text should change. An everyday verb counts only with
    /// one of these ("make it more formal", "fix the grammar").
    static let qualityWords: Set<String> = [
        "grammar", "spelling", "punctuation", "typo", "typos", "tone", "wording",
        "formal", "casual", "friendly", "friendlier", "professional", "polite",
        "shorter", "longer", "simpler", "clearer", "concise", "uppercase", "lowercase", "capitals",
        "list", "bullets", "bullet", "bulleted", "numbered",
        "text", "selection", "paragraph", "paragraphs", "sentence", "sentences"
    ]

    /// Short commands that are instructions only as the whole utterance.
    static let wholeCommands: Set<[String]> = [
        ["fix", "this"], ["fix", "it"], ["fix", "that"],
        ["clean", "this", "up"], ["clean", "it", "up"], ["tidy", "this", "up"], ["tidy", "it", "up"],
        ["improve", "this"], ["improve", "it"], ["make", "this", "better"], ["make", "it", "better"]
    ]

    /// Polite openers skipped before looking for the verb.
    static let openers: [[String]] = [
        ["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"],
        ["please"], ["just"], ["now"], ["okay"], ["ok"]
    ]

    static func isInstruction(_ transcript: String) -> Bool {
        var words = transcript
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= maxWords else { return false }

        var skipped = true
        while skipped {
            skipped = false
            for opener in openers where words.starts(with: opener) && words.count > opener.count {
                words.removeFirst(opener.count)
                skipped = true
            }
        }

        if wholeCommands.contains(words) { return true }
        guard let verb = words.first else { return false }
        let rest = Array(words.dropFirst())

        if editVerbs.contains(verb) {
            guard let next = rest.first else { return true }
            if editVerbFollowers.contains(next) { return true }
            return next == "the" && rest.count > 1 && textNouns.contains(rest[1])
        }

        guard commonVerbs.contains(verb) else { return false }
        // "Make sure you call her" is a sentence, not a command.
        if verb == "make", rest.first == "sure" { return false }
        return rest.contains(where: qualityWords.contains)
    }
}
