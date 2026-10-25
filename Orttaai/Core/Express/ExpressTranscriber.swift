// ExpressTranscriber.swift
// Orttaai

import ExpressAudio
import Foundation
import os

/// What TranscriptionService needs from a loaded Express model. A protocol so
/// the service can hold one without availability annotations and tests can
/// stand in for Fluid Speech Mini without Core ML models.
protocol ExpressBackend: Actor {
    /// The cleaned transcript. Numbers are formatted by the caller, once the
    /// whole dictation's text is together.
    func transcribe(_ audioSamples: [Float]) async throws -> String
    /// Installs the Word Boost vocabulary for later decodes and returns how
    /// many terms it will use: 0 when the list is empty or Word Boost's model
    /// is not loaded.
    func setWordBoost(_ terms: [WordBoostTerm]) async -> Int
    /// Scores the Word Boost chunks a recording in progress has completed,
    /// so the final decode only has to score what came after them.
    func prepareWordBoost(_ audioPrefix: [Float]) async
    /// Drops scores kept for a recording that will not be decoded.
    func discardPreparedWordBoost() async
}

extension ExpressBackend {
    func prepareWordBoost(_ audioPrefix: [Float]) async {}
    func discardPreparedWordBoost() async {}
}

/// Fluid Speech Mini through FluidAudio. Decoding is fast enough (about 40 ms
/// for a short dictation, 1.5 s for a 10-minute one on the Neural Engine)
/// that it decodes the whole recording once at the end, unless live segments
/// are on (`TranscriptionService`), which decode windows of it as it grows.
/// With Word Boost, a second small model (Parakeet CTC 110M) checks the
/// user's dictionary words against the audio and `WordBoostGuard` decides
/// which of its proposed replacements to keep. That model's scores are
/// computed in 15 s chunks as the recording grows (`prepareWordBoost`).
@available(macOS 15, *)
actor ExpressTranscriber: ExpressBackend {
    private static let sampleRate = 16_000
    /// FluidAudio rejects audio shorter than one second; silence is padded on.
    private static let minimumSampleCount = sampleRate

    private struct WordBoostModel {
        let directory: URL
        let spotter: CtcKeywordSpotter
        let tokenizer: CtcTokenizer
    }

    private struct WordBoostSession {
        let terms: [WordBoostTerm]
        let vocabulary: CustomVocabularyContext
        let rescorer: VocabularyRescorer
        let sizeConfig: ContextBiasingConstants.VocabSizeConfig
    }

    /// One Word Boost chunk's CTC scores and the audio they were computed on.
    private struct ScoredChunk {
        let range: Range<Int>
        let fingerprint: Int
        let logProbs: [[Float]]
        let frameDuration: Double
    }

    private let asr: AsrManager
    private let wordBoostModel: WordBoostModel?
    private var wordBoost: WordBoostSession?
    /// Chunks scored for the current recording, by first sample.
    private var scoredChunks: [Int: ScoredChunk] = [:]
    private var preparing: Task<Void, Never>?
    private var isTranscribing = false

    private init(asr: AsrManager, wordBoostModel: WordBoostModel?) {
        self.asr = asr
        self.wordBoostModel = wordBoostModel
    }

    /// Loads the packages installed by `ExpressModelStore`. The first load on
    /// a Mac compiles them for the Neural Engine (about 10 s); macOS caches
    /// the result, and later loads take a fraction of a second. Word Boost is
    /// optional: without its folder Express transcribes unboosted.
    static func load(from folder: URL, wordBoostFolder: URL?) async throws -> ExpressTranscriber {
        let models = try AsrModels.loadLocal(from: folder, version: ExpressEngine.modelVersion)
        let asr = AsrManager()
        try await asr.loadModels(models)

        var wordBoostModel: WordBoostModel?
        if let wordBoostFolder {
            do {
                let ctcModels = try await CtcModels.loadDirect(from: wordBoostFolder)
                wordBoostModel = WordBoostModel(
                    directory: wordBoostFolder,
                    spotter: CtcKeywordSpotter(models: ctcModels, blankId: ctcModels.vocabulary.count),
                    tokenizer: try await CtcTokenizer.load(from: wordBoostFolder)
                )
            } catch {
                Logger.transcription.error("Word Boost model failed to load: \(error.localizedDescription, privacy: .public)")
            }
        }
        Logger.transcription.info(
            "Express model loaded from \(folder.path, privacy: .public) (Word Boost \(wordBoostModel == nil ? "off" : "ready"))"
        )
        return ExpressTranscriber(asr: asr, wordBoostModel: wordBoostModel)
    }

    func setWordBoost(_ terms: [WordBoostTerm]) async -> Int {
        guard let model = wordBoostModel, !terms.isEmpty else {
            wordBoost = nil
            return 0
        }
        if let wordBoost, wordBoost.terms == terms {
            return wordBoost.vocabulary.terms.count
        }
        let vocabularyTerms = terms.compactMap { term -> CustomVocabularyTerm? in
            let tokenIDs = model.tokenizer.encode(term.text)
            guard !tokenIDs.isEmpty else { return nil }
            return CustomVocabularyTerm(
                text: term.text,
                aliases: term.aliases.isEmpty ? nil : term.aliases,
                ctcTokenIds: tokenIDs
            )
        }
        guard !vocabularyTerms.isEmpty else {
            wordBoost = nil
            return 0
        }
        let vocabulary = CustomVocabularyContext(terms: vocabularyTerms)
        do {
            let rescorer = try await VocabularyRescorer.create(
                spotter: model.spotter,
                vocabulary: vocabulary,
                config: VocabularyBoostingSession.itnDefaultConfig,
                ctcModelDirectory: model.directory
            )
            wordBoost = WordBoostSession(
                terms: terms,
                vocabulary: vocabulary,
                rescorer: rescorer,
                sizeConfig: ContextBiasingConstants.rescorerConfig(forVocabSize: vocabularyTerms.count)
            )
            return vocabularyTerms.count
        } catch {
            Logger.transcription.error("Word Boost vocabulary failed: \(error.localizedDescription, privacy: .public)")
            wordBoost = nil
            return 0
        }
    }

    func prepareWordBoost(_ audioPrefix: [Float]) async {
        guard let session = wordBoost, let model = wordBoostModel, preparing == nil, !isTranscribing else { return }
        let task = Task {
            for range in WordBoostChunks.completeChunks(inPrefixOf: audioPrefix.count) {
                guard !Task.isCancelled else { return }
                _ = try? await self.scoredChunk(range, of: audioPrefix, model: model, session: session)
            }
        }
        preparing = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        preparing = nil
    }

    func discardPreparedWordBoost() async {
        preparing?.cancel()
        await preparing?.value
        scoredChunks = [:]
    }

    func transcribe(_ audioSamples: [Float]) async throws -> String {
        isTranscribing = true
        defer {
            isTranscribing = false
            // A recording's scores are used once.
            scoredChunks = [:]
        }
        await preparing?.value

        var samples = ExpressAudioConditioner.liftingQuietTail(audioSamples)
        if samples.count < Self.minimumSampleCount {
            samples.append(contentsOf: [Float](repeating: 0, count: Self.minimumSampleCount - samples.count))
        }
        var decoderState = TdtDecoderState.make()
        let result = try await asr.transcribe(samples, decoderState: &decoderState)
        var text = result.text
        if let wordBoost, let model = wordBoostModel, let timings = result.tokenTimings, !timings.isEmpty {
            text = await boosted(text, timings: timings, samples: samples, session: wordBoost, model: model)
        }
        return Self.cleanedText(text)
    }

    /// Applies the replacements FluidAudio's own rescorer would apply, minus
    /// the ones `WordBoostGuard` rejects. Boosting must never break a
    /// dictation: any failure returns the unboosted text.
    private func boosted(
        _ text: String,
        timings: [TokenTiming],
        samples: [Float],
        session: WordBoostSession,
        model: WordBoostModel
    ) async -> String {
        do {
            let scores = try await wordBoostScores(for: samples, model: model, session: session)
            guard !scores.logProbs.isEmpty else { return text }
            let evidence = session.rescorer.ctcTokenEvaluateCandidates(
                transcript: text,
                tokenTimings: timings,
                logProbs: scores.logProbs,
                frameDuration: scores.frameDuration,
                cbw: session.sizeConfig.cbw,
                marginSeconds: 0.5,
                minSimilarity: max(session.sizeConfig.minSimilarity, session.vocabulary.minSimilarity)
            )
            let replacements = evidence.candidates.compactMap { candidate -> (Range<Int>, String)? in
                guard candidate.legacyOutcome == .applied,
                      let range = candidate.baseTextUTF8Range,
                      let vocabularyScore = candidate.rawVocabularyCTCScore,
                      let originalScore = candidate.rawOriginalCTCScore else { return nil }
                let margin = vocabularyScore - originalScore
                let accepted = WordBoostGuard.accepts(.init(
                    heard: candidate.basePhrase,
                    term: candidate.canonicalTerm,
                    acousticMargin: margin
                ))
                // Every proposal, kept or not, so a wrong swap can be traced
                // to its numbers. What was said stays private in the log.
                let similarity = WordBoostGuard.spellingSimilarity(
                    WordBoostGuard.words(in: candidate.basePhrase).joined(),
                    WordBoostGuard.words(in: candidate.canonicalTerm).joined()
                )
                Logger.transcription.info(
                    "Word Boost \(accepted ? "applied" : "rejected", privacy: .public): \(candidate.basePhrase, privacy: .private) -> \(candidate.canonicalTerm, privacy: .public) [margin \(margin, format: .fixed(precision: 2), privacy: .public), spelling \(similarity, format: .fixed(precision: 2), privacy: .public)]"
                )
                return accepted ? (range, candidate.canonicalTerm) : nil
            }
            Logger.transcription.info("Word Boost: \(replacements.count, privacy: .public) of \(evidence.candidates.count, privacy: .public) proposals applied")
            return Self.applying(replacements, to: evidence.baseText)
        } catch {
            Logger.transcription.error("Word Boost skipped: \(error.localizedDescription, privacy: .public)")
            return text
        }
    }

    /// The CTC scores for the whole recording, reusing chunks scored while it
    /// was being recorded.
    private func wordBoostScores(
        for samples: [Float],
        model: WordBoostModel,
        session: WordBoostSession
    ) async throws -> (logProbs: [[Float]], frameDuration: Double) {
        var chunks: [ScoredChunk] = []
        for range in WordBoostChunks.chunks(forSampleCount: samples.count) {
            chunks.append(try await scoredChunk(range, of: samples, model: model, session: session))
        }
        guard let frameDuration = chunks.first?.frameDuration else { return ([], 0) }
        return (WordBoostChunks.stitch(chunks.map(\.logProbs), frameDuration: frameDuration), frameDuration)
    }

    private func scoredChunk(
        _ range: Range<Int>,
        of samples: [Float],
        model: WordBoostModel,
        session: WordBoostSession
    ) async throws -> ScoredChunk {
        let fingerprint = WordBoostChunks.fingerprint(samples[range])
        if let cached = scoredChunks[range.lowerBound], cached.range == range, cached.fingerprint == fingerprint {
            return cached
        }
        let spot = try await model.spotter.spotKeywordsWithLogProbs(
            audioSamples: Array(samples[range]),
            customVocabulary: session.vocabulary,
            minScore: nil
        )
        let chunk = ScoredChunk(range: range, fingerprint: fingerprint, logProbs: spot.logProbs, frameDuration: spot.frameDuration)
        scoredChunks[range.lowerBound] = chunk
        return chunk
    }

    /// Replaces UTF-8 byte ranges of `text` with terms, keeping punctuation
    /// that was attached to the heard phrase ("release." keeps its period).
    nonisolated static func applying(_ replacements: [(Range<Int>, String)], to text: String) -> String {
        var result = text
        let utf8Count = text.utf8.count
        for (range, term) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            guard range.lowerBound >= 0, range.upperBound <= utf8Count,
                  let lower = result.utf8.index(result.startIndex, offsetBy: range.lowerBound, limitedBy: result.endIndex),
                  let upper = result.utf8.index(result.startIndex, offsetBy: range.upperBound, limitedBy: result.endIndex),
                  lower <= upper else { continue }
            let heard = result[lower..<upper]
            let leading = heard.prefix { !($0.isLetter || $0.isNumber) }
            let trailing = String(heard.reversed().prefix { !($0.isLetter || $0.isNumber) }.reversed())
            result.replaceSubrange(lower..<upper, with: leading + term + trailing)
        }
        return result
    }

    /// Mini occasionally emits `<unk>` where an apostrophe belongs ("I<unk>ll",
    /// once in 50 real recordings). Between letters it becomes an apostrophe;
    /// anywhere else it is dropped.
    nonisolated static func cleanedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"(?<=\p{L})<unk>(?=\p{L})"#, with: "'", options: .regularExpression)
            .replacingOccurrences(of: "<unk>", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
