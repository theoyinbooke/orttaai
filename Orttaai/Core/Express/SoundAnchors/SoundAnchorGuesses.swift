// SoundAnchorGuesses.swift
// Orttaai (ported from Orttakey's OrttakeyPolish, same rules and numbers)
//
// Starting anchors for your Words before you've fixed anything. A name like
// Eimailar is spelled like an everyday word with an ending ("email" + "ar"),
// and that everyday word is what the speech model writes when you say it
// fast. So each of your words that looks like that gets an anchor from the
// start, with nothing learned yet: the line at zero, the sound's spellings
// ("emailer", "emailar") and listening again slowed down. Your fixes then
// teach the real sound and move the line, as for any anchor.

import Foundation

nonisolated enum SoundAnchorGuesses {
    /// How alike your word and "everyday word + ending" must be spelled.
    /// Near-exact only: "emailar" for Eimailar is 0.88, "soundar" for
    /// soundAr 1, "equipar" for iquipAr 0.86; "meetupa" for Meetumo (0.71)
    /// and "hetmaner" for Hetzner (0.75) are too far to guess.
    static let minimumSimilarity: Float = 0.85

    /// Each term's guess, worked out once: the word list is long.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: SoundAnchor?] = [:]

    /// For each of `terms`, the everyday word it starts like, if one fits.
    static func anchors(for terms: [String]) -> [SoundAnchor] {
        terms.compactMap { term in
            lock.lock()
            if let known = cache[term] { lock.unlock(); return known }
            lock.unlock()
            let guess = guessed(term)
            lock.lock()
            cache[term] = guess
            lock.unlock()
            return guess
        }
    }

    private static func guessed(_ term: String) -> SoundAnchor? {
        guard EnglishLexicon.isAvailable, !term.contains(" ") else { return nil }
        let listed = EnglishLexicon.listedWords
        var anchors: [SoundAnchor] = []
        do {
            let letters = term.lowercased().filter { $0.isLetter }
            // Long enough to be a name, and not itself an everyday word.
            guard letters.count >= 6, !EnglishLexicon.isRealWord(letters), let first = letters.first else { return nil }
            var best: (word: String, similarity: Float)?
            for word in listed where word.first == first && word.count >= 4 && word.count < letters.count && word.count >= letters.count - 4 {
                for ending in SoundAnchorJudge.lostEndings {
                    let similarity = WordBoostGuard.spellingSimilarity(word + ending, letters)
                    if similarity >= minimumSimilarity, similarity > (best?.similarity ?? 0) || (similarity == best?.similarity && word.count > best!.word.count) {
                        best = (word, similarity)
                    }
                }
            }
            if let best {
                anchors.append(SoundAnchor(heard: best.word, term: term, sounds: SoundAnchorJudge.soundOptions(heard: best.word, term: term)))
            }
        }
        return anchors.first
    }
}

extension SoundAnchorBook {
    /// The anchors your fixes taught, plus starting ones for your Words that
    /// have none yet. The starting ones are never saved.
    func addingGuesses(for terms: [String]) -> SoundAnchorBook {
        adding(SoundAnchorBook(SoundAnchorGuesses.anchors(for: terms)))
    }

    /// These anchors, plus `guesses` for words they have none for.
    func adding(_ guesses: SoundAnchorBook) -> SoundAnchorBook {
        let taught = Set(anchors.map { $0.term.lowercased() })
        return SoundAnchorBook(anchors + guesses.anchors.filter { !taught.contains($0.term.lowercased()) })
    }
}
