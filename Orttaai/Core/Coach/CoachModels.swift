// CoachModels.swift
// Orttaai
//
// Coach's two model jobs on the person's own local server (Ollama or LM
// Studio, whichever Orttaai uses): the judge, one yes/no question per call,
// and the coach, who writes the note. Without either, reps are scored on
// the counted checks and the coach's own lines.

import CoachCore
import Foundation
import os

nonisolated struct CoachModelSetup: Sendable, Equatable {
    var provider: LocalLLMProviderKind
    var endpoint: String
    var coachModel: String
    var judgeModel: String
}

nonisolated enum CoachModels {
    /// The model Orttaai's insights already use, as the starting choice.
    static var insightsModel: String {
        let value = UserDefaults.standard.string(forKey: "localLLMInsightsModel")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "gemma4:e2b" : value
    }

    static func current(defaults: UserDefaults = .standard) -> CoachModelSetup {
        let provider = LocalLLMProviderKind(rawValue: defaults.string(forKey: "localLLMProvider") ?? "") ?? .ollama
        let key = provider == .ollama ? "localLLMEndpoint" : "lmStudioEndpoint"
        let endpoint = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let coach = defaults.string(forKey: CoachPreferences.coachModelKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let judge = defaults.string(forKey: CoachPreferences.judgeModelKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let coachModel = coach.isEmpty ? insightsModel : coach
        return CoachModelSetup(
            provider: provider,
            endpoint: endpoint.isEmpty ? provider.defaultEndpoint : endpoint,
            coachModel: coachModel,
            judgeModel: judge.isEmpty ? coachModel : judge
        )
    }

    /// Models on the server, or nil when it isn't running.
    static func installed(_ setup: CoachModelSetup = current()) async -> [String]? {
        let client = LocalLLM.client(for: setup.provider)
        return try? await client.fetchModelNames(baseURLString: setup.endpoint, timeoutMs: 1_500)
    }

    /// The judge's answer to one question, or nil when it couldn't say.
    static func judge(
        _ question: CoachQuestion,
        text: String,
        context: String?,
        setup: CoachModelSetup
    ) async -> (answer: JudgeAnswer, confidence: Double)? {
        let client = LocalLLM.client(for: setup.provider)
        do {
            let reply = try await client.generate(
                baseURLString: setup.endpoint,
                model: setup.judgeModel,
                prompt: CoachJudgePrompt.prompt(question: question, text: text, context: context),
                timeoutMs: 20_000,
                think: setup.provider.supportsThinkFlag ? false : nil,
                format: "json",
                formatJSONSchema: CoachJudgePrompt.jsonSchema,
                temperature: 0,
                numPredict: 60,
                numContext: 4_096,
                keepAlive: "10m"
            )
            return CoachJudgePrompt.parse(reply)
        } catch {
            Logger.dictation.info("Coach judge skipped a check: \(error.localizedDescription)")
            return nil
        }
    }

    /// The scene partner's next line and mood, played by the coach model.
    static func partner(prompt: String, setup: CoachModelSetup) async -> (reply: String, mood: PartnerMood)? {
        let client = LocalLLM.client(for: setup.provider)
        do {
            let reply = try await client.generate(
                baseURLString: setup.endpoint,
                model: setup.coachModel,
                prompt: prompt,
                timeoutMs: 30_000,
                think: setup.provider.supportsThinkFlag ? false : nil,
                format: "json",
                formatJSONSchema: CoachPartnerPrompt.jsonSchema,
                temperature: 0.7,
                numPredict: 160,
                numContext: 8_192,
                keepAlive: "10m"
            )
            return CoachPartnerPrompt.parse(reply)
        } catch {
            Logger.dictation.info("Coach scene partner didn't answer: \(error.localizedDescription)")
            return nil
        }
    }

    /// The judge's answer to a question asked in its own words.
    static func judge(questionText: String, text: String, context: String?, setup: CoachModelSetup) async -> (answer: JudgeAnswer, confidence: Double)? {
        let client = LocalLLM.client(for: setup.provider)
        do {
            let reply = try await client.generate(
                baseURLString: setup.endpoint,
                model: setup.judgeModel,
                prompt: CoachJudgePrompt.prompt(questionText: questionText, text: text, context: context),
                timeoutMs: 20_000,
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
                let verdict = await CoachModels.judge(question, text: text, context: nil, setup: setupForModel)
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
