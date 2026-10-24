// EditLearningWatcher.swift
// Orttaai

import AppKit
import Foundation
import os

/// Called when recording starts, after a dictation is inserted, and again
/// when the next one starts.
protocol InsertedTextWatching: AnyObject {
    /// Recording into `targetApp` has started: get its field ready to read.
    func prepare(targetApp: NSRunningApplication?)
    func watch(insertedText: String, targetApp: NSRunningApplication?)
    func finishCurrentWatch()
}

extension InsertedTextWatching {
    func prepare(targetApp: NSRunningApplication?) {}
}

/// How one check of a dictation's field ended. Shown in Memory › Suggestions
/// so the person can see the feature at work; never carries any text.
nonisolated enum EditCheckOutcome: String, Codable, Sendable, CaseIterable {
    /// A fixed name or term became a suggestion.
    case learned
    /// A name or term was fixed, but it is already in the dictionary or
    /// was turned down before.
    case alreadyKnown
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

/// Learns dictionary words from the user's own fixes. When recording starts it
/// asks the target app to expose its fields (Chromium apps hide them until
/// asked). Right after a dictation is inserted it reads the focused field
/// (again for up to about a second and a half if the paste hasn't shown up
/// yet), then takes the field's text each time its value changes, checks a
/// few times over the next several minutes that the user is still in the
/// same field, and reads it once more when the next dictation starts. A
/// field that empties, as a chat box does when the message is sent, ends the
/// watch with the text it held just before. Words the user corrected inside the dictated text become pending
/// suggestions in Memory > Suggestions; nothing reaches the dictionary until
/// the user accepts one, and only the word pair is stored, never the field's
/// text. Secure fields are never read, and a move to another field ends the
/// watch. Each watch reports how it ended, with no text.
final class EditLearningWatcher: InsertedTextWatching {
    /// Timed reads, cumulative ~6.8 minutes. Edits are taken from change
    /// notifications as they happen; these reads notice that the user moved
    /// to another field, and stand in for notifications an app doesn't send.
    static let readDelays: [Duration] = [.seconds(4), .seconds(12), .seconds(30), .seconds(60), .seconds(120), .seconds(180)]
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
    /// Saves the drafts and returns how many became (or refreshed) pending
    /// suggestions.
    private let save: ([LearningSuggestionDraft]) -> Int
    private let report: (EditCheckOutcome, String?, Int) -> Void
    private let sleep: (Duration) async -> Void
    private var current: Watch?
    private var polling: Task<Void, Never>?
    private var starting: Task<Void, Never>?
    private var startingAppName: String?

    init(
        reader: FocusedFieldReading,
        settings: AppSettings,
        save: @escaping ([LearningSuggestionDraft]) -> Int,
        report: @escaping (EditCheckOutcome, String?, Int) -> Void = { _, _, _ in },
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.reader = reader
        self.settings = settings
        self.save = save
        self.report = report
        self.sleep = sleep
    }

    func prepare(targetApp: NSRunningApplication?) {
        guard settings.learnFromEditsEnabled, settings.effectiveDictationLanguage == "en", let targetApp else { return }
        reader.prepareToRead(targetApp)
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
        current?.observation = reader.observeFocusedField(processIdentifier: processIdentifier) { [weak self] text in
            self?.fieldChanged(to: text)
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

    /// `text` is the watched field's new value, or nil when it couldn't be
    /// read; then a full read decides whether the watch goes on.
    private func fieldChanged(to text: String?) {
        guard current != nil else { return }
        if let text {
            guard Self.isEmptied(text) else {
                current?.latestText = text
                return
            }
        } else if readAgain() {
            return
        }
        finish(readingFirst: false)
    }

    /// A chat box that empties has sent its message.
    private static func isEmptied(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            let edited = EditCorrectionFinder.comparable(watch.latestText)
                != EditCorrectionFinder.comparable(watch.baseline.text ?? "")
            report(edited ? .editedNoName : .noChange, watch.appName, 0)
            return
        }
        let evidence = watch.appName.map { "Corrected after dictating into \($0)" } ?? "Corrected after dictating"
        let saved = save(corrections.map {
            LearningSuggestionDraft(
                type: .dictionary,
                candidateSource: $0.heard,
                candidateTarget: $0.corrected,
                confidence: 0.9,
                evidence: evidence
            )
        })
        guard saved > 0 else {
            report(.alreadyKnown, watch.appName, 0)
            return
        }
        report(.learned, watch.appName, saved)
        Logger.memory.info("Learned \(saved) correction(s) from an edit")
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
            guard !Self.isEmptied(text) else { return false }
            current?.latestText = text
        }
        return true
    }
}
