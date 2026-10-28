// CoachPractice.swift
// Orttaai
//
// A practice rep from start to reveal: what to do, recording or typing it,
// scoring it on the track's checks (counted, and judged by the local model
// one question at a time), the coach's note, and saving the numbers.

import AVFoundation
import CoachCore
import Combine
import Foundation
import os

/// A rep, ready to do.
struct CoachRepPlan: Identifiable, Equatable {
    let id = UUID()
    var skill: CoachSkill
    var kind: CoachRepKind
    var spoken: Bool
    /// What to do, in a sentence.
    var instruction: String
    /// For a redo: the dictation to say again.
    var source: CoachQuote?
    var persona: CoachPersona
}

/// One counted figure on the reveal, beside your usual.
nonisolated struct CoachRepFigure: Equatable, Identifiable {
    var label: String
    var value: String
    var usual: String?
    /// True when the rep did better than usual, false worse, nil level.
    var better: Bool?

    var id: String { label }
}

struct CoachRepResult: Equatable {
    var plan: CoachRepPlan
    /// What the attempt said, after Polish. Shown, never stored.
    var text: String
    var measures: DictationMeasures
    var checks: [CheckResult]
    var score: Double?
    var usual: Double?
    var skillMet: Bool?
    var note: String
    /// The model that judged, nil when only counted checks ran.
    var judgeModel: String?
    var figures: [CoachRepFigure]
    var durationMs: Int
}

/// Progress on one skill, from its reps.
nonisolated struct CoachSkillProgress: Sendable, Equatable {
    var reps: Int
    /// Reps at 4 or more with the skill's own check met.
    var strongReps: Int
    var lastAt: Date?
    /// The average of the last five scores.
    var usual: Double?

    var mastered: Bool { strongReps >= CoachScore.repsToMaster }

    func reviewDue(now: Date) -> Bool {
        guard mastered, let lastAt else { return false }
        return now.timeIntervalSince(lastAt) > 7 * 86_400
    }

    static func make(_ reps: [CoachRepRecord]) -> CoachSkillProgress {
        let scores = reps.compactMap(\.score)
        let recent = scores.suffix(5)
        return CoachSkillProgress(
            reps: reps.count,
            strongReps: reps.filter { ($0.score ?? 0) >= CoachScore.masteryScore && $0.skillMet == true }.count,
            lastAt: reps.last?.createdAt,
            usual: recent.isEmpty ? nil : recent.reduce(0, +) / Double(recent.count)
        )
    }
}

@MainActor
final class CoachPracticeSession: ObservableObject {
    /// Set at launch: practice records on dictation's own microphone.
    static weak var recorder: DictationCoordinator?

    enum Phase: Equatable {
        case ready
        case recording(started: Date)
        case scoring(String)
        case revealed(CoachRepResult)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .ready
    @Published private(set) var plan: CoachRepPlan
    @Published var spoken: Bool
    @Published var typed = ""
    @Published private(set) var level: Float = 0
    @Published private(set) var elapsed: TimeInterval = 0

    private let database: DatabaseManager?
    private let progress: CoachSkillProgress?
    private let usualSummary: CoachSummary?
    private var meter: Task<Void, Never>?

    init(plan: CoachRepPlan, database: DatabaseManager?, progress: CoachSkillProgress?, usualSummary: CoachSummary?) {
        self.plan = plan
        self.spoken = plan.spoken || plan.skill.speakOnly
        self.database = database
        self.progress = progress
        self.usualSummary = usualSummary
    }

    var canType: Bool { !plan.skill.speakOnly }

    // MARK: Doing it

    func startRecording() {
        guard let recorder = Self.recorder else {
            phase = .failed("Dictation isn't ready yet. Try again in a moment.")
            return
        }
        do {
            try recorder.startPracticeRecording()
            let started = Date()
            phase = .recording(started: started)
            elapsed = 0
            meter = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(80))
                    guard let self, case .recording(let started) = self.phase else { return }
                    self.level = recorder.practiceLevel()
                    self.elapsed = Date().timeIntervalSince(started)
                    if self.elapsed >= Double(self.plan.kind.timeLimitSeconds) {
                        // Its own task: finishing cancels this one.
                        Task { await self.finishRecording() }
                        return
                    }
                }
            }
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    func finishRecording() async {
        guard case .recording = phase, let recorder = Self.recorder else { return }
        meter?.cancel()
        level = 0
        phase = .scoring("Listening back…")
        do {
            let heard = try await recorder.finishPracticeRecording()
            await score(heard: heard.raw, written: heard.polished, durationMs: heard.durationMs, spoken: true)
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    func submitTyped() async {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await score(heard: text, written: text, durationMs: 0, spoken: false)
    }

    /// The same rep again, from the start.
    func again() {
        cancel()
        typed = ""
        phase = .ready
    }

    func cancel() {
        meter?.cancel()
        if case .recording = phase { Self.recorder?.cancelPracticeRecording() }
        level = 0
    }

    // MARK: Scoring

    private func score(heard: String, written: String, durationMs: Int, spoken: Bool) async {
        let measures = DictationMeasures(measuring: CoachDictation(
            createdAt: Date(), heard: heard, written: written, recordingMs: spoken ? durationMs : 0, rawKnown: true
        ))
        guard measures.words >= 3 else {
            phase = .failed("That was too short to score. Try a few sentences.")
            return
        }
        let plan = self.plan
        let setup = CoachModels.current()
        // Judged checks only with a judge that passed the judge check.
        let judgeAvailable = plan.skill.checks.contains { if case .judged = $0 { return true } else { return false } }
            && CoachModels.judgeTrusted(setup)
            ? await CoachModels.installed(setup)?.contains(setup.judgeModel) == true
            : false

        var results: [CheckResult] = []
        for check in plan.skill.checks {
            switch check {
            case .counted(let count):
                results.append(.counted(count, measures))
            case .judged(let question):
                guard judgeAvailable else {
                    results.append(CheckResult(check: check, answer: nil))
                    continue
                }
                phase = .scoring("Checking: \(question.label.lowercased())…")
                let verdict = await CoachModels.judge(question, text: written, context: plan.instruction, setup: setup)
                results.append(CheckResult(check: check, answer: verdict?.answer, confidence: verdict?.confidence))
            case .goal:
                // Only scenes have a goal.
                continue
            }
        }
        let score = CoachScore.score(results)
        let skillResult = results.first { $0.check == plan.skill.check }
        let skillMet = skillResult?.answer.map { $0 == .yes }
        let missing = results.first { $0.check != plan.skill.check && $0.answer == .no }?.check.label

        // The coach's note: the model's if it keeps to the facts, else the coach's own line.
        let figures = Self.figures(measures, usual: usualSummary, spoken: spoken)
        var facts: [String] = []
        var numbers: [Double] = []
        if let score { facts.append("score \(String(format: "%.1f", score))"); numbers.append(score) }
        if let usual = progress?.usual { facts.append("usual score for this skill \(String(format: "%.1f", usual))"); numbers.append(usual) }
        facts.append("\(measures.words) words"); numbers.append(Double(measures.words))
        if let wpm = measures.wpm { facts.append("\(wpm) words a minute"); numbers.append(Double(wpm)) }
        facts.append("\(measures.umUh) um or uh"); numbers.append(Double(measures.umUh))
        phase = .scoring("Your coach is writing…")
        let fallback = plan.persona.line(skill: plan.skill.title, met: skillMet, missing: missing)
        var note = fallback
        let coachAvailable: Bool
        if judgeAvailable {
            coachAvailable = true
        } else {
            coachAvailable = await CoachModels.installed(setup)?.isEmpty == false
        }
        if coachAvailable {
            let prompt = plan.persona.notePrompt(skill: plan.skill, results: results, facts: facts, score: score)
            note = await CoachModels.note(prompt: prompt, allowed: CoachNoteGuard.allowedNumbers(from: numbers), setup: setup) ?? fallback
        }

        let result = CoachRepResult(
            plan: plan,
            text: written,
            measures: measures,
            checks: results,
            score: score,
            usual: progress?.usual,
            skillMet: skillMet,
            note: note,
            judgeModel: judgeAvailable ? setup.judgeModel : nil,
            figures: figures,
            durationMs: durationMs
        )
        save(result)
        phase = .revealed(result)
        if CoachPreferences.readsAloud { CoachVoice.shared.speak(note) }
    }

    private func save(_ result: CoachRepResult) {
        guard let database else { return }
        let checks = (try? String(data: JSONEncoder().encode(result.checks), encoding: .utf8)) ?? "[]"
        let rep = CoachRepRecord(
            id: nil,
            skillID: result.plan.skill.id,
            kind: result.plan.kind.rawValue,
            spoken: result.durationMs > 0,
            createdAt: Date(),
            score: result.score,
            skillMet: result.skillMet,
            durationMs: result.durationMs,
            words: result.measures.words,
            checks: checks,
            persona: result.plan.persona.rawValue
        )
        do {
            try database.saveCoachRep(rep)
        } catch {
            Logger.database.error("Coach couldn't save a rep: \(error.localizedDescription)")
        }
        Task { await CoachCenter.shared.refresh() }
    }

    nonisolated static func figures(_ m: DictationMeasures, usual: CoachSummary?, spoken: Bool) -> [CoachRepFigure] {
        var figures: [CoachRepFigure] = []
        let rate = m.words == 0 ? 0 : Double(m.umUh) / Double(m.words) * 100
        if spoken {
            let usualRate = usual.flatMap { $0.rawDictations > 0 ? $0.umUhRate : nil }
            figures.append(CoachRepFigure(label: "Ums and uhs", value: String(format: "%.1f", rate), usual: usualRate.map { String(format: "%.1f", $0) }, better: usualRate.map { rate < $0 ? true : rate > $0 ? false : nil } ?? nil))
            if let wpm = m.wpm {
                let usualPace = usual?.pace
                figures.append(CoachRepFigure(label: "Pace", value: "\(wpm)", usual: usualPace.map(String.init), better: nil))
            }
        }
        if let longest = m.longestSentence {
            let usualMedian = usual?.medianSentence
            figures.append(CoachRepFigure(label: "Longest sentence", value: "\(longest)", usual: usualMedian.map { "\($0) typical" }, better: nil))
        }
        figures.append(CoachRepFigure(label: "Words", value: "\(m.words)", usual: nil, better: nil))
        return figures
    }

    static func message(for error: Error) -> String {
        if case OrttaaiError.transcriptionFailed(let underlying) = error, let practice = underlying as? CoachPracticeError {
            return practice.errorDescription ?? "Something went wrong."
        }
        return error.localizedDescription
    }
}

/// Speaks Coach's words on this Mac: a partner's natural voice when it has
/// one, else the Mac's own.
@MainActor
final class CoachVoice {
    static let shared = CoachVoice()
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var speaking: Task<Void, Never>?

    var isSpeaking: Bool { speaking != nil }

    /// Says it in the speaker's own natural voice when there is one and it's
    /// installed, else in the Mac's own voice.
    func speak(_ text: String, as speaker: String? = nil) {
        stop()
        let (sentences, continuation) = AsyncStream<String>.makeStream()
        continuation.yield(text)
        continuation.finish()
        speaking = Task { [weak self] in
            guard let self else { return }
            await self.say(sentences, as: speaker)
        }
    }

    /// Speaks sentences as they arrive, making each one's audio while the one
    /// before plays, and returns once the last has been heard or `stop()` is
    /// called.
    func speak(sentences: AsyncStream<String>, as speaker: String?) async {
        stop()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.say(sentences, as: speaker)
        }
        speaking = task
        await task.value
    }

    func stop() {
        speaking?.cancel()
        speaking = nil
        player?.stop()
        player = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func say(_ sentences: AsyncStream<String>, as speaker: String?) async {
        defer { if !Task.isCancelled { speaking = nil } }
        let natural = speaker.map { CoachNaturalVoice.shared.canSpeak(as: $0) } ?? false
        var playing: Task<Void, Never>?
        for await sentence in sentences {
            guard !Task.isCancelled else { break }
            if natural, let speaker {
                let audio = await CoachNaturalVoice.shared.speech(sentence, as: speaker)
                await playing?.value
                guard !Task.isCancelled else { break }
                if let audio, let next = try? AVAudioPlayer(data: audio) {
                    player = next
                    next.play()
                    playing = Task { await Self.waitUntilDone { next.isPlaying } }
                    continue
                }
            }
            await playing?.value
            guard !Task.isCancelled else { break }
            speakWithMacVoice(sentence)
            let synthesizer = self.synthesizer
            playing = Task { await Self.waitUntilDone { synthesizer.isSpeaking } }
        }
        await playing?.value
    }

    private static func waitUntilDone(_ busy: @escaping () -> Bool) async {
        // Give playback a moment to start before asking whether it's over.
        try? await Task.sleep(for: .milliseconds(60))
        while busy(), !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    private func speakWithMacVoice(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        synthesizer.speak(utterance)
    }
}

/// Picks what to practise and sets it up.
nonisolated enum CoachRepPlanner {
    /// A dictation of yours to say again: recent, in the track's way of
    /// talking, long enough to improve, and for Delivery one that missed.
    static func redoSource(
        skill: CoachSkill,
        inputs: [CoachInput],
        overrides: [String: CoachAppRule],
        avoiding: Set<Int64> = [],
        now: Date = Date()
    ) -> Int64? {
        let since = now.addingTimeInterval(-21 * 86_400)
        let candidates = inputs.reversed().filter { input in
            guard input.createdAt >= since, !avoiding.contains(input.id),
                  (15...140).contains(input.measures.words),
                  let mode = CoachAppCatalog.mode(bundleID: input.bundleID, appName: input.appName, overrides: overrides) else { return false }
            if let wanted = skill.track.mode, mode != wanted { return false }
            if let measure = skill.measure, measure.isHit(input.measures) != false { return false }
            return true
        }
        return candidates.prefix(12).randomElement()?.id
    }

    static func instruction(skill: CoachSkill, kind: CoachRepKind, hasSource: Bool) -> String {
        switch kind {
        case .redo where hasSource:
            switch skill.track {
            case .prompting: return "Say it again so the agent knows exactly what to do. \(skill.drill)"
            case .messages: return "Say it again so they can answer at a glance. \(skill.drill)"
            case .delivery, .explaining: return "Say it again, better. \(skill.drill)"
            }
        case .redo, .drill:
            return "\(skill.track.openBrief) \(skill.drill)"
        case .timed:
            return "\(skill.track.openBrief) You have a minute. \(skill.drill)"
        case .scene:
            return skill.drill
        }
    }
}
