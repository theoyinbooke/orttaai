// CoachSceneSession.swift
// Orttaai
//
// A roleplay scene: you speak or type a turn, the partner (the scene model in
// character) answers with a mood, and at the end your turns are scored
// together on the track's checks and whether you reached the goal. Spoken,
// it runs like a conversation: the partner's reply streams in and is spoken
// sentence by sentence, and hands-free your turn starts when the partner
// stops and ends when you pause.

import CoachCore
import Combine
import Foundation
import os

@MainActor
final class CoachSceneSession: ObservableObject {
    enum Phase: Equatable {
        case starting
        case talking
        case recording(started: Date)
        case thinking
        case scoring(String)
        case ended(CoachRepResult)
        case failed(String)
    }

    enum ReplyMode: String, CaseIterable, Identifiable {
        case voice
        case text
        case both

        var id: String { rawValue }

        var title: String {
            switch self {
            case .voice: return "Voice"
            case .text: return "Text"
            case .both: return "Both"
            }
        }

        var speaks: Bool { self != .text }
    }

    let scene: CoachScene
    let skill: CoachSkill
    let persona: CoachPersona

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var turns: [SceneTurn]
    @Published private(set) var mood: PartnerMood = .pushing
    @Published var replyMode: ReplyMode = .both
    @Published var typed = ""
    @Published private(set) var level: Float = 0
    /// The partner's reply while it's still arriving.
    @Published private(set) var liveReply: String?
    @Published private(set) var partnerSpeaking = false
    /// Why the last turn didn't go through, until the next one starts.
    @Published private(set) var notice: String?
    @Published var handsFree = CoachPreferences.handsFree {
        didSet { UserDefaults.standard.set(handsFree, forKey: CoachPreferences.handsFreeKey) }
    }

    private let database: DatabaseManager?
    private var detector = TurnDetector()
    private var splitter = SentenceStream()
    /// Where the reply's sentences go to be spoken while it streams in.
    private var spoken: AsyncStream<String>.Continuation?
    private var cancelled = false
    private var timing: TurnTiming?
    private let usual: Double?
    /// What was actually heard on each of your spoken turns, before Polish.
    private var heard: [UUID: String] = [:]
    private var meter: Task<Void, Never>?

    init(scene: CoachScene, skill: CoachSkill, persona: CoachPersona, database: DatabaseManager?, usual: Double?) {
        self.scene = scene
        self.skill = skill
        self.persona = persona
        self.database = database
        self.usual = usual
        self.turns = [SceneTurn(speaker: .partner, text: scene.opening)]
        Task { await checkReady() }
    }

    var yourTurns: Int { turns.filter { $0.speaker == .you }.count }
    var canEnd: Bool { yourTurns > 0 }

    private func checkReady() async {
        let setup = CoachModels.current()
        guard let installed = await CoachModels.installed(setup) else {
            phase = .failed("Scenes need your local model server. Start Ollama or LM Studio, then try again.")
            return
        }
        guard installed.contains(setup.sceneModel) else {
            phase = .failed("\(setup.sceneModel) isn't installed. Pick a scene partner in Cast › Models.")
            return
        }
        // The speech model loads while the partner talks, so your first turn
        // is heard quickly; the partner and its voice load first, so the
        // opening line is.
        Task { await CoachPracticeSession.recorder?.preparePractice() }
        async let model: Void = CoachModels.warmPartner(setup)
        async let voice: Void = replyMode.speaks ? CoachNaturalVoice.shared.warmUp(scene.partnerName) : ()
        _ = await (model, voice)
        guard !cancelled else { return }
        phase = .talking
        if replyMode.speaks {
            partnerSpeaking = true
            let speech = Task { await CoachVoice.shared.speak(sentences: Self.single(scene.opening), as: scene.partnerName) }
            listenOverPartner()
            await speech.value
            partnerSpeaking = false
        }
        listenIfHandsFree()
    }

    private static func single(_ text: String) -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        continuation.yield(text)
        continuation.finish()
        return stream
    }

    // MARK: Your turn

    /// Hands-free, the microphone opens as soon as the partner stops.
    private func listenIfHandsFree() {
        guard handsFree, replyMode != .text, phase == .talking, !cancelled else { return }
        startRecording()
    }

    /// With headphones on, the microphone opens while the partner is still
    /// speaking, so you can cut in just by talking. On speakers it would hear
    /// the partner, so it waits for them to stop.
    private func listenOverPartner() {
        guard handsFree, partnerSpeaking, replyMode != .text, phase == .talking, !cancelled, AudioOutputRoute.isPrivate else { return }
        startRecording(overPartner: true)
    }

    /// Stops the partner mid-sentence and gives you the turn.
    func cutIn() {
        if partnerSpeaking {
            CoachVoice.shared.stop()
            partnerSpeaking = false
        }
        if phase == .talking { startRecording() }
    }

    /// Starts your turn. Over the partner, it listens without stopping them.
    func startRecording(overPartner: Bool = false) {
        guard phase == .talking, let recorder = CoachPracticeSession.recorder else { return }
        if !overPartner {
            CoachVoice.shared.stop()
            partnerSpeaking = false
        }
        notice = nil
        do {
            try recorder.startPracticeRecording()
            let started = Date()
            phase = .recording(started: started)
            detector = TurnDetector()
            // The time limit counts from when the partner stops.
            var limitFrom = 0.0
            meter = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(80))
                    guard let self, case .recording = self.phase else { return }
                    let level = recorder.practiceLevel()
                    self.level = level
                    let elapsed = Date().timeIntervalSince(started)
                    if self.partnerSpeaking {
                        self.detector.restartPatience(at: elapsed)
                        limitFrom = elapsed
                    }
                    if self.handsFree {
                        switch self.detector.feed(level: level, at: elapsed) {
                        case .started where self.partnerSpeaking:
                            // You started talking: the partner gives way.
                            CoachVoice.shared.stop()
                            self.partnerSpeaking = false
                        case .ended:
                            // Its own task: finishing cancels this one, and
                            // would cancel the transcription with it.
                            Task { await self.finishRecording() }
                            return
                        case .gaveUp:
                            // Nobody spoke: close the microphone and wait for a tap.
                            recorder.cancelPracticeRecording()
                            self.level = 0
                            self.phase = .talking
                            return
                        case .none, .started:
                            break
                        }
                    }
                    if elapsed - limitFrom >= Double(CoachRepKind.scene.timeLimitSeconds) {
                        Task { await self.finishRecording() }
                        return
                    }
                }
            }
        } catch {
            phase = .failed(CoachPracticeSession.message(for: error))
        }
    }

    func finishRecording() async {
        guard case .recording = phase, let recorder = CoachPracticeSession.recorder else { return }
        meter?.cancel()
        level = 0
        phase = .thinking
        timing = TurnTiming()
        do {
            // The partner answers what you said; Polish would only slow it down.
            // The quiet before you spoke (a little margin kept) isn't your turn.
            let skip = max(0, (detector.speechStartedAt ?? 0) - 0.4)
            let result = try await recorder.finishPracticeRecording(polish: false, skippingFirst: skip)
            timing?.mark(\.heard)
            let turn = SceneTurn(speaker: .you, text: result.polished, durationMs: result.durationMs)
            heard[turn.id] = result.raw
            turns.append(turn)
            await partnerTurn()
        } catch {
            phase = .talking
            if case OrttaaiError.transcriptionFailed(let underlying) = error, underlying is CoachPracticeError {
                listenIfHandsFree()
                return
            }
            // Say so, and wait: listening again would only fail the same way.
            notice = "That turn didn't go through: \(CoachPracticeSession.message(for: error))"
            Logger.dictation.error("Coach scene turn failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func sendTyped() async {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .talking, !text.isEmpty else { return }
        typed = ""
        turns.append(SceneTurn(speaker: .you, text: text))
        phase = .thinking
        timing = TurnTiming()
        timing?.mark(\.heard)
        await partnerTurn()
    }

    private func partnerTurn() async {
        if yourTurns >= CoachScene.maxTurns {
            await end()
            return
        }
        let setup = CoachModels.current()
        let speaks = replyMode.speaks
        let (sentences, continuation) = AsyncStream<String>.makeStream()
        splitter = SentenceStream()
        spoken = speaks ? continuation : nil
        liveReply = ""
        partnerSpeaking = speaks
        let speech: Task<Void, Never>? = speaks
            ? Task { [weak self] in
                await CoachVoice.shared.speak(sentences: sentences, as: self?.scene.partnerName) { self?.timing?.mark(\.firstSound) }
            }
            : nil
        let name = scene.partnerName
        let reply = await CoachModels.partnerReply(scene: scene, turns: turns, setup: setup) { text in
            Task { @MainActor [weak self] in
                self?.received(CoachPartnerPrompt.withoutName(text, partnerName: name))
            }
        }
        timing?.mark(\.replyDone)
        if let reply {
            received(reply)
            if let rest = splitter.finish(reply) { say(rest) }
            turns.append(SceneTurn(speaker: .partner, text: CoachPartnerPrompt.cleaned(reply, partnerName: name)))
            let sofar = turns
            Task { [weak self] in
                guard let self, let mood = await CoachModels.partnerMood(scene: self.scene, turns: sofar, setup: setup) else { return }
                self.mood = mood
            }
        }
        continuation.finish()
        spoken = nil
        liveReply = nil
        phase = .talking
        if reply != nil { listenOverPartner() }
        await speech?.value
        partnerSpeaking = false
        if let timing {
            Logger.dictation.info("Coach scene turn with \(setup.sceneModel, privacy: .public): \(timing.summary, privacy: .public)")
            self.timing = nil
        }
        if reply != nil { listenIfHandsFree() }
    }

    /// The reply so far: shown as it grows, and each finished sentence spoken.
    private func received(_ text: String) {
        guard let live = liveReply, text.count > live.count else { return }
        timing?.mark(\.firstWord)
        liveReply = text
        for sentence in splitter.feed(text) { say(sentence) }
    }

    private func say(_ sentence: String) {
        let text = CoachPartnerPrompt.spoken(sentence)
        guard !text.isEmpty else { return }
        timing?.mark(\.firstSentence)
        spoken?.yield(text)
    }

    // MARK: The end

    func end() async {
        guard canEnd else { return }
        cancelled = true
        meter?.cancel()
        if case .recording = phase { CoachPracticeSession.recorder?.cancelPracticeRecording() }
        CoachVoice.shared.stop()
        phase = .scoring("Reading the scene back…")

        let yours = turns.filter { $0.speaker == .you }
        let written = yours.map(\.text).joined(separator: "\n")
        let said = yours.map { heard[$0.id] ?? $0.text }.joined(separator: "\n")
        let spokenMs = yours.allSatisfy { $0.durationMs != nil } ? yours.reduce(0) { $0 + ($1.durationMs ?? 0) } : 0
        let measures = DictationMeasures(measuring: CoachDictation(
            createdAt: Date(), heard: said, written: written, recordingMs: spokenMs, rawKnown: true
        ))
        let transcript = turns.map { "\($0.speaker == .you ? "Speaker" : scene.partnerName): \($0.text)" }.joined(separator: "\n")
        let setup = CoachModels.current()

        var results: [CheckResult] = []
        for check in scene.track.checks {
            switch check {
            case .counted(let count):
                results.append(.counted(count, measures))
            case .judged(let question):
                phase = .scoring("Checking: \(question.label.lowercased())…")
                let verdict = await CoachModels.judge(question, text: written, context: "In a conversation: \(scene.goal)", setup: setup)
                results.append(CheckResult(check: check, answer: verdict?.answer, confidence: verdict?.confidence))
            case .goal:
                break
            }
        }
        phase = .scoring("Checking the goal…")
        let goal = await CoachModels.judge(questionText: scene.goalQuestion, text: transcript, context: "\(scene.partnerName), \(scene.partnerRole.lowercased())", setup: setup)
        results.append(CheckResult(check: .goal(scene.id), answer: goal?.answer, confidence: goal?.confidence))

        let score = CoachScore.score(results)
        let skillMet = results.first { $0.check == skill.check }?.answer.map { $0 == .yes }
        let goalMet = goal.map { $0.answer == .yes }
        let missing = results.first { $0.answer == .no }?.check.label
        var numbers: [Double] = [Double(yours.count), Double(measures.words)]
        var facts = ["\(yours.count) turns", "\(measures.words) words", "goal reached: \(goalMet == true ? "yes" : goalMet == false ? "no" : "not known")"]
        if let score { facts.append("score \(String(format: "%.1f", score))"); numbers.append(score) }
        phase = .scoring("Your coach is writing…")
        let fallback = persona.line(skill: scene.goal, met: goalMet, missing: missing)
        let note = await CoachModels.note(
            prompt: persona.notePrompt(skill: skill, results: results, facts: facts, score: score),
            allowed: CoachNoteGuard.allowedNumbers(from: numbers),
            setup: setup
        ) ?? fallback

        let plan = CoachRepPlan(skill: skill, kind: .scene, spoken: spokenMs > 0, instruction: scene.goal, source: nil, persona: persona)
        let result = CoachRepResult(
            plan: plan,
            text: written,
            measures: measures,
            checks: results,
            score: score,
            usual: usual,
            skillMet: skillMet,
            note: note,
            judgeModel: CoachModels.judgeTrusted(setup) ? setup.judgeModel : nil,
            figures: CoachPracticeSession.figures(measures, usual: nil, spoken: spokenMs > 0),
            durationMs: spokenMs
        )
        save(result)
        phase = .ended(result)
        if CoachPreferences.readsAloud { CoachVoice.shared.speak(note) }
    }

    private func save(_ result: CoachRepResult) {
        guard let database else { return }
        let checks = (try? String(data: JSONEncoder().encode(result.checks), encoding: .utf8)) ?? "[]"
        let rep = CoachRepRecord(
            id: nil, skillID: skill.id, kind: CoachRepKind.scene.rawValue, spoken: result.durationMs > 0,
            createdAt: Date(), score: result.score, skillMet: result.skillMet, durationMs: result.durationMs,
            words: result.measures.words, checks: checks, persona: persona.rawValue
        )
        do {
            try database.saveCoachRep(rep)
        } catch {
            Logger.database.error("Coach couldn't save a scene: \(error.localizedDescription)")
        }
        Task { await CoachCenter.shared.refresh() }
    }

    func cancel() {
        cancelled = true
        CoachVoice.shared.stop()
        meter?.cancel()
        if case .recording = phase { CoachPracticeSession.recorder?.cancelPracticeRecording() }
        level = 0
    }
}

/// How long each step of a partner's turn took, counted from the end of
/// yours, for the log.
struct TurnTiming {
    private let start = Date()
    var heard: TimeInterval?
    var firstWord: TimeInterval?
    var firstSentence: TimeInterval?
    var firstSound: TimeInterval?
    var replyDone: TimeInterval?

    /// Records a step the first time it happens.
    mutating func mark(_ step: WritableKeyPath<TurnTiming, TimeInterval?>) {
        if self[keyPath: step] == nil { self[keyPath: step] = Date().timeIntervalSince(start) }
    }

    var summary: String {
        [("heard", heard), ("first word", firstWord), ("first sentence", firstSentence), ("first sound", firstSound), ("reply done", replyDone)]
            .map { "\($0.0) \($0.1.map { String(format: "%.2f s", $0) } ?? "–")" }
            .joined(separator: ", ")
    }
}
