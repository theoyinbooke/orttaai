// ToneOfVoiceService.swift
// Orttaai

import Foundation
import os

final class ToneOfVoiceService {
    private let settings: AppSettings
    private let ollamaClient: OllamaClient

    init(settings: AppSettings = AppSettings(), ollamaClient: OllamaClient = OllamaClient()) {
        self.settings = settings
        self.ollamaClient = ollamaClient
    }

    func analyze(transcriptions: [Transcription], model: String) async -> ToneOfVoiceAnalysisResult? {
        let samples = transcriptions
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !samples.isEmpty else { return nil }

        var profile = makeHeuristicProfile(samples: samples, model: model)
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty else {
            return ToneOfVoiceAnalysisResult(profile: profile, usedOllama: false, errorMessage: nil)
        }

        do {
            let response = try await ollamaClient.generate(
                baseURLString: settings.normalizedLocalLLMEndpoint,
                model: normalizedModel,
                prompt: ollamaPrompt(samples: samples, fallbackProfile: profile),
                timeoutMs: nil,
                think: settings.localLLMInsightsThinkingEnabled,
                format: nil,
                temperature: 0.12,
                numPredict: 8_000,
                numContext: settings.clampedLocalLLMInsightsContextTokens
            )

            if let aiProfile = decodeAIProfile(from: response, fallback: profile, model: normalizedModel) {
                profile = aiProfile
            }

            return ToneOfVoiceAnalysisResult(profile: profile, usedOllama: true, errorMessage: nil)
        } catch {
            Logger.ai.error("Tone of voice Ollama analysis failed: \(error.localizedDescription)")
            return ToneOfVoiceAnalysisResult(
                profile: profile,
                usedOllama: false,
                errorMessage: "Ollama could not complete tone analysis, so Orttaai used local metrics."
            )
        }
    }

    private func makeHeuristicProfile(samples: [String], model: String) -> ToneOfVoiceProfile {
        let combinedText = samples.joined(separator: "\n\n")
        let words = words(in: combinedText)
        let sentences = sentences(in: combinedText)
        let lowerText = " \(combinedText.lowercased()) "
        let uniqueWordRatio = Double(Set(words).count) / Double(max(1, words.count))
        let averageWordLength = words.reduce(0) { $0 + $1.count }.nonZeroAverage(count: words.count)
        let averageSentenceLength = Double(words.count) / Double(max(1, sentences.count))
        let contractionRate = rate(matches: contractionMarkers, in: lowerText, denominator: words.count)
        let hedgeRate = rate(matches: hedgeMarkers, in: lowerText, denominator: sentences.count)
        let warmRate = rate(matches: warmMarkers, in: lowerText, denominator: sentences.count)
        let inclusiveRate = rate(matches: inclusiveMarkers, in: lowerText, denominator: words.count)
        let questionRate = punctuationRate("?", in: combinedText, denominator: sentences.count)
        let exclamationRate = punctuationRate("!", in: combinedText, denominator: sentences.count)

        let formality = clamp01(0.62 - contractionRate * 4 + (averageWordLength - 4.2) * 0.12)
        let warmth = clamp01(0.38 + warmRate * 2.2 + inclusiveRate * 6)
        let directness = clamp01(0.74 - hedgeRate * 1.8 + min(0.16, averageSentenceLength / 180))
        let enthusiasm = clamp01(0.32 + exclamationRate * 1.8 + warmRate)
        let complexity = clamp01(0.28 + uniqueWordRatio * 0.7 + (averageSentenceLength - 10) / 42 + (averageWordLength - 4) / 10)
        let conversational = clamp01(0.5 + contractionRate * 5 + questionRate * 0.7 - formality * 0.2)

        let descriptors = descriptors(
            formality: formality,
            warmth: warmth,
            directness: directness,
            enthusiasm: enthusiasm,
            complexity: complexity,
            conversational: conversational
        )
        let phrases = signaturePhrases(from: samples)
        let metrics = [
            metric("Formality", formality, low: "Casual", mid: "Balanced", high: "Formal", detail: "Based on contractions, word choice, and sentence shape."),
            metric("Warmth", warmth, low: "Reserved", mid: "Neutral", high: "Warm", detail: "Based on appreciation, inclusive language, and positive markers."),
            metric("Directness", directness, low: "Diplomatic", mid: "Balanced", high: "Direct", detail: "Based on hedging, sentence focus, and assertive phrasing."),
            metric("Enthusiasm", enthusiasm, low: "Measured", mid: "Moderate", high: "Energetic", detail: "Based on punctuation and energetic language."),
            metric("Complexity", complexity, low: "Simple", mid: "Clear", high: "Layered", detail: "Based on vocabulary variety and average sentence length."),
            metric("Conversation", conversational, low: "Composed", mid: "Natural", high: "Conversational", detail: "Based on contractions, questions, and spoken rhythm.")
        ]
        let overall = Int((metrics.map(\.value).reduce(0, +) / Double(metrics.count) * 100).rounded())
        let confidence = clamp01(min(0.92, Double(words.count) / 650.0))
        let summary = "Your writing voice reads as \(descriptors.prefix(3).joined(separator: ", ")). It tends to use \(sentenceLengthLabel(averageSentenceLength)) sentences with \(contractionRate > 0.015 ? "natural contractions" : "more complete phrasing")."
        let recommendations = recommendations(
            formality: formality,
            warmth: warmth,
            directness: directness,
            enthusiasm: enthusiasm,
            complexity: complexity
        )
        let avoidances = avoidances(
            formality: formality,
            directness: directness,
            enthusiasm: enthusiasm,
            contractionRate: contractionRate
        )
        let approaches = signatureApproaches(
            averageSentenceLength: averageSentenceLength,
            questionRate: questionRate,
            phrases: phrases
        )

        return ToneOfVoiceProfile(
            generatedAt: Date(),
            model: model,
            sampleCount: samples.count,
            wordCount: words.count,
            sentenceCount: sentences.count,
            overallScore: overall,
            confidence: confidence,
            summary: summary,
            descriptors: descriptors,
            signaturePhrases: phrases,
            avoidances: avoidances,
            signatureApproaches: approaches,
            recommendations: recommendations,
            metrics: metrics,
            promptGuide: promptGuide(
                descriptors: descriptors,
                metrics: metrics,
                phrases: phrases,
                avoidances: avoidances,
                approaches: approaches,
                averageSentenceLength: averageSentenceLength,
                contractionRate: contractionRate
            ),
            sampleExcerpts: samples.prefix(4).map { cleanedExcerpt($0, maxLength: 180) }
        )
    }

    private func ollamaPrompt(samples: [String], fallbackProfile: ToneOfVoiceProfile) -> String {
        let sampleText = samples.prefix(140).enumerated().map { index, sample in
            "[\(index + 1)] \(cleanedExcerpt(sample, maxLength: 900))"
        }.joined(separator: "\n\n")

        return """
        You are a computational stylometry analyst. Analyze this user's writing and dictation samples to create a tone-of-voice profile that can guide a local writing assistant.

        Return ONLY valid JSON with this structure:
        {
          "summary": "one concise paragraph",
          "descriptors": ["word", "word", "word"],
          "metrics": [
            {"name": "Formality", "value": 0.0, "label": "Casual|Balanced|Formal", "detail": "short note"},
            {"name": "Warmth", "value": 0.0, "label": "Reserved|Neutral|Warm", "detail": "short note"},
            {"name": "Directness", "value": 0.0, "label": "Diplomatic|Balanced|Direct", "detail": "short note"},
            {"name": "Enthusiasm", "value": 0.0, "label": "Measured|Moderate|Energetic", "detail": "short note"},
            {"name": "Complexity", "value": 0.0, "label": "Simple|Clear|Layered", "detail": "short note"},
            {"name": "Conversation", "value": 0.0, "label": "Composed|Natural|Conversational", "detail": "short note"}
          ],
          "signaturePhrases": ["phrase"],
          "avoidances": ["Avoid ..."],
          "signatureApproaches": ["approach"],
          "recommendations": ["practical recommendation"],
          "promptGuide": "Instruction block for an AI assistant to write in this user's tone.",
          "confidence": 0.0
        }

        Rules:
        - Score metric values from 0.0 to 1.0.
        - Keep the summary under 70 words.
        - Use the provided local metrics as a starting point, but refine with the samples.
        - The promptGuide must be direct instructions, not analysis commentary.
        - Do not invent personal facts.

        Local metric baseline:
        Summary: \(fallbackProfile.summary)
        Metrics: \(fallbackProfile.metrics.map { "\($0.name)=\($0.label) \(Int(($0.value * 100).rounded()))%" }.joined(separator: ", "))
        Signature phrases: \(fallbackProfile.signaturePhrases.joined(separator: ", "))

        Writing samples:
        \(sampleText)
        """
    }

    private func decodeAIProfile(from response: String, fallback: ToneOfVoiceProfile, model: String) -> ToneOfVoiceProfile? {
        for candidate in extractJSONObjects(from: response) {
            guard let data = candidate.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(OllamaToneProfileResponse.self, from: data) else {
                continue
            }

            let metrics = sanitizeMetrics(decoded.metrics, fallback: fallback.metrics)
            let descriptors = sanitizedStrings(decoded.descriptors, fallback: fallback.descriptors, limit: 5)
            let phrases = sanitizedStrings(decoded.signaturePhrases, fallback: fallback.signaturePhrases, limit: 8)
            let avoidances = sanitizedStrings(decoded.avoidances, fallback: fallback.avoidances, limit: 6)
            let approaches = sanitizedStrings(decoded.signatureApproaches, fallback: fallback.signatureApproaches, limit: 6)
            let recommendations = sanitizedStrings(decoded.recommendations, fallback: fallback.recommendations, limit: 6)
            let promptGuide = decoded.promptGuide?.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = decoded.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            let overall = Int((metrics.map(\.value).reduce(0, +) / Double(max(1, metrics.count)) * 100).rounded())

            return ToneOfVoiceProfile(
                generatedAt: Date(),
                model: model,
                sampleCount: fallback.sampleCount,
                wordCount: fallback.wordCount,
                sentenceCount: fallback.sentenceCount,
                overallScore: overall,
                confidence: clamp01(decoded.confidence ?? fallback.confidence),
                summary: summary?.isEmpty == false ? summary! : fallback.summary,
                descriptors: descriptors,
                signaturePhrases: phrases,
                avoidances: avoidances,
                signatureApproaches: approaches,
                recommendations: recommendations,
                metrics: metrics,
                promptGuide: promptGuide?.isEmpty == false ? promptGuide! : fallback.promptGuide,
                sampleExcerpts: fallback.sampleExcerpts
            )
        }

        return nil
    }

    private func sanitizeMetrics(_ metrics: [OllamaToneMetricResponse]?, fallback: [ToneOfVoiceMetric]) -> [ToneOfVoiceMetric] {
        guard let metrics, !metrics.isEmpty else { return fallback }
        let allowedNames = ["Formality", "Warmth", "Directness", "Enthusiasm", "Complexity", "Conversation"]
        var byName: [String: ToneOfVoiceMetric] = [:]

        for metric in metrics {
            let name = metric.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard allowedNames.contains(name) else { continue }
            let value = clamp01(metric.value)
            let label = metric.label.trimmingCharacters(in: .whitespacesAndNewlines)
            byName[name] = ToneOfVoiceMetric(
                name: name,
                value: value,
                label: label.isEmpty ? fallback.first(where: { $0.name == name })?.label ?? name : label,
                detail: metric.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return allowedNames.compactMap { name in
            byName[name] ?? fallback.first(where: { $0.name == name })
        }
    }

    private func words(in text: String) -> [String] {
        text.lowercased()
            .split { character in
                !(character.isLetter || character.isNumber || character == "'")
            }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func sentences(in text: String) -> [String] {
        text.split { ".!?".contains($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func rate(matches markers: [String], in lowerText: String, denominator: Int) -> Double {
        guard denominator > 0 else { return 0 }
        let count = markers.reduce(0) { total, marker in
            total + lowerText.components(separatedBy: marker).count - 1
        }
        return Double(count) / Double(denominator)
    }

    private func punctuationRate(_ punctuation: Character, in text: String, denominator: Int) -> Double {
        guard denominator > 0 else { return 0 }
        return Double(text.filter { $0 == punctuation }.count) / Double(denominator)
    }

    private func signaturePhrases(from samples: [String]) -> [String] {
        var counts: [String: Int] = [:]
        let stopWords: Set<String> = [
            "the", "and", "for", "that", "this", "with", "from", "have", "has", "had",
            "are", "was", "were", "you", "your", "but", "not", "can", "will", "just"
        ]

        for sample in samples {
            let sampleWords = words(in: sample)
            guard sampleWords.count >= 2 else { continue }

            for length in 2...3 {
                guard sampleWords.count >= length else { continue }
                for index in 0...(sampleWords.count - length) {
                    let phraseWords = Array(sampleWords[index..<(index + length)])
                    guard phraseWords.contains(where: { !stopWords.contains($0) && $0.count > 3 }) else { continue }
                    let phrase = phraseWords.joined(separator: " ")
                    counts[phrase, default: 0] += 1
                }
            }
        }

        return counts
            .filter { $0.value > 1 }
            .sorted {
                if $0.value == $1.value { return $0.key.count > $1.key.count }
                return $0.value > $1.value
            }
            .prefix(8)
            .map(\.key)
    }

    private func descriptors(
        formality: Double,
        warmth: Double,
        directness: Double,
        enthusiasm: Double,
        complexity: Double,
        conversational: Double
    ) -> [String] {
        var values: [String] = []
        values.append(formality > 0.64 ? "professional" : formality < 0.36 ? "casual" : "balanced")
        values.append(warmth > 0.62 ? "warm" : "measured")
        values.append(directness > 0.62 ? "direct" : "diplomatic")
        if enthusiasm > 0.62 { values.append("energetic") }
        if complexity > 0.62 { values.append("layered") }
        if conversational > 0.62 { values.append("conversational") }
        return Array(NSOrderedSet(array: values).compactMap { $0 as? String }.prefix(5))
    }

    private func metric(_ name: String, _ value: Double, low: String, mid: String, high: String, detail: String) -> ToneOfVoiceMetric {
        let label: String
        if value < 0.38 {
            label = low
        } else if value > 0.64 {
            label = high
        } else {
            label = mid
        }

        return ToneOfVoiceMetric(name: name, value: value, label: label, detail: detail)
    }

    private func recommendations(
        formality: Double,
        warmth: Double,
        directness: Double,
        enthusiasm: Double,
        complexity: Double
    ) -> [String] {
        var values: [String] = []
        values.append("Use the detected tone profile in ChatAI's My Tone mode for drafts that sound closer to your writing.")
        values.append(directness > 0.64 ? "Keep generated drafts concise and action-oriented." : "Let drafts keep some nuance instead of forcing overly blunt phrasing.")
        values.append(warmth > 0.62 ? "Preserve friendly relational language when rewriting." : "Keep warmth intentional so generated text does not sound artificially cheerful.")
        if complexity > 0.62 {
            values.append("Allow layered explanations, but ask ChatAI to tighten final delivery when needed.")
        } else {
            values.append("Prefer plain language and short transitions in generated content.")
        }
        if formality < 0.36 {
            values.append("Let contractions remain when the audience is informal.")
        } else if formality > 0.64 {
            values.append("Avoid slang when generating professional content.")
        }
        if enthusiasm < 0.38 {
            values.append("Use exclamation points sparingly.")
        }
        return Array(values.prefix(6))
    }

    private func avoidances(formality: Double, directness: Double, enthusiasm: Double, contractionRate: Double) -> [String] {
        var values: [String] = []
        if enthusiasm < 0.42 { values.append("Avoid excessive exclamation points or hype.") }
        if formality > 0.64 { values.append("Avoid slang and overly casual shortcuts.") }
        if directness > 0.64 { values.append("Avoid excessive hedging or long caveats.") }
        if contractionRate < 0.006 { values.append("Avoid forcing contractions when the context is formal.") }
        if values.isEmpty { values.append("Avoid overusing signature phrases; keep them natural.") }
        return values
    }

    private func signatureApproaches(averageSentenceLength: Double, questionRate: Double, phrases: [String]) -> [String] {
        var values = [
            averageSentenceLength > 20 ? "Builds ideas in fuller sentences." : "Keeps sentences compact and easy to scan."
        ]
        if questionRate > 0.12 {
            values.append("Uses questions to frame or advance the point.")
        }
        if let firstPhrase = phrases.first {
            values.append("Repeats phrases like \"\(firstPhrase)\" across samples.")
        }
        return values
    }

    private func promptGuide(
        descriptors: [String],
        metrics: [ToneOfVoiceMetric],
        phrases: [String],
        avoidances: [String],
        approaches: [String],
        averageSentenceLength: Double,
        contractionRate: Double
    ) -> String {
        let metricLines = metrics.map { "- \($0.name): \($0.label) (\(Int(($0.value * 100).rounded()))%). \($0.detail)" }.joined(separator: "\n")
        let phraseLine = phrases.isEmpty ? "- Do not force catchphrases; prioritize natural rhythm." : "- Signature phrases to consider lightly: \(phrases.prefix(5).joined(separator: ", "))."
        let contractionLine = contractionRate > 0.015 ? "- Use contractions naturally when context allows." : "- Prefer complete forms unless the user asks for a casual rewrite."
        let sentenceLine = averageSentenceLength > 20 ? "- Use fuller sentences and allow nuance." : "- Prefer concise sentences and clean transitions."

        return """
        Write in the user's tone of voice.
        Voice descriptors: \(descriptors.joined(separator: ", ")).
        \(metricLines)
        \(sentenceLine)
        \(contractionLine)
        \(phraseLine)
        Signature approaches:
        \(approaches.map { "- \($0)" }.joined(separator: "\n"))
        Avoid:
        \(avoidances.map { "- \($0)" }.joined(separator: "\n"))
        Keep the content useful and natural. Do not imitate personal facts or exaggerate style markers.
        """
    }

    private func sentenceLengthLabel(_ value: Double) -> String {
        if value < 12 { return "short" }
        if value > 20 { return "longer, more layered" }
        return "moderate-length"
    }

    private func cleanedExcerpt(_ text: String, maxLength: Int) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > maxLength else { return cleaned }
        return String(cleaned.prefix(max(0, maxLength - 3))) + "..."
    }

    private func sanitizedStrings(_ values: [String]?, fallback: [String], limit: Int) -> [String] {
        let sanitized = (values ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(limit)
            .map { $0 }
        return sanitized.isEmpty ? Array(fallback.prefix(limit)) : sanitized
    }

    private func clamp01(_ value: Double) -> Double {
        max(0, min(1, value))
    }

    private func extractJSONObjects(from text: String) -> [String] {
        let characters = Array(text)
        var candidates: [String] = []
        var depth = 0
        var startIndex: Int?
        var isEscaped = false
        var isInsideString = false

        for index in characters.indices {
            let character = characters[index]

            if isEscaped {
                isEscaped = false
                continue
            }

            if character == "\\" && isInsideString {
                isEscaped = true
                continue
            }

            if character == "\"" {
                isInsideString.toggle()
                continue
            }

            guard !isInsideString else { continue }

            if character == "{" {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
            } else if character == "}", depth > 0 {
                depth -= 1
                if depth == 0, let objectStartIndex = startIndex {
                    candidates.append(String(characters[objectStartIndex...index]))
                    startIndex = nil
                }
            }
        }

        return candidates
    }

    private var contractionMarkers: [String] {
        ["n't", "'re", "'ll", "'ve", "'d", "'m", " it's ", " i'm ", " don't ", " can't "]
    }

    private var hedgeMarkers: [String] {
        [" maybe ", " perhaps ", " i think ", " sort of ", " kind of ", " probably ", " might ", " could ", " somewhat "]
    }

    private var warmMarkers: [String] {
        [" thanks ", " thank you ", " appreciate ", " happy ", " love ", " great ", " glad ", " please ", " excited "]
    }

    private var inclusiveMarkers: [String] {
        [" we ", " us ", " our ", " together "]
    }
}

private struct OllamaToneProfileResponse: Decodable {
    let summary: String?
    let descriptors: [String]?
    let metrics: [OllamaToneMetricResponse]?
    let signaturePhrases: [String]?
    let avoidances: [String]?
    let signatureApproaches: [String]?
    let recommendations: [String]?
    let promptGuide: String?
    let confidence: Double?
}

private struct OllamaToneMetricResponse: Decodable {
    let name: String
    let value: Double
    let label: String
    let detail: String
}

private extension Int {
    func nonZeroAverage(count: Int) -> Double {
        guard count > 0 else { return 0 }
        return Double(self) / Double(count)
    }
}
