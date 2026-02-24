// TextProcessor.swift
// Orttaai

import Foundation

enum ProcessingMode: String, Codable {
    case raw
    case clean
    case formal
    case casual
}

struct TextProcessorInput {
    let rawTranscript: String
    let targetApp: String?
    let mode: ProcessingMode
}

struct TextProcessorOutput {
    let text: String
    let changes: [String]
}

protocol TextProcessor {
    func process(_ input: TextProcessorInput) async throws -> TextProcessorOutput
    func isAvailable() -> Bool
}

final class PassthroughProcessor: TextProcessor {
    func process(_ input: TextProcessorInput) async throws -> TextProcessorOutput {
        TextProcessorOutput(text: input.rawTranscript, changes: [])
    }

    func isAvailable() -> Bool {
        true
    }
}
