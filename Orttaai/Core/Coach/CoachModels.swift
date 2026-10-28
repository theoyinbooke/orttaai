// CoachModels.swift
// Orttaai
//
// Coach's two model jobs on the person's own local server (Ollama or LM
// Studio, whichever Orttaai uses): the judge, one yes/no question per call,
// and the coach, who writes the note. A judge is only asked once it has
// passed Coach's judge check; without one, reps are scored on the counted
// checks and the coach's own lines.

import CoachCore
import Foundation
import os

nonisolated struct CoachModelSetup: Sendable, Equatable {
    var provider: LocalLLMProviderKind
    var endpoint: String
    var coachModel: String
    var judgeModel: String
    /// Plays the scene partners; the coach model unless one was picked.
    var partnerModel: String = ""

    var sceneModel: String { partnerModel.isEmpty ? coachModel : partnerModel }
}

nonisolated enum CoachModels {
    /// The model Orttaai's insights already use, as the starting choice.
    static var insightsModel: String {
        let value = UserDefaults.standard.string(forKey: "localLLMInsightsModel")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "gemma4:e2b" : value
    }

    /// The models in use. Unless the person picked them, both jobs go to
    /// the best model that passed the judge check, else the insights model.
    static func current(defaults: UserDefaults = .standard) -> CoachModelSetup {
        let provider = LocalLLMProviderKind(rawValue: defaults.string(forKey: "localLLMProvider") ?? "") ?? .ollama
        let key = provider == .ollama ? "localLLMEndpoint" : "lmStudioEndpoint"
        let endpoint = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let coach = defaults.string(forKey: CoachPreferences.coachModelKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let judge = defaults.string(forKey: CoachPreferences.judgeModelKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let partner = defaults.string(forKey: CoachPreferences.partnerModelKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let automatic = CoachPreferences.bestPassingJudge?.model ?? insightsModel
        return CoachModelSetup(
            provider: provider,
            endpoint: endpoint.isEmpty ? provider.defaultEndpoint : endpoint,
            coachModel: coach.isEmpty ? automatic : coach,
            judgeModel: judge.isEmpty ? automatic : judge,
            partnerModel: partner
        )
    }

    /// The judge passed Coach's check against the current examples.
    static func judgeTrusted(_ setup: CoachModelSetup) -> Bool {
        CoachPreferences.judgeGrade(for: setup.judgeModel)?.passes == true
    }

    /// Grades a model on every calibration example, one question at a time.
    static func grade(
        model: String,
        setup: CoachModelSetup,
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> JudgeGrade {
        let examples = CoachCalibration.examples
        var answers: [(example: CalibrationExample, answer: JudgeAnswer?)] = []
        var timings: [Int] = []
        for (index, example) in examples.enumerated() {
            progress(index, examples.count)
            let start = Date()
            let verdict = await ask(questionText: example.question.question, text: example.text, context: nil, model: model, setup: setup)
            // The first answer also loads the model; it isn't a fair time.
            if verdict != nil, index > 0 { timings.append(Int(Date().timeIntervalSince(start) * 1_000)) }
            answers.append((example, verdict?.answer))
        }
        progress(examples.count, examples.count)
        return CoachCalibration.grade(
            model: model,
            answers: answers,
            msPerAnswer: timings.isEmpty ? nil : timings.reduce(0, +) / timings.count
        )
    }

    /// Models on the server, or nil when it isn't running.
    static func installed(_ setup: CoachModelSetup = current()) async -> [String]? {
        let client = LocalLLM.client(for: setup.provider)
        return try? await client.fetchModelNames(baseURLString: setup.endpoint, timeoutMs: 1_500)
    }

    /// The judge's answer to one question, or nil when it couldn't say or
    /// hasn't passed the judge check.
    static func judge(
        _ question: CoachQuestion,
        text: String,
        context: String?,
        setup: CoachModelSetup
    ) async -> (answer: JudgeAnswer, confidence: Double)? {
        await judge(questionText: question.question, text: text, context: context, setup: setup)
    }

    /// The scene partner's reply, streamed: `onText` gets the reply so far as
    /// it grows. Nil when the model didn't answer.
    static func partnerReply(
        scene: CoachScene,
        turns: [SceneTurn],
        setup: CoachModelSetup,
        onText: @escaping @Sendable (String) -> Void
    ) async -> String? {
        let client = LocalLLM.client(for: setup.provider)
        let messages = CoachPartnerPrompt.chat(scene: scene, turns: turns).map { line in
            OllamaChatMessage(role: OllamaChatRole(rawValue: line.role.rawValue) ?? .user, content: line.content)
        }
        do {
            let reply = try await client.chatStream(
                baseURLString: setup.endpoint,
                model: setup.sceneModel,
                messages: messages,
                timeoutMs: 30_000,
                think: setup.provider.supportsThinkFlag ? false : nil,
                temperature: 0.7,
                numPredict: 160,
                numContext: 8_192,
                keepAlive: "15m",
                onDelta: onText
            )
            // As written, so it stays in step with what streamed in; the
            // session tidies it for the transcript.
            let text = CoachPartnerPrompt.withoutName(reply, partnerName: scene.partnerName)
            return text.isEmpty ? nil : text
        } catch {
            Logger.dictation.info("Coach scene partner didn't answer: \(error.localizedDescription)")
            return nil
        }
    }

    /// How the partner feels after its last line.
    static func partnerMood(scene: CoachScene, turns: [SceneTurn], setup: CoachModelSetup) async -> PartnerMood? {
        let client = LocalLLM.client(for: setup.provider)
        let reply = try? await client.generate(
            baseURLString: setup.endpoint,
            model: setup.sceneModel,
            prompt: CoachPartnerPrompt.moodPrompt(scene: scene, turns: turns),
            timeoutMs: 15_000,
            think: setup.provider.supportsThinkFlag ? false : nil,
            format: "json",
            formatJSONSchema: CoachPartnerPrompt.moodSchema,
            temperature: 0,
            numPredict: 20,
            numContext: 8_192,
            keepAlive: "15m"
        )
        return reply.flatMap(CoachPartnerPrompt.parseMood)
    }

    /// Loads the scene model so its first reply isn't kept waiting.
    static func warmPartner(_ setup: CoachModelSetup) async {
        let client = LocalLLM.client(for: setup.provider)
        _ = try? await client.warmModel(baseURLString: setup.endpoint, model: setup.sceneModel, timeoutMs: 60_000, keepAlive: "15m")
    }

    /// The judge's answer to a question asked in its own words.
    static func judge(questionText: String, text: String, context: String?, setup: CoachModelSetup) async -> (answer: JudgeAnswer, confidence: Double)? {
        guard judgeTrusted(setup) else { return nil }
        return await ask(questionText: questionText, text: text, context: context, model: setup.judgeModel, setup: setup)
    }

    /// Any model's answer, trusted or not: for grading and comparing.
    static func ask(questionText: String, text: String, context: String?, model: String, setup: CoachModelSetup) async -> (answer: JudgeAnswer, confidence: Double)? {
        let client = LocalLLM.client(for: setup.provider)
        do {
            let reply = try await client.generate(
                baseURLString: setup.endpoint,
                model: model,
                prompt: CoachJudgePrompt.prompt(questionText: questionText, text: text, context: context),
                timeoutMs: 60_000,
                think: setup.provider.supportsThinkFlag ? false : nil,
                format: "json",
                formatJSONSchema: CoachJudgePrompt.jsonSchema,
                temperature: 0,
                numPredict: 60,
                numContext: 8_192,
                keepAlive: "10m"
            )
            return CoachJudgePrompt.parse(reply)
        } catch {
            Logger.dictation.info("Coach judge skipped a check: \(error.localizedDescription)")
            return nil
        }
    }

    /// The coach model's note, if it wrote one that keeps to the facts.
    static func note(prompt: String, allowed: Set<String>, setup: CoachModelSetup) async -> String? {
        let client = LocalLLM.client(for: setup.provider)
        do {
            let reply = try await client.generate(
                baseURLString: setup.endpoint,
                model: setup.coachModel,
                prompt: prompt,
                timeoutMs: 25_000,
                think: setup.provider.supportsThinkFlag ? false : nil,
                format: nil,
                formatJSONSchema: nil,
                temperature: 0.6,
                numPredict: 120,
                numContext: 4_096,
                keepAlive: "10m"
            )
            let note = CoachNoteGuard.cleaned(reply)
            return CoachNoteGuard.accepts(note, allowed: allowed) ? note : nil
        } catch {
            Logger.dictation.info("Coach note fell back to the coach's line: \(error.localizedDescription)")
            return nil
        }
    }
}

/// How each installed model does as judge on the same dictations: how often
/// it agrees with the others, and how long an answer takes.
nonisolated struct CoachModelComparison: Sendable, Equatable, Identifiable {
    var model: String
    /// Share of dictations where its answer matched the majority.
    var agreement: Double?
    var msPerAnswer: Int?
    var answered: Int

    var id: String { model }

    static func run(
        models: [String],
        texts: [String],
        question: CoachQuestion,
        setup: CoachModelSetup,
        progress: @Sendable (String) -> Void
    ) async -> [CoachModelComparison] {
        var answers: [String: [JudgeAnswer?]] = [:]
        var timings: [String: [Int]] = [:]
        for model in models {
            progress(model)
            var mine: [JudgeAnswer?] = []
            var setupForModel = setup
            setupForModel.judgeModel = model
            for text in texts {
                let start = Date()
                let verdict = await CoachModels.ask(questionText: question.question, text: text, context: nil, model: model, setup: setupForModel)
                mine.append(verdict?.answer)
                if verdict != nil { timings[model, default: []].append(Int(Date().timeIntervalSince(start) * 1_000)) }
            }
            answers[model] = mine
        }
        let majority: [JudgeAnswer?] = texts.indices.map { index in
            let votes = models.compactMap { answers[$0]?[index] }
            let counts = Dictionary(grouping: votes, by: { $0 }).mapValues(\.count)
            return counts.max { $0.value < $1.value }?.key
        }
        return models.map { model in
            let mine = answers[model] ?? []
            let pairs = zip(mine, majority).compactMap { a, m -> Bool? in
                guard let a, let m else { return nil }
                return a == m
            }
            let times = timings[model] ?? []
            return CoachModelComparison(
                model: model,
                agreement: pairs.isEmpty ? nil : Double(pairs.filter { $0 }.count) / Double(pairs.count),
                msPerAnswer: times.isEmpty ? nil : times.reduce(0, +) / times.count,
                answered: pairs.count
            )
        }
        .sorted { ($0.agreement ?? -1, -($0.msPerAnswer ?? .max)) > ($1.agreement ?? -1, -($1.msPerAnswer ?? .max)) }
    }
}
