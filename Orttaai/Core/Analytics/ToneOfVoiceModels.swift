// ToneOfVoiceModels.swift
// Orttaai

import Foundation

struct ToneOfVoiceMetric: Codable, Identifiable, Equatable {
    var id: String { name }

    let name: String
    let value: Double
    let label: String
    let detail: String
}

struct ToneOfVoiceProfile: Codable, Equatable {
    let generatedAt: Date
    let model: String
    let sampleCount: Int
    let wordCount: Int
    let sentenceCount: Int
    let overallScore: Int
    let confidence: Double
    let summary: String
    let descriptors: [String]
    let signaturePhrases: [String]
    let avoidances: [String]
    let signatureApproaches: [String]
    let recommendations: [String]
    let metrics: [ToneOfVoiceMetric]
    let promptGuide: String
    let sampleExcerpts: [String]

    var confidencePercent: Int {
        Int((max(0, min(1, confidence)) * 100).rounded())
    }

    var compactPromptGuide: String {
        promptGuide.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ToneOfVoiceAnalysisResult {
    let profile: ToneOfVoiceProfile
    let usedOllama: Bool
    let errorMessage: String?
}

enum ToneOfVoiceProfileStore {
    static let storageKey = "toneOfVoiceProfile"

    static func load() -> ToneOfVoiceProfile? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ToneOfVoiceProfile.self, from: data)
    }

    static func save(_ profile: ToneOfVoiceProfile) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
