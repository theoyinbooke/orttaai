// LocalAIMigrationTests.swift
// OrttaaiTests

import GRDB
import XCTest
@testable import Orttaai

final class LocalAIMigrationTests: XCTestCase {
    /// The models Ollama had on the development Mac when cloud AI was removed.
    private let ollamaModels = [
        "gemma4:e2b", "qwen3:1.7b", "smollm2:360m", "qwen3:0.6b", "smollm2:135m",
        "clef-flash:latest", "nimble:latest", "gemma4:26b", "all-minilm:latest",
    ]

    // MARK: - Provider

    func testOnlyLocalProvidersExist() {
        XCTAssertEqual(LocalLLMProviderKind.allCases, [.ollama, .lmStudio])
        XCTAssertNil(LocalLLMProviderKind(rawValue: "codex"))
        XCTAssertNil(LocalLLMProviderKind(rawValue: "grok"))
    }

    func testCloudProviderMovesToOllamaWhenItHasModels() {
        let decision = LocalAIMigration.decideProvider(
            storedRaw: "codex",
            installed: [.ollama: ollamaModels, .lmStudio: ["qwen3.5-2b"]]
        )
        XCTAssertEqual(decision, .init(provider: .ollama, switched: true))
    }

    func testCloudProviderMovesToLMStudioWhenOllamaIsDown() {
        let decision = LocalAIMigration.decideProvider(
            storedRaw: "grok",
            installed: [.ollama: nil, .lmStudio: ["qwen3.5-2b"]]
        )
        XCTAssertEqual(decision, .init(provider: .lmStudio, switched: true))
    }

    func testCloudProviderMovesToOllamaWhenNothingAnswers() {
        let decision = LocalAIMigration.decideProvider(
            storedRaw: "codex",
            installed: [.ollama: nil, .lmStudio: nil]
        )
        XCTAssertEqual(decision, .init(provider: .ollama, switched: true))
    }

    func testLocalProviderIsKept() {
        let decision = LocalAIMigration.decideProvider(
            storedRaw: "lmstudio",
            installed: [.ollama: ollamaModels, .lmStudio: nil]
        )
        XCTAssertEqual(decision, .init(provider: .lmStudio, switched: false))
    }

    // MARK: - Models

    /// The installed app's settings when cloud AI was removed: insights and
    /// the graph summary on qwen3.5:0.8b, which only LM Studio had.
    func testMissingInsightsModelIsReplacedByTheInstalledPolishModel() {
        let repaired = LocalAIMigration.repairModels(
            .init(insights: "qwen3.5:0.8b", summary: "qwen3.5:0.8b", polish: "gemma4:e2b"),
            provider: .ollama,
            installed: ollamaModels
        )
        XCTAssertEqual(repaired, .init(insights: "gemma4:e2b", summary: "gemma4:e2b", polish: "gemma4:e2b"))
    }

    func testInstalledModelsAreKept() {
        let current = LocalAIMigration.ModelChoices(insights: "qwen3:1.7b", summary: "gemma4:26b", polish: "gemma4:e2b")
        XCTAssertEqual(LocalAIMigration.repairModels(current, provider: .ollama, installed: ollamaModels), current)
    }

    func testFallsBackToARecommendedThenAnyChatModelButNeverAnEmbeddingModel() {
        let recommended = LocalAIMigration.repairModels(
            .init(insights: "missing", summary: "missing", polish: "also-missing"),
            provider: .lmStudio,
            installed: ["text-embedding-nomic-embed-text-v1.5", "qwen3-8b", "qwen3.5-2b"]
        )
        XCTAssertEqual(recommended.insights, "qwen3.5-2b")

        let anyChat = LocalAIMigration.repairModels(
            .init(insights: "missing", summary: "missing", polish: "also-missing"),
            provider: .lmStudio,
            installed: ["text-embedding-nomic-embed-text-v1.5", "zeta-chat", "alpha-chat"]
        )
        XCTAssertEqual(anyChat.insights, "alpha-chat")
    }

    func testEmbeddingModelMovesToOneTheServerHas() {
        XCTAssertEqual(LocalAIMigration.repairEmbeddingModel("all-minilm", installed: ollamaModels), "all-minilm")
        XCTAssertEqual(
            LocalAIMigration.repairEmbeddingModel("all-minilm", installed: ["qwen3.5-2b", "text-embedding-nomic-embed-text-v1.5"]),
            "text-embedding-nomic-embed-text-v1.5"
        )
        XCTAssertEqual(LocalAIMigration.repairEmbeddingModel("all-minilm", installed: ["qwen3.5-2b"]), "all-minilm")
    }

    func testNothingChangesWithoutChatModels() {
        let current = LocalAIMigration.ModelChoices(insights: "a", summary: "b", polish: "c")
        XCTAssertEqual(
            LocalAIMigration.repairModels(current, provider: .ollama, installed: ["all-minilm:latest"]),
            current
        )
    }

    // MARK: - Settings

    private let touchedKeys = [
        "localLLMProvider", "aiProviderMigrationVersion", "aiProviderMigrationNotice",
        LocalAIMigration.modelRepairPendingKey,
    ] + LocalAIMigration.obsoleteKeys

    func testFirstStepSwitchesProviderDeletesCloudSettingsAndRunsOnce() {
        let saved = touchedKeys.reduce(into: [String: Any]()) { $0[$1] = UserDefaults.standard.object(forKey: $1) }
        defer {
            for key in touchedKeys {
                if let value = saved[key] {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }

        let defaults = UserDefaults.standard
        defaults.set("codex", forKey: "localLLMProvider")
        defaults.set(0, forKey: "aiProviderMigrationVersion")
        defaults.set("gpt-5.4-mini", forKey: "codexModel")
        defaults.set(true, forKey: "grokConsentAcknowledged")
        defaults.removeObject(forKey: LocalAIMigration.modelRepairPendingKey)
        let settings = AppSettings()

        LocalAIMigration.migrateProviderIfNeeded(settings: settings)

        XCTAssertEqual(settings.localLLMProviderRaw, "ollama")
        XCTAssertEqual(settings.aiProviderMigrationVersion, LocalAIMigration.currentVersion)
        XCTAssertEqual(defaults.string(forKey: LocalAIMigration.modelRepairPendingKey), "codex")
        for key in LocalAIMigration.obsoleteKeys {
            XCTAssertNil(defaults.object(forKey: key), key)
        }

        // A later launch on a local provider leaves things alone.
        settings.localLLMProvider = .lmStudio
        LocalAIMigration.migrateProviderIfNeeded(settings: settings)
        XCTAssertEqual(settings.localLLMProviderRaw, "lmstudio")
    }

    func testAFreshInstallWaitsToPickARunningServer() {
        let saved = touchedKeys.reduce(into: [String: Any]()) { $0[$1] = UserDefaults.standard.object(forKey: $1) }
        defer {
            for key in touchedKeys {
                if let value = saved[key] {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }

        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "localLLMProvider")
        defaults.set(0, forKey: "aiProviderMigrationVersion")
        defaults.removeObject(forKey: LocalAIMigration.modelRepairPendingKey)

        LocalAIMigration.migrateProviderIfNeeded(settings: AppSettings())

        XCTAssertEqual(defaults.string(forKey: LocalAIMigration.modelRepairPendingKey), "")
        XCTAssertEqual(
            LocalAIMigration.decideProvider(storedRaw: "", installed: [.ollama: nil, .lmStudio: ["qwen3.5-2b"]]),
            .init(provider: .lmStudio, switched: true)
        )
    }

    func testOldInsightReportsFromACloudProviderStillLoad() throws {
        let db = try DatabaseManager(dbQueue: try DatabaseQueue())
        let snapshot = WritingInsightSnapshot(
            generatedAt: Date(),
            sampleCount: 3,
            analyzerName: "ChatGPT (Codex)",
            usedFallback: false,
            request: WritingInsightsRequest(timeRange: .days30, generationMode: .deep, appFilterMode: .allApps, selectedApps: []),
            summary: "You write in short bursts.",
            signals: [],
            patterns: [],
            strengths: [],
            opportunities: [],
            recommendations: []
        )
        _ = try db.saveWritingInsightSnapshot(snapshot)

        let loaded = try XCTUnwrap(db.fetchLatestWritingInsightSnapshot())
        XCTAssertEqual(loaded.analyzerName, "ChatGPT (Codex)")
        XCTAssertEqual(loaded.summary, snapshot.summary)
    }
}
