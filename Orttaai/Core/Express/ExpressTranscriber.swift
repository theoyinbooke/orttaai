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
    /// The same, for a recording still in progress: the Word Boost scores
    /// prepared for it are kept for a later decode, as the speaker may go on.
    func transcribe(_ audioSamples: [Float], keepingPreparedScores: Bool) async throws -> String
    /// Installs the Word Boost vocabulary for later decodes and returns how
    /// many terms it will use: 0 when the list is empty or Word Boost's model
    /// is not loaded.
    func setWordBoost(_ terms: [WordBoostTerm]) async -> Int
    /// Scores the Word Boost chunks a recording in progress has completed,
    /// so the final decode only has to score what came after them.
    func prepareWordBoost(_ audioPrefix: [Float]) async
    /// Drops scores kept for a recording that will not be decoded.
    func discardPreparedWordBoost() async
    /// What your fixes taught about how your words sound.
    func setSoundAnchors(_ book: SoundAnchorBook) async
    /// Each heard word the sound anchors judged in the last decode.
    func soundDecisions() async -> [SoundAnchorJudge.Decision]
    /// What a fix teaches: in this recording you said `term` where the
    /// dictation had `heard`.
    func learnSound(from audioSamples: [Float], heard: String, term: String, occurrence: Int) async throws -> ExpressLearnedSound?
}

/// What one fix taught: the ways your word sounded, best first, and how
/// strongly the sound backed it.
nonisolated struct ExpressLearnedSound: Sendable, Equatable {
    var sounds: [String]
    var margin: Float
}

extension ExpressBackend {
    func transcribe(_ audioSamples: [Float], keepingPreparedScores: Bool) async throws -> String {
        try await transcribe(audioSamples)
    }
    func prepareWordBoost(_ audioPrefix: [Float]) async {}
    func discardPreparedWordBoost() async {}
    func setSoundAnchors(_ book: SoundAnchorBook) async {}
    func soundDecisions() async -> [SoundAnchorJudge.Decision] { [] }
    func learnSound(from audioSamples: [Float], heard: String, term: String, occurrence: Int) async throws -> ExpressLearnedSound? { nil }
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
        let blankID: Int
        /// Token id to SentencePiece piece, for spelling what was heard.
        let pieces: [Int: String]
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
                    tokenizer: try await CtcTokenizer.load(from: wordBoostFolder),
                    blankID: ctcModels.vocabulary.count,
                    pieces: Self.pieces(in: wordBoostFolder)
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
        try await transcribe(audioSamples, keepingPreparedScores: false)
    }

    func transcribe(_ audioSamples: [Float], keepingPreparedScores: Bool) async throws -> String {
        isTranscribing = true
        defer {
            isTranscribing = false
            // A finished recording's scores are used once.
            if !keepingPreparedScores { scoredChunks = [:] }
        }
        await preparing?.value

        var samples = ExpressAudioConditioner.liftingQuietTail(audioSamples)
        if samples.count < Self.minimumSampleCount {
            samples.append(contentsOf: [Float](repeating: 0, count: Self.minimumSampleCount - samples.count))
        }
        var decoderState = TdtDecoderState.make()
        let result = try await asr.transcribe(samples, decoderState: &decoderState)
        var text = result.text
        lastSoundDecisions = []
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
            var replacements = evidence.candidates.compactMap { candidate -> (Range<Int>, String)? in
                guard candidate.legacyOutcome == .applied,
                      let range = candidate.baseTextUTF8Range,
                      let vocabularyScore = candidate.rawVocabularyCTCScore,
                      let originalScore = candidate.rawOriginalCTCScore,
                      // A word your fixes taught by sound is decided by the sound.
                      !soundAnchors.decidesBySound(term: candidate.canonicalTerm) else { return nil }
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
            if !soundAnchors.isEmpty {
                let anchored = await soundAnchorReplacements(text, timings: timings, samples: samples, scores: scores, model: model)
                replacements.removeAll { kept in anchored.contains { $0.0.overlaps(kept.0) } }
                replacements += anchored
            }
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

    // MARK: Sound anchors

    /// What your fixes taught about how your words sound (SoundAnchors):
    /// "email" written as Eimailar only where the sound says Eimailar.
    private var soundAnchors = SoundAnchorBook()
    /// Each heard word the anchors judged in the last decode.
    private var lastSoundDecisions: [SoundAnchorJudge.Decision] = []

    // `async`, as the protocol's do-nothing defaults are: from async code
    // Swift prefers an async overload, and a plain method here lost to them.
    func setSoundAnchors(_ book: SoundAnchorBook) async {
        soundAnchors = book
    }

    func soundDecisions() async -> [SoundAnchorJudge.Decision] {
        lastSoundDecisions
    }

    /// For the own-voice eval: anchors set, Word Boost model and session.
    func soundState() -> (anchors: Int, model: Bool, session: Bool) {
        (soundAnchors.anchors.count, wordBoostModel != nil, wordBoost != nil)
    }

    private func soundAnchorReplacements(
        _ text: String,
        timings: [TokenTiming],
        samples: [Float],
        scores: (logProbs: [[Float]], frameDuration: Double),
        model: WordBoostModel
    ) async -> [(Range<Int>, String)] {
        let words = SoundWord.words(fromTokens: timings.map { ($0.token, $0.startTime, $0.endTime) })
        var (replacements, decisions) = SoundAnchorJudge.judge(soundAnchors, text: text, words: words) { range, heard, sound in
            guard let window = SoundContrast.window(for: range, in: words, frameDuration: scores.frameDuration, frameCount: scores.logProbs.count) else { return nil }
            return SoundContrast.margin(scores.logProbs, window: window, heard: heard, term: sound, blank: model.blankID) { model.tokenizer.encode($0) }
        }
        // Where the sound check kept the heard word, listen again slowed
        // down: a fast Eimailar whose ending was swallowed is often heard then.
        let spellings = SoundAnchorJudge.soundSpellings(soundAnchors)
        let ranges = SoundAnchorJudge.utf8Ranges(of: words, in: text)
        for index in decisions.indices where !decisions[index].applied {
            guard let range = decisions[index].wordRange, range.count == 1, let utf8 = ranges[range.lowerBound],
                  !replacements.contains(where: { $0.0.overlaps(utf8) }),
                  await heardWhenSlowed(range, words: words, samples: samples, heard: decisions[index].heard,
                                        term: decisions[index].term, spellings: spellings) else { continue }
            replacements.append((utf8, decisions[index].term))
            decisions[index].applied = true
            decisions[index].margin = SoundAnchorJudge.slowListenMargin
        }
        lastSoundDecisions = decisions
        // Scores only, never what was said.
        let scoresText = decisions.map { String(format: "%@%.1f", $0.applied ? "+" : "kept ", $0.margin) }.joined(separator: ", ")
        Logger.transcription.info("Sound anchors: \(decisions.filter(\.applied).count, privacy: .public) of \(decisions.count, privacy: .public) heard words written your way (\(scoresText, privacy: .public))")
        return replacements
    }

    /// The heard word and two words either side, slowed with the pitch kept
    /// and transcribed again: whether your word was heard.
    private func heardWhenSlowed(_ range: Range<Int>, words: [SoundWord], samples: [Float], heard: String, term: String, spellings: [String: String]) async -> Bool {
        let lower = max(0, range.lowerBound - 2), upper = min(words.count - 1, range.upperBound + 1)
        let start = max(0, Int((words[lower].start - 0.3) * Double(Self.sampleRate)))
        let end = min(samples.count, Int((words[upper].end + 0.3) * Double(Self.sampleRate)))
        guard start < end else { return false }
        let window = Array(samples[start..<end])
        for rate in SoundAnchorJudge.slowListenRates {
            guard var slowed = SlowListen.stretched(window, rate: rate) else { return false }
            if slowed.count < Self.minimumSampleCount { slowed += [Float](repeating: 0, count: Self.minimumSampleCount - slowed.count) }
            var state = TdtDecoderState.make()
            guard let result = try? await asr.transcribe(slowed, decoderState: &state) else { return false }
            if SoundAnchorJudge.slowListenHeard(SoundContrast.key(result.text), heard: heard, term: term, spellings: spellings) { return true }
        }
        return false
    }

    /// Learns from a fix: in this recording you said `term` where the
    /// dictation had `heard` (its `occurrence`-th time, from 0). Nil without
    /// Word Boost's model or when the heard words aren't found.
    func learnSound(from audioSamples: [Float], heard: String, term: String, occurrence: Int) async throws -> ExpressLearnedSound? {
        guard let model = wordBoostModel, let session = wordBoost else { return nil }
        var samples = ExpressAudioConditioner.liftingQuietTail(audioSamples)
        if samples.count < Self.minimumSampleCount {
            samples += [Float](repeating: 0, count: Self.minimumSampleCount - samples.count)
        }
        var decoderState = TdtDecoderState.make()
        let result = try await asr.transcribe(samples, decoderState: &decoderState)
        let words = SoundWord.words(fromTokens: (result.tokenTimings ?? []).map { ($0.token, $0.startTime, $0.endTime) })
        let found = SoundContrast.occurrences(of: heard, in: words)
        guard !found.isEmpty else { return nil }
        let range = found[min(max(0, occurrence), found.count - 1)]
        var chunks: [[[Float]]] = []
        var frameDuration: Double?
        for chunk in WordBoostChunks.chunks(forSampleCount: samples.count) {
            let spot = try await model.spotter.spotKeywordsWithLogProbs(
                audioSamples: Array(samples[chunk]), customVocabulary: session.vocabulary, minScore: nil
            )
            chunks.append(spot.logProbs)
            if frameDuration == nil { frameDuration = spot.frameDuration }
        }
        guard let frameDuration else { return nil }
        let logProbs = WordBoostChunks.stitch(chunks, frameDuration: frameDuration)
        var options = SoundAnchorJudge.soundOptions(heard: heard, term: term)
        if let spelled = Self.spelling(of: range, in: words, logProbs: logProbs, model: model),
           SoundAnchorJudge.isPlausibleSound(spelled, heard: heard, term: term) { options.append(spelled) }
        let heardText = words[range].map(\.text).joined(separator: " ")
        guard let window = SoundContrast.window(for: range, in: words, frameDuration: frameDuration, frameCount: logProbs.count) else { return nil }
        var scored: [(String, Float)] = []
        for option in Set(options.map { $0.lowercased() }) {
            if let margin = SoundContrast.margin(logProbs, window: window, heard: heardText, term: option, blank: model.blankID, encode: { model.tokenizer.encode($0) }) {
                scored.append((option, margin))
            }
        }
        scored.sort { $0.1 > $1.1 }
        guard let best = scored.first else { return nil }
        return ExpressLearnedSound(sounds: scored.prefix(SoundAnchorJudge.soundsLearnedPerFix).map(\.0), margin: best.1)
    }

    /// The CTC model's own best path through the recording, lined up with
    /// the speech model's words: how `range` sounded, spelled its way.
    private static func spelling(of range: Range<Int>, in words: [SoundWord], logProbs: [[Float]], model: WordBoostModel) -> String? {
        var pieces: [Int] = []
        var previous = -1
        for row in logProbs {
            guard let best = row.indices.max(by: { row[$0] < row[$1] }) else { continue }
            if best != previous, best != model.blankID { pieces.append(best) }
            previous = best
        }
        let text = pieces.compactMap { model.pieces[$0] }.joined().replacingOccurrences(of: "▁", with: " ").lowercased()
        return SoundContrast.spelling(of: range, in: words, spelled: text.split(separator: " ").map(String.init))
    }

    private static func pieces(in folder: URL) -> [Int: String] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("vocab.json")),
              let table = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        var pieces: [Int: String] = [:]
        for (key, piece) in table { if let id = Int(key) { pieces[id] = piece } }
        return pieces
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
