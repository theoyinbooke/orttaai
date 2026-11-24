// SoundAnchors.swift
// Orttaai (ported from Orttakey's OrttakeyPolish, same rules and numbers)
//
// What your fixes taught about how your words sound. When you change a
// dictated "email" to "Eimailar", the keyboard asks the recording what it
// heard and keeps a sound anchor: the heard word, your word, how your word
// sounds to the speech model ("emailer"), and the sound margin of that fix.
// From then on every "email" the speech model writes is checked against the
// sound (SoundContrast): it becomes Eimailar only when the sound says
// "emailer", so plain "email" stays "email". Fixing it back the other way
// ("Eimailar" back to "email") teaches the opposite, and the line between the
// two moves to fit your voice.
//
// Pure Swift and Codable: the app and keyboard keep the anchors in the App
// Group (Library/Words/sound-anchors.json).

import Foundation

nonisolated struct SoundAnchor: Codable, Sendable, Equatable {
    /// What the speech model writes, as SoundContrast.key joins it ("email").
    var heard: String
    /// Your word ("Eimailar").
    var term: String
    /// How your word sounds to the CTC model, learned from your fixes
    /// ("emailer", "email or"), newest first. A heard word is scored against
    /// each and the best counts: the spelling of your word plays no part.
    var sounds: [String]
    /// Sound margins where you said your word (fixes to it).
    var said: [Float]
    /// Sound margins where you said the heard word (fixes back to it).
    var notSaid: [Float]
    /// Spellings fixed back: never written as your word again.
    var forgotten: [String] = []
    var updated: Date

    private enum CodingKeys: String, CodingKey { case heard, term, sounds, said, notSaid, forgotten, updated }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        heard = try values.decode(String.self, forKey: .heard)
        term = try values.decode(String.self, forKey: .term)
        sounds = try values.decode([String].self, forKey: .sounds)
        said = try values.decode([Float].self, forKey: .said)
        notSaid = try values.decode([Float].self, forKey: .notSaid)
        forgotten = try values.decodeIfPresent([String].self, forKey: .forgotten) ?? []
        updated = try values.decode(Date.self, forKey: .updated)
    }

    init(heard: String, term: String, sounds: [String], said: [Float] = [], notSaid: [Float] = [], updated: Date = Date()) {
        self.heard = SoundAnchorJudge.coreHeard(heard)
        self.term = term
        self.sounds = Self.merged(sounds, into: [])
        self.said = said
        self.notSaid = notSaid
        self.updated = updated
    }

    /// Margins kept for each side: enough to place the line, not a history.
    static let evidenceKept = 12
    /// Ways your word sounds, kept: a few voices and speeds.
    static let soundsKept = 4
    /// With no fix back yet, the line sits at zero (the sound fits your word
    /// better than the heard one), or a little below when your fixes were
    /// only weakly backed by the sound: never below this after one fix...
    static let lowestLineAfterOneFix: Float = -1
    /// ...or this after several.
    static let lowestLine: Float = -2
    /// Never above this, however a fix back scored.
    static let highestLine: Float = 8

    /// The sound margin above which the heard word becomes your word.
    ///
    /// Measured on synthetic speech (10 voices, 6 words, SoundLab): at this
    /// line about half of the times your word was said are caught, and about
    /// 1 in 100 times the ordinary word was said is changed. Each fix moves
    /// it: a fix to your word with a weak sound lowers it, a fix back raises
    /// it above that fix's margin.
    var line: Float {
        var line: Float = 0
        if let lowestSaid = said.min(), let highestNotSaid = notSaid.max() {
            if lowestSaid > highestNotSaid {
                // Your voice on both sides: between them, nearer to never
                // changing the heard word.
                line = max((lowestSaid + highestNotSaid) / 2, highestNotSaid + Self.marginAboveYourWord)
            } else {
                // Overlapping: halfway between the two sides' middles.
                line = (median(said) + median(notSaid)) / 2
            }
            // Enough of your own "email"s to know where they end: the line
            // may go as low as your voice says (your real "email"s scored
            // -9.4 to -5.5, your fast Eimailar -3.6).
            if notSaid.count >= Self.ownWordsToTrust {
                return min(Self.highestLine, max(Self.lowestLineFromYourVoice, line))
            }
        } else if let highestNotSaid = notSaid.max() {
            // Only fixes back: the line moves above the worst of them.
            line = max(0, highestNotSaid + 0.5)
        } else if let lowestSaid = said.min(), lowestSaid < 0 {
            let lowest = said.count >= 2 ? Self.lowestLine : Self.lowestLineAfterOneFix
            line = max(lowest, lowestSaid / 2)
        }
        return min(Self.highestLine, max(Self.lowestLine, line))
    }

    /// How far above your highest kept heard word the line stays.
    static let marginAboveYourWord: Float = 0.25
    /// Kept heard words ("email" you left as it was) needed before the line
    /// follows your voice below `lowestLine`.
    static let ownWordsToTrust = 3
    static let lowestLineFromYourVoice: Float = -8

    func accepts(_ margin: Float) -> Bool { margin > line }

    mutating func learnSaid(_ margin: Float, sounds learned: [String] = [], at date: Date = Date()) {
        said = Array((said + [margin]).suffix(Self.evidenceKept))
        sounds = Self.merged(learned, into: sounds)
        updated = date
    }

    /// New ways first, each once, lowercased, at most `soundsKept`.
    static func merged(_ new: [String], into old: [String]) -> [String] {
        var seen = Set<String>()
        return (new + old)
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(soundsKept)
            .map { $0 }
    }

    mutating func learnNotSaid(_ margin: Float, at date: Date = Date()) {
        notSaid = Array((notSaid + [margin]).suffix(Self.evidenceKept))
        updated = date
    }

    private func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

/// Every anchor, looked up by heard phrase.
nonisolated struct SoundAnchorBook: Codable, Sendable, Equatable {
    var anchors: [SoundAnchor]

    init(_ anchors: [SoundAnchor] = []) {
        self.anchors = anchors
    }

    /// Anchors are few (one per word you fixed): more than this, the oldest go.
    static let largest = 200

    var isEmpty: Bool { anchors.isEmpty }

    func anchor(heard: String, term: String) -> SoundAnchor? {
        let key = SoundAnchorJudge.coreHeard(heard)
        return anchors.first { $0.heard == key && $0.term == term }
    }

    /// Whether `term` is ever written for a heard phrase by sound: such a
    /// pair is decided by the sound, never by a text rule.
    func decidesBySound(heard: String, term: String) -> Bool {
        anchor(heard: heard, term: term) != nil
    }

    /// Whether any of your fixes taught how `term` sounds: then the sound
    /// check, not Word Boost's spelling rules, decides where it's written.
    func decidesBySound(term: String) -> Bool {
        anchors.contains { $0.term.caseInsensitiveCompare(term) == .orderedSame }
    }

    /// A fix to your word: you said `term` where the speech model wrote `heard`.
    mutating func learnSaid(heard: String, term: String, sounds: [String], margin: Float, at date: Date = Date()) {
        let key = SoundAnchorJudge.coreHeard(heard)
        guard !key.isEmpty, !term.isEmpty else { return }
        if let index = anchors.firstIndex(where: { $0.heard == key && $0.term == term }) {
            anchors[index].learnSaid(margin, sounds: sounds, at: date)
        } else if !sounds.isEmpty {
            anchors.append(SoundAnchor(heard: key, term: term, sounds: sounds, said: [margin], updated: date))
        }
        trim()
    }

    /// A fix back: you said `heard` where the sound check wrote `term`.
    /// With no anchor yet (the change came from a starting guess), one is
    /// made, so the fix back is remembered.
    mutating func learnNotSaid(heard: String, term: String, margin: Float, at date: Date = Date()) {
        let key = SoundAnchorJudge.coreHeard(heard)
        guard !key.isEmpty, !term.isEmpty else { return }
        if let index = anchors.firstIndex(where: { $0.heard == key && $0.term == term }) {
            anchors[index].learnNotSaid(margin, at: date)
        } else {
            anchors.append(SoundAnchor(heard: key, term: term, sounds: SoundAnchorJudge.soundOptions(heard: key, term: term), notSaid: [margin], updated: date))
            trim()
        }
    }

    /// A spelling of your word's sound fixed back to what it says ("emailer"
    /// back from Eimailar): never written as your word again.
    mutating func forgetSpelling(_ spelling: String, term: String) {
        let letters = spelling.lowercased().filter { $0.isLetter || $0.isNumber }
        for index in anchors.indices where anchors[index].term == term && !anchors[index].forgotten.contains(letters) {
            anchors[index].forgotten.append(letters)
            anchors[index].sounds.removeAll { $0.lowercased().filter { $0.isLetter || $0.isNumber } == letters }
        }
    }

    /// Forgets every anchor for a word, as when it leaves your Words.
    mutating func forget(term: String) {
        anchors.removeAll { $0.term.lowercased() == term.lowercased() }
    }

    private mutating func trim() {
        guard anchors.count > Self.largest else { return }
        anchors.sort { $0.updated > $1.updated }
        anchors = Array(anchors.prefix(Self.largest))
    }

    // MARK: Stored

    static func load(from url: URL?) -> SoundAnchorBook {
        guard let url, let data = try? Data(contentsOf: url) else { return SoundAnchorBook() }
        return (try? decoder.decode(SoundAnchorBook.self, from: data)) ?? SoundAnchorBook()
    }

    func save(to url: URL?) {
        guard let url, let data = try? Self.encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
