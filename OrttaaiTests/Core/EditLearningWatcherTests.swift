// EditLearningWatcherTests.swift
// OrttaaiTests

import AppKit
import XCTest
@testable import Orttaai

@MainActor
final class EditLearningWatcherTests: XCTestCase {
    private var settings: AppSettings!
    private var savedDefaults: [String: Any] = [:]
    private let keys = ["learnFromEditsEnabled", "dictationLanguage", "lowLatencyModeEnabled"]

    override func setUp() async throws {
        savedDefaults = keys.reduce(into: [:]) { $0[$1] = UserDefaults.standard.object(forKey: $1) }
        settings = AppSettings()
        settings.learnFromEditsEnabled = true
        settings.dictationLanguage = "en"
    }

    override func tearDown() async throws {
        for key in keys {
            if let value = savedDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    private let inserted = "Please call for Lash a day tomorrow."
    private let fixed = "Please call Folasade tomorrow."

    private func field(_ text: String, id: Int = 1, secure: Bool = false) -> FocusedFieldRead {
        FocusedFieldRead(elementID: id, isSecure: secure, text: secure ? nil : text, caretUTF16: text.utf16.count)
    }

    private func makeWatcher(_ reader: ScriptedFieldReader, saved: SavedDrafts) -> EditLearningWatcher {
        EditLearningWatcher(reader: reader, settings: settings, save: { saved.drafts += $0; return $0.count }, sleep: { _ in await Task.yield() })
    }

    private func waitForReads(_ reader: ScriptedFieldReader, count: Int) async {
        for _ in 0..<200 where reader.readCount < count {
            await Task.yield()
        }
    }

    func testFixMadeAfterInsertionBecomesAPendingSuggestion() async {
        let reader = ScriptedFieldReader([field(inserted), field(inserted), field(fixed)])
        let saved = SavedDrafts()
        let watcher = makeWatcher(reader, saved: saved)

        watcher.watch(insertedText: inserted, targetApp: .current)
        await waitForReads(reader, count: 1 + EditLearningWatcher.readDelays.count + 1)
        for _ in 0..<50 where saved.drafts.isEmpty { await Task.yield() }

        XCTAssertEqual(saved.drafts.map(\.candidateSource), ["for Lash a day"])
        XCTAssertEqual(saved.drafts.map(\.candidateTarget), ["Folasade"])
        XCTAssertEqual(saved.drafts.first?.type, .dictionary)
    }

    func testNextDictationFinishesTheWatchWithTheFixSoFar() {
        let reader = ScriptedFieldReader([field(inserted), field(fixed)])
        let saved = SavedDrafts()
        let watcher = EditLearningWatcher(reader: reader, settings: settings, save: { saved.drafts += $0; return $0.count }, sleep: { _ in
            try? await Task.sleep(for: .seconds(3600))
        })

        watcher.watch(insertedText: inserted, targetApp: .current)
        watcher.finishCurrentWatch()

        XCTAssertEqual(saved.drafts.map(\.candidateTarget), ["Folasade"])
    }

    func testMovingToAnotherFieldKeepsEarlierFixesButReadsNoFurther() async {
        let reader = ScriptedFieldReader([field(inserted), field(fixed), field("Unrelated text in another field", id: 2)])
        let saved = SavedDrafts()
        let watcher = makeWatcher(reader, saved: saved)

        watcher.watch(insertedText: inserted, targetApp: .current)
        for _ in 0..<200 where saved.drafts.isEmpty { await Task.yield() }

        XCTAssertEqual(saved.drafts.map(\.candidateTarget), ["Folasade"])
        XCTAssertEqual(reader.readCount, 3, "the watch ends once focus moves")
    }

    func testSendingTheMessageKeepsTheFixMadeJustBeforeIt() async {
        // A chat box empties when the message is sent.
        let reader = ScriptedFieldReader([field(inserted), field(fixed), field("")])
        let saved = SavedDrafts()
        let watcher = makeWatcher(reader, saved: saved)

        watcher.watch(insertedText: inserted, targetApp: .current)
        for _ in 0..<200 where saved.drafts.isEmpty { await Task.yield() }

        XCTAssertEqual(saved.drafts.map(\.candidateTarget), ["Folasade"])
        XCTAssertEqual(reader.readCount, 3, "the watch ends once the field empties")
    }

    func testEachChangeToTheFieldIsReadStraightAway() {
        // Fixed and sent between two timed reads: only the change
        // notifications see the fix.
        let reader = ScriptedFieldReader([field(inserted), field(fixed), field("")])
        let saved = SavedDrafts()
        let watcher = EditLearningWatcher(reader: reader, settings: settings, save: { saved.drafts += $0; return $0.count }, sleep: { _ in
            try? await Task.sleep(for: .seconds(3600))
        })

        watcher.watch(insertedText: inserted, targetApp: .current)
        reader.sendChange()
        XCTAssertTrue(saved.drafts.isEmpty)
        reader.sendChange()

        XCTAssertEqual(saved.drafts.map(\.candidateTarget), ["Folasade"])
        XCTAssertNil(reader.onChange, "the observation ends with the watch")
    }

    // MARK: - Visible outcomes, retry and whitespace

    private func reportingWatcher(_ reader: ScriptedFieldReader, saved: SavedDrafts, outcomes: OutcomeLog) -> EditLearningWatcher {
        EditLearningWatcher(
            reader: reader,
            settings: settings,
            save: { saved.drafts += $0; return $0.count },
            report: { outcome, app, learned in outcomes.entries.append((outcome, learned)) },
            sleep: { _ in await Task.yield() }
        )
    }

    func testAFixAlreadyKnownIsNotReportedAsLearned() {
        let outcomes = OutcomeLog()
        let watcher = EditLearningWatcher(
            reader: ScriptedFieldReader([field(inserted), field(fixed)]),
            settings: settings,
            save: { _ in 0 },
            report: { outcome, _, learned in outcomes.entries.append((outcome, learned)) },
            sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }
        )

        watcher.watch(insertedText: inserted, targetApp: .current)
        watcher.finishCurrentWatch()

        XCTAssertEqual(outcomes.entries.map(\.0), [.alreadyKnown])
        XCTAssertEqual(outcomes.entries.first?.1, 0)
    }

    // MARK: - Getting the app ready

    func testRecordingStartReadiesTheTargetApp() {
        let reader = ScriptedFieldReader([field(inserted)])
        let watcher = makeWatcher(reader, saved: SavedDrafts())

        watcher.prepare(targetApp: .current)

        XCTAssertEqual(reader.preparedApps.map(\.processIdentifier), [NSRunningApplication.current.processIdentifier])
        XCTAssertEqual(reader.readCount, 0, "readying the app reads nothing")
    }

    func testNoAppIsReadiedWhenLearningIsOffOrNotEnglish() {
        let reader = ScriptedFieldReader([field(inserted)])
        let watcher = makeWatcher(reader, saved: SavedDrafts())

        settings.learnFromEditsEnabled = false
        watcher.prepare(targetApp: .current)
        settings.learnFromEditsEnabled = true
        settings.dictationLanguage = "fr"
        watcher.prepare(targetApp: .current)

        XCTAssertTrue(reader.preparedApps.isEmpty)
    }

    func testAChangeWhoseReadFailsFallsBackToAFullRead() {
        // The full read finds the fix and the watch goes on.
        let reader = ScriptedFieldReader([field(inserted), field(fixed)])
        let saved = SavedDrafts()
        let watcher = EditLearningWatcher(reader: reader, settings: settings, save: { saved.drafts += $0; return $0.count }, sleep: { _ in
            try? await Task.sleep(for: .seconds(3600))
        })

        watcher.watch(insertedText: inserted, targetApp: .current)
        reader.sendUnreadableChange()
        XCTAssertTrue(saved.drafts.isEmpty, "the watch is still going")
        XCTAssertEqual(reader.readCount, 2)
        watcher.finishCurrentWatch()

        XCTAssertEqual(saved.drafts.map(\.candidateTarget), ["Folasade"])
    }

    func testAChatBoxThatCapitalizesAndCurlsQuotesStillShowsTheDictation() {
        let dictated = "the client's name is Folasade, and they're happy."
        let stored = "The client’s name is Folasade, and they’re happy."
        let reader = ScriptedFieldReader([field(stored), field(stored)])
        let outcomes = OutcomeLog()
        let watcher = reportingWatcher(reader, saved: SavedDrafts(), outcomes: outcomes)

        watcher.watch(insertedText: dictated, targetApp: .current)
        watcher.finishCurrentWatch()

        XCTAssertEqual(outcomes.entries.map(\.0), [.noChange])
    }

    func testEachCheckReportsHowItEnded() {
        let cases: [([FocusedFieldRead], EditCheckOutcome, Int)] = [
            ([field(inserted), field(fixed)], .learned, 1),
            ([field(inserted), field(inserted)], .noChange, 0),
            ([field(inserted), field(inserted + " See you then.")], .editedNoName, 0),
            ([field(inserted, secure: true)], .secureField, 0),
        ]
        for (reads, expected, learned) in cases {
            let outcomes = OutcomeLog()
            let watcher = reportingWatcher(ScriptedFieldReader(reads), saved: SavedDrafts(), outcomes: outcomes)
            watcher.watch(insertedText: inserted, targetApp: .current)
            watcher.finishCurrentWatch()
            XCTAssertEqual(outcomes.entries.map(\.0), [expected], "\(reads.map(\.text))")
            XCTAssertEqual(outcomes.entries.first?.1, learned)
        }
    }

    func testAPasteThatShowsUpLateIsStillWatched() async {
        // Some apps show pasted text a moment after the paste.
        let reader = ScriptedFieldReader([field("draft"), field("draft"), field(inserted), field(fixed)])
        let saved = SavedDrafts()
        let outcomes = OutcomeLog()
        let watcher = reportingWatcher(reader, saved: saved, outcomes: outcomes)

        watcher.watch(insertedText: inserted, targetApp: .current)
        for _ in 0..<400 where outcomes.entries.isEmpty { await Task.yield() }

        XCTAssertEqual(saved.drafts.map(\.candidateTarget), ["Folasade"])
        XCTAssertEqual(outcomes.entries.map(\.0), [.learned])
    }

    func testADictationThatNeverAppearsIsReportedNotFound() async {
        let reader = ScriptedFieldReader([field("Something else entirely")])
        let outcomes = OutcomeLog()
        let watcher = reportingWatcher(reader, saved: SavedDrafts(), outcomes: outcomes)

        watcher.watch(insertedText: inserted, targetApp: .current)
        for _ in 0..<400 where outcomes.entries.isEmpty { await Task.yield() }

        XCTAssertEqual(outcomes.entries.map(\.0), [.textNotFound])
        XCTAssertEqual(reader.readCount, 1 + EditLearningWatcher.baselineRetries)
    }

    func testEditorWhitespaceDoesNotHideTheDictation() {
        // A chat box may keep a non-breaking space or turn a space into a line break.
        let stored = "Please call for\u{00A0}Lash a day\ntomorrow."
        let reader = ScriptedFieldReader([field(stored), field("Please call Folasade\ntomorrow.")])
        let saved = SavedDrafts()
        let watcher = EditLearningWatcher(reader: reader, settings: settings, save: { saved.drafts += $0; return $0.count }, sleep: { _ in
            try? await Task.sleep(for: .seconds(3600))
        })

        watcher.watch(insertedText: inserted, targetApp: .current)
        watcher.finishCurrentWatch()

        XCTAssertEqual(saved.drafts.map(\.candidateTarget), ["Folasade"])
    }

    func testFieldThatTurnsSecureIsDropped() async {
        let reader = ScriptedFieldReader([field(inserted), field(fixed, secure: true)])
        let saved = SavedDrafts()
        let watcher = makeWatcher(reader, saved: saved)

        watcher.watch(insertedText: inserted, targetApp: .current)
        await waitForReads(reader, count: 2)
        watcher.finishCurrentWatch()

        XCTAssertTrue(saved.drafts.isEmpty)
    }

    func testSecureFieldIsNeverWatched() {
        let reader = ScriptedFieldReader([field(inserted, secure: true), field(fixed)])
        let saved = SavedDrafts()
        let watcher = makeWatcher(reader, saved: saved)

        watcher.watch(insertedText: inserted, targetApp: .current)
        watcher.finishCurrentWatch()

        XCTAssertEqual(reader.readCount, 1)
        XCTAssertTrue(saved.drafts.isEmpty)
    }

    func testNothingIsReadWhenTheSettingIsOff() {
        settings.learnFromEditsEnabled = false
        let reader = ScriptedFieldReader([field(inserted), field(fixed)])
        let saved = SavedDrafts()
        let watcher = makeWatcher(reader, saved: saved)

        watcher.watch(insertedText: inserted, targetApp: .current)
        watcher.finishCurrentWatch()

        XCTAssertEqual(reader.readCount, 0)
        XCTAssertTrue(saved.drafts.isEmpty)
    }
}

/// Returns the scripted reads in order, then repeats the last one.
private final class ScriptedFieldReader: FocusedFieldReading {
    private var reads: [FocusedFieldRead]
    private(set) var readCount = 0

    init(_ reads: [FocusedFieldRead]) {
        self.reads = reads
    }

    private(set) var preparedApps: [NSRunningApplication] = []

    func prepareToRead(_ app: NSRunningApplication) {
        preparedApps.append(app)
    }

    func readFocusedField(processIdentifier: pid_t) -> FocusedFieldRead? {
        readCount += 1
        return reads.count > 1 ? reads.removeFirst() : reads.first
    }

    private weak var observation: Observation?
    var onChange: ((String?) -> Void)? { observation?.onChange }

    func observeFocusedField(processIdentifier: pid_t, onChange: @escaping (String?) -> Void) -> AnyObject? {
        let observation = Observation(onChange: onChange)
        self.observation = observation
        return observation
    }

    /// Delivers the next scripted read's text, as a change notification does.
    func sendChange() {
        onChange?(readFocusedField(processIdentifier: 0)?.text)
    }

    /// A notification whose read failed.
    func sendUnreadableChange() {
        onChange?(nil)
    }

    private final class Observation {
        let onChange: (String?) -> Void
        init(onChange: @escaping (String?) -> Void) { self.onChange = onChange }
    }
}

private final class OutcomeLog {
    var entries: [(EditCheckOutcome, Int)] = []
}

private final class SavedDrafts {
    var drafts: [LearningSuggestionDraft] = []
}
