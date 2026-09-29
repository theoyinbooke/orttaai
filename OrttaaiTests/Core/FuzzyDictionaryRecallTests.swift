// FuzzyDictionaryRecallTests.swift
// OrttaaiTests
//
// Replays the recorded ASR hypotheses in gauntlet/asr_eval/results.json
// (whole and live decode paths) through the fuzzy dictionary pass, using the
// corpus manifest's bias_vocabulary as the user dictionary. Measures the
// strict hard-vocab recall gain with the same definition score.py uses
// (case-insensitive substring of the whitespace-squashed hypothesis) and
// asserts the pass never rewrites anything that is not a hard term of that
// item. No audio, no models: pure text.
//
// Held out: items whose id ends in an even number are the "tuning" half the
// thresholds were adjusted against; odd-numbered items are reported (and
// asserted) separately so the gain is not in-sample only.

import XCTest
@testable import Orttaai

@MainActor
final class FuzzyDictionaryRecallTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Item: Decodable {
            let id: String
            let reference: String
            let hard_terms: [String]
        }

        let bias_vocabulary: [String]
        let items: [Item]
    }

    private struct Results: Decodable {
        struct Path: Decodable {
            struct Item: Decodable {
                let text: String
            }

            let per_item: [String: Item]
        }

        let whole: Path
        let live: Path
    }

    private struct Tally {
        var before = 0
        var after = 0
        var total = 0

        func description(_ label: String) -> String {
            func percent(_ hits: Int) -> String {
                total == 0 ? "n/a" : String(format: "%.1f%%", 100 * Double(hits) / Double(total))
            }
            return "\(label): recall \(percent(before)) (\(before)/\(total)) -> \(percent(after)) (\(after)/\(total))"
        }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func load<T: Decodable>(_ type: T.Type, _ relativePath: String) throws -> T {
        let url = repositoryRoot().appendingPathComponent(relativePath)
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private func squashed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private func words(_ text: String) -> Set<String> {
        Set(text.split { !$0.isLetter && !$0.isNumber }.map { String($0).lowercased() })
    }

    /// The corpus references are correct text: a matcher that touches them
    /// is rewriting valid prose.
    func testFuzzyPassLeavesTheCorrectReferencesUntouched() throws {
        let manifest = try load(Manifest.self, "gauntlet/asr_eval/corpus/manifest.json")
        let matcher = FuzzyDictionaryMatcher(targets: manifest.bias_vocabulary)

        for item in manifest.items {
            let result = matcher.apply(to: item.reference)
            XCTAssertEqual(result.text, item.reference, "\(item.id): \(result.replacements)")
        }
    }

    func testFuzzyPassRaisesHardVocabRecallWithoutRewritingAnythingElse() throws {
        let manifest = try load(Manifest.self, "gauntlet/asr_eval/corpus/manifest.json")
        let results = try load(Results.self, "gauntlet/asr_eval/results.json")
        let matcher = FuzzyDictionaryMatcher(targets: manifest.bias_vocabulary)
        let hardTermsByID = Dictionary(uniqueKeysWithValues: manifest.items.map { ($0.id, $0.hard_terms) })

        var tuning = Tally()
        var heldOut = Tally()
        var falseRewrites: [String] = []
        var appliedRewrites: [String] = []

        for (pathName, path) in [("whole", results.whole), ("live", results.live)] {
            for (id, item) in path.per_item.sorted(by: { $0.key < $1.key }) {
                let hardTerms = try XCTUnwrap(hardTermsByID[id], "no manifest item for \(id)")
                let result = matcher.apply(to: item.text)
                let isTuning = (Int(id.suffix(while: \.isNumber)) ?? 0) % 2 == 0

                for term in hardTerms {
                    let hit = squashed(item.text).contains(term.lowercased())
                    let hitAfter = squashed(result.text).contains(term.lowercased())
                    if isTuning {
                        tuning.total += 1; tuning.before += hit ? 1 : 0; tuning.after += hitAfter ? 1 : 0
                    } else {
                        heldOut.total += 1; heldOut.before += hit ? 1 : 0; heldOut.after += hitAfter ? 1 : 0
                    }
                }

                for replacement in result.replacements {
                    let line = "\(pathName)/\(id): '\(replacement.original)' -> '\(replacement.target)'"
                    appliedRewrites.append(line)
                    if !hardTerms.contains(replacement.target) {
                        falseRewrites.append(line)
                    }
                }
                // Nothing outside the replaced spans may differ.
                let introduced = words(result.text).subtracting(words(item.text))
                let allowed = Set(hardTerms.flatMap { words($0) })
                if !introduced.isSubset(of: allowed) {
                    falseRewrites.append("\(pathName)/\(id): introduced \(introduced.subtracting(allowed).sorted())")
                }
            }
        }

        var combined = Tally()
        combined.total = tuning.total + heldOut.total
        combined.before = tuning.before + heldOut.before
        combined.after = tuning.after + heldOut.after
        print("FUZZY-RECALL \(combined.description("all items (whole+live)"))")
        print("FUZZY-RECALL \(tuning.description("tuning (even ids)"))")
        print("FUZZY-RECALL \(heldOut.description("held out (odd ids)"))")
        print("FUZZY-RECALL rewrites applied: \(appliedRewrites.count), false rewrites: \(falseRewrites.count)")
        for line in appliedRewrites { print("FUZZY-RECALL   \(line)") }

        XCTAssertEqual(falseRewrites, [], "the fuzzy pass rewrote something that is not a hard term")
        XCTAssertGreaterThan(tuning.after, tuning.before, "no recall gain on the tuning half")
        XCTAssertGreaterThan(heldOut.after, heldOut.before, "no recall gain on the held-out half")
    }
}

private extension String {
    /// The trailing run of characters satisfying `predicate`.
    func suffix(while predicate: (Character) -> Bool) -> Substring {
        var start = endIndex
        while start > startIndex, predicate(self[index(before: start)]) {
            start = index(before: start)
        }
        return self[start...]
    }
}
