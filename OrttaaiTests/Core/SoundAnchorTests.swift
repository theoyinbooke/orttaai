import Foundation
import XCTest
@testable import Orttaai

final class SoundContrastTests: XCTestCase {
    /// Frames from a made-up 4-piece vocabulary (blank = 3): each frame puts
    /// almost all its weight on one piece.
    static func frames(_ pieces: [Int], vocabulary: Int = 4) -> [[Float]] {
        pieces.map { piece in
            (0..<vocabulary).map { $0 == piece ? logf(0.97) : logf(0.01) }
        }
    }

    func testCtcPrefersTheSequenceThatWasSaid() {
        // Said: 0 0 blank 1 1, i.e. "a b".
        let logProbs = Self.frames([0, 0, 3, 1, 1])
        let said = SoundContrast.logLikelihood(logProbs, frames: 0..<5, tokens: [0, 1], blank: 3)
        let shorter = SoundContrast.logLikelihood(logProbs, frames: 0..<5, tokens: [0], blank: 3)
        let longer = SoundContrast.logLikelihood(logProbs, frames: 0..<5, tokens: [0, 1, 2], blank: 3)
        XCTAssertTrue(said > shorter + 3)
        XCTAssertTrue(said > longer + 3)
    }

    func testRepeatedPiecesNeedABlankBetween() {
        // "a a" can't be said in two frames with no blank between them.
        let logProbs = Self.frames([0, 0])
        XCTAssertTrue(SoundContrast.logLikelihood(logProbs, frames: 0..<2, tokens: [0, 0], blank: 3) == -.infinity)
        XCTAssertTrue(SoundContrast.logLikelihood(Self.frames([0, 3, 0]), frames: 0..<3, tokens: [0, 0], blank: 3).isFinite)
    }

    func testMarginIsPositiveWhenTheTermFitsTheSound() {
        // Pieces: 0 = "email", 1 = "er", 2 = "and"; the sound is "email er and".
        let logProbs = Self.frames([0, 0, 1, 3, 2])
        let words = [SoundWord(text: "email", start: 0, end: 0.2), SoundWord(text: "and", start: 0.3, end: 0.4)]
        let encode: (String) -> [Int] = { text in
            text.split(separator: " ").flatMap { word -> [Int] in
                switch word {
                case "email": [0]
                case "emailer": [0, 1]
                case "and": [2]
                default: []
                }
            }
        }
        guard let window = SoundContrast.window(for: 0..<1, in: words, frameDuration: 0.08, frameCount: logProbs.count) else {
            XCTFail("no window")
            return
        }
        let margin = SoundContrast.margin(logProbs, window: window, heard: "email", term: "emailer", blank: 3, encode: encode)
        XCTAssertTrue((margin ?? 0) > 3)
        // And the other way: the sound is plain "email and".
        let plain = Self.frames([0, 0, 3, 3, 2])
        let other = SoundContrast.margin(plain, window: window, heard: "email", term: "emailer", blank: 3, encode: encode)
        XCTAssertTrue((other ?? 0) < -3)
    }

    func testWordsComeFromTokenTimings() {
        let words = SoundWord.words(fromTokens: [
            ("▁Can", 0, 0.1), ("▁open", 0.2, 0.3), ("▁e", 0.4, 0.5), ("mail", 0.5, 0.7), ("er", 0.7, 0.8), ("▁and", 0.9, 1.0),
        ])
        XCTAssertTrue(words.map(\.text) == ["Can", "open", "emailer", "and"])
        XCTAssertTrue(words[2].start == 0.4 && words[2].end == 0.8)
    }

    func testOccurrencesMatchWholeWordsAnyCase() {
        let words = ["I", "sent", "the", "Email,", "then", "an", "email"].map { SoundWord(text: $0, start: 0, end: 0) }
        XCTAssertTrue(SoundContrast.occurrences(of: "email", in: words) == [3..<4, 6..<7])
        XCTAssertTrue(SoundContrast.occurrences(of: "an email", in: words) == [5..<7])
        XCTAssertTrue(SoundContrast.occurrences(of: "emails", in: words).isEmpty)
        let hyphen = ["E-mail", "is", "ready"].map { SoundWord(text: $0, start: 0, end: 0) }
        XCTAssertTrue(SoundContrast.occurrences(of: "email", in: hyphen) == [0..<1])
    }

    func testSpellingLinesUpTheCTCTranscript() {
        let words = ["Can", "you", "open", "email", "and", "check"].map { SoundWord(text: $0, start: 0, end: 0) }
        let spelled = ["can", "you", "open", "emmaler", "and", "check"]
        XCTAssertTrue(SoundContrast.spelling(of: 3..<4, in: words, spelled: spelled) == "emmaler")
    }
}

final class SoundAnchorTests: XCTestCase {
    func testLineStartsAtZero() {
        let anchor = SoundAnchor(heard: "Email", term: "Eimailar", sounds: ["emailer"], said: [4.2])
        XCTAssertTrue(anchor.heard == "email")
        XCTAssertTrue(anchor.line == 0)
        XCTAssertTrue(anchor.accepts(1))
        XCTAssertTrue(!anchor.accepts(-0.5))
    }

    func testAWeakFixAllowsALittleBelowZero() {
        let anchor = SoundAnchor(heard: "email", term: "Eimailar", sounds: ["emailer"], said: [-1.2])
        XCTAssertTrue(anchor.line == -0.6)
        XCTAssertTrue(anchor.accepts(-0.4))
        // One fix never takes the line below -1; several, -2.
        XCTAssertTrue(SoundAnchor(heard: "email", term: "Eimailar", sounds: ["emailer"], said: [-6]).line == -1)
        XCTAssertTrue(SoundAnchor(heard: "email", term: "Eimailar", sounds: ["emailer"], said: [-6, 2]).line == -2)
    }

    func testFixesBothWaysPutTheLineBetween() {
        var anchor = SoundAnchor(heard: "email", term: "Eimailar", sounds: ["emailer"], said: [3, 5])
        anchor.learnNotSaid(1)
        XCTAssertTrue(anchor.line == 2.5)
        XCTAssertTrue(!anchor.accepts(2.4))
        XCTAssertTrue(anchor.accepts(2.6))
    }

    func testOnlyFixesBackRaiseTheLine() {
        var anchor = SoundAnchor(heard: "email", term: "Eimailar", sounds: ["emailer"])
        anchor.learnNotSaid(2)
        XCTAssertTrue(anchor.line == 2.5)
    }

    func testEvidenceIsBounded() {
        var anchor = SoundAnchor(heard: "email", term: "Eimailar", sounds: ["emailer"])
        for value in 0..<30 { anchor.learnSaid(Float(value)) }
        XCTAssertTrue(anchor.said.count == SoundAnchor.evidenceKept)
        XCTAssertTrue(anchor.said.first == 18)
    }

    func testBookLearnsForgetsAndRoundTrips() throws {
        var book = SoundAnchorBook()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        book.learnSaid(heard: "email", term: "Eimailar", sounds: ["emailer"], margin: 3, at: date)
        book.learnSaid(heard: "Email", term: "Eimailar", sounds: ["Emaila", "emailer"], margin: 4, at: date)
        XCTAssertTrue(book.anchors.count == 1)
        XCTAssertTrue(book.anchor(heard: "email", term: "Eimailar")?.said == [3, 4])
        XCTAssertTrue(book.anchor(heard: "email", term: "Eimailar")?.sounds == ["emaila", "emailer"])
        book.learnNotSaid(heard: "email", term: "Eimailar", margin: 1, at: date)
        XCTAssertTrue(book.anchor(heard: "email", term: "Eimailar")?.notSaid == [1])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sound-anchors.json")
        book.save(to: url)
        XCTAssertTrue(SoundAnchorBook.load(from: url) == book)
        book.forget(term: "eimailar")
        XCTAssertTrue(book.isEmpty)
    }
}

final class SoundAnchorJudgeTests: XCTestCase {
    static let words = ["Open", "email", "and", "the", "email", "er", "list."].enumerated().map {
        SoundWord(text: $0.element, start: Double($0.offset), end: Double($0.offset) + 0.5)
    }
    static let text = "Open email and the email er list."

    static var book: SoundAnchorBook {
        SoundAnchorBook([SoundAnchor(heard: "email", term: "Eimailar", sounds: ["emailer"], said: [3])])
    }

    func testWritesYourWordOnlyWhereTheSoundSaysSo() {
        // The first "email" sounded like "email", the second like "emailer".
        let text = "Open email and the email list."
        let words = ["Open", "email", "and", "the", "email", "list."].map { SoundWord(text: $0, start: 0, end: 0) }
        let (replacements, decisions) = SoundAnchorJudge.judge(Self.book, text: text, words: words) { range, _, _ in
            range.lowerBound == 1 ? -6 : 2
        }
        let result = applyingTerms(replacements, to: text)
        XCTAssertTrue(result == "Open email and the Eimailar list.")
        XCTAssertTrue(decisions.map(\.applied) == [false, true])
    }

    func testTakesAShortWordAlongOnlyWhenClearlyBetter() {
        // "email er" together sounds like "emailer" far better than "email" alone.
        let (replacements, _) = SoundAnchorJudge.judge(Self.book, text: Self.text, words: Self.words) { range, _, _ in
            if range == 4..<6 { return Float(4) }
            return Float(range.lowerBound == 4 ? 0.5 : -6)
        }
        XCTAssertTrue(applyingTerms(replacements, to: Self.text) == "Open email and the Eimailar list.")
        // Only a little better: nothing changes, since "er" after it also
        // asks the heard word alone for much clearer sound.
        let (kept, _) = SoundAnchorJudge.judge(Self.book, text: Self.text, words: Self.words) { range, _, _ in
            if range == 4..<6 { return Float(1.0) }
            return Float(range.lowerBound == 4 ? 0.5 : -6)
        }
        XCTAssertTrue(kept.isEmpty)
    }

    func testBeforeAnEverydayEndingTheSoundMustBeClearer() {
        let words = ["an", "email", "or", "a", "text"].map { SoundWord(text: $0, start: 0, end: 0) }
        let text = "an email or a text"
        let (some, _) = SoundAnchorJudge.judge(Self.book, text: text, words: words) { _, _, _ in Float(2) }
        XCTAssertTrue(some.isEmpty)
        let (clear, _) = SoundAnchorJudge.judge(Self.book, text: text, words: words) { _, _, _ in Float(5) }
        XCTAssertTrue(applyingTerms(clear, to: text) == "an Eimailar or a text")
    }

    func testATaughtPhraseEndingInAnEverydayWordBecomesTheWord() {
        // Taught from "email or": kept as "email", and "email or" in later
        // speech needs the stricter check for endings.
        let book = SoundAnchorBook([SoundAnchor(heard: "email or", term: "Eimailar", sounds: ["emailer"], said: [3])])
        XCTAssertTrue(book.anchors.first?.heard == "email")
        let words = ["send", "the", "email", "or", "update"].map { SoundWord(text: $0, start: 0, end: 0) }
        let text = "send the email or update"
        XCTAssertTrue(SoundAnchorJudge.judge(book, text: text, words: words) { _, _, _ in Float(2) }.replacements.isEmpty)
    }

    func testYourWordSpelledAsItSoundsIsYourWord() {
        let text = "Open E-mailer and check the emailer list, not the email."
        let words = ["Open", "E-mailer", "and", "check", "the", "emailer", "list,", "not", "the", "email."].map { SoundWord(text: $0, start: 0, end: 0) }
        let (replacements, decisions) = SoundAnchorJudge.judge(Self.book, text: text, words: words) { _, _, _ in Float(-9) }
        XCTAssertTrue(applyingTerms(replacements, to: text) == "Open Eimailar and check the Eimailar list, not the email.")
        XCTAssertTrue(decisions.filter(\.applied).count == 2)
    }

    func testEverydayWordsAreNeverSpellings() {
        let book = SoundAnchorBook([SoundAnchor(heard: "sound", term: "soundAr", sounds: ["sounder", "soundar"], said: [2])])
        let spellings = SoundAnchorJudge.soundSpellings(book)
        XCTAssertTrue(spellings["sounder"] == nil)
        XCTAssertTrue(spellings["sound"] == nil)
    }

    func testASpellingFixedBackIsForgotten() {
        var book = Self.book
        book.forgetSpelling("Emailer", term: "Eimailar")
        XCTAssertTrue(SoundAnchorJudge.soundSpellings(book)["emailer"] == nil)
        XCTAssertTrue(SoundAnchorJudge.soundSpellings(book)["emaila"] == "Eimailar")
    }

    func testSlowListenHearsOnlyTheLongerWord() {
        let spellings = ["emailer": "Eimailar"]
        XCTAssertTrue(SoundAnchorJudge.slowListenHeard(["open", "emailer", "and"], heard: "email", term: "Eimailar", spellings: [:]))
        XCTAssertTrue(SoundAnchorJudge.slowListenHeard(["open", "eimailar"], heard: "email", term: "Eimailar", spellings: [:]))
        XCTAssertTrue(SoundAnchorJudge.slowListenHeard(["e", "mailer"].map { $0 }, heard: "email", term: "Eimailar", spellings: spellings) == false)
        XCTAssertTrue(!SoundAnchorJudge.slowListenHeard(["open", "email", "and"], heard: "email", term: "Eimailar", spellings: spellings))
        XCTAssertTrue(!SoundAnchorJudge.slowListenHeard(["emails", "emailed"], heard: "email", term: "Eimailar", spellings: spellings))
    }

    func testAFixFromAWordAndAnEndingTeachesTheWord() {
        var book = SoundAnchorBook()
        book.learnSaid(heard: "email at", term: "Eimailar", sounds: ["emailer"], margin: 2)
        XCTAssertTrue(book.anchors.map(\.heard) == ["email"])
        XCTAssertTrue(SoundAnchorJudge.soundOptions(heard: "email or", term: "Eimailar").contains("emailer"))
        XCTAssertTrue(SoundAnchorJudge.coreHeard("my local") == "my local")
    }

    func testNoAnchorsChangeNothing() {
        let (replacements, decisions) = SoundAnchorJudge.judge(SoundAnchorBook(), text: Self.text, words: Self.words) { _, _, _ in 9 }
        XCTAssertTrue(replacements.isEmpty && decisions.isEmpty)
    }

    func testPlausibleSoundsLookLikeYourWord() {
        XCTAssertTrue(SoundAnchorJudge.isPlausibleSound("emailer", heard: "email", term: "Eimailar"))
        XCTAssertTrue(SoundAnchorJudge.isPlausibleSound("email or", heard: "email", term: "Eimailar"))
        XCTAssertTrue(!SoundAnchorJudge.isPlausibleSound("email", heard: "email", term: "Eimailar"))
        XCTAssertTrue(!SoundAnchorJudge.isPlausibleSound("to wecome chter", heard: "sound", term: "soundAr"))
        XCTAssertTrue(!SoundAnchorJudge.isPlausibleSound("so", heard: "sound", term: "soundAr"))
    }

    func testSoundOptionsCoverCommonEndings() {
        XCTAssertTrue(SoundAnchorJudge.soundOptions(heard: "Email", term: "Eimailar") == ["eimailar", "emailer", "emailar", "emaila", "emailor"])
    }
}

final class WordBoostEndingTests: XCTestCase {
    func testAnOrdinaryWordAndAnEverydayEndingStayApart() {
        XCTAssertTrue(!WordBoostGuard.accepts(.init(heard: "email or", term: "Eimailar", acousticMargin: 0.5)))
        XCTAssertTrue(WordBoostGuard.accepts(.init(heard: "email or", term: "Eimailar", acousticMargin: 2.5)))
    }
}

final class SoundAnchorGuessTests: XCTestCase {
    func testYourWordsStartWithAnAnchorWhenTheyLookLikeAWordAndAnEnding() {
        let anchors = SoundAnchorGuesses.anchors(for: ["Eimailar", "soundAr", "Temitope", "Mylokai", "keyboard", "Meetumo", "Hetzner"])
        let byTerm = Dictionary(uniqueKeysWithValues: anchors.map { ($0.term, $0.heard) })
        XCTAssertTrue(byTerm["Eimailar"] == "email")
        XCTAssertTrue(byTerm["soundAr"] == "sound")
        XCTAssertTrue(byTerm["keyboard"] == nil)
        XCTAssertTrue(byTerm["Meetumo"] == nil && byTerm["Hetzner"] == nil)
        XCTAssertTrue(anchors.allSatisfy { $0.said.isEmpty && $0.line == 0 })
    }

    func testTaughtAnchorsAreKeptOverGuesses() {
        let book = SoundAnchorBook([SoundAnchor(heard: "email", term: "Eimailar", sounds: ["emailer"], said: [3])])
        let merged = book.addingGuesses(for: ["Eimailar", "soundAr"])
        XCTAssertTrue(merged.anchors.filter { $0.term == "Eimailar" }.count == 1)
        XCTAssertTrue(merged.anchors.contains { $0.term == "soundAr" })
    }
}

final class NearSpellingTests: XCTestCase {
    func testMisspellingsOfYourWordsSoundAreYourWord() {
        let book = SoundAnchorBook().addingGuesses(for: ["Eimailar"])
        let text = "We fixed the bug in emila yesterday. Emilar is ready. Emily said email works."
        let words = text.split(separator: " ").map { SoundWord(text: String($0), start: 0, end: 0) }
        let (replacements, _) = SoundAnchorJudge.judge(book, text: text, words: words) { _, _, _ in Float(-9) }
        XCTAssertTrue(applyingTerms(replacements, to: text) == "We fixed the bug in Eimailar yesterday. Eimailar is ready. Emily said email works.")
    }
}

final class OwnVoiceLineTests: XCTestCase {
    func testYourKeptWordsLetTheLineFollowYourVoice() {
        // The owner's voice: a fix at -5.2, kept "email"s at -9.4, -9.3, -5.5.
        var anchor = SoundAnchor(heard: "email", term: "Eimailar", sounds: ["emaila"], said: [-5.2])
        anchor.learnNotSaid(-9.4)
        anchor.learnNotSaid(-9.3)
        XCTAssertTrue(anchor.line == -2)  // two kept words: not trusted yet
        anchor.learnNotSaid(-5.5)
        XCTAssertTrue(anchor.line == -4)
        XCTAssertTrue(anchor.accepts(-3.6))
        XCTAssertTrue(!anchor.accepts(-5.5))
        XCTAssertTrue(!anchor.accepts(-6.6))
    }

    func testTheLineStaysNearAWeakFixWhenKeptWordsAreFarBelow() {
        // A voice whose fix scored -3 and whose kept "email"s score near -11.
        var anchor = SoundAnchor(heard: "email", term: "Eimailar", sounds: ["emaila"], said: [-3])
        for kept: Float in [-11.9, -11.4, -11.4] { anchor.learnNotSaid(kept) }
        XCTAssertEqual(anchor.line, -4.5)
        XCTAssertFalse(anchor.accepts(-5.7), "a real email")
        XCTAssertTrue(anchor.accepts(-3))
        // A strong fix doesn't lift the line above zero.
        var strong = SoundAnchor(heard: "email", term: "Eimailar", sounds: ["emaila"], said: [3.9])
        for kept: Float in [-11.9, -11.4, -11.4] { strong.learnNotSaid(kept) }
        XCTAssertEqual(strong.line, 0)
    }
}

/// ExpressTranscriber.applying, which is limited to macOS 15.
private func applyingTerms(_ replacements: [(Range<Int>, String)], to text: String) -> String {
    var result = text
    for (range, term) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
        guard let lower = result.utf8.index(result.startIndex, offsetBy: range.lowerBound, limitedBy: result.endIndex),
              let upper = result.utf8.index(result.startIndex, offsetBy: range.upperBound, limitedBy: result.endIndex) else { continue }
        let heard = result[lower..<upper]
        let leading = heard.prefix { !($0.isLetter || $0.isNumber) }
        let trailing = String(heard.reversed().prefix { !($0.isLetter || $0.isNumber) }.reversed())
        result.replaceSubrange(lower..<upper, with: leading + term + trailing)
    }
    return result
}

// MARK: - Mac

final class SoundAnchorMacTests: XCTestCase {
    func testEveryChangeIsSeenNotOnlyNames() {
        let inserted = "We fixed the bug in Eimailar yesterday."
        let after = "We fixed the bug in email yesterday."
        let names = EditCorrectionFinder.corrections(inserted: inserted, before: inserted, insertionEndUTF16: nil, after: after)
        let all = EditCorrectionFinder.corrections(inserted: inserted, before: inserted, insertionEndUTF16: nil, after: after, nameLikeOnly: false)
        XCTAssertTrue(names.isEmpty)
        XCTAssertTrue(all == [EditCorrection(heard: "Eimailar", corrected: "email")])
    }

    func testEverydayWordPairsAreDecidedBySoundOnlyWhileListening() {
        let store = SoundAnchorStore.shared
        store.setSoundIsListening(false)
        XCTAssertTrue(!store.decidesBySound(source: "email", target: "Eimailar"))
        store.setSoundIsListening(true)
        XCTAssertTrue(store.decidesBySound(source: "email", target: "Eimailar"))
        XCTAssertTrue(!store.decidesBySound(source: "Tematope", target: "Temitope"))
        XCTAssertTrue(!store.decidesBySound(source: "email", target: "Email"))
        store.setSoundIsListening(false)
    }

    func testGuardKeepsOneEverydayWordAndEverydayEndings() {
        XCTAssertTrue(!WordBoostGuard.accepts(.init(heard: "header", term: "Hetzner", acousticMargin: 3)))
        XCTAssertTrue(!WordBoostGuard.accepts(.init(heard: "email or", term: "Eimailar", acousticMargin: 0.5)))
        XCTAssertTrue(WordBoostGuard.accepts(.init(heard: "email or", term: "Eimailar", acousticMargin: 2.5)))
    }

    @MainActor func testAFixToYourWordIsLearnedBySoundAndNotSuggestedAsARule() async {
        let learning = SoundAnchorLearning()
        learning.store = SoundAnchorStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        learning.dictionaryTargets = { ["eimailar"] }
        let inserted = "We fixed the bug in email yesterday."
        learning.remember(samples: [Float](repeating: 0, count: 16_000), inserted: inserted, decisions: [])
        let after = "We fixed the bug in Eimailar yesterday."
        let suggestion = EditCorrection(heard: "email", corrected: "Eimailar")
        let left = learning.review(inserted: inserted, before: inserted, caret: nil, after: after, suggestions: [suggestion])
        XCTAssertTrue(left.isEmpty)
    }

    @MainActor func testAFixToANewWordIsSuggestedAsTheWordItself() {
        let learning = SoundAnchorLearning()
        learning.store = SoundAnchorStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        learning.dictionaryTargets = { [] }
        let inserted = "Open email and check."
        learning.remember(samples: [Float](repeating: 0, count: 16_000), inserted: inserted, decisions: [])
        let left = learning.review(inserted: inserted, before: inserted, caret: nil, after: "Open emailer and check.", suggestions: [])
        XCTAssertTrue(left == [EditCorrection(heard: "emailer", corrected: "emailer")])
    }
}
