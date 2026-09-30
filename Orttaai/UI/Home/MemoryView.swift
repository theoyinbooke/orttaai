// MemoryView.swift
// Orttaai

import SwiftUI
import AppKit

private enum MemorySubsection: String, CaseIterable, Identifiable {
    case dictionary
    case snippets
    case suggestions

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dictionary: return "character.book.closed"
        case .snippets: return "text.badge.plus"
        case .suggestions: return "lightbulb"
        }
    }

    var title: String {
        switch self {
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .suggestions: return "Suggestions"
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
    @AppStorage("vocabularyBiasEnabled") private var vocabularyBiasEnabled = true
    @AppStorage("aiSuggestionsEnabled") private var aiSuggestionsEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Spacing.md) {
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
                .padding(.horizontal, WorkspaceLayout.contentHorizontalPadding)
                .padding(.top, WorkspaceLayout.contentTopPadding)
                .padding(.bottom, WorkspaceLayout.contentBottomPadding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.Orttaai.bgPrimary)
        .workspaceHeader("Memory") {
            OrttaaiTabBar(
                tabs: MemorySubsection.allCases,
                selection: $subsection,
                title: \.title,
                icon: \.icon
            )
        } trailing: {
            searchField
                .frame(width: 240)
        }
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

    private var searchField: some View {
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
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.Orttaai.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.input)
                .stroke(Color.Orttaai.border, lineWidth: BorderWidth.standard)
        )
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
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    // MARK: - Dictionary

    private var dictionaryContent: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SettingsCard {
                SettingsToggleRow(
                    title: "Dictionary Replacements",
                    info: "Replaces what you said with how you want it written, as you dictate.",
                    isOn: $dictionaryEnabled
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: "Bias Recognition to My Words",
                    info: "Nudges speech recognition toward the words in your dictionary, so names are heard right the first time.",
                    isOn: $vocabularyBiasEnabled
                )
            }

            SettingsCard(
                "Dictionary",
                info: "What speech recognition hears, and how Orttaai should write it."
            ) {
                countChip(active: viewModel.dictionaryEntries.filter(\.isActive).count, total: viewModel.dictionaryEntries.count)
            } content: {
                dictionaryEditorRow
                    .padding(.bottom, Spacing.sm)

                if filteredDictionaryEntries.isEmpty {
                    emptyState(
                        title: searchText.isEmpty ? subsection.emptyTitle : "No dictionary matches",
                        message: searchText.isEmpty ? subsection.emptyMessage : "Try a different search query.",
                        systemImage: "text.badge.checkmark"
                    )
                } else {
                    tableHeader([("Heard as", nil), ("Written as", nil), ("Used", 56), ("Active", 56), ("", 64)])
                    LazyVStack(spacing: 0) {
                        ForEach(filteredDictionaryEntries, id: \.id) { entry in
                            SettingsDivider()
                            dictionaryRow(entry)
                        }
                    }
                    .padding(.bottom, Spacing.xs)
                }
            }
        }
    }

    /// One line to add or edit an entry.
    private var dictionaryEditorRow: some View {
        HStack(spacing: Spacing.sm) {
            OrttaaiTextField(placeholder: "Heard as", text: $viewModel.dictionarySourceDraft)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.Orttaai.textTertiary)
                .accessibilityHidden(true)
            OrttaaiTextField(placeholder: "Written as", text: $viewModel.dictionaryTargetDraft)

            Button {
                viewModel.dictionaryCaseSensitiveDraft.toggle()
            } label: {
                Text("Aa")
                    .font(.Orttaai.secondary.weight(.semibold))
                    .foregroundStyle(viewModel.dictionaryCaseSensitiveDraft ? Color.Orttaai.accent : Color.Orttaai.textTertiary)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                            .fill(viewModel.dictionaryCaseSensitiveDraft ? Color.Orttaai.accentSubtle : Color.Orttaai.bgPrimary.opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                            .stroke(Color.Orttaai.border, lineWidth: BorderWidth.standard)
                    )
            }
            .buttonStyle(.plain)
            .help(viewModel.dictionaryCaseSensitiveDraft ? "Matches exact capitalization" : "Matches any capitalization")
            .accessibilityLabel("Case sensitive")
            .accessibilityValue(viewModel.dictionaryCaseSensitiveDraft ? "On" : "Off")

            Button(viewModel.editingDictionaryID == nil ? "Add" : "Update") {
                viewModel.saveDictionaryDraft()
            }
            .buttonStyle(OrttaaiButtonStyle(.primary, size: .small))
            .disabled(!isDictionaryDraftValid)

            if viewModel.editingDictionaryID != nil {
                Button("Cancel") {
                    viewModel.resetDictionaryDraft()
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
            }
        }
    }

    private func dictionaryRow(_ entry: DictionaryEntry) -> some View {
        HStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.xs) {
                Text(entry.source)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .lineLimit(1)
                if entry.isCaseSensitive {
                    Text("Aa")
                        .font(.Orttaai.caption.weight(.semibold))
                        .foregroundStyle(Color.Orttaai.textTertiary)
                        .help("Case sensitive")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.target)
                .font(.Orttaai.secondary.weight(.medium))
                .foregroundStyle(Color.Orttaai.accent)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(entry.usageCount)×")
                .font(.Orttaai.caption.monospacedDigit())
                .foregroundStyle(Color.Orttaai.textTertiary)
                .frame(width: 56, alignment: .leading)

            OrttaaiSwitch(
                title: "\(entry.source) active",
                isOn: Binding(
                    get: { entry.isActive },
                    set: { viewModel.setDictionaryEntryActive(entry, isActive: $0) }
                )
            )
            .scaleEffect(0.8, anchor: .leading)
            .frame(width: 56, alignment: .leading)

            rowActions(width: 64) {
                rowIconButton("pencil", label: "Edit \(entry.source)") {
                    viewModel.beginEditingDictionary(entry)
                }
                rowIconButton("trash", label: "Delete \(entry.source)", tint: Color.Orttaai.error) {
                    pendingDeleteDictionaryEntry = entry
                }
            }
        }
        .frame(minHeight: 34)
        .opacity(entry.isActive ? 1 : 0.6)
    }

    // MARK: - Snippets

    private var snippetsContent: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SettingsCard {
                SettingsToggleRow(
                    title: "Snippet Expansions",
                    info: "Say a trigger phrase and Orttaai types its full text.",
                    isOn: $snippetsEnabled
                )
            }

            SettingsCard(
                "Snippets",
                info: "Short phrases that expand into text you repeat often."
            ) {
                countChip(active: viewModel.snippetEntries.filter(\.isActive).count, total: viewModel.snippetEntries.count)
            } content: {
                snippetEditorRow
                    .padding(.bottom, Spacing.sm)

                if filteredSnippetEntries.isEmpty {
                    emptyState(
                        title: searchText.isEmpty ? subsection.emptyTitle : "No snippet matches",
                        message: searchText.isEmpty ? subsection.emptyMessage : "Try a different search query.",
                        systemImage: "text.insert"
                    )
                } else {
                    tableHeader([("Say", 180), ("Types", nil), ("Used", 56), ("Active", 56), ("", 92)])
                    LazyVStack(spacing: 0) {
                        ForEach(filteredSnippetEntries, id: \.id) { entry in
                            SettingsDivider()
                            snippetRow(entry)
                        }
                    }
                    .padding(.bottom, Spacing.xs)
                }
            }
        }
    }

    private var snippetEditorRow: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            OrttaaiTextField(placeholder: "Trigger phrase", text: $viewModel.snippetTriggerDraft)
                .frame(width: 180)
            TextField("Text it types", text: $viewModel.snippetExpansionDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .font(.Orttaai.body)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.sm)
                .background(Color.Orttaai.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.input)
                        .stroke(Color.Orttaai.border, lineWidth: BorderWidth.standard)
                )

            Button(viewModel.editingSnippetID == nil ? "Add" : "Update") {
                viewModel.saveSnippetDraft()
            }
            .buttonStyle(OrttaaiButtonStyle(.primary, size: .small))
            .disabled(!isSnippetDraftValid)
            .padding(.top, 3)

            if viewModel.editingSnippetID != nil {
                Button("Cancel") {
                    viewModel.resetSnippetDraft()
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
                .padding(.top, 3)
            }
        }
    }

    private func snippetRow(_ entry: SnippetEntry) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(entry.trigger)
                .font(.Orttaai.secondary.weight(.medium))
                .foregroundStyle(Color.Orttaai.accent)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)

            Text(entry.expansion.replacingOccurrences(of: "\n", with: " "))
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(entry.expansion)

            Text("\(entry.usageCount)×")
                .font(.Orttaai.caption.monospacedDigit())
                .foregroundStyle(Color.Orttaai.textTertiary)
                .frame(width: 56, alignment: .leading)

            OrttaaiSwitch(
                title: "\(entry.trigger) active",
                isOn: Binding(
                    get: { entry.isActive },
                    set: { viewModel.setSnippetEntryActive(entry, isActive: $0) }
                )
            )
            .scaleEffect(0.8, anchor: .leading)
            .frame(width: 56, alignment: .leading)

            rowActions(width: 92) {
                rowIconButton("doc.on.doc", label: "Copy text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.expansion, forType: .string)
                }
                rowIconButton("pencil", label: "Edit \(entry.trigger)") {
                    viewModel.beginEditingSnippet(entry)
                }
                rowIconButton("trash", label: "Delete \(entry.trigger)", tint: Color.Orttaai.error) {
                    pendingDeleteSnippetEntry = entry
                }
            }
        }
        .frame(minHeight: 34)
        .opacity(entry.isActive ? 1 : 0.6)
    }

    // MARK: - Suggestions

    private var suggestionsContent: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SettingsCard {
                SettingsToggleRow(
                    title: "Prefer Apple AI for Suggestions",
                    info: "Uses Apple's on-device model to propose dictionary words and snippets from your history.",
                    isOn: $aiSuggestionsEnabled
                )
            }

            SettingsCard(
                "Suggestions",
                info: "Words and phrases found in your history that could become dictionary entries or snippets."
            ) {
                Button(viewModel.isAnalyzing ? "Analyzing…" : "Analyze History") {
                    viewModel.analyzeHistory()
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
                .disabled(viewModel.isAnalyzing)
            } content: {
                if filteredSuggestions.isEmpty {
                    emptyState(
                        title: searchText.isEmpty ? subsection.emptyTitle : "No suggestion matches",
                        message: searchText.isEmpty ? subsection.emptyMessage : "Try a different search query.",
                        systemImage: "brain.head.profile"
                    )
                } else {
                    tableHeader([("Type", 84), ("Heard as", nil), ("Suggested", nil), ("Confidence", 80), ("", 150)])
                    LazyVStack(spacing: 0) {
                        ForEach(filteredSuggestions, id: \.id) { suggestion in
                            SettingsDivider()
                            suggestionRow(suggestion)
                        }
                    }
                    .padding(.bottom, Spacing.xs)
                }
            }
        }
    }

    private func suggestionRow(_ suggestion: LearningSuggestion) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(suggestion.suggestionType == .dictionary ? "Dictionary" : "Snippet")
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .frame(width: 84, alignment: .leading)

            Text(suggestion.candidateSource)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(suggestion.candidateTarget)
                .font(.Orttaai.secondary.weight(.medium))
                .foregroundStyle(Color.Orttaai.accent)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(suggestion.evidence ?? "")

            Text("\(Int((suggestion.confidence * 100).rounded()))%")
                .font(.Orttaai.caption.monospacedDigit())
                .foregroundStyle(Color.Orttaai.textTertiary)
                .frame(width: 80, alignment: .leading)

            HStack(spacing: Spacing.xs) {
                Button("Accept") {
                    viewModel.acceptSuggestion(suggestion)
                }
                .buttonStyle(OrttaaiButtonStyle(.primary, size: .small))
                Button("Reject") {
                    viewModel.rejectSuggestion(suggestion)
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary, destructive: true, size: .small))
            }
            .frame(width: 150, alignment: .trailing)
        }
        .frame(minHeight: 38)
    }

    // MARK: - Table parts

    /// Column labels. A nil width is a flexible column.
    private func tableHeader(_ columns: [(title: String, width: CGFloat?)]) -> some View {
        HStack(spacing: Spacing.sm) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                let label = Text(column.title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.Orttaai.textTertiary)
                if let width = column.width {
                    label.frame(width: width, alignment: column.title.isEmpty ? .trailing : .leading)
                } else {
                    label.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityHidden(true)
    }

    private func rowActions<Content: View>(width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 2) {
            content()
        }
        .frame(width: width, alignment: .trailing)
    }

    private func rowIconButton(
        _ systemName: String,
        label: String,
        tint: Color = Color.Orttaai.textSecondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func countChip(active: Int, total: Int) -> some View {
        Text(active == total ? "\(total) entries" : "\(active) of \(total) active")
            .font(.Orttaai.caption.monospacedDigit())
            .foregroundStyle(Color.Orttaai.textTertiary)
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
