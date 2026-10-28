// CoachSceneSession.swift
// Orttaai
//
// A roleplay scene: you speak or type a turn, the partner (the coach model
// in character) answers with a mood, and at the end your turns are scored
// together on the track's checks and whether you reached the goal.

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

    private let database: DatabaseManager?
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
        guard installed.contains(setup.coachModel) else {
            phase = .failed("\(setup.coachModel) isn't installed. Pick a coach model in Cast › Models.")
            return
        }
        phase = .talking
        if replyMode.speaks { CoachVoice.shared.speak(scene.opening) }
    }

    // MARK: Your turn

    func startRecording() {
        guard phase == .talking, let recorder = CoachPracticeSession.recorder else { return }
        CoachVoice.shared.stop()
        do {
            try recorder.startPracticeRecording()
            phase = .recording(started: Date())
            meter = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(80))
                    guard let self, case .recording(let started) = self.phase else { return }
                    self.level = recorder.practiceLevel()
                    if Date().timeIntervalSince(started) >= Double(CoachRepKind.scene.timeLimitSeconds) {
                        await self.finishRecording()
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
        do {
            let result = try await recorder.finishPracticeRecording()
            let turn = SceneTurn(speaker: .you, text: result.polished, durationMs: result.durationMs)
            heard[turn.id] = result.raw
            turns.append(turn)
            await partnerTurn()
        } catch {
            phase = .talking
            if case OrttaaiError.transcriptionFailed(let underlying) = error, underlying is CoachPracticeError {
                return
            }
            Logger.dictation.error("Coach scene turn failed: \(error.localizedDescription)")
        }
    }

    func sendTyped() async {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .talking, !text.isEmpty else { return }
        typed = ""
        turns.append(SceneTurn(speaker: .you, text: text))
        phase = .thinking
        await partnerTurn()
    }

    private func partnerTurn() async {
        if yourTurns >= CoachScene.maxTurns {
            await end()
            return
        }
        let setup = CoachModels.current()
        if let next = await CoachModels.partner(prompt: CoachPartnerPrompt.prompt(scene: scene, turns: turns), setup: setup) {
            mood = next.mood
            turns.append(SceneTurn(speaker: .partner, text: next.reply))
            if replyMode.speaks { CoachVoice.shared.speak(next.reply) }
        }
        phase = .talking
    }

    // MARK: The end

    func end() async {
        guard canEnd else { return }
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
            judgeModel: setup.judgeModel,
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
        meter?.cancel()
        if case .recording = phase { CoachPracticeSession.recorder?.cancelPracticeRecording() }
        level = 0
    }
}
