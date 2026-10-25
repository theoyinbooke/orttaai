// S1MiniPolisher.swift
// PolishEngine
//
// Polish with S1-mini by Superwhisper (Qwen3 0.6B fine-tuned for dictation
// clean-up, Apache 2.0, to be credited as "S1-mini" by "Superwhisper"), the
// model Orttakey uses on the iPhone. One paragraph at a time, each checked by
// PolishChecker: a paragraph whose answer fails the check, or that time runs
// out on, keeps its rules text, without costing the others theirs.

import Foundation

/// S1-mini's input, exactly as it was trained: this system prompt and a
/// control line before the transcript, in Qwen's chat format with thinking
/// off.
public nonisolated enum S1MiniPrompt {
    public static let instructions = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."
    public static let controlLine = "[Styling: semi-formal] [Structure: lists] [Context: general]"

    public static func prompt(for text: String) -> String {
        "<|im_start|>system\n\(instructions)<|im_end|>\n<|im_start|>user\n\(controlLine)\n\(text)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    /// Room for the answer: about twice the words, plus a little.
    public static func maxTokens(for text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count * 2 + 48
    }
}

/// What polishing a dictation did.
public nonisolated struct PolishOutcome: Sendable, Equatable {
    public var text: String
    /// Paragraphs whose polished text replaced the rules text.
    public var polished: Int
    /// Paragraphs long enough to polish.
    public var paragraphs: Int
    /// Why the others kept their rules text, for the log.
    public var notes: [String]

    public var applied: Bool { polished > 0 }
}

public nonisolated enum ParagraphPolish {
    /// Paragraphs shorter than this are left as they are.
    static let minimumWords = 3

    /// Polishes `text` one paragraph ("\n\n" apart) at a time with
    /// `generate`, which returns nil when it ran out of time. Each answer must
    /// pass PolishChecker against its own paragraph.
    public static func polish(
        _ text: String,
        protecting protected: [String] = [],
        deadline: ContinuousClock.Instant,
        generate: (_ paragraph: String, _ deadline: ContinuousClock.Instant) throws -> String?
    ) -> PolishOutcome {
        var pieces: [String] = []
        var polished = 0
        var paragraphs = 0
        var notes: [String] = []
        for paragraph in text.components(separatedBy: "\n\n") {
            guard paragraph.split(whereSeparator: \.isWhitespace).count >= minimumWords else {
                pieces.append(paragraph)
                continue
            }
            paragraphs += 1
            guard ContinuousClock.now < deadline else {
                pieces.append(paragraph)
                notes.append("out of time")
                continue
            }
            do {
                guard let answer = try generate(paragraph, deadline) else {
                    pieces.append(paragraph)
                    notes.append("out of time")
                    continue
                }
                let ownWords = protected.filter { paragraph.contains($0) }
                switch PolishChecker.check(answer, against: paragraph, protecting: ownWords) {
                case .accepted(let text):
                    pieces.append(text)
                    polished += 1
                case .rejected(let reason):
                    pieces.append(paragraph)
                    notes.append(reason.description)
                }
            } catch {
                pieces.append(paragraph)
                notes.append(error.localizedDescription)
            }
        }
        return PolishOutcome(text: pieces.joined(separator: "\n\n"), polished: polished, paragraphs: paragraphs, notes: notes)
    }
}

/// S1-mini loaded once and kept, one polish at a time.
public actor S1MiniPolisher {
    private let modelPath: String
    private let useGPU: Bool
    private var runner: LlamaRunner?

    public init(modelPath: String, useGPU: Bool = true) {
        self.modelPath = modelPath
        self.useGPU = useGPU
    }

    public var isLoaded: Bool { runner != nil }

    /// Loads the model if it isn't yet; returns how long that took (0 when
    /// it was already loaded).
    @discardableResult
    public func load() throws -> TimeInterval {
        if runner != nil { return 0 }
        let loaded = try LlamaRunner(path: modelPath, useGPU: useGPU)
        runner = loaded
        return loaded.loadSeconds
    }

    public func unload() {
        runner = nil
    }

    /// How long a dictation of `words` words may spend in Polish: a second,
    /// plus 6 ms a word, at most 8 s. On an M5 Max S1-mini needs about a
    /// third of that (0.14 s for 29 words, 0.77 s for 206, 2.3 s for 553).
    public static func timeBudget(forWords words: Int) -> Duration {
        .milliseconds(min(8_000, 1_000 + 6 * words))
    }

    public func polish(_ text: String, protecting protected: [String] = [], deadline: ContinuousClock.Instant) throws -> PolishOutcome {
        try load()
        guard let runner else { throw LlamaRunner.Failure.contextFailed }
        return ParagraphPolish.polish(text, protecting: protected, deadline: deadline) { paragraph, deadline in
            let output = try runner.generate(
                prompt: S1MiniPrompt.prompt(for: paragraph),
                maxTokens: S1MiniPrompt.maxTokens(for: paragraph)
            ) { _ in ContinuousClock.now < deadline }
            return output.cancelled ? nil : output.text
        }
    }
}
