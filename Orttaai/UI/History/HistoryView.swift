// HistoryView.swift
// Orttaai

import SwiftUI
import GRDB
import os
import AppKit

struct HistoryView: View {
    @State private var entries: [HistoryTableEntry] = []
    @State private var searchText = ""
    @State private var observation: DatabaseCancellable?
    @State private var detailEntry: HistoryTableEntry?
    @State private var pendingDeleteEntry: HistoryTableEntry?
    @State private var errorMessage: String?
    @State private var copiedEntryID: Int64?
    @State private var copyFeedbackTask: Task<Void, Never>?

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let showWords = width >= 920
            let showLatency = width >= 1_060
            let showModel = width >= 1_280
            let appColumnWidth: CGFloat = width < 880 ? 96 : 132

            VStack(alignment: .leading, spacing: Spacing.lg) {
                header

                if let errorMessage {
                    Text(errorMessage)
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.error)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
                        .background(Color.Orttaai.errorSubtle)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
                }

                if entries.isEmpty {
                    emptyState
                } else if filteredEntries.isEmpty {
                    noResultsState
                } else {
                    VStack(spacing: 0) {
                        tableHeaderRow(
                            appColumnWidth: appColumnWidth,
                            showWords: showWords,
                            showLatency: showLatency,
                            showModel: showModel
                        )
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.sm)

                        Divider()
                            .background(Color.Orttaai.border)

                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { index, entry in
                                    tableRow(
                                        entry,
                                        appColumnWidth: appColumnWidth,
                                        showWords: showWords,
                                        showLatency: showLatency,
                                        showModel: showModel
                                    )

                                    if index < filteredEntries.count - 1 {
                                        Divider()
                                            .background(Color.Orttaai.border.opacity(0.6))
                                    }
                                }
                            }
                        }
                    }
                    .dashboardCard()
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(Spacing.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.Orttaai.bgPrimary)
        .onAppear {
            loadEntries()
            startObservation()
        }
        .onDisappear {
            observation?.cancel()
            copyFeedbackTask?.cancel()
        }
        .sheet(item: $detailEntry) { entry in
            HistoryTranscriptDetailModal(
                entry: entry,
                onCopy: {
                    copyTranscript(entry.fullText)
                }
            )
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
                guard let pendingDeleteEntry else { return }
                deleteEntry(pendingDeleteEntry)
                self.pendingDeleteEntry = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteEntry = nil
            }
        } message: {
            Text("This removes the transcript from local history.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("History")
                        .font(.Orttaai.heading)
                        .foregroundStyle(Color.Orttaai.textPrimary)

                    Text("Browse, copy, and manage your recent dictations.")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }

                Spacer()

                Text("\(filteredEntries.count) / \(entries.count)")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.xs)
                    .background(Color.Orttaai.bgSecondary)
                    .clipShape(Capsule())
            }

            searchField
        }
    }

    private var searchField: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.Orttaai.textTertiary)

            TextField("Search transcript, app, or model", text: $searchText)
                .textFieldStyle(.plain)
                .font(.Orttaai.body)
                .foregroundStyle(Color.Orttaai.textPrimary)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.Orttaai.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.Orttaai.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.input)
                .stroke(Color.Orttaai.border, lineWidth: BorderWidth.standard)
        )
    }

    private func tableHeaderRow(
        appColumnWidth: CGFloat,
        showWords: Bool,
        showLatency: Bool,
        showModel: Bool
    ) -> some View {
        HStack(spacing: Spacing.sm) {
            tableHeaderText("Time", width: 96, alignment: .leading)
            tableHeaderText("App", width: appColumnWidth, alignment: .leading)
            tableHeaderText("Transcript", width: nil, alignment: .leading)

            if showWords {
                tableHeaderText("Words", width: 64, alignment: .trailing)
            }

            if showLatency {
                tableHeaderText("Latency", width: 84, alignment: .trailing)
            }

            if showModel {
                tableHeaderText("Model", width: 140, alignment: .leading)
            }

            tableHeaderText("Actions", width: 88, alignment: .center)
        }
    }

    private func tableHeaderText(_ text: String, width: CGFloat?, alignment: Alignment) -> some View {
        Text(text)
            .font(.Orttaai.caption)
            .foregroundStyle(Color.Orttaai.textTertiary)
            .frame(width: width, alignment: alignment)
    }

    private func tableRow(
        _ entry: HistoryTableEntry,
        appColumnWidth: CGFloat,
        showWords: Bool,
        showLatency: Bool,
        showModel: Bool
    ) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(Self.relativeDateFormatter.localizedString(for: entry.createdAt, relativeTo: Date()))
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .frame(width: 96, alignment: .leading)

            Text(entry.appName)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: appColumnWidth, alignment: .leading)

            Text(entry.previewText)
                .font(.Orttaai.body)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if showWords {
                Text("\(entry.wordCount)")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .frame(width: 64, alignment: .trailing)
            }

            if showLatency {
                Text("\(entry.processingMs) ms")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .frame(width: 84, alignment: .trailing)
            }

            if showModel {
                Text(entry.modelId)
                    .font(.Orttaai.monoSmall)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 140, alignment: .leading)
            }

            HStack(spacing: Spacing.xs) {
                let isCopied = copiedEntryID == entry.id
                iconButton(
                    systemName: isCopied ? "checkmark.circle.fill" : "doc.on.doc",
                    label: isCopied ? "Copied" : "Copy",
                    tint: isCopied ? Color.Orttaai.success : Color.Orttaai.textSecondary
                ) {
                    copyTranscript(entry.fullText)
                    showCopyFeedback(for: entry.id)
                }

                iconButton(systemName: "trash", label: "Delete", tint: Color.Orttaai.error) {
                    pendingDeleteEntry = entry
                }
            }
            .frame(width: 88, alignment: .center)
        }
        .padding(.vertical, Spacing.sm)
        .padding(.horizontal, Spacing.sm)
        .contentShape(Rectangle())
        .onTapGesture {
            detailEntry = entry
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(entry.appName), \(entry.previewText), \(entry.wordCount) words, \(entry.processingMs) milliseconds."
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
                .background(Color.Orttaai.bgPrimary.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            Image(systemName: "waveform.circle")
                .font(.system(size: 40))
                .foregroundStyle(Color.Orttaai.textTertiary)

            Text("No transcriptions yet.")
                .font(.Orttaai.body)
                .foregroundStyle(Color.Orttaai.textSecondary)

            Text("Press Ctrl + Shift + Space to start dictating.")
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textTertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var noResultsState: some View {
        VStack(spacing: Spacing.md) {
            Spacer()
            Text("No results for \"\(searchText)\"")
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
            Button("Clear Search") {
                searchText = ""
            }
            .buttonStyle(OrttaaiButtonStyle(.secondary))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var filteredEntries: [HistoryTableEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return entries
        }
        return entries.filter { entry in
            entry.fullText.localizedCaseInsensitiveContains(query)
                || entry.appName.localizedCaseInsensitiveContains(query)
                || entry.modelId.localizedCaseInsensitiveContains(query)
        }
    }

    private func loadEntries() {
        do {
            let db = try DatabaseManager()
            let records = try db.fetchRecent(limit: 500)
            entries = makeTableEntries(from: records)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load history."
            Logger.database.error("Failed to load history: \(error.localizedDescription)")
        }
    }

    private func startObservation() {
        do {
            let db = try DatabaseManager()
            observation = db.observeTranscriptions(limit: 500) { [self] records in
                entries = makeTableEntries(from: records)
            }
        } catch {
            Logger.database.error("Failed to start observation: \(error.localizedDescription)")
        }
    }

    private func copyTranscript(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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

    private func deleteEntry(_ entry: HistoryTableEntry) {
        do {
            let db = try DatabaseManager()
            _ = try db.deleteTranscription(id: entry.id)
            errorMessage = nil
            if detailEntry?.id == entry.id {
                detailEntry = nil
            }
        } catch {
            errorMessage = "Couldn't delete dictation."
            Logger.database.error("Failed to delete history entry: \(error.localizedDescription)")
        }
    }

    private func makeTableEntries(from records: [Transcription]) -> [HistoryTableEntry] {
        records.map { record in
            let normalizedText = record.text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let previewLimit = 140
            let previewText: String
            if normalizedText.count > previewLimit {
                let cutoff = normalizedText.index(normalizedText.startIndex, offsetBy: previewLimit)
                previewText = "\(normalizedText[..<cutoff])..."
            } else {
                previewText = normalizedText
            }

            let appName: String = {
                guard
                    let trimmed = record.targetAppName?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !trimmed.isEmpty
                else {
                    return "Unknown App"
                }
                return trimmed
            }()
            let modelId = record.modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Not set"
                : record.modelId
            let fallbackId = Int64(record.createdAt.timeIntervalSince1970 * 1_000)
                + Int64(max(0, record.processingDurationMs))
                + Int64(max(0, record.recordingDurationMs))

            return HistoryTableEntry(
                id: record.id ?? fallbackId,
                createdAt: record.createdAt,
                appName: appName,
                fullText: normalizedText,
                previewText: previewText,
                wordCount: normalizedText.split(whereSeparator: \.isWhitespace).count,
                processingMs: max(0, record.processingDurationMs),
                modelId: modelId
            )
        }
    }
}

private struct HistoryTableEntry: Identifiable {
    let id: Int64
    let createdAt: Date
    let appName: String
    let fullText: String
    let previewText: String
    let wordCount: Int
    let processingMs: Int
    let modelId: String
}

private struct HistoryTranscriptDetailModal: View {
    let entry: HistoryTableEntry
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

                Label("\(entry.processingMs) ms", systemImage: "speedometer")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textTertiary)

                Button {
                    onCopy()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(OrttaaiButtonStyle(.primary))
            }
        }
        .padding(Spacing.xxl)
        .frame(minWidth: 700, minHeight: 440)
        .background(Color.Orttaai.bgPrimary)
    }
}
