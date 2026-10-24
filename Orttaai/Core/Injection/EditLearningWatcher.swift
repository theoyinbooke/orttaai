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

/// How one check of a dictation's field ended. Shown in Memory › Suggestions
/// so the person can see the feature at work; never carries any text.
nonisolated enum EditCheckOutcome: String, Codable, Sendable, CaseIterable {
    /// A fixed name or term became a suggestion.
    case learned
    /// The dictation was edited, but not in a way that teaches a word.
    case editedNoName
    /// The dictation was left as it was.
    case noChange
    /// The field could be read, but the dictation wasn't in it.
    case textNotFound
    /// The app didn't let Orttaai read the field.
    case unreadable
    /// A password field: never read.
    case secureField
    /// Learning works on English dictation only.
    case notEnglish
}

/// Learns dictionary words from the user's own fixes. Right after a dictation
/// is inserted it reads the focused field (again for up to about a second and
/// a half if the paste hasn't shown up yet), then reads it again each time
/// its value changes and a few times over the next minute (and once more
/// when the next dictation starts). A field that empties, as a chat box does
/// when the message is sent, ends the watch with the text it held just
/// before. Words the user corrected inside the dictated text become pending
/// suggestions in Memory > Suggestions; nothing reaches the dictionary until
/// the user accepts one, and only the word pair is stored, never the field's
/// text. Secure fields are never read, and a move to another field ends the
/// watch. Each watch reports how it ended, with no text.
final class EditLearningWatcher: InsertedTextWatching {
    static let readDelays: [Duration] = [.seconds(4), .seconds(12), .seconds(30), .seconds(60)]
    /// Re-reads while waiting for the pasted text to appear in the field.
    static let baselineRetries = 10
    static let baselineRetryDelay: Duration = .milliseconds(150)

    private struct Watch {
        let processIdentifier: pid_t
        let appName: String?
        let inserted: String
        let baseline: FocusedFieldRead
        var latestText: String
        var observation: AnyObject?
    }

    private let reader: FocusedFieldReading
    private let settings: AppSettings
    private let save: ([LearningSuggestionDraft]) -> Void
    private let report: (EditCheckOutcome, String?, Int) -> Void
    private let sleep: (Duration) async -> Void
    private var current: Watch?
    private var polling: Task<Void, Never>?
    private var starting: Task<Void, Never>?
    private var startingAppName: String?

    init(
        reader: FocusedFieldReading,
        settings: AppSettings,
        save: @escaping ([LearningSuggestionDraft]) -> Void,
        report: @escaping (EditCheckOutcome, String?, Int) -> Void = { _, _, _ in },
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.reader = reader
        self.settings = settings
        self.save = save
        self.report = report
        self.sleep = sleep
    }

    func watch(insertedText: String, targetApp: NSRunningApplication?) {
        finishCurrentWatch()
        guard settings.learnFromEditsEnabled else { return }
        let appName = targetApp?.localizedName
        guard settings.effectiveDictationLanguage == "en" else {
            report(.notEnglish, appName, 0)
            return
        }
        guard let processIdentifier = targetApp?.processIdentifier else {
            report(.unreadable, appName, 0)
            return
        }

        // The first read happens straight away; a paste some apps take a
        // moment to show is read again a few times before giving up.
        switch tryBegin(insertedText: insertedText, processIdentifier: processIdentifier, appName: appName) {
        case .began, .ended:
            return
        case .notYet:
            break
        }
        startingAppName = appName
        starting = Task { [weak self] in
            for _ in 0..<Self.baselineRetries {
                await self?.sleep(Self.baselineRetryDelay)
                guard !Task.isCancelled, let self else { return }
                switch self.tryBegin(insertedText: insertedText, processIdentifier: processIdentifier, appName: appName) {
                case .began, .ended:
                    self.starting = nil
                    return
                case .notYet:
                    continue
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.starting = nil
            self.report(self.lastStartFailure, appName, 0)
        }
    }

    func finishCurrentWatch() {
        if let starting {
            starting.cancel()
            self.starting = nil
            report(lastStartFailure, startingAppName, 0)
        }
        finish(readingFirst: true)
    }

    private enum StartResult {
        case began
        /// The watch can't start and has reported why.
        case ended
        case notYet
    }

    private var lastStartFailure: EditCheckOutcome = .unreadable

    private func tryBegin(insertedText: String, processIdentifier: pid_t, appName: String?) -> StartResult {
        guard let baseline = reader.readFocusedField(processIdentifier: processIdentifier) else {
            lastStartFailure = .unreadable
            return .notYet
        }
        guard !baseline.isSecure else {
            report(.secureField, appName, 0)
            return .ended
        }
        guard let text = baseline.text, EditCorrectionFinder.fieldText(text, contains: insertedText) else {
            lastStartFailure = baseline.text == nil ? .unreadable : .textNotFound
            return .notYet
        }

        current = Watch(
            processIdentifier: processIdentifier,
            appName: appName,
            inserted: insertedText,
            baseline: baseline,
            latestText: text
        )
        current?.observation = reader.observeFocusedField(processIdentifier: processIdentifier) { [weak self] in
            self?.fieldChanged()
        }
        polling = Task { [weak self] in
            for delay in Self.readDelays {
                await self?.sleep(delay)
                guard !Task.isCancelled, let watcher = self else { return }
                guard watcher.readAgain() else { break }
            }
            guard !Task.isCancelled else { return }
            self?.finish(readingFirst: false)
        }
        return .began
    }

    private func fieldChanged() {
        guard current != nil, !readAgain() else { return }
        finish(readingFirst: false)
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
        guard !corrections.isEmpty else {
            let edited = EditCorrectionFinder.normalizedWhitespace(watch.latestText)
                != EditCorrectionFinder.normalizedWhitespace(watch.baseline.text ?? "")
            report(edited ? .editedNoName : .noChange, watch.appName, 0)
            return
        }
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
        report(.learned, watch.appName, corrections.count)
        Logger.memory.info("Learned \(corrections.count) correction(s) from an edit")
    }

    /// Updates the latest text from the watched field. Returns false when the
    /// watch is over: the field lost focus, can't be read, was emptied (the
    /// message was sent), or turned secure (then nothing is learned at all).
    private func readAgain() -> Bool {
        guard let watch = current else { return false }
        guard let read = reader.readFocusedField(processIdentifier: watch.processIdentifier),
              read.elementID == watch.baseline.elementID else { return false }
        guard !read.isSecure else {
            current = nil
            report(.secureField, watch.appName, 0)
            return false
        }
        if let text = read.text {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            current?.latestText = text
        }
        return true
    }
}
