// ExpressTranscriber.swift
// Orttaai

import ExpressAudio
import Foundation
import os

/// What TranscriptionService needs from a loaded Express model. A protocol so
/// the service can hold one without availability annotations and tests can
/// stand in for Fluid Speech Mini without Core ML models.
protocol ExpressBackend: Actor {
    func transcribe(_ audioSamples: [Float]) async throws -> String
    /// Installs the Word Boost vocabulary for later decodes and returns how
    /// many terms it will use: 0 when the list is empty or Word Boost's model
    /// is not loaded.
    func setWordBoost(_ terms: [WordBoostTerm]) async -> Int
}

/// Fluid Speech Mini through FluidAudio. Decoding is fast enough (about 40 ms
/// for a short dictation, under 300 ms for a 35 s one on the Neural Engine)
/// that it decodes the whole recording once at the end, with no live clips.
/// With Word Boost, a second small model (Parakeet CTC 110M) checks the
/// user's dictionary words against the audio and `WordBoostGuard` decides
/// which of its proposed replacements to keep.
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

    private let asr: AsrManager
    private let wordBoostModel: WordBoostModel?
    private var wordBoost: WordBoostSession?

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

    func transcribe(_ audioSamples: [Float]) async throws -> String {
        var samples = audioSamples
        if samples.count < Self.minimumSampleCount {
            samples.append(contentsOf: [Float](repeating: 0, count: Self.minimumSampleCount - samples.count))
        }
        var decoderState = TdtDecoderState.make()
        let result = try await asr.transcribe(samples, decoderState: &decoderState)
        var text = result.text
        if let wordBoost, let model = wordBoostModel, let timings = result.tokenTimings, !timings.isEmpty {
            text = await boosted(text, timings: timings, samples: samples, session: wordBoost, model: model)
        }
        return ExpressNumberFormatter.format(Self.cleanedText(text))
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
            let spot = try await model.spotter.spotKeywordsWithLogProbs(
                audioSamples: samples,
                customVocabulary: session.vocabulary,
                minScore: nil
            )
            guard !spot.logProbs.isEmpty else { return text }
            let evidence = session.rescorer.ctcTokenEvaluateCandidates(
                transcript: text,
                tokenTimings: timings,
                logProbs: spot.logProbs,
                frameDuration: spot.frameDuration,
                cbw: session.sizeConfig.cbw,
                marginSeconds: 0.5,
                minSimilarity: max(session.sizeConfig.minSimilarity, session.vocabulary.minSimilarity)
            )
            let replacements = evidence.candidates.compactMap { candidate -> (Range<Int>, String)? in
                guard candidate.legacyOutcome == .applied,
                      let range = candidate.baseTextUTF8Range,
                      let vocabularyScore = candidate.rawVocabularyCTCScore,
                      let originalScore = candidate.rawOriginalCTCScore else { return nil }
                let accepted = WordBoostGuard.accepts(.init(
                    heard: candidate.basePhrase,
                    term: candidate.canonicalTerm,
                    acousticMargin: vocabularyScore - originalScore
                ))
                return accepted ? (range, candidate.canonicalTerm) : nil
            }
            return Self.applying(replacements, to: evidence.baseText)
        } catch {
            Logger.transcription.error("Word Boost skipped: \(error.localizedDescription, privacy: .public)")
            return text
        }
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
