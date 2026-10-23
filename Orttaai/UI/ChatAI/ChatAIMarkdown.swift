// ChatAIMarkdown.swift
// Orttaai

import AppKit
import SwiftUI

/// Markdown as local models write it, split into blocks: headings, lists,
/// tables, code, quotes, rules and paragraphs. Inline styling (bold,
/// italic, code, links) is left to `AttributedString` at render time.
/// Works on half-finished text too, so a streaming reply renders as it
/// arrives (an unclosed code fence runs to the end).
enum ChatMarkdown {
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list(ordered: Bool, items: [ListItem])
        case quote(String)
        case code(language: String?, code: String)
        case table(header: [String], alignments: [TableAlignment], rows: [[String]])
        case rule
    }

    struct ListItem: Equatable {
        let marker: String
        let text: String
        let depth: Int
    }

    enum TableAlignment: Equatable {
        case leading, center, trailing
    }

    static func parse(_ markdown: String) -> [Block] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code fence: everything up to the closing fence, or the end.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(language: language.isEmpty ? nil : language, code: code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = headingLevel(trimmed) {
                flushParagraph()
                let text = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: heading, text: text.trimmingCharacters(in: CharacterSet(charactersIn: "# "))))
                index += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            // Table: a row of cells, then a separator row of dashes.
            if trimmed.contains("|"), index + 1 < lines.count, let alignments = separatorAlignments(lines[index + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let rowLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard rowLine.contains("|"), !rowLine.isEmpty else { break }
                    rows.append(cells(rowLine))
                    index += 1
                }
                let width = max(header.count, alignments.count)
                blocks.append(.table(
                    header: padded(header, to: width),
                    alignments: padded(alignments, to: width, with: .leading),
                    rows: rows.map { padded($0, to: width) }
                ))
                continue
            }

            if let item = listItem(line) {
                flushParagraph()
                var items = [item.item]
                let ordered = item.ordered
                index += 1
                while index < lines.count {
                    if let next = listItem(lines[index]), next.ordered == ordered || next.item.depth > 0 {
                        items.append(next.item)
                        index += 1
                    } else if !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                              lines[index].hasPrefix("  "), !items.isEmpty {
                        // A wrapped continuation of the previous item.
                        let last = items.removeLast()
                        items.append(ListItem(marker: last.marker, text: last.text + " " + lines[index].trimmingCharacters(in: .whitespaces), depth: last.depth))
                        index += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(ordered: ordered, items: items))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let quoteLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard quoteLine.hasPrefix(">") else { break }
                    quoted.append(String(quoteLine.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            paragraph.append(trimmed)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: - Line rules

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        return rest.isEmpty || rest.first == " " ? hashes : nil
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> (ordered: Bool, item: ListItem)? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        let depth = min(3, indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2)
        let body = line.dropFirst(indent.count)
        if let marker = body.first, "-*+•".contains(marker), body.dropFirst().first == " " {
            let text = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !isRule(String(body)) else { return nil }
            return (false, ListItem(marker: "•", text: text, depth: depth))
        }
        let digits = body.prefix(while: { $0.isNumber })
        if !digits.isEmpty, digits.count <= 3 {
            let after = body.dropFirst(digits.count)
            if let punctuation = after.first, punctuation == "." || punctuation == ")", after.dropFirst().first == " " {
                let text = after.dropFirst(2).trimmingCharacters(in: .whitespaces)
                return (true, ListItem(marker: "\(digits).", text: text, depth: depth))
            }
        }
        return nil
    }

    private static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func separatorAlignments(_ line: String) -> [TableAlignment]? {
        let parts = cells(line)
        guard !parts.isEmpty, line.contains("-") else { return nil }
        var alignments: [TableAlignment] = []
        for part in parts {
            let core = part.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard core.count >= 1, core.allSatisfy({ $0 == "-" }) else { return nil }
            switch (part.hasPrefix(":"), part.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }

    private static func padded<T>(_ values: [T], to count: Int, with filler: T) -> [T] {
        values.count >= count ? Array(values.prefix(count)) : values + Array(repeating: filler, count: count - values.count)
    }

    private static func padded(_ values: [String], to count: Int) -> [String] {
        padded(values, to: count, with: "")
    }

    // MARK: - Inline

    /// Bold, italic, inline code and links in one run of text.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(size: 12, design: .monospaced)
            attributed[run.range].backgroundColor = Color.Orttaai.bgTertiary
            attributed[run.range].foregroundColor = Color.Orttaai.accent
        }
        for run in attributed.runs where run.link != nil {
            attributed[run.range].foregroundColor = Color.Orttaai.accent
        }
        return attributed
    }
}

// MARK: - View

/// An assistant reply rendered from Markdown.
struct ChatAIMarkdownView: View {
    let markdown: String

    var body: some View {
        let blocks = ChatMarkdown.parse(markdown)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, isFirst: index == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: ChatMarkdown.Block, isFirst: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(ChatMarkdown.inline(text))
                .font(headingFont(level))
                .foregroundStyle(Color.Orttaai.textPrimary)
                .padding(.top, isFirst ? 0 : (level <= 2 ? 10 : 6))
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(ChatMarkdown.inline(text))
                .font(.Orttaai.body)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .lineSpacing(3.5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .list(_, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker == "•" ? (item.depth == 0 ? "•" : "◦") : item.marker)
                            .font(item.marker == "•" ? .system(size: 14, weight: .bold) : .Orttaai.body.monospacedDigit())
                            .foregroundStyle(item.marker == "•" ? Color.Orttaai.accent : Color.Orttaai.textSecondary)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(ChatMarkdown.inline(item.text))
                            .font(.Orttaai.body)
                            .foregroundStyle(Color.Orttaai.textPrimary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(item.depth) * 18)
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.Orttaai.accent.opacity(0.7))
                    .frame(width: 3)
                Text(ChatMarkdown.inline(text))
                    .font(.Orttaai.body)
                    .italic()
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let code):
            ChatAICodeBlock(language: language, code: code)
        case .table(let header, let alignments, let rows):
            ChatAITable(header: header, alignments: alignments, rows: rows)
        case .rule:
            Rectangle()
                .fill(Color.Orttaai.border.opacity(0.7))
                .frame(height: 1)
                .padding(.vertical, 4)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 20, weight: .semibold)
        case 2: return .system(size: 17, weight: .semibold)
        case 3: return .system(size: 15, weight: .semibold)
        default: return .system(size: 13.5, weight: .semibold)
        }
    }
}

/// A fenced code block: language and Copy on a header line, the code in a
/// monospaced, horizontally scrolling body.
private struct ChatAICodeBlock: View {
    let language: String?
    let code: String
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    didCopy = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        didCopy = false
                    }
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.Orttaai.caption)
                        .foregroundStyle(didCopy ? Color.Orttaai.success : Color.Orttaai.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.Orttaai.bgTertiary.opacity(0.6))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Color.Orttaai.bgPrimary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.Orttaai.border.opacity(0.8), lineWidth: BorderWidth.standard)
        )
    }
}

/// A Markdown table, as wide as the reply: a shaded header row, striped
/// body rows, column alignment from the separator row; long cells wrap.
private struct ChatAITable: View {
    let header: [String]
    let alignments: [ChatMarkdown.TableAlignment]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { column, title in
                    cell(title, column: column, isHeader: true, fill: Color.Orttaai.bgTertiary.opacity(0.75))
                }
            }

            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                Rectangle()
                    .fill(Color.Orttaai.border.opacity(0.6))
                    .frame(height: 1)
                    .gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, value in
                        cell(
                            value,
                            column: column,
                            isHeader: false,
                            fill: rowIndex.isMultiple(of: 2) ? Color.clear : Color.Orttaai.bgTertiary.opacity(0.25)
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Orttaai.bgSecondary.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.Orttaai.border.opacity(0.8), lineWidth: BorderWidth.standard)
        )
    }

    private func cell(_ text: String, column: Int, isHeader: Bool, fill: Color) -> some View {
        let alignment = column < alignments.count ? alignments[column] : .leading
        let frameAlignment: Alignment = alignment == .trailing ? .trailing : (alignment == .center ? .center : .leading)
        return Text(ChatMarkdown.inline(text))
            .font(isHeader ? .Orttaai.secondary.weight(.semibold) : .Orttaai.secondary)
            .foregroundStyle(isHeader ? Color.Orttaai.textPrimary : Color.Orttaai.textSecondary)
            .multilineTextAlignment(alignment == .trailing ? .trailing : (alignment == .center ? .center : .leading))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
            .background(fill)
            .textSelection(.enabled)
    }
}
