// SoundAnchorStore.swift
// Orttaai
//
// Where the sound anchors live on the Mac (sound-anchors.json beside the
// database, never synced, no audio in it), and what a dictation is given:
// the anchors your fixes taught, starting anchors for your words that look
// like an everyday word with an ending (SoundAnchorGuesses), and anchors for
// dictionary pairs from one everyday word to another word ("email" ->
// Eimailar), which the sound now decides instead of a text rule that rewrote
// every "email" you ever said.

import Foundation
import os

nonisolated final class SoundAnchorStore: @unchecked Sendable {
    static let shared = SoundAnchorStore()

    private let lock = NSLock()
    private var loaded: SoundAnchorBook?
    /// Express with Word Boost's model is decoding, so the sound can decide.
    private var soundIsListening = false

    private let fileURL: URL?

    /// - Parameter fileURL: where the anchors are kept; beside the database
    ///   unless given (tests).
    init(fileURL: URL? = try? AppStoragePaths.applicationSupportURL().appendingPathComponent("sound-anchors.json")) {
        self.fileURL = fileURL
    }

    /// The anchors your fixes taught.
    func book() -> SoundAnchorBook {
        lock.lock()
        defer { lock.unlock() }
        if let loaded { return loaded }
        let book = SoundAnchorBook.load(from: fileURL)
        loaded = book
        return book
    }

    /// Changes the taught anchors and saves them.
    @discardableResult
    func update(_ change: (inout SoundAnchorBook) -> Void) -> SoundAnchorBook {
        lock.lock()
        defer { lock.unlock() }
        var book = loaded ?? SoundAnchorBook.load(from: fileURL)
        change(&book)
        loaded = book
        book.save(to: fileURL)
        return book
    }

    /// What a word taught goes when it leaves the dictionary.
    func forget(term: String) {
        update { $0.forget(term: term) }
    }

    func setSoundIsListening(_ listening: Bool) {
        lock.lock()
        soundIsListening = listening
        lock.unlock()
    }

    /// A dictionary pair the sound decides rather than the text: only while
    /// the sound can (Express with Word Boost), and only from one everyday
    /// English word to another word ("email" -> Eimailar). Pairs from a
    /// misheard non-word ("Tematope" -> Temitope) stay text rules.
    func decidesBySound(source: String, target: String) -> Bool {
        lock.lock()
        let listening = soundIsListening
        lock.unlock()
        return listening && Self.isEverydayWordPair(source: source, target: target)
    }

    static func isEverydayWordPair(source: String, target: String) -> Bool {
        let words = SoundContrast.key(source)
        guard words.count == 1, EnglishLexicon.isAvailable, EnglishLexicon.isRealWord(words[0]) else { return false }
        return SoundAnchorJudge.letters(target) != words[0]
    }

    /// The anchors for a dictation with `terms` in the dictionary: the taught
    /// ones, starting guesses for terms with none, and anchors for terms an
    /// everyday word is mapped to. The guesses read the word list, so they
    /// are worked out off the caller's thread (and cached per term).
    func bookForDictation(terms: [WordBoostTerm]) async -> SoundAnchorBook {
        let taught = book()
        let texts = terms.map(\.text)
        let guesses = await Task.detached(priority: .utility) {
            SoundAnchorGuesses.anchors(for: texts)
        }.value
        var mapped: [SoundAnchor] = []
        for term in terms {
            for alias in term.aliases where Self.isEverydayWordPair(source: alias, target: term.text) {
                mapped.append(SoundAnchor(heard: alias, term: term.text, sounds: SoundAnchorJudge.soundOptions(heard: alias, term: term.text)))
            }
        }
        let freshGuesses = guesses.filter { guess in !mapped.contains { $0.heard == guess.heard && $0.term == guess.term } }
        return taught.adding(SoundAnchorBook(mapped + freshGuesses))
    }
}
