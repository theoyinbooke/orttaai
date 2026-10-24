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
        EditLearningWatcher(reader: reader, settings: settings, save: { saved.drafts += $0 }, sleep: { _ in await Task.yield() })
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
        let watcher = EditLearningWatcher(reader: reader, settings: settings, save: { saved.drafts += $0 }, sleep: { _ in
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
        let watcher = EditLearningWatcher(reader: reader, settings: settings, save: { saved.drafts += $0 }, sleep: { _ in
            try? await Task.sleep(for: .seconds(3600))
        })

        watcher.watch(insertedText: inserted, targetApp: .current)
        reader.sendChange()
        XCTAssertTrue(saved.drafts.isEmpty)
        reader.sendChange()

        XCTAssertEqual(saved.drafts.map(\.candidateTarget), ["Folasade"])
        XCTAssertNil(reader.onChange, "the observation ends with the watch")
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

    func readFocusedField(processIdentifier: pid_t) -> FocusedFieldRead? {
        readCount += 1
        return reads.count > 1 ? reads.removeFirst() : reads.first
    }

    private weak var observation: Observation?
    var onChange: (() -> Void)? { observation?.onChange }

    func observeFocusedField(processIdentifier: pid_t, onChange: @escaping () -> Void) -> AnyObject? {
        let observation = Observation(onChange: onChange)
        self.observation = observation
        return observation
    }

    func sendChange() {
        onChange?()
    }

    private final class Observation {
        let onChange: () -> Void
        init(onChange: @escaping () -> Void) { self.onChange = onChange }
    }
}

private final class SavedDrafts {
    var drafts: [LearningSuggestionDraft] = []
}
