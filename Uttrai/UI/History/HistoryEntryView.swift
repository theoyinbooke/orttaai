// HistoryEntryView.swift
// Uttrai

import SwiftUI

struct HistoryEntryView: View {
    let entry: Transcription
    let isExpanded: Bool

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Header: timestamp and app name
            HStack {
                Text(Self.relativeDateFormatter.localizedString(for: entry.createdAt, relativeTo: Date()))
                    .font(.Uttrai.secondary)
                    .foregroundStyle(Color.Uttrai.textSecondary)

                Spacer()

                if let appName = entry.targetAppName {
                    Text(appName)
                        .font(.Uttrai.caption)
                        .foregroundStyle(Color.Uttrai.textTertiary)
                }
            }

            if isExpanded {
                // Full text
                Text(entry.text)
                    .font(.Uttrai.body)
                    .foregroundStyle(Color.Uttrai.textPrimary)
                    .textSelection(.enabled)

                // Copy button
                HStack {
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.text, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(UttraiButtonStyle(.ghost))
                }
            } else {
                // Truncated text
                Text(entry.text)
                    .font(.Uttrai.body)
                    .foregroundStyle(Color.Uttrai.textPrimary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
    }
}
