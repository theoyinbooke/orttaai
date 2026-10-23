// EditLearningWatcher.swift
// Orttaai

import AppKit
import Foundation
import os

/// Called after a dictation is inserted, and again when the next one starts.
protocol InsertedTextWatching: AnyObject {
    func watch(insertedText: String, targetApp: NSRunningApplication?)
    func finishCurrentWatch()
}

/// Learns dictionary words from the user's own fixes. Right after a dictation
/// is inserted it reads the focused field, then reads the same field again a
/// few times over the next minute (and once more when the next dictation
/// starts). Words the user corrected inside the dictated text become pending
/// suggestions in Memory > Suggestions; nothing reaches the dictionary until
/// the user accepts one, and only the word pair is stored, never the field's
/// text. Secure fields are never read, and a move to another field ends the
/// watch.
final class EditLearningWatcher: InsertedTextWatching {
    static let readDelays: [Duration] = [.seconds(4), .seconds(12), .seconds(30), .seconds(60)]

    private struct Watch {
        let processIdentifier: pid_t
        let appName: String?
        let inserted: String
        let baseline: FocusedFieldRead
        var latestText: String
    }

    private let reader: FocusedFieldReading
    private let settings: AppSettings
    private let save: ([LearningSuggestionDraft]) -> Void
    private let sleep: (Duration) async -> Void
    private var current: Watch?
    private var polling: Task<Void, Never>?

    init(
        reader: FocusedFieldReading,
        settings: AppSettings,
        save: @escaping ([LearningSuggestionDraft]) -> Void,
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.reader = reader
        self.settings = settings
        self.save = save
        self.sleep = sleep
    }

    func watch(insertedText: String, targetApp: NSRunningApplication?) {
        finishCurrentWatch()
        guard settings.learnFromEditsEnabled, settings.effectiveDictationLanguage == "en",
              let processIdentifier = targetApp?.processIdentifier,
              let baseline = reader.readFocusedField(processIdentifier: processIdentifier),
              !baseline.isSecure, let text = baseline.text,
              text.contains(insertedText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }

        current = Watch(
            processIdentifier: processIdentifier,
            appName: targetApp?.localizedName,
            inserted: insertedText,
            baseline: baseline,
            latestText: text
        )
        polling = Task { [weak self] in
            for delay in Self.readDelays {
                await self?.sleep(delay)
                guard !Task.isCancelled, let watcher = self else { return }
                guard watcher.readAgain() else { break }
            }
            guard !Task.isCancelled else { return }
            self?.finish(readingFirst: false)
        }
    }

    func finishCurrentWatch() {
        finish(readingFirst: true)
    }

    /// Ends the watch and saves what the user corrected. Reads the field one
    /// last time unless the watch already ended on a failed read.
    private func finish(readingFirst: Bool) {
        polling?.cancel()
        polling = nil
        if readingFirst {
            _ = readAgain()
        }
        guard let watch = current else { return }
        current = nil

        let corrections = EditCorrectionFinder.corrections(
            inserted: watch.inserted,
            before: watch.baseline.text ?? "",
            insertionEndUTF16: watch.baseline.caretUTF16,
            after: watch.latestText
        )
        guard !corrections.isEmpty else { return }
        let evidence = watch.appName.map { "Corrected after dictating into \($0)" } ?? "Corrected after dictating"
        save(corrections.map {
            LearningSuggestionDraft(
                type: .dictionary,
                candidateSource: $0.heard,
                candidateTarget: $0.corrected,
                confidence: 0.9,
                evidence: evidence
            )
        })
        Logger.memory.info("Learned \(corrections.count) correction(s) from an edit")
    }

    /// Updates the latest text from the watched field. Returns false when the
    /// watch is over: the field lost focus, can't be read, or turned secure
    /// (then nothing is learned at all).
    private func readAgain() -> Bool {
        guard let watch = current else { return false }
        guard let read = reader.readFocusedField(processIdentifier: watch.processIdentifier),
              read.elementID == watch.baseline.elementID else { return false }
        guard !read.isSecure else {
            current = nil
            return false
        }
        if let text = read.text {
            current?.latestText = text
        }
        return true
    }
}
