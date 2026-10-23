// VoiceStampSpikeTests.swift
// OrttaaiTests
//
// Research spike for voice stamps (tracker P5.2): could a few spoken examples
// of a name find it in later dictations, where Word Boost's spelling-based
// matching misses? Env-gated like ASREvalRunnerTests, and never part of the
// unit suite:
//   ORTTAAI_VOICESTAMP_SPIKE=1        enable
//   ORTTAAI_VOICESTAMP_MANIFEST       a corpus manifest (the real-voice set)
//   ORTTAAI_VOICESTAMP_MODEL_ROOT     storage base; Parakeet CTC 110M is
//                                     installed there when missing
//   ORTTAAI_VOICESTAMP_OUT            JSON for gauntlet/asr_eval/voice_stamp_spike.py
//
// Every vocabulary term spoken in two or more recordings gives one-shot
// stamps: each occurrence, located by the CTC keyword spotter (which knows
// the spelling), is cut out of the CTC model's per-frame token posteriors.
// Each stamp is matched against every recording with subsequence dynamic
// time warping, comparing frames by -log of the dot product of their
// posteriors, with and without the blank token.

import ExpressAudio
import Accelerate
import XCTest
@testable import Orttaai

final class VoiceStampSpikeTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Item: Decodable {
            let id: String
            let reference: String
            let wav: String
        }

        let bias_vocabulary: [String]
        let items: [Item]
    }

    private struct Occurrence: Encodable {
        let term: String
        let clip: String
        let startFrame: Int
        let endFrame: Int
        let spotScore: Float
    }

    private struct Match: Encodable {
        let term: String
        let stampClip: String
        let clip: String
        let variant: String
        let cost: Float
        let startFrame: Int
        let endFrame: Int
        let clipHasTerm: Bool
    }

    private struct Output: Encodable {
        let frameDuration: Double
        let occurrences: [Occurrence]
        let matches: [Match]
    }

    func testRunVoiceStampSpike() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ORTTAAI_VOICESTAMP_SPIKE"] == "1" else {
            throw XCTSkip("ORTTAAI_VOICESTAMP_SPIKE not set; spike disabled")
        }
        guard let manifest = env["ORTTAAI_VOICESTAMP_MANIFEST"],
              let root = env["ORTTAAI_VOICESTAMP_MODEL_ROOT"],
              let out = env["ORTTAAI_VOICESTAMP_OUT"] else {
            XCTFail("ORTTAAI_VOICESTAMP_MANIFEST, _MODEL_ROOT and _OUT are required")
            return
        }
        guard #available(macOS 15, *) else { throw XCTSkip("needs macOS 15") }
        try await Self.run(
            manifestURL: URL(fileURLWithPath: manifest),
            root: URL(fileURLWithPath: root, isDirectory: true),
            out: URL(fileURLWithPath: out)
        )
    }

    @available(macOS 15, *)
    private static func run(manifestURL: URL, root: URL, out: URL) async throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        if !ExpressModelStore.isInstalled(ExpressModelStore.wordBoost, in: root) {
            try await ExpressModelStore.install(ExpressModelStore.wordBoost, into: root) { _ in }
        }
        let folder = ExpressModelStore.folder(for: ExpressModelStore.wordBoost, in: root)
        let models = try await CtcModels.loadDirect(from: folder)
        let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        let tokenizer = try await CtcTokenizer.load(from: folder)

        func spoken(_ term: String, in item: Manifest.Item) -> Bool {
            item.reference.range(of: "\\b\(NSRegularExpression.escapedPattern(for: term))\\b", options: .regularExpression) != nil
        }
        let terms = manifest.bias_vocabulary.filter { term in manifest.items.filter { spoken(term, in: $0) }.count >= 2 }
        let vocabulary = CustomVocabularyContext(terms: terms.map {
            CustomVocabularyTerm(text: $0, aliases: nil, ctcTokenIds: tokenizer.encode($0))
        })

        // Posteriors per clip, and where the spotter places each term in the
        // clips that say it.
        var posteriors: [String: [[Float]]] = [:]
        var occurrences: [Occurrence] = []
        var frameDuration = 0.0
        for item in manifest.items {
            let samples = try ASREvalRunnerTests.loadFloat32WAV(url: manifestURL.deletingLastPathComponent().appendingPathComponent(item.wav))
            let spot = try await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: vocabulary, minScore: -1_000_000)
            frameDuration = spot.frameDuration
            posteriors[item.id] = spot.logProbs.map { $0.map(expf) }
            for term in terms where spoken(term, in: item) {
                guard let best = spot.detections.filter({ $0.term.text == term }).max(by: { $0.score < $1.score }) else { continue }
                occurrences.append(Occurrence(term: term, clip: item.id, startFrame: best.startFrame, endFrame: best.endFrame, spotScore: best.score))
            }
            print("VOICESTAMP: scored \(item.id)")
        }

        let blankID = models.vocabulary.count
        var matches: [Match] = []
        for variant in ["full", "no_blank"] {
            let frames = variant == "full" ? posteriors : posteriors.mapValues { $0.map { withoutBlank($0, blankID: blankID) } }
            for stamp in occurrences {
                guard let source = frames[stamp.clip], stamp.endFrame >= stamp.startFrame else { continue }
                let query = Array(source[max(0, stamp.startFrame)...min(source.count - 1, stamp.endFrame)])
                for item in manifest.items where item.id != stamp.clip {
                    guard let target = frames[item.id], let best = subsequenceDTW(query: query, target: target) else { continue }
                    matches.append(Match(
                        term: stamp.term,
                        stampClip: stamp.clip,
                        clip: item.id,
                        variant: variant,
                        cost: best.cost,
                        startFrame: best.start,
                        endFrame: best.end,
                        clipHasTerm: spoken(stamp.term, in: item)
                    ))
                }
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Output(frameDuration: frameDuration, occurrences: occurrences, matches: matches)).write(to: out)
        print("VOICESTAMP: wrote \(occurrences.count) occurrences, \(matches.count) matches to \(out.path)")
    }

    private static func withoutBlank(_ frame: [Float], blankID: Int) -> [Float] {
        var copy = frame
        if blankID < copy.count { copy[blankID] = 0 }
        let total = copy.reduce(0, +)
        return total > 0 ? copy.map { $0 / total } : copy
    }

    /// Lowest path-length-normalised cost of `query` aligned to any stretch
    /// of `target`, with that stretch.
    private static func subsequenceDTW(query: [[Float]], target: [[Float]]) -> (cost: Float, start: Int, end: Int)? {
        let n = query.count, m = target.count
        guard n > 0, m > 0 else { return nil }
        func distance(_ i: Int, _ j: Int) -> Float {
            var dot: Float = 0
            vDSP_dotpr(query[i], 1, target[j], 1, &dot, vDSP_Length(min(query[i].count, target[j].count)))
            return -logf(max(dot, 1e-8))
        }
        var cost = [Float](repeating: 0, count: n * m)
        var length = [Int](repeating: 0, count: n * m)
        var start = [Int](repeating: 0, count: n * m)
        for i in 0..<n {
            for j in 0..<m {
                let d = distance(i, j)
                let index = i * m + j
                if i == 0 {
                    cost[index] = d
                    length[index] = 1
                    start[index] = j
                    continue
                }
                var best = (i - 1) * m + j
                if j > 0 {
                    for candidate in [(i - 1) * m + j - 1, i * m + j - 1]
                    where cost[candidate] / Float(length[candidate]) < cost[best] / Float(length[best]) {
                        best = candidate
                    }
                }
                cost[index] = cost[best] + d
                length[index] = length[best] + 1
                start[index] = start[best]
            }
        }
        let last = (n - 1) * m
        let end = (0..<m).min { cost[last + $0] / Float(length[last + $0]) < cost[last + $1] / Float(length[last + $1]) }!
        return (cost[last + end] / Float(length[last + end]), start[last + end], end)
    }
}
