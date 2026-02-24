// HistoryEntryView.swift
// Orttaai

import SwiftUI
import AppKit

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
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)

                Spacer()

                if let appName = entry.targetAppName {
                    Text(appName)
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                }
            }

            if isExpanded {
                // Full text
                Text(entry.text)
                    .font(.Orttaai.body)
                    .foregroundStyle(Color.Orttaai.textPrimary)
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
                    .buttonStyle(OrttaaiButtonStyle(.ghost))
                }
            } else {
                // Truncated text
                Text(entry.text)
                    .font(.Orttaai.body)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
    }
}
