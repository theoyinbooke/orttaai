// TextAccuracyReplayTests.swift
// OrttaaiTests
//
// Env-gated review aid, skipped in the normal unit suite. Replays the fuzzy
// dictionary pass and the disfluency cleaner over a snapshot of dictation
// history and writes every changed span (before -> after, with three words
// of context) for a human to review. It never opens the app database: the
// input is a JSON snapshot exported read-only, e.g.
//
//   sqlite3 -readonly "$HOME/Library/Application Support/Orttaai/orttaai.db" \
//     "select json_object(
//        'targets', (select json_group_array(target) from dictionary_entry where isActive = 1),
//        'texts',   (select json_group_array(text) from transcription))" > history.json
//
// Environment (pass with the TEST_RUNNER_ prefix through xcodebuild):
//   ORTTAAI_TEXT_REPLAY_INPUT    path to the JSON snapshot (required)
//   ORTTAAI_TEXT_REPLAY_OUT_DIR  directory for fuzzy_replay.txt and
//                                disfluency_replay.txt (required)
//
// The outputs contain personal dictation: keep them out of the repository.

import XCTest
@testable import Orttaai

@MainActor
final class TextAccuracyReplayTests: XCTestCase {
    private struct Snapshot: Decodable {
        let targets: [String]
        let texts: [String]
    }

    private static let contextWords = 3

    func testReplayHistory() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let inputPath = environment["ORTTAAI_TEXT_REPLAY_INPUT"],
              let outputDirectory = environment["ORTTAAI_TEXT_REPLAY_OUT_DIR"] else {
            throw XCTSkip("Set ORTTAAI_TEXT_REPLAY_INPUT and ORTTAAI_TEXT_REPLAY_OUT_DIR to replay history.")
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: URL(fileURLWithPath: inputPath)))
        let matcher = FuzzyDictionaryMatcher(targets: snapshot.targets)

        try write(
            title: "Fuzzy dictionary replay (targets: \(snapshot.targets.count))",
            snapshot: snapshot,
            to: "\(outputDirectory)/fuzzy_replay.txt",
            transform: { matcher.apply(to: $0).text }
        )
        try write(
            title: "Disfluency replay",
            snapshot: snapshot,
            to: "\(outputDirectory)/disfluency_replay.txt",
            transform: { DisfluencyCleaner.clean($0).text }
        )
    }

    private func write(
        title: String,
        snapshot: Snapshot,
        to path: String,
        transform: (String) -> String
    ) throws {
        var lines: [String] = []
        var changedTexts = 0
        for (index, text) in snapshot.texts.enumerated() {
            let transformed = transform(text)
            guard transformed != text else { continue }
            changedTexts += 1
            for span in Self.changedSpans(from: text, to: transformed) {
                lines.append("#\(index)  \(span.before)  =>  \(span.after)")
            }
        }
        let header = "\(title)\ntexts: \(snapshot.texts.count), changed: \(changedTexts), changed spans: \(lines.count)\n"
        try (header + "\n" + lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        print("TEXT-REPLAY \(title): texts \(snapshot.texts.count), changed \(changedTexts), spans \(lines.count) -> \(path)")
    }

    /// Word-level diff (longest common subsequence) that groups each run of
    /// differing words into one span, rendered with surrounding context.
    private static func changedSpans(from before: String, to after: String) -> [(before: String, after: String)] {
        let old = before.split(whereSeparator: \.isWhitespace).map(String.init)
        let new = after.split(whereSeparator: \.isWhitespace).map(String.init)

        var table = [[Int]](repeating: [Int](repeating: 0, count: new.count + 1), count: old.count + 1)
        for row in stride(from: old.count - 1, through: 0, by: -1) {
            for column in stride(from: new.count - 1, through: 0, by: -1) {
                table[row][column] = old[row] == new[column]
                    ? table[row + 1][column + 1] + 1
                    : max(table[row + 1][column], table[row][column + 1])
            }
        }

        var spans: [(before: String, after: String)] = []
        var row = 0
        var column = 0
        while row < old.count || column < new.count {
            if row < old.count, column < new.count, old[row] == new[column] {
                row += 1; column += 1
                continue
            }
            let startRow = row
            let startColumn = column
            while row < old.count || column < new.count {
                if row < old.count, column < new.count, old[row] == new[column] { break }
                if column == new.count || (row < old.count && table[row + 1][column] >= table[row][column + 1]) {
                    row += 1
                } else {
                    column += 1
                }
            }
            spans.append((
                rendered(old, startRow, row),
                rendered(new, startColumn, column)
            ))
        }
        return spans
    }

    private static func rendered(_ words: [String], _ start: Int, _ end: Int) -> String {
        let leading = words[max(0, start - contextWords)..<start].joined(separator: " ")
        let changed = words[start..<end].joined(separator: " ")
        let trailing = words[end..<min(words.count, end + contextWords)].joined(separator: " ")
        return "\(leading) [\(changed)] \(trailing)".trimmingCharacters(in: .whitespaces)
    }
}
