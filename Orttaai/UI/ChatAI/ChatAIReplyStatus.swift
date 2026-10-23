// ChatAIReplyStatus.swift
// Orttaai

import SwiftUI

/// The line beside the beating mark while a Chat AI reply has no words yet:
/// timed stages that move on as the wait grows ("Reading your message", then
/// "Working on your reply"…), or, when a thinking model shares its reasoning,
/// the latest sentence of it. A long wait never shows the same words for long.
nonisolated enum ChatAIReplyStatus {
    struct Step: Equatable {
        let after: TimeInterval
        let text: String
    }

    static func steps(thinking: Bool) -> [Step] {
        thinking
            ? [
                Step(after: 0, text: "Reading your message"),
                Step(after: 1.5, text: "Thinking"),
                Step(after: 8, text: "Thinking it through"),
                Step(after: 20, text: "Still thinking"),
            ]
            : [
                Step(after: 0, text: "Reading your message"),
                Step(after: 2.5, text: "Working on your reply"),
                Step(after: 7, text: "Longer chats take a little more time"),
                Step(after: 15, text: "Still working on it"),
            ]
    }

    static func line(elapsed: TimeInterval, thinking: Bool, thought: String?) -> String {
        if let latest = latestThought(in: thought) { return latest }
        let steps = steps(thinking: thinking)
        return (steps.last { elapsed >= $0.after } ?? steps[0]).text
    }

    /// The last finished sentence of the model's reasoning, one line long.
    /// A sentence still being written is skipped, so the line changes once
    /// per thought rather than once per word.
    static func latestThought(in thinking: String?) -> String? {
        guard let thinking else { return nil }
        var sentences: [String] = []
        var current = ""
        for character in thinking {
            if character == "\n" {
                sentences.append(current)
                current = ""
            } else {
                current.append(character)
                if ".!?".contains(character) {
                    sentences.append(current)
                    current = ""
                }
            }
        }
        guard var sentence = sentences
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { $0.split(separator: " ").count >= 3 }) else { return nil }
        if sentence.hasSuffix(".") { sentence.removeLast() }
        if sentence.count > 90 { sentence = String(sentence.prefix(89)) + "…" }
        return sentence
    }

    /// Splits a streamed reply written with inline `<think>…</think>` tags
    /// into the visible reply and the reasoning so far.
    static func splitInlineThinking(_ partial: String) -> (visible: String, thought: String?) {
        guard let open = partial.range(of: "<think>") else { return (partial, nil) }
        let before = String(partial[..<open.lowerBound])
        guard let close = partial.range(of: "</think>", range: open.upperBound..<partial.endIndex) else {
            return (before, String(partial[open.upperBound...]))
        }
        let thought = String(partial[open.upperBound..<close.lowerBound])
        return (before + String(partial[close.upperBound...]), thought)
    }
}

/// The Orttaai mark beating gently while Chat AI works: a quick rise and a
/// slower fall, like a soft beep. Under Reduce Motion it only fades.
struct ChatAIWaitingMark: View {
    var size: CGFloat = 16
    var isBeating = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let mark = OrttaaiBrandMark().frame(width: size * SignalCursorGlyph.aspectRatio, height: size)
        if isBeating {
            mark.phaseAnimator([false, true]) { view, beat in
                view
                    .scaleEffect(reduceMotion ? 1 : (beat ? 1.12 : 0.9))
                    .opacity(beat ? 1 : 0.65)
            } animation: { beat in
                beat ? .easeOut(duration: 0.3) : .easeInOut(duration: 0.7)
            }
        } else {
            mark
        }
    }
}

/// The assistant's header row: the mark and, while the reply has no words,
/// what it is doing. A new line slides up and replaces the old one.
struct ChatAIReplyHeader: View {
    /// Nil once the reply is finished.
    var startedAt: Date?
    var hasWords: Bool
    var thinking: Bool
    var thought: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Spacing.sm) {
            ChatAIWaitingMark(size: 15, isBeating: startedAt != nil)
            if let startedAt, !hasWords {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    statusText(ChatAIReplyStatus.line(
                        elapsed: context.date.timeIntervalSince(startedAt),
                        thinking: thinking,
                        thought: thought
                    ))
                }
            } else {
                statusText("ChatAI")
            }
        }
        .frame(minHeight: 18)
    }

    private func statusText(_ line: String) -> some View {
        ZStack(alignment: .leading) {
            Text(line)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .id(line)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .animation(.easeInOut(duration: 0.28), value: line)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line)
    }
}
