// DictionaryPassEvalTests.swift
// OrttaaiTests
//
// Env-gated eval step, skipped in the normal unit suite. Runs a raw ASR eval
// decode (the JSON ASREvalRunnerTests or gauntlet/asr_eval/fluidbench writes)
// through the production RuleBasedTextProcessor with the manifest's
// bias_vocabulary saved as dictionary entries (source = target = term), and
// writes the same JSON with every whole/live text replaced, so score.py can
// score "the model plus the user's dictionary" against the model alone.
//
// Only the dictionary stage runs (exact replacements, then the fuzzy
// matcher): snippets, disfluency cleanup and spoken formatting are off, so
// the WER change is the dictionary's alone.
//
// Environment (pass with the TEST_RUNNER_ prefix through xcodebuild):
//   ORTTAAI_DICT_EVAL_MANIFEST  corpus manifest with bias_vocabulary (required)
//   ORTTAAI_DICT_EVAL_IN        comma-separated raw decode JSON paths (required)
//   ORTTAAI_DICT_EVAL_SUFFIX    appended before .json for each output
//                               (default _dict)

import XCTest
import GRDB
@testable import Orttaai

@MainActor
final class DictionaryPassEvalTests: XCTestCase {
    private struct Manifest: Decodable {
        let bias_vocabulary: [String]
    }

    private let settingKeys = [
        "dictionaryEnabled", "fuzzyDictionaryEnabled", "snippetsEnabled",
        "disfluencyCleanupEnabled", "spokenFormattingEnabled", "dictationLanguage"
    ]

    func testApplyDictionaryPass() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let manifestPath = environment["ORTTAAI_DICT_EVAL_MANIFEST"],
              let inputPaths = environment["ORTTAAI_DICT_EVAL_IN"] else {
            throw XCTSkip("Set ORTTAAI_DICT_EVAL_MANIFEST and ORTTAAI_DICT_EVAL_IN to run the dictionary pass.")
        }
        let suffix = environment["ORTTAAI_DICT_EVAL_SUFFIX"] ?? "_dict"
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: manifestPath))
        )

        let savedDefaults = settingKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, value) in savedDefaults {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let settings = AppSettings()
        settings.dictionaryEnabled = true
        settings.fuzzyDictionaryEnabled = true
        settings.snippetsEnabled = false
        settings.disfluencyCleanupEnabled = false
        settings.spokenFormattingEnabled = false
        settings.dictationLanguage = "en"

        let db = try DatabaseManager(dbQueue: try DatabaseQueue(path: ":memory:"))
        for term in manifest.bias_vocabulary {
            _ = try db.upsertDictionaryEntry(source: term, target: term)
        }
        let processor = RuleBasedTextProcessor(databaseManager: db, settings: settings)

        for inputPath in inputPaths.split(separator: ",").map(String.init) {
            let data = try Data(contentsOf: URL(fileURLWithPath: inputPath))
            guard var run = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = run["items"] as? [[String: Any]] else {
                XCTFail("\(inputPath) is not a raw ASR eval decode")
                continue
            }
            var changed = 0
            var processed: [[String: Any]] = []
            for var item in items {
                for path in ["whole", "live"] {
                    guard var result = item[path] as? [String: Any], let text = result["text"] as? String else { continue }
                    let output = try await processor.process(
                        TextProcessorInput(rawTranscript: text, targetApp: nil, mode: .raw)
                    )
                    if output.text != text.trimmingCharacters(in: .whitespacesAndNewlines) { changed += 1 }
                    result["text"] = output.text
                    item[path] = result
                }
                processed.append(item)
            }
            run["items"] = processed
            run["dictionaryPass"] = ["terms": manifest.bias_vocabulary.count]
            let outputPath = inputPath.hasSuffix(".json")
                ? String(inputPath.dropLast(5)) + suffix + ".json"
                : inputPath + suffix
            try JSONSerialization.data(withJSONObject: run, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: outputPath))
            print("DICT-EVAL \(inputPath): \(changed) texts changed -> \(outputPath)")
        }
    }
}
