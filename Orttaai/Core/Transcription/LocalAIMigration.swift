// LocalAIMigration.swift
// Orttaai

import Foundation
import os

/// Moves an install off the removed cloud providers (ChatGPT through the
/// Codex CLI, and the Grok CLI) onto a local model server, once. A fresh
/// install that hasn't picked a provider goes through the same steps, so it
/// starts on whichever local server is running.
///
/// Two steps, because the second needs a running server:
/// 1. At launch, before any AI feature reads settings: a stored cloud
///    provider becomes a local one, and the cloud settings are deleted.
/// 2. Whenever a server answers: the provider settles on one that's running,
///    and feature models that aren't installed there are swapped for ones
///    that are, so insights don't quietly point at a missing model. Retried
///    on later launches until a server answers.
enum LocalAIMigration {
    static let currentVersion = 1

    /// Settings only the removed cloud providers used.
    static let obsoleteKeys = [
        "codexModel",
        "codexReasoningEffort",
        "codexConsentAcknowledged",
        "grokModel",
        "grokConsentAcknowledged",
        "lastLocalLLMProvider",
    ]

    static let modelRepairPendingKey = "aiProviderModelRepairPending"

    /// Chat models to fall back to, best first, per provider.
    static func recommendedChatModels(for provider: LocalLLMProviderKind) -> [String] {
        switch provider {
        case .ollama: return ["gemma4:e2b", "gemma4:e4b", "qwen3:1.7b", "qwen3.5:2b", "qwen3:0.6b"]
        case .lmStudio: return ["qwen3.5-2b", "qwen3.5-4b", "qwen3.5-0.8b", "google/gemma-3-4b", "qwen3-8b"]
        }
    }

    static func displayName(forRemovedProvider raw: String) -> String {
        switch raw {
        case "codex": return "ChatGPT (Codex)"
        case "grok": return "Grok"
        default: return "The previous AI provider"
        }
    }

    // MARK: - Step 1: provider

    struct ProviderDecision: Equatable {
        let provider: LocalLLMProviderKind
        /// True when the stored provider was a removed cloud one.
        let switched: Bool
    }

    /// `installed` holds each server's chat models, or nil when it didn't
    /// answer. A stored local provider is kept as it is.
    static func decideProvider(
        storedRaw: String,
        installed: [LocalLLMProviderKind: [String]?]
    ) -> ProviderDecision {
        if let kept = LocalLLMProviderKind(rawValue: storedRaw) {
            return ProviderDecision(provider: kept, switched: false)
        }
        // A missing key and a nil value both mean the server didn't answer.
        func models(_ kind: LocalLLMProviderKind) -> [String]? { installed[kind].flatMap { $0 } }
        if let ollama = models(.ollama), !ollama.isEmpty {
            return ProviderDecision(provider: .ollama, switched: true)
        }
        if models(.lmStudio) != nil {
            return ProviderDecision(provider: .lmStudio, switched: true)
        }
        return ProviderDecision(provider: .ollama, switched: true)
    }

    // MARK: - Step 2: models

    struct ModelChoices: Equatable {
        var insights: String
        var summary: String
        var polish: String
    }

    /// Keeps each configured model that's installed; replaces the rest with
    /// the polish model if it's installed, then the first recommended model
    /// that is, then the first installed chat model.
    static func repairModels(
        _ current: ModelChoices,
        provider: LocalLLMProviderKind,
        installed: [String]
    ) -> ModelChoices {
        let chatModels = installed.filter { !looksLikeEmbeddingModel($0) }
        guard !chatModels.isEmpty else { return current }

        func isInstalled(_ model: String) -> Bool {
            chatModels.contains { $0.caseInsensitiveCompare(model) == .orderedSame }
        }
        let replacement = [current.polish]
            .filter(isInstalled)
            .first
            ?? recommendedChatModels(for: provider).first(where: isInstalled)
            ?? chatModels.sorted().first!

        return ModelChoices(
            insights: isInstalled(current.insights) ? current.insights : replacement,
            summary: isInstalled(current.summary) ? current.summary : replacement,
            polish: isInstalled(current.polish) ? current.polish : replacement
        )
    }

    /// Keeps an installed embedding model; otherwise picks the first
    /// installed one, or keeps the setting when there's none (semantic
    /// memory then uses keyword search until one is added).
    static func repairEmbeddingModel(_ current: String, installed: [String]) -> String {
        let embeddingModels = installed.filter(looksLikeEmbeddingModel)
        let isInstalled = embeddingModels.contains {
            $0.caseInsensitiveCompare(current) == .orderedSame
                || $0.lowercased().hasPrefix(current.lowercased() + ":")
        }
        if isInstalled { return current }
        return embeddingModels.sorted().first ?? current
    }

    static func looksLikeEmbeddingModel(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("embed") || lowered.contains("minilm") || lowered.contains("nomic")
    }

    // MARK: - Running it

    private static let logger = Logger(subsystem: "com.orttaai.app", category: "ai")

    /// Step 1. Synchronous so it runs before anything reads the provider;
    /// it doesn't need a server, so a cloud install switches to Ollama
    /// straight away and step 2 decides the rest.
    static func migrateProviderIfNeeded(settings: AppSettings, defaults: UserDefaults = .standard) {
        guard settings.aiProviderMigrationVersion < currentVersion else { return }

        if defaults.object(forKey: "localLLMProvider") == nil {
            // Never chosen: settle on a running server in step 2.
            defaults.set("", forKey: modelRepairPendingKey)
        } else {
            let storedRaw = settings.localLLMProviderRaw
            if LocalLLMProviderKind(rawValue: storedRaw) == nil {
                settings.localLLMProvider = .ollama
                defaults.set(storedRaw, forKey: modelRepairPendingKey)
                logger.info("Moved AI provider off removed cloud provider \(storedRaw, privacy: .public)")
            }
        }
        for key in obsoleteKeys {
            defaults.removeObject(forKey: key)
        }
        settings.aiProviderMigrationVersion = currentVersion
    }

    /// Step 2. Probes both servers, settles on one per `decideProvider`, and
    /// repairs the feature models there. Does nothing unless step 1 left work
    /// (the removed provider's name, or "" for a provider never chosen).
    @MainActor
    static func finishMigrationIfNeeded(settings: AppSettings, defaults: UserDefaults = .standard) async {
        guard let removedRaw = defaults.string(forKey: modelRepairPendingKey) else { return }

        var installed: [LocalLLMProviderKind: [String]?] = [:]
        for kind in LocalLLMProviderKind.allCases {
            let health = await LocalLLM.client(for: kind)
                .checkHealth(baseURLString: settings.endpoint(for: kind), timeoutMs: 2_500)
            installed[kind] = health.isReachable ? health.installedModels : nil
        }
        guard installed.values.contains(where: { $0.flatMap { $0 } != nil }) else {
            logger.info("Local AI migration waits for Ollama or LM Studio to answer")
            return
        }

        let decision = decideProvider(storedRaw: removedRaw, installed: installed)
        settings.localLLMProvider = decision.provider
        let models = installed[decision.provider].flatMap { $0 } ?? []
        let repaired = repairModels(
            ModelChoices(
                insights: settings.normalizedLocalLLMInsightsModel,
                summary: settings.normalizedSemanticInsightSummaryModel,
                polish: settings.normalizedLocalLLMPolishModel
            ),
            provider: decision.provider,
            installed: models
        )
        settings.localLLMInsightsModel = repaired.insights
        settings.semanticInsightSummaryModel = repaired.summary
        settings.localLLMPolishModel = repaired.polish
        let embedding = repairEmbeddingModel(settings.normalizedSemanticEmbeddingModel, installed: models)
        if embedding != settings.normalizedSemanticEmbeddingModel {
            settings.semanticEmbeddingModel = embedding
            settings.semanticActiveIndexModelID = ""
        }

        if !removedRaw.isEmpty {
            settings.aiProviderMigrationNotice = "\(displayName(forRemovedProvider: removedRaw)) is no longer supported. "
                + "Orttaai now runs AI on \(decision.provider.displayName) on your own hardware, "
                + "with \(repaired.insights) for insights."
        }
        defaults.removeObject(forKey: modelRepairPendingKey)
        logger.info("Local AI migration finished on \(decision.provider.rawValue, privacy: .public) with \(repaired.insights, privacy: .public)")
    }
}
