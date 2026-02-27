// MemoryView.swift
// Orttaai

import SwiftUI
import AppKit

private enum MemorySubsection: String, CaseIterable, Identifiable {
    case dictionary
    case snippets
    case suggestions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .suggestions: return "Suggestions"
        }
    }

    var subtitle: String {
        switch self {
        case .dictionary: return "Auto-correct your preferred terms."
        case .snippets: return "Expand short triggers into full text."
        case .suggestions: return "Learn from history and review proposed entries."
        }
    }

    var emptyTitle: String {
        switch self {
        case .dictionary: return "No dictionary entries"
        case .snippets: return "No snippets yet"
        case .suggestions: return "No pending suggestions"
        }
    }

    var emptyMessage: String {
        switch self {
        case .dictionary: return "Add common terms, names, and preferred spellings."
        case .snippets: return "Save short triggers for long text you repeat often."
        case .suggestions: return "Run Analyze Now to generate suggestions from history."
        }
    }
}

struct MemoryView: View {
    @State private var viewModel = MemoryViewModel()
    @State private var subsection: MemorySubsection = .dictionary
    @State private var searchText = ""
    @State private var pendingDeleteDictionaryEntry: DictionaryEntry?
    @State private var pendingDeleteSnippetEntry: SnippetEntry?

    @AppStorage("dictionaryEnabled") private var dictionaryEnabled = true
    @AppStorage("snippetsEnabled") private var snippetsEnabled = true
    @AppStorage("aiSuggestionsEnabled") private var aiSuggestionsEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Spacing.xxl)
                .padding(.top, Spacing.xxl)
                .padding(.bottom, Spacing.lg)

            Divider()
                .background(Color.Orttaai.border)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    statusRow
                    featureToggles
                    flashMessages

                    if viewModel.isLoading {
                        loadingCard
                    } else {
                        switch subsection {
                        case .dictionary:
                            dictionaryContent
                        case .snippets:
                            snippetsContent
                        case .suggestions:
                            suggestionsContent
                        }
                    }
                }
                .padding(Spacing.xxl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.Orttaai.bgPrimary)
        .onAppear {
            viewModel.load()
        }
        .onChange(of: subsection) { _, _ in
            searchText = ""
        }
        .confirmationDialog(
            "Delete Dictionary Entry?",
            isPresented: Binding(
                get: { pendingDeleteDictionaryEntry != nil },
                set: { isPresented in
                    if !isPresented { pendingDeleteDictionaryEntry = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDeleteDictionaryEntry {
                    viewModel.deleteDictionaryEntry(pendingDeleteDictionaryEntry)
                    self.pendingDeleteDictionaryEntry = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteDictionaryEntry = nil
            }
        } message: {
            Text("This dictionary rule will no longer apply during dictation.")
        }
        .confirmationDialog(
            "Delete Snippet?",
            isPresented: Binding(
                get: { pendingDeleteSnippetEntry != nil },
                set: { isPresented in
                    if !isPresented { pendingDeleteSnippetEntry = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDeleteSnippetEntry {
                    viewModel.deleteSnippetEntry(pendingDeleteSnippetEntry)
                    self.pendingDeleteSnippetEntry = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteSnippetEntry = nil
            }
        } message: {
            Text("This snippet trigger will no longer expand.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Memory")
                .font(.Orttaai.heading)
                .foregroundStyle(Color.Orttaai.textPrimary)

            Text(subsection.subtitle)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)

            HStack(spacing: Spacing.sm) {
                ForEach(MemorySubsection.allCases) { item in
                    subsectionButton(item)
                }
                Spacer()
            }

            HStack(spacing: Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.Orttaai.textTertiary)

                TextField("Search entries", text: $searchText)
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
    }

    private var statusRow: some View {
        HStack(spacing: Spacing.sm) {
            StatChipView(
                label: "dictionary",
                value: "\(viewModel.dictionaryEntries.filter(\.isActive).count)/\(viewModel.dictionaryEntries.count)"
            )
            StatChipView(
                label: "snippets",
                value: "\(viewModel.snippetEntries.filter(\.isActive).count)/\(viewModel.snippetEntries.count)"
            )
            StatChipView(label: "pending", value: "\(viewModel.pendingSuggestions.count)")
            Spacer()
        }
    }

    private var featureToggles: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Runtime Controls")
                .font(.Orttaai.subheading)
                .foregroundStyle(Color.Orttaai.textPrimary)

            Toggle("Enable dictionary replacements", isOn: $dictionaryEnabled)
                .toggleStyle(OrttaaiToggleStyle())
            Toggle("Enable snippet expansions", isOn: $snippetsEnabled)
                .toggleStyle(OrttaaiToggleStyle())
            Toggle("Prefer Apple AI for suggestions", isOn: $aiSuggestionsEnabled)
                .toggleStyle(OrttaaiToggleStyle())
        }
        .padding(Spacing.lg)
        .dashboardCard()
    }

    @ViewBuilder
    private var flashMessages: some View {
        if let errorMessage = viewModel.errorMessage {
            Text(errorMessage)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.error)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(Color.Orttaai.errorSubtle)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
        }

        if let analysisMessage = viewModel.analysisMessage {
            Text(analysisMessage)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(Color.Orttaai.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
        }
    }

    private var loadingCard: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Loading memory entries...")
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    private var dictionaryContent: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            dictionaryEditorCard

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Entries")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                if filteredDictionaryEntries.isEmpty {
                    emptyState(
                        title: searchText.isEmpty ? subsection.emptyTitle : "No dictionary matches",
                        message: searchText.isEmpty ? subsection.emptyMessage : "Try a different search query.",
                        systemImage: "text.badge.checkmark"
                    )
                } else {
                    LazyVStack(spacing: Spacing.sm) {
                        ForEach(filteredDictionaryEntries, id: \.id) { entry in
                            dictionaryRow(entry)
                        }
                    }
                }
            }
            .padding(Spacing.lg)
            .dashboardCard()
        }
    }

    private var dictionaryEditorCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(viewModel.editingDictionaryID == nil ? "Add Dictionary Entry" : "Edit Dictionary Entry")
                .font(.Orttaai.subheading)
                .foregroundStyle(Color.Orttaai.textPrimary)

            Text("Use this to force preferred terms (for example, `whispr` -> `Wispr`).")
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)

            HStack(spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Input")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                    OrttaaiTextField(placeholder: "Say or type", text: $viewModel.dictionarySourceDraft)
                }

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Replace With")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                    OrttaaiTextField(placeholder: "Preferred term", text: $viewModel.dictionaryTargetDraft)
                }
            }

            Toggle("Case sensitive match", isOn: $viewModel.dictionaryCaseSensitiveDraft)
                .toggleStyle(OrttaaiToggleStyle())

            Toggle("Active", isOn: $viewModel.dictionaryActiveDraft)
                .toggleStyle(OrttaaiToggleStyle())

            HStack(spacing: Spacing.sm) {
                Button(viewModel.editingDictionaryID == nil ? "Save Entry" : "Update Entry") {
                    viewModel.saveDictionaryDraft()
                }
                .buttonStyle(OrttaaiButtonStyle(.primary))
                .disabled(!isDictionaryDraftValid)

                if viewModel.editingDictionaryID != nil {
                    Button("Cancel") {
                        viewModel.resetDictionaryDraft()
                    }
                    .buttonStyle(OrttaaiButtonStyle(.secondary))
                }
            }
        }
        .padding(Spacing.lg)
        .dashboardCard()
    }

    private func dictionaryRow(_ entry: DictionaryEntry) -> some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    Text(entry.source)
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.Orttaai.textTertiary)
                    Text(entry.target)
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.accent)
                }

                HStack(spacing: Spacing.sm) {
                    Text("Used \(entry.usageCount)x")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                    if entry.isCaseSensitive {
                        textPill("Case sensitive")
                    }
                    textPill(entry.isActive ? "Active" : "Disabled", tint: entry.isActive ? .success : .warning)
                }
            }

            Spacer()

            HStack(spacing: Spacing.xs) {
                iconButton(systemName: entry.isActive ? "pause.circle" : "play.circle", label: entry.isActive ? "Disable" : "Enable") {
                    viewModel.setDictionaryEntryActive(entry, isActive: !entry.isActive)
                }
                iconButton(systemName: "pencil", label: "Edit") {
                    viewModel.beginEditingDictionary(entry)
                }
                iconButton(systemName: "trash", label: "Delete", tint: Color.Orttaai.error) {
                    pendingDeleteDictionaryEntry = entry
                }
            }
        }
        .padding(Spacing.md)
        .background(Color.Orttaai.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
    }

    private var snippetsContent: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            snippetEditorCard

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Entries")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                if filteredSnippetEntries.isEmpty {
                    emptyState(
                        title: searchText.isEmpty ? subsection.emptyTitle : "No snippet matches",
                        message: searchText.isEmpty ? subsection.emptyMessage : "Try a different search query.",
                        systemImage: "text.insert"
                    )
                } else {
                    LazyVStack(spacing: Spacing.sm) {
                        ForEach(filteredSnippetEntries, id: \.id) { entry in
                            snippetRow(entry)
                        }
                    }
                }
            }
            .padding(Spacing.lg)
            .dashboardCard()
        }
    }

    private var snippetEditorCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(viewModel.editingSnippetID == nil ? "Add Snippet" : "Edit Snippet")
                .font(.Orttaai.subheading)
                .foregroundStyle(Color.Orttaai.textPrimary)

            Text("Speak a trigger phrase to paste the full expansion instantly.")
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Trigger")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                OrttaaiTextField(placeholder: "Trigger phrase", text: $viewModel.snippetTriggerDraft)
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Expansion")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)

                TextEditor(text: $viewModel.snippetExpansionDraft)
                    .font(.Orttaai.body)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .frame(minHeight: 92)
                    .padding(Spacing.xs)
                    .background(Color.Orttaai.bgSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                            .stroke(Color.Orttaai.border, lineWidth: BorderWidth.standard)
                    )
            }

            Toggle("Active", isOn: $viewModel.snippetActiveDraft)
                .toggleStyle(OrttaaiToggleStyle())

            HStack(spacing: Spacing.sm) {
                Button(viewModel.editingSnippetID == nil ? "Save Snippet" : "Update Snippet") {
                    viewModel.saveSnippetDraft()
                }
                .buttonStyle(OrttaaiButtonStyle(.primary))
                .disabled(!isSnippetDraftValid)

                if viewModel.editingSnippetID != nil {
                    Button("Cancel") {
                        viewModel.resetSnippetDraft()
                    }
                    .buttonStyle(OrttaaiButtonStyle(.secondary))
                }
            }
        }
        .padding(Spacing.lg)
        .dashboardCard()
    }

    private func snippetRow(_ entry: SnippetEntry) -> some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(entry.trigger)
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.accent)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(entry.expansion)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)

                HStack(spacing: Spacing.sm) {
                    Text("Used \(entry.usageCount)x")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                    textPill(entry.isActive ? "Active" : "Disabled", tint: entry.isActive ? .success : .warning)
                }
            }

            Spacer()

            HStack(spacing: Spacing.xs) {
                iconButton(systemName: "doc.on.doc", label: "Copy expansion") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.expansion, forType: .string)
                }
                iconButton(systemName: entry.isActive ? "pause.circle" : "play.circle", label: entry.isActive ? "Disable" : "Enable") {
                    viewModel.setSnippetEntryActive(entry, isActive: !entry.isActive)
                }
                iconButton(systemName: "pencil", label: "Edit") {
                    viewModel.beginEditingSnippet(entry)
                }
                iconButton(systemName: "trash", label: "Delete", tint: Color.Orttaai.error) {
                    pendingDeleteSnippetEntry = entry
                }
            }
        }
        .padding(Spacing.md)
        .background(Color.Orttaai.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
    }

    private var suggestionsContent: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Analyze History")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Text("Generate personal dictionary and snippet suggestions from recent dictations.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)

                Button(viewModel.isAnalyzing ? "Analyzing..." : "Analyze Now") {
                    viewModel.analyzeHistory()
                }
                .buttonStyle(OrttaaiButtonStyle(.primary))
                .disabled(viewModel.isAnalyzing)
            }
            .padding(Spacing.lg)
            .dashboardCard()

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Pending Suggestions")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                if filteredSuggestions.isEmpty {
                    emptyState(
                        title: searchText.isEmpty ? subsection.emptyTitle : "No suggestion matches",
                        message: searchText.isEmpty ? subsection.emptyMessage : "Try a different search query.",
                        systemImage: "sparkles.rectangle.stack"
                    )
                } else {
                    LazyVStack(spacing: Spacing.sm) {
                        ForEach(filteredSuggestions, id: \.id) { suggestion in
                            suggestionRow(suggestion)
                        }
                    }
                }
            }
            .padding(Spacing.lg)
            .dashboardCard()
        }
    }

    private func suggestionRow(_ suggestion: LearningSuggestion) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                textPill(suggestion.suggestionType == .dictionary ? "Dictionary" : "Snippet", tint: .accent)

                HStack(spacing: Spacing.xs) {
                    Text(suggestion.candidateSource)
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.Orttaai.textTertiary)
                    Text(suggestion.candidateTarget)
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.accent)
                }

                if let evidence = suggestion.evidence, !evidence.isEmpty {
                    Text(evidence)
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }

                Text("Confidence \(Int((suggestion.confidence * 100).rounded()))%")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
            }

            Spacer()

            HStack(spacing: Spacing.xs) {
                Button("Accept") {
                    viewModel.acceptSuggestion(suggestion)
                }
                .buttonStyle(OrttaaiButtonStyle(.primary))

                Button("Reject") {
                    viewModel.rejectSuggestion(suggestion)
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary, destructive: true))
            }
        }
        .padding(Spacing.md)
        .background(Color.Orttaai.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
    }

    private func subsectionButton(_ item: MemorySubsection) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                subsection = item
            }
        } label: {
            Text(item.title)
                .font(.Orttaai.secondary)
                .foregroundStyle(subsection == item ? Color.Orttaai.textPrimary : Color.Orttaai.textSecondary)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous)
                        .fill(
                            subsection == item
                                ? Color.Orttaai.accentSubtle
                                : Color.Orttaai.bgSecondary.opacity(0.55)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous)
                        .stroke(
                            subsection == item
                                ? Color.Orttaai.accent.opacity(0.55)
                                : Color.Orttaai.border.opacity(0.6),
                            lineWidth: BorderWidth.standard
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func iconButton(
        systemName: String,
        label: String,
        tint: Color = Color.Orttaai.textSecondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Color.Orttaai.bgTertiary.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func textPill(_ text: String, tint: PillTint = .neutral) -> some View {
        Text(text)
            .font(.Orttaai.caption)
            .foregroundStyle(tint.foreground)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 3)
            .background(tint.background)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(tint.border, lineWidth: BorderWidth.standard)
            )
    }

    private func emptyState(title: String, message: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.Orttaai.textTertiary)
                Text(title)
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)
            }
            Text(message)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.sm)
    }

    private var isDictionaryDraftValid: Bool {
        !viewModel.dictionarySourceDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !viewModel.dictionaryTargetDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isSnippetDraftValid: Bool {
        !viewModel.snippetTriggerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !viewModel.snippetExpansionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredDictionaryEntries: [DictionaryEntry] {
        filterText(searchText) { query in
            viewModel.dictionaryEntries.filter { entry in
                entry.source.localizedCaseInsensitiveContains(query) ||
                    entry.target.localizedCaseInsensitiveContains(query)
            }
        } fallback: {
            viewModel.dictionaryEntries
        }
    }

    private var filteredSnippetEntries: [SnippetEntry] {
        filterText(searchText) { query in
            viewModel.snippetEntries.filter { entry in
                entry.trigger.localizedCaseInsensitiveContains(query) ||
                    entry.expansion.localizedCaseInsensitiveContains(query)
            }
        } fallback: {
            viewModel.snippetEntries
        }
    }

    private var filteredSuggestions: [LearningSuggestion] {
        filterText(searchText) { query in
            viewModel.pendingSuggestions.filter { suggestion in
                suggestion.candidateSource.localizedCaseInsensitiveContains(query) ||
                    suggestion.candidateTarget.localizedCaseInsensitiveContains(query)
            }
        } fallback: {
            viewModel.pendingSuggestions
        }
    }

    private func filterText<T>(
        _ rawQuery: String,
        filtered: (String) -> [T],
        fallback: () -> [T]
    ) -> [T] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return fallback() }
        return filtered(query)
    }
}

private enum PillTint {
    case neutral
    case accent
    case success
    case warning

    var foreground: Color {
        switch self {
        case .neutral: return Color.Orttaai.textTertiary
        case .accent: return Color.Orttaai.accent
        case .success: return Color.Orttaai.success
        case .warning: return Color.Orttaai.warning
        }
    }

    var background: Color {
        switch self {
        case .neutral: return Color.Orttaai.bgTertiary.opacity(0.5)
        case .accent: return Color.Orttaai.accentSubtle
        case .success: return Color.Orttaai.successSubtle
        case .warning: return Color.Orttaai.warningSubtle
        }
    }

    var border: Color {
        switch self {
        case .neutral: return Color.Orttaai.border.opacity(0.65)
        case .accent: return Color.Orttaai.accent.opacity(0.45)
        case .success: return Color.Orttaai.success.opacity(0.45)
        case .warning: return Color.Orttaai.warning.opacity(0.45)
        }
    }
}
