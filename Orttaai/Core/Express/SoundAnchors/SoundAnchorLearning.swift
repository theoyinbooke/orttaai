// SoundAnchorLearning.swift
// Orttaai
//
// Learns from what you change in a dictation, by the sound rather than the
// text. It keeps the last few dictations' sound in memory (never on disk)
// with what the sound anchors decided in each, and when the edit watch on a
// dictation ends it looks at every word you changed:
//  - an everyday word changed to one of your dictionary words, or to itself
//    with the ending the speech model lost ("email" -> Eimailar, "email" ->
//    emailer): you said your word there, so its sound is learned from the
//    recording. No "email -> Eimailar" text rule is suggested: that rewrote
//    every "email" you ever said. A word not yet in the dictionary is
//    suggested as a word of its own instead.
//  - your word changed back where the sound wrote it ("Eimailar" -> "email"):
//    you didn't say it there. The line moves up; no reverse rule.
//  - an "email" the sound kept and you left alone: one of your own "email"s,
//    which teaches where your voice's line sits.
// Ported from Orttakey's keyboard (KeyboardModel, "Sound anchors").

import Foundation
import os

@MainActor
final class SoundAnchorLearning {
    static let shared = SoundAnchorLearning()

    /// The transcriber the sound is learned with.
    var transcription: (any Transcribing)?
    /// Your dictionary words (targets), lowercased.
    var dictionaryTargets: () -> Set<String> = { [] }
    /// Where what's learned is kept.
    var store: SoundAnchorStore = .shared

    private struct Recent {
        let inserted: String
        let samples: [Float]
        let decisions: [SoundAnchorJudge.Decision]
        let at: Date
    }

    private var recent: [Recent] = []
    /// Longest sound kept for this (about 7.7 MB at 16 kHz).
    static let longestKept: TimeInterval = 120
    /// How long after its dictation a fix can still be learned from.
    static let keptFor: TimeInterval = 10 * 60
    static let dictationsKept = 3

    /// A dictation was typed in: its sound and decisions, for its edit watch.
    func remember(samples: [Float], inserted: String, decisions: [SoundAnchorJudge.Decision]) {
        recent.removeAll { Date().timeIntervalSince($0.at) > Self.keptFor || $0.inserted == inserted }
        guard Double(samples.count) / 16_000 <= Self.longestKept else { return }
        recent.append(Recent(inserted: inserted, samples: samples, decisions: decisions, at: Date()))
        if recent.count > Self.dictationsKept { recent.removeFirst(recent.count - Self.dictationsKept) }
    }

    /// The edit watch on `inserted` ended: learns from every change, and
    /// returns the name-like `suggestions` still worth offering.
    func review(inserted: String, before: String, caret: Int?, after: String, suggestions: [EditCorrection]) -> [EditCorrection] {
        guard let dictation = recent.last(where: { $0.inserted == inserted }),
              Date().timeIntervalSince(dictation.at) < Self.keptFor else { return suggestions }
        let changes = EditCorrectionFinder.corrections(
            inserted: inserted, before: before, insertionEndUTF16: caret, after: after, nameLikeOnly: false
        )
        let targets = dictionaryTargets()
        var handled: [EditCorrection] = []
        var changedHeard = Set<[String]>()
        var keptBack: [(heard: String, term: String, margin: Float, spelled: String?)] = []
        var toLearn: [(heard: String, term: String, occurrence: Int)] = []

        for change in changes {
            changedHeard.insert(SoundContrast.key(change.heard))
            // Your word put back where the sound wrote it.
            if let decision = dictation.decisions.first(where: {
                $0.applied && $0.term.caseInsensitiveCompare(change.heard) == .orderedSame
            }) {
                keptBack.append((change.corrected, decision.term, decision.margin,
                                 decision.margin >= SoundAnchorJudge.spelledMargin ? decision.heard : nil))
                handled.append(change)
                continue
            }
            // An everyday word made one of your words, or given back its ending.
            let heardWords = SoundContrast.key(change.heard)
            guard (1...2).contains(heardWords.count), EnglishLexicon.isAvailable,
                  heardWords.allSatisfy(EnglishLexicon.isRealWord),
                  !change.corrected.contains(" "),
                  targets.contains(change.corrected.lowercased()) || SoundAnchorJudge.isLongerForm(change.corrected, of: change.heard)
            else { continue }
            // The first place it was written: changes don't say which.
            toLearn.append((change.heard, change.corrected, 0))
            handled.append(change)
        }

        // Heard words the sound kept that you left as they were.
        let kept = dictation.decisions.filter {
            !$0.applied && $0.margin < SoundAnchorJudge.slowListenMargin && !changedHeard.contains(SoundContrast.key($0.heard))
        }
        if !kept.isEmpty || !keptBack.isEmpty {
            store.update { book in
                for decision in kept { book.learnNotSaid(heard: decision.heard, term: decision.term, margin: decision.margin) }
                for back in keptBack {
                    book.learnNotSaid(heard: back.heard, term: back.term, margin: back.margin)
                    if let spelled = back.spelled { book.forgetSpelling(spelled, term: back.term) }
                }
            }
            Logger.memory.info("Sound anchors: \(kept.count, privacy: .public) kept and \(keptBack.count, privacy: .public) put-back word(s) taught your voice's line")
        }
        if !toLearn.isEmpty {
            let samples = dictation.samples
            let transcription = transcription
            let store = store
            Task {
                for item in toLearn {
                    let learned = await transcription?.learnSound(from: samples, heard: item.heard, term: item.term, occurrence: item.occurrence)
                    store.update { book in
                        // Without the sound (no Word Boost model) the anchor
                        // still starts, from the spellings alone.
                        book.learnSaid(
                            heard: item.heard, term: item.term,
                            sounds: learned?.sounds ?? SoundAnchorJudge.soundOptions(heard: item.heard, term: item.term),
                            margin: learned?.margin ?? 0
                        )
                    }
                    Logger.memory.info("Sound anchors: a fix taught how one of your words sounds (margin \(learned?.margin ?? 0, format: .fixed(precision: 1), privacy: .public))")
                }
                await transcription?.refreshSoundAnchors()
            }
        }
        if !keptBack.isEmpty, toLearn.isEmpty {
            let transcription = transcription
            Task { await transcription?.refreshSoundAnchors() }
        }

        // Suggestions: never a rule the sound now decides. A word you made
        // that isn't in your dictionary yet is offered as itself.
        var remaining = suggestions.filter { suggestion in
            !handled.contains { $0.heard == suggestion.heard && $0.corrected == suggestion.corrected }
        }
        for item in toLearn where !targets.contains(item.term.lowercased()) {
            remaining.append(EditCorrection(heard: item.term, corrected: item.term))
        }
        return remaining
    }
}
