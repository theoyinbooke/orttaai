// MemoryViewModel.swift
// Orttaai

import Foundation
import os

@MainActor
@Observable
final class MemoryViewModel {
    private let databaseManager: DatabaseManager?
    private let learningService: MemoryLearningService?

    private(set) var dictionaryEntries: [DictionaryEntry] = []
    private(set) var snippetEntries: [SnippetEntry] = []
    private(set) var pendingSuggestions: [LearningSuggestion] = []

    private(set) var isLoading = false
    private(set) var isAnalyzing = false
    var errorMessage: String?
    var analysisMessage: String?

    var dictionarySourceDraft = ""
    var dictionaryTargetDraft = ""
    var dictionaryCaseSensitiveDraft = false
    var dictionaryActiveDraft = true
    var editingDictionaryID: Int64?

    var snippetTriggerDraft = ""
    var snippetExpansionDraft = ""
    var snippetActiveDraft = true
    var editingSnippetID: Int64?

    init(
        databaseManager: DatabaseManager?,
        learningService: MemoryLearningService?
    ) {
        self.databaseManager = databaseManager
        self.learningService = learningService
    }

    convenience init() {
        do {
            let databaseManager = try DatabaseManager()
            let settings = AppSettings()
            let learningService = MemoryLearningService(
                databaseManager: databaseManager,
                settings: settings
            )
            self.init(databaseManager: databaseManager, learningService: learningService)
        } catch {
            Logger.database.error("Failed to initialize MemoryViewModel database: \(error.localizedDescription)")
            self.init(databaseManager: nil, learningService: nil)
            self.errorMessage = "Couldn't load memory data."
        }
    }

    func load() {
        guard !isLoading else { return }
        guard let databaseManager else {
            errorMessage = "Couldn't load memory data."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            dictionaryEntries = try databaseManager.fetchDictionaryEntries()
            snippetEntries = try databaseManager.fetchSnippetEntries()
            pendingSuggestions = try databaseManager.fetchLearningSuggestions(status: .pending, limit: 150)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load memory data."
            Logger.memory.error("Failed to load memory entries: \(error.localizedDescription)")
        }
    }

    func saveDictionaryDraft() {
        guard let databaseManager else { return }

        do {
            if let editingDictionaryID {
                _ = try databaseManager.updateDictionaryEntry(
                    id: editingDictionaryID,
                    source: dictionarySourceDraft,
                    target: dictionaryTargetDraft,
                    isCaseSensitive: dictionaryCaseSensitiveDraft,
                    isActive: dictionaryActiveDraft
                )
            } else {
                _ = try databaseManager.upsertDictionaryEntry(
                    source: dictionarySourceDraft,
                    target: dictionaryTargetDraft,
                    isCaseSensitive: dictionaryCaseSensitiveDraft,
                    isActive: dictionaryActiveDraft
                )
            }
            resetDictionaryDraft()
            errorMessage = nil
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func beginEditingDictionary(_ entry: DictionaryEntry) {
        errorMessage = nil
        editingDictionaryID = entry.id
        dictionarySourceDraft = entry.source
        dictionaryTargetDraft = entry.target
        dictionaryCaseSensitiveDraft = entry.isCaseSensitive
        dictionaryActiveDraft = entry.isActive
    }

    func resetDictionaryDraft() {
        editingDictionaryID = nil
        dictionarySourceDraft = ""
        dictionaryTargetDraft = ""
        dictionaryCaseSensitiveDraft = false
        dictionaryActiveDraft = true
    }

    func deleteDictionaryEntry(_ entry: DictionaryEntry) {
        guard let id = entry.id else { return }
        guard let databaseManager else { return }

        do {
            _ = try databaseManager.deleteDictionaryEntry(id: id)
            if editingDictionaryID == id {
                resetDictionaryDraft()
            }
            errorMessage = nil
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setDictionaryEntryActive(_ entry: DictionaryEntry, isActive: Bool) {
        guard let id = entry.id else { return }
        guard let databaseManager else { return }

        do {
            _ = try databaseManager.updateDictionaryEntry(
                id: id,
                source: entry.source,
                target: entry.target,
                isCaseSensitive: entry.isCaseSensitive,
                isActive: isActive
            )
            errorMessage = nil
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveSnippetDraft() {
        guard let databaseManager else { return }

        do {
            if let editingSnippetID {
                _ = try databaseManager.updateSnippetEntry(
                    id: editingSnippetID,
                    trigger: snippetTriggerDraft,
                    expansion: snippetExpansionDraft,
                    isActive: snippetActiveDraft
                )
            } else {
                _ = try databaseManager.upsertSnippetEntry(
                    trigger: snippetTriggerDraft,
                    expansion: snippetExpansionDraft,
                    isActive: snippetActiveDraft
                )
            }
            resetSnippetDraft()
            errorMessage = nil
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func beginEditingSnippet(_ entry: SnippetEntry) {
        errorMessage = nil
        editingSnippetID = entry.id
        snippetTriggerDraft = entry.trigger
        snippetExpansionDraft = entry.expansion
        snippetActiveDraft = entry.isActive
    }

    func resetSnippetDraft() {
        editingSnippetID = nil
        snippetTriggerDraft = ""
        snippetExpansionDraft = ""
        snippetActiveDraft = true
    }

    func deleteSnippetEntry(_ entry: SnippetEntry) {
        guard let id = entry.id else { return }
        guard let databaseManager else { return }

        do {
            _ = try databaseManager.deleteSnippetEntry(id: id)
            if editingSnippetID == id {
                resetSnippetDraft()
            }
            errorMessage = nil
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setSnippetEntryActive(_ entry: SnippetEntry, isActive: Bool) {
        guard let id = entry.id else { return }
        guard let databaseManager else { return }

        do {
            _ = try databaseManager.updateSnippetEntry(
                id: id,
                trigger: entry.trigger,
                expansion: entry.expansion,
                isActive: isActive
            )
            errorMessage = nil
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func analyzeHistory() {
        guard let learningService else { return }
        guard !isAnalyzing else { return }

        errorMessage = nil
        analysisMessage = nil
        isAnalyzing = true

        Task { [weak self] in
            guard let self else { return }
            let result = await learningService.analyzeRecentHistory()
            self.isAnalyzing = false
            self.load()

            if result.historySampleCount == 0 {
                self.analysisMessage = "No history yet to analyze."
                return
            }

            if result.insertedCount == 0 {
                self.analysisMessage = "No new suggestions found from \(result.historySampleCount) transcripts."
                return
            }

            let fallbackLabel = result.usedFallback ? " (fallback used)" : ""
            self.analysisMessage = "Added \(result.insertedCount) suggestions using \(result.analyzerName)\(fallbackLabel)."
        }
    }

    func acceptSuggestion(_ suggestion: LearningSuggestion) {
        guard let databaseManager else { return }
        guard let suggestionID = suggestion.id else { return }

        do {
            switch suggestion.suggestionType {
            case .dictionary:
                _ = try databaseManager.upsertDictionaryEntry(
                    source: suggestion.candidateSource,
                    target: suggestion.candidateTarget,
                    isCaseSensitive: false,
                    isActive: true
                )
            case .snippet:
                _ = try databaseManager.upsertSnippetEntry(
                    trigger: suggestion.candidateSource,
                    expansion: suggestion.candidateTarget,
                    isActive: true
                )
            }

            try databaseManager.updateLearningSuggestionStatus(id: suggestionID, status: .accepted)
            errorMessage = nil
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rejectSuggestion(_ suggestion: LearningSuggestion) {
        guard let databaseManager else { return }
        guard let suggestionID = suggestion.id else { return }

        do {
            try databaseManager.updateLearningSuggestionStatus(id: suggestionID, status: .rejected)
            errorMessage = nil
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
