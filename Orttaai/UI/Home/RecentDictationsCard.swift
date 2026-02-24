// RecentDictationsCard.swift
// Orttaai

import SwiftUI

struct RecentDictationsCard: View {
    let entries: [DashboardRecentDictation]
    let isCompact: Bool
    let onOpenHistory: () -> Void
    let onCopyEntry: (DashboardRecentDictation) -> Void
    let onDeleteEntry: (DashboardRecentDictation) -> Void

    @State private var detailEntry: DashboardRecentDictation?
    @State private var pendingDeleteEntry: DashboardRecentDictation?
    @State private var copiedEntryID: Int64?
    @State private var copyFeedbackTask: Task<Void, Never>?

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text("Recent Dictations")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Spacer()

                Button("Open History", action: onOpenHistory)
                    .buttonStyle(OrttaaiButtonStyle(.ghost))
                    .accessibilityHint("Switches to the full history workspace.")
            }

            if entries.isEmpty {
                Text("No dictations yet. Hold Ctrl + Shift + Space to get started.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            } else {
                headerRow

                Divider()
                    .background(Color.Orttaai.border)

                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        tableRow(entry)

                        if index < entries.count - 1 {
                            Divider()
                                .background(Color.Orttaai.border.opacity(0.6))
                        }
                    }
                }
                .background(Color.Orttaai.bgPrimary.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent dictations table")
        .sheet(item: $detailEntry) { entry in
            RecentDictationDetailModal(entry: entry, onCopy: {
                onCopyEntry(entry)
            })
        }
        .confirmationDialog(
            "Delete Dictation?",
            isPresented: Binding(
                get: { pendingDeleteEntry != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDeleteEntry = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDeleteEntry {
                    onDeleteEntry(pendingDeleteEntry)
                    self.pendingDeleteEntry = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteEntry = nil
            }
        } message: {
            Text("This removes the transcript from local history.")
        }
        .onDisappear {
            copyFeedbackTask?.cancel()
        }
    }

    private var headerRow: some View {
        HStack(spacing: Spacing.sm) {
            tableHeaderText("Time", width: 88, alignment: .leading)
            tableHeaderText("App", width: isCompact ? 100 : 140, alignment: .leading)
            tableHeaderText("Transcript", width: nil, alignment: .leading)

            if !isCompact {
                tableHeaderText("Words", width: 70, alignment: .trailing)
                tableHeaderText("Latency", width: 80, alignment: .trailing)
            }

            tableHeaderText("Actions", width: 84, alignment: .center)
        }
    }

    private func tableHeaderText(_ text: String, width: CGFloat?, alignment: Alignment) -> some View {
        Text(text)
            .font(.Orttaai.caption)
            .foregroundStyle(Color.Orttaai.textTertiary)
            .frame(width: width, alignment: alignment)
    }

    private func tableRow(_ entry: DashboardRecentDictation) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(Self.timestampFormatter.string(from: entry.createdAt))
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .frame(width: 88, alignment: .leading)

            Text(entry.appName)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: isCompact ? 100 : 140, alignment: .leading)

            Text(entry.previewText)
                .font(.Orttaai.body)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !isCompact {
                Text("\(entry.wordCount)")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .frame(width: 70, alignment: .trailing)

                Text("\(entry.processingMs) ms")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .frame(width: 80, alignment: .trailing)
            }

            HStack(spacing: Spacing.xs) {
                let isCopied = copiedEntryID == entry.id
                iconButton(
                    systemName: isCopied ? "checkmark.circle.fill" : "doc.on.doc",
                    label: isCopied ? "Copied" : "Copy",
                    tint: isCopied ? Color.Orttaai.success : Color.Orttaai.textSecondary
                ) {
                    onCopyEntry(entry)
                    showCopyFeedback(for: entry.id)
                }

                iconButton(systemName: "trash", label: "Delete", tint: Color.Orttaai.error) {
                    pendingDeleteEntry = entry
                }
            }
            .frame(width: 84, alignment: .center)
        }
        .padding(.vertical, Spacing.sm)
        .padding(.horizontal, Spacing.sm)
        .contentShape(Rectangle())
        .onTapGesture {
            detailEntry = entry
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(Self.timestampFormatter.string(from: entry.createdAt)), \(entry.appName), \(entry.previewText), \(entry.wordCount) words, \(entry.processingMs) milliseconds processing."
        )
        .accessibilityHint("Double tap to open full transcript.")
    }

    private func iconButton(
        systemName: String,
        label: String,
        tint: Color = Color.Orttaai.textSecondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(Color.Orttaai.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func showCopyFeedback(for id: Int64) {
        copiedEntryID = id
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            copiedEntryID = nil
        }
    }
}

private struct RecentDictationDetailModal: View {
    let entry: DashboardRecentDictation
    let onCopy: () -> Void

    @Environment(\.dismiss) private var dismiss

    private static let detailFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Transcript")
                        .font(.Orttaai.heading)
                        .foregroundStyle(Color.Orttaai.textPrimary)

                    Text("\(entry.appName) • \(Self.detailFormatter.string(from: entry.createdAt))")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary))
            }

            ScrollView(showsIndicators: false) {
                Text(entry.fullText)
                    .font(.Orttaai.body)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.md)
                    .background(Color.Orttaai.bgSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
            }

            HStack {
                Label("\(entry.wordCount) words", systemImage: "textformat.abc")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)

                Spacer()

                Button {
                    onCopy()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(OrttaaiButtonStyle(.primary))
            }
        }
        .padding(Spacing.xxl)
        .frame(minWidth: 640, minHeight: 420)
        .background(Color.Orttaai.bgPrimary)
    }
}
