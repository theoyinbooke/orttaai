// SoundAnchorJudge.swift
// Orttaai (ported from Orttakey's OrttakeyPolish, same rules and numbers)
//
// Applies your sound anchors to one transcript: every place the speech model
// wrote an anchor's heard word is scored by sound against each way your word
// sounds, and written as your word only when the sound says so. The
// transcriber supplies the scoring (SoundContrast over its CTC frames).

import Foundation

nonisolated enum SoundAnchorJudge {
    /// Ways of sounding kept from each fix (the best few of the candidates).
    static let soundsLearnedPerFix = 3

    /// Pieces the speech model splits off the end of your word ("emailer"
    /// as "email er"): scored together with the heard word. Only pieces that
    /// aren't everyday words: in the lab, plain "email or a text" and
    /// "email at noon" sounded as much like "emailer" as the real thing, so
    /// taking "or" or "at" along changed one in ten of them.
    static let absorbable: Set<String> = ["er", "ar", "uh", "ah", "erm"]
    /// Taking a piece along needs the sound to be this much clearer.
    static let absorbedExtraLine: Float = 1.5
    /// Everyday words that can pass for the end of your word: "email or"
    /// and "emailer" are nearly the same sound. Before one of these, the
    /// heard word is changed only on much clearer sound.
    static let soundsLikeAnEnding: Set<String> = ["or", "a", "at", "are", "her", "of", "uh", "er"]
    static let beforeAnEndingExtraLine: Float = 4

    struct Decision: Sendable, Equatable {
        var heard: String
        var term: String
        var margin: Float
        var applied: Bool
        /// The margin with the next short word taken along, when tried.
        var marginWithNextWord: Float? = nil
        /// How much less likely the words are with that short word in them
        /// than without it, in nats, when the language could say.
        var languageGain: Float? = nil
        /// The heard words, for a second listen where the sound check kept them.
        var wordRange: Range<Int>? = nil
    }

    /// The margin recorded where listening again slowed down heard your word.
    static let slowListenMargin: Float = 50

    /// Speeds to listen again at, slowest last: at 60% of the speed, the lab
    /// heard the longer word in 35 of 133 clips where "emailer" had been
    /// written "email", and in none of 478 where "email" was said.
    static let slowListenRates: [Float] = [0.6, 0.7]

    /// Whether listening again slowed down heard your word where the heard
    /// one was written: your word itself, one of its sound spellings, or the
    /// heard word with the ending it lost ("emailer" for "email").
    static func slowListenHeard(_ words: [String], heard: String, term: String, spellings: [String: String]) -> Bool {
        words.contains { word in
            let spelled = letters(word)
            return spelled == letters(term) || spellings[spelled] == term || isLongerForm(word, of: heard)
        }
    }

    /// Endings a fast word loses: "emailer" said, "email" written.
    static let lostEndings: Set<String> = ["er", "ar", "a", "or", "ah", "ers", "ars"]

    /// `word` is `heard` with an ending it lost ("emailer" for "email"): a
    /// fix like that is about the sound, so it's learned by sound even when
    /// the word isn't in your Words.
    static func isLongerForm(_ word: String, of heard: String) -> Bool {
        let core = letters(coreHeard(heard)), spelled = letters(word)
        guard !core.isEmpty, spelled.hasPrefix(core), spelled.count > core.count else { return false }
        return lostEndings.contains(String(spelled.dropFirst(core.count)))
    }

    /// With an everyday ending word taken along ("email at" -> your word),
    /// the sound is weighed together with the words around it: "email at
    /// to Bola" is unlikely English and "Eimailar to Bola" fine, while
    /// "email or a text" is ordinary. Decided by `together + weight · gain`
    /// above the line plus `endingLine`.
    ///
    /// Measured in SoundLab (46 clips of your word written "email or/at …",
    /// 232 of plain "email or a text", "email at noon" and the like): the two
    /// overlap a lot, sound and language together. At 3 above the line, 12
    /// in 120 plain sentences changed; 9 is where none did, and it still
    /// catches 9 of the 46.
    static let languageWeight: Float = 1
    static let endingLine: Float = 9

    /// Spellings to try when learning how your word sounds, before the CTC
    /// model's own: your word as written, in lower case, split where its
    /// capitals are, and the heard word with the endings it most often lost.
    static func soundOptions(heard: String, term: String) -> [String] {
        let base = coreHeard(heard)
        var seen = Set<String>()
        return ([term.lowercased(), split(term)] + ["er", "ar", "a", "or"].map { base + $0 })
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Whether the CTC model's own spelling of the fixed words can stand for
    /// how your word sounds. Its spellings are often noise ("to wecome
    /// chter"); on the lab's clips, keeping only ones like these took false
    /// changes from 18 in 211 to 1.
    static func isPlausibleSound(_ spelling: String, heard: String, term: String) -> Bool {
        let letters = { (text: String) in text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let sound = letters(spelling), word = letters(term), base = letters(heard)
        guard !sound.isEmpty, sound != base, sound.count >= base.count else { return false }
        guard spelling.split(separator: " ").count <= split(term).split(separator: " ").count + 1 else { return false }
        return WordBoostGuard.spellingSimilarity(sound, word) >= 0.5
    }

    /// The heard words without an everyday ending word the speech model
    /// split off your word: a fix from "email at" teaches about "email".
    /// Anchors are kept for that, so a genuine "email at noon" is weighed
    /// with the stricter check for endings, never as a taught phrase.
    static func coreHeard(_ heard: String) -> String {
        var words = SoundContrast.key(heard)
        while words.count > 1, let last = words.last, soundsLikeAnEnding.contains(last) { words.removeLast() }
        return words.joined(separator: " ")
    }

    /// "soundAr" -> "sound ar", "BudgetBook" -> "budget book".
    static func split(_ term: String) -> String {
        var out = ""
        for character in term {
            if character.isUppercase, !out.isEmpty, out.last != " " { out.append(" ") }
            out.append(character)
        }
        return out.lowercased()
    }

    /// - Parameter margin: the sound margin of a word range, scored as heard
    ///   text against one way of sounding; nil when it can't be scored.
    /// - Returns: UTF-8 ranges of `text` to write as your words, and every
    ///   decision made.
    static func judge(
        _ book: SoundAnchorBook,
        text: String,
        words: [SoundWord],
        pairCost: ((String, String) -> Double?)? = nil,
        margin: (Range<Int>, String, String) -> Float?
    ) -> (replacements: [(Range<Int>, String)], decisions: [Decision]) {
        guard !book.isEmpty, !words.isEmpty else { return ([], []) }
        let ranges = utf8Ranges(of: words, in: text)
        var replacements: [(Range<Int>, String)] = []
        var taken: [Range<Int>] = []
        var decisions: [Decision] = []

        // Your word as the speech model spells its sound ("emailer",
        // "E-mailer"): the sound has already said which word it was.
        let spellings = soundSpellings(book)
        for (index, word) in words.enumerated() {
            let letters = Self.letters(word.text)
            guard let term = spellings[letters] ?? nearSpelling(letters, in: spellings), let range = ranges[index], word.text != term else { continue }
            replacements.append((range, term))
            taken.append(index..<(index + 1))
            decisions.append(Decision(heard: word.text, term: term, margin: spelledMargin, applied: true))
        }

        for anchor in book.anchors where !anchor.sounds.isEmpty {
            for occurrence in SoundContrast.occurrences(of: anchor.heard, in: words) {
                guard !taken.contains(where: { $0.overlaps(occurrence) }) else { continue }
                func best(_ range: Range<Int>) -> Float? {
                    let heard = words[range].map(\.text).joined(separator: " ")
                    return anchor.sounds.compactMap { margin(range, heard, $0) }.max()
                }
                guard let alone = best(occurrence) else { continue }
                let nextKey = occurrence.upperBound < words.count ? SoundContrast.key(words[occurrence.upperBound].text).joined() : ""
                // "email or" heard (a fix taught it) or "email" heard before
                // "or": either way an everyday word may be the ending.
                let endsInAnEnding = anchor.heard.split(separator: " ").count > 1
                    && soundsLikeAnEnding.contains(String(anchor.heard.split(separator: " ").last ?? ""))
                // Before an everyday ending the bar never drops with your fixes:
                // "email at lunch" must stay, however often you said Eimailar.
                let line = soundsLikeAnEnding.contains(nextKey) || endsInAnEnding ? max(0, anchor.line) + beforeAnEndingExtraLine : anchor.line
                var chosen: (range: Range<Int>, margin: Float)? = alone > line ? (occurrence, alone) : nil
                var withNext: Float?
                var gain: Float?
                if absorbable.contains(nextKey) || soundsLikeAnEnding.contains(nextKey) {
                    let longer = occurrence.lowerBound..<(occurrence.upperBound + 1)
                    withNext = best(longer)
                    if let together = withNext {
                        if absorbable.contains(nextKey) {
                            if together > anchor.line + absorbedExtraLine, together > alone { chosen = (longer, together) }
                        } else if let pairCost, occurrence.upperBound + 1 < words.count,
                                  let heardLast = SoundContrast.key(words[occurrence.upperBound - 1].text).last {
                            // The heard word is your word's stand-in for the
                            // language: how much the ending word costs between
                            // it and the word after, against going straight on.
                            let after = SoundContrast.key(words[occurrence.upperBound + 1].text).first ?? ""
                            if let first = pairCost(heardLast, nextKey), let second = pairCost(nextKey, after),
                               let direct = pairCost(heardLast, after) {
                                gain = Float(first + second - direct)
                                let score = together + languageWeight * gain!
                                if score > max(0, anchor.line) + endingLine { chosen = (longer, score) }
                            }
                        }
                    }
                }
                let heard = words[occurrence].map(\.text).joined(separator: " ")
                guard let chosen,
                      let first = ranges[chosen.range.lowerBound], let last = ranges[chosen.range.upperBound - 1] else {
                    decisions.append(Decision(heard: heard, term: anchor.term, margin: alone, applied: false, marginWithNextWord: withNext, languageGain: gain, wordRange: occurrence))
                    continue
                }
                replacements.append((first.lowerBound..<last.upperBound, anchor.term))
                taken.append(chosen.range)
                decisions.append(Decision(heard: heard, term: anchor.term, margin: chosen.margin, applied: true, marginWithNextWord: withNext, languageGain: gain))
            }
        }
        return (replacements, decisions)
    }

    /// The margin recorded for a word written as one of your word's sound
    /// spellings: the sound was unmistakable.
    static let spelledMargin: Float = 99

    /// Spellings of your words' sounds that stand for them wherever the
    /// speech model writes them: one word, not the heard word itself, and
    /// not in the English word list ("emailer" and "emaila" are kept,
    /// "sounder" isn't: that one is left to the sound check).
    static func soundSpellings(_ book: SoundAnchorBook) -> [String: String] {
        guard EnglishLexicon.isAvailable else { return [:] }
        var spellings: [String: String] = [:]
        for anchor in book.anchors {
            let heard = letters(anchor.heard)
            for sound in anchor.sounds + soundOptions(heard: anchor.heard, term: anchor.term) {
                let spelled = letters(sound)
                guard !sound.contains(" "), spelled.count >= 4, spelled != heard, spelled != letters(anchor.term),
                      !anchor.forgotten.contains(spelled), !EnglishLexicon.isListedWord(spelled) else { continue }
                spellings[spelled] = spellings[spelled] ?? anchor.term
            }
        }
        return spellings
    }

    /// How alike a written word must be to one of your word's sound
    /// spellings to count as it: "emila" and "emaila" are 0.83, "emilar"
    /// and "emailar" 0.86 (both written for Eimailar on the owner's phone),
    /// "emily" and "emaila" only 0.67.
    static let nearSpellingSimilarity: Float = 0.8

    /// A word the speech model spelled close to one of your word's sound
    /// spellings ("Emila" for "emaila"), that isn't English: your word.
    static func nearSpelling(_ letters: String, in spellings: [String: String]) -> String? {
        guard letters.count >= 4, EnglishLexicon.isAvailable, !EnglishLexicon.isRealWord(letters) else { return nil }
        var best: (term: String, similarity: Float)?
        for (spelling, term) in spellings where abs(spelling.count - letters.count) <= 2 {
            let similarity = WordBoostGuard.spellingSimilarity(letters, spelling)
            if similarity >= nearSpellingSimilarity, similarity > (best?.similarity ?? 0) { best = (term, similarity) }
        }
        return best?.term
    }

    static func letters(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Each word's UTF-8 range in `text`, found in order; nil where the text
    /// doesn't spell the word the same way.
    static func utf8Ranges(of words: [SoundWord], in text: String) -> [Range<Int>?] {
        var cursor = text.startIndex
        return words.map { word in
            guard let found = text.range(of: word.text, range: cursor..<text.endIndex) else { return nil }
            cursor = found.upperBound
            let lower = text.utf8.distance(from: text.startIndex, to: found.lowerBound)
            let upper = text.utf8.distance(from: text.startIndex, to: found.upperBound)
            return lower..<upper
        }
    }
}
