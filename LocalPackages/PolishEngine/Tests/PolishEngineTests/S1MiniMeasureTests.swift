import Foundation
@testable import PolishEngine
import Testing

/// Opt-in measurement on real dictations, kept out of normal runs: set
/// S1MINI_MEASURE to a JSON file holding an array of dictation texts and
/// S1MINI_MODEL to the GGUF file. Prints time and how many paragraphs were
/// polished per dictation, and a summary; the texts are never printed.
struct S1MiniMeasureTests {
    static var inputs: String? { ProcessInfo.processInfo.environment["S1MINI_MEASURE"] }
    static var model: String? { ProcessInfo.processInfo.environment["S1MINI_MODEL"] }

    @Test("Measure S1-mini Polish on real dictations", .enabled(if: inputs != nil && model != nil))
    func measure() async throws {
        let texts = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: Self.inputs!)))
        let polisher = S1MiniPolisher(modelPath: Self.model!)
        let loadSeconds = try await polisher.load()
        print("load \(Int(loadSeconds * 1_000)) ms")
        var rows: [(words: Int, ms: Int, polished: Int, paragraphs: Int, notes: [String])] = []
        for text in texts {
            let words = text.split(whereSeparator: \.isWhitespace).count
            let started = ContinuousClock.now
            let outcome = try await polisher.polish(text, deadline: started.advanced(by: S1MiniPolisher.timeBudget(forWords: words)))
            let elapsed = started.duration(to: .now)
            let ms = Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            rows.append((words, ms, outcome.polished, outcome.paragraphs, outcome.notes))
            print("\(words) words: \(ms) ms, \(outcome.polished)/\(outcome.paragraphs) paragraphs\(outcome.notes.isEmpty ? "" : " (" + outcome.notes.joined(separator: "; ") + ")")")
        }
        for (label, range) in [("short", 0..<40), ("medium", 40..<150), ("long", 150..<100_000)] {
            let group = rows.filter { range.contains($0.words) }
            guard !group.isEmpty else { continue }
            let median = group.map(\.ms).sorted()[group.count / 2]
            let polished = group.reduce(0) { $0 + $1.polished }
            let paragraphs = group.reduce(0) { $0 + $1.paragraphs }
            print("== \(label): \(group.count) dictations, median \(median) ms, \(polished)/\(paragraphs) paragraphs polished, \(group.filter { $0.notes.contains("out of time") }.count) ran out of time")
        }
    }
}
