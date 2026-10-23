// Runs a Parakeet-family model over an Orttaai ASR eval manifest, with and without
// FluidAudio's CTC vocabulary boosting, and writes two raw JSON files in the
// ASREvalRunnerTests format so gauntlet/asr_eval/score.py can score them.
//
//   fluidbench <ultra|phonon2> <model dir> <ctc dir> <manifest.json> <out prefix>
//
// The boost vocabulary is the manifest's bias_vocabulary (the simulated user dictionary).
import AVFoundation
import FluidAudio
import Foundation

struct Manifest: Decodable {
    struct Item: Decodable { let id: String; let wav: String }
    let bias_vocabulary: [String]
    let items: [Item]
}

struct PathResult: Encodable { let text: String; let ms: Int; let error: String? }
struct ItemResult: Encodable { let id: String; let whole: PathResult?; let live: PathResult?; let boost_applied: [String]? }
struct RunOutput: Encodable {
    let model: String; let preset: String; let speedup: Double
    let biasEnabled: Bool; let biasTermCount: Int
    let items: [ItemResult]
}

func readSamples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    precondition(file.processingFormat.sampleRate == 16_000 && file.processingFormat.channelCount == 1, "expected 16 kHz mono")
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

func write(_ out: RunOutput, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(out).write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
guard args.count == 6 else {
    print("usage: fluidbench <ultra|phonon2> <model dir> <ctc dir> <manifest.json> <out prefix>")
    exit(1)
}
let version: AsrModelVersion = args[1] == "phonon2" ? .phonon2 : .ultra
let modelDir = URL(fileURLWithPath: args[2])
let ctcDir = URL(fileURLWithPath: args[3])
let manifestURL = URL(fileURLWithPath: args[4])
let outPrefix = args[5]
let corpusDir = manifestURL.deletingLastPathComponent()
let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))

let asr = AsrManager()
// loadLocal reads exactly this folder; load(from:) would download the version's own repo beside it.
try await asr.loadModels(try AsrModels.loadLocal(from: modelDir, version: version))

let ctcModelDir = try await CtcModels.download(to: ctcDir)
let ctcModels = try await CtcModels.load(from: ctcModelDir)
let tokenizer = try await CtcTokenizer.load(from: ctcModelDir)
let terms = manifest.bias_vocabulary.map { CustomVocabularyTerm(text: $0, ctcTokenIds: tokenizer.encode($0)) }
let vocabulary = CustomVocabularyContext(terms: terms)
print("FLUIDBENCH: loaded \(args[1]) with \(terms.count) boost terms")

// Mirrors VocabularyBoostingSession.rescore, which hard-codes the default CTC cache folder.
struct Booster {
    let spotter: CtcKeywordSpotter
    let rescorer: VocabularyRescorer
    let vocabulary: CustomVocabularyContext
    let sizeConfig: ContextBiasingConstants.VocabSizeConfig

    func rescore(text: String, tokenTimings: [TokenTiming], audioSamples: [Float]) async -> VocabularyRescorer.RescoreOutput? {
        guard !tokenTimings.isEmpty, !audioSamples.isEmpty,
              let spot = try? await spotter.spotKeywordsWithLogProbs(
                  audioSamples: audioSamples, customVocabulary: vocabulary, minScore: nil),
              !spot.logProbs.isEmpty
        else { return nil }
        return rescorer.ctcTokenRescore(
            transcript: text, tokenTimings: tokenTimings, logProbs: spot.logProbs,
            frameDuration: spot.frameDuration, cbw: sizeConfig.cbw, marginSeconds: 0.5,
            minSimilarity: max(sizeConfig.minSimilarity, vocabulary.minSimilarity))
    }
}
let spotter = CtcKeywordSpotter(models: ctcModels, blankId: ctcModels.vocabulary.count)
let session = Booster(
    spotter: spotter,
    rescorer: try await VocabularyRescorer.create(
        spotter: spotter, vocabulary: vocabulary,
        config: VocabularyBoostingSession.itnDefaultConfig, ctcModelDirectory: ctcModelDir),
    vocabulary: vocabulary,
    sizeConfig: ContextBiasingConstants.rescorerConfig(forVocabSize: terms.count))

func decode(_ samples: [Float]) async throws -> ASRResult {
    var state = TdtDecoderState.make()
    return try await asr.transcribe(samples, decoderState: &state)
}

// Warm the Neural Engine (TDT and CTC) so the first timed item is not a cold compile.
let warm = try readSamples(corpusDir.appendingPathComponent(manifest.items[0].wav))
for _ in 0..<2 {
    let r = try await decode(warm)
    _ = await session.rescore(text: r.text, tokenTimings: r.tokenTimings ?? [], audioSamples: warm)
}

var plain: [ItemResult] = []
var boosted: [ItemResult] = []
for (index, item) in manifest.items.enumerated() {
    let samples = try readSamples(corpusDir.appendingPathComponent(item.wav))
    let start = Date()
    do {
        let result = try await decode(samples)
        let decodeMs = Int(Date().timeIntervalSince(start) * 1000)
        let rescored = await session.rescore(text: result.text, tokenTimings: result.tokenTimings ?? [], audioSamples: samples)
        let totalMs = Int(Date().timeIntervalSince(start) * 1000)
        let base = PathResult(text: result.text, ms: decodeMs, error: nil)
        // Like the session, keep the decoder's own text unless a replacement was applied.
        let boost = PathResult(text: rescored?.wasModified == true ? rescored!.text : result.text, ms: totalMs, error: nil)
        let applied = rescored.map { $0.wasModified ? $0.replacements.map { "\($0)" } : [] } ?? []
        plain.append(ItemResult(id: item.id, whole: base, live: base, boost_applied: nil))
        boosted.append(ItemResult(id: item.id, whole: boost, live: boost, boost_applied: applied))
        print("FLUIDBENCH [\(index + 1)/\(manifest.items.count)] \(item.id) decode=\(decodeMs)ms boost=\(totalMs)ms")
    } catch {
        let failed = PathResult(text: "", ms: Int(Date().timeIntervalSince(start) * 1000), error: "\(error)")
        plain.append(ItemResult(id: item.id, whole: failed, live: failed, boost_applied: nil))
        boosted.append(ItemResult(id: item.id, whole: failed, live: failed, boost_applied: nil))
    }
}

let name = version == .phonon2 ? "phonon-2-coreml" : "fluid-speech-mini-coreml"
try write(RunOutput(model: name, preset: "plain", speedup: 1, biasEnabled: false, biasTermCount: 0, items: plain), to: outPrefix + "_plain.json")
try write(RunOutput(model: name, preset: "ctc-boost", speedup: 1, biasEnabled: true, biasTermCount: terms.count, items: boosted), to: outPrefix + "_boost.json")
print("FLUIDBENCH: wrote \(plain.count) items to \(outPrefix)_{plain,boost}.json")
