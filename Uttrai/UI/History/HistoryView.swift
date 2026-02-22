// HistoryView.swift
// Uttrai

import SwiftUI
import GRDB

struct HistoryView: View {
    @State private var entries: [Transcription] = []
    @State private var searchText = ""
    @State private var observation: DatabaseCancellable?
    @State private var selectedId: Int64?

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty && searchText.isEmpty {
                emptyState
            } else {
                List(filteredEntries, selection: $selectedId) { entry in
                    HistoryEntryView(
                        entry: entry,
                        isExpanded: selectedId == entry.id
                    )
                    .listRowBackground(
                        selectedId == entry.id
                            ? Color.Uttrai.accentSubtle
                            : Color.clear
                    )
                    .onTapGesture {
                        withAnimation {
                            selectedId = selectedId == entry.id ? nil : entry.id
                        }
                    }
                }
                .listStyle(.plain)
                .searchable(text: $searchText, prompt: "Search transcriptions")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Uttrai.bgPrimary)
        .onAppear {
            loadEntries()
            startObservation()
        }
        .onDisappear {
            observation?.cancel()
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            Image(systemName: "waveform.circle")
                .font(.system(size: 40))
                .foregroundStyle(Color.Uttrai.textTertiary)
            Text("No transcriptions yet.")
                .font(.Uttrai.body)
                .foregroundStyle(Color.Uttrai.textSecondary)
            Text("Press Ctrl+Shift+Space to get started.")
                .font(.Uttrai.secondary)
                .foregroundStyle(Color.Uttrai.textTertiary)
            Spacer()
        }
    }

    private var filteredEntries: [Transcription] {
        if searchText.isEmpty {
            return entries
        }
        return entries.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    private func loadEntries() {
        do {
            let db = try DatabaseManager()
            entries = try db.fetchRecent(limit: 500)
        } catch {
            Logger.database.error("Failed to load history: \(error.localizedDescription)")
        }
    }

    private func startObservation() {
        do {
            let db = try DatabaseManager()
            observation = db.observeTranscriptions { [self] records in
                entries = records
            }
        } catch {
            Logger.database.error("Failed to start observation: \(error.localizedDescription)")
        }
    }
}
