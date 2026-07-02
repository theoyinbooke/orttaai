// CloudSyncModels.swift
// Orttaai

import Foundation

enum CloudSyncTable: String, Codable, CaseIterable, Sendable {
    case transcription
    case dictionaryEntry = "dictionary_entry"
    case snippetEntry = "snippet_entry"
    case learningSuggestion = "learning_suggestion"
    case writingInsightSnapshot = "writing_insight_snapshot"

    var recordType: String {
        switch self {
        case .transcription: return "OrttaaiTranscription"
        case .dictionaryEntry: return "OrttaaiDictionaryEntry"
        case .snippetEntry: return "OrttaaiSnippetEntry"
        case .learningSuggestion: return "OrttaaiLearningSuggestion"
        case .writingInsightSnapshot: return "OrttaaiWritingInsightSnapshot"
        }
    }

    var displayName: String {
        switch self {
        case .transcription: return "History"
        case .dictionaryEntry: return "Dictionary"
        case .snippetEntry: return "Snippets"
        case .learningSuggestion: return "Suggestions"
        case .writingInsightSnapshot: return "Insights"
        }
    }
}

struct CloudSyncStats: Codable, Equatable, Sendable {
    var transcriptionCount: Int = 0
    var dictionaryCount: Int = 0
    var snippetCount: Int = 0
    var learningSuggestionCount: Int = 0
    var writingInsightCount: Int = 0
    var chatConversationCount: Int = 0
    var syncedPreferenceCount: Int = 0
    var latestModifiedAt: Date?

    var databaseItemCount: Int {
        transcriptionCount
            + dictionaryCount
            + snippetCount
            + learningSuggestionCount
            + writingInsightCount
    }

    var totalItemCount: Int {
        databaseItemCount + chatConversationCount + syncedPreferenceCount
    }

    var hasUserData: Bool {
        totalItemCount > 0
    }
}

struct CloudDatabaseSnapshot: Codable, Equatable, Sendable {
    var transcriptions: [CloudSyncTranscription] = []
    var dictionaryEntries: [CloudSyncDictionaryEntry] = []
    var snippetEntries: [CloudSyncSnippetEntry] = []
    var learningSuggestions: [CloudSyncLearningSuggestion] = []
    var writingInsightSnapshots: [CloudSyncWritingInsightSnapshot] = []
    var tombstones: [CloudSyncTombstone] = []

    var stats: CloudSyncStats {
        var stats = CloudSyncStats(
            transcriptionCount: transcriptions.count,
            dictionaryCount: dictionaryEntries.count,
            snippetCount: snippetEntries.count,
            learningSuggestionCount: learningSuggestions.count,
            writingInsightCount: writingInsightSnapshots.count
        )
        stats.latestModifiedAt = latestModifiedAt
        return stats
    }

    var latestModifiedAt: Date? {
        let dates = transcriptions.map(\.modifiedAt)
            + dictionaryEntries.map(\.modifiedAt)
            + snippetEntries.map(\.modifiedAt)
            + learningSuggestions.map(\.modifiedAt)
            + writingInsightSnapshots.map(\.modifiedAt)
            + tombstones.map(\.deletedAt)
        return dates.max()
    }
}

struct CloudFullSnapshot: Codable, Equatable, Sendable {
    var database: CloudDatabaseSnapshot
    var profile: CloudProfileSnapshot
    var capturedAt: Date

    var stats: CloudSyncStats {
        var stats = database.stats
        stats.chatConversationCount = profile.chatConversationCount
        stats.syncedPreferenceCount = profile.values.count
        if let profileModifiedAt = profile.modifiedAt {
            stats.latestModifiedAt = max(stats.latestModifiedAt ?? profileModifiedAt, profileModifiedAt)
        }
        return stats
    }
}

struct CloudSyncTranscription: Codable, Equatable, Sendable {
    var localID: Int64?
    var syncID: String
    var modifiedAt: Date
    var createdAt: Date
    var text: String
    var targetAppName: String?
    var targetAppBundleID: String?
    var recordingDurationMs: Int
    var processingDurationMs: Int
    var settingsSyncDurationMs: Int?
    var transcriptionDurationMs: Int?
    var textProcessingDurationMs: Int?
    var injectionDurationMs: Int?
    var appActivationDurationMs: Int?
    var clipboardRestoreDelayMs: Int?
    var modelId: String
    var audioDevice: String?
    // Optional for backward compatibility with payloads from older app versions.
    var sourceDeviceID: String?
}

struct CloudSyncDictionaryEntry: Codable, Equatable, Sendable {
    var localID: Int64?
    var syncID: String
    var modifiedAt: Date
    var source: String
    var target: String
    var normalizedSource: String
    var isCaseSensitive: Bool
    var isActive: Bool
    var usageCount: Int
    var createdAt: Date
    var updatedAt: Date
}

struct CloudSyncSnippetEntry: Codable, Equatable, Sendable {
    var localID: Int64?
    var syncID: String
    var modifiedAt: Date
    var trigger: String
    var expansion: String
    var normalizedTrigger: String
    var isActive: Bool
    var usageCount: Int
    var createdAt: Date
    var updatedAt: Date
}

struct CloudSyncLearningSuggestion: Codable, Equatable, Sendable {
    var localID: Int64?
    var syncID: String
    var modifiedAt: Date
    var type: String
    var candidateSource: String
    var candidateTarget: String
    var normalizedSource: String
    var confidence: Double
    var status: String
    var evidence: String?
    var createdAt: Date
    var updatedAt: Date
}

struct CloudSyncWritingInsightSnapshot: Codable, Equatable, Sendable {
    var localID: Int64?
    var syncID: String
    var modifiedAt: Date
    var generatedAt: Date
    var analyzerName: String
    var usedFallback: Bool
    var isPinned: Bool
    var sampleCount: Int
    var requestJSON: String
    var snapshotJSON: String
}

struct CloudSyncTombstone: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(table.rawValue):\(syncID)" }
    var table: CloudSyncTable
    var syncID: String
    var deletedAt: Date
}

enum UserDefaultsSyncValue: Codable, Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case data(Data)

    init?(object: Any) {
        switch object {
        case let value as String:
            self = .string(value)
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .int(value)
        case let value as Double:
            self = .double(value)
        case let value as Data:
            self = .data(value)
        default:
            return nil
        }
    }

    var object: Any {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .data(let value): return value
        }
    }
}

struct CloudProfileSnapshot: Codable, Equatable, Sendable {
    static let modifiedAtKey = "cloudSyncProfileModifiedAt"

    // Device-specific keys are intentionally NOT synced. Each Mac has different
    // hardware, downloaded models, and audio devices, so syncing these breaks the
    // receiving machine (e.g. Performance Health filtering by a model this device
    // never ran, or activating a model that isn't downloaded here):
    // selectedModelId, activeModelId, selectedAudioDeviceID, computeMode,
    // decodingWorkerCount, lowLatencyModeEnabled, fastFirstRecommendedModelId,
    // fastFirstPrefetchStarted/Ready/ErrorMessage, localLLMPolishModel,
    // localLLMInsightsModel, semanticEmbeddingModel.
    static let syncedUserDefaultsKeys: [String] = [
        "polishModeEnabled",
        "launchAtLogin",
        "hasCompletedSetup",
        "showProcessingEstimate",
        "homeWorkspaceAutoOpenEnabled",
        "spokenFormattingEnabled",
        "dictionaryEnabled",
        "snippetsEnabled",
        "aiSuggestionsEnabled",
        "fastFirstOnboardingEnabled",
        "fastFirstUpgradeDismissed",
        "githubStarPromptCompleted",
        "githubStarPromptShownCount",
        "githubStarPromptLastShownAtEpoch",
        "dictationLanguage",
        "maxRecordingDuration",
        "decodingPreset",
        "advancedDecodingEnabled",
        "decodingTemperature",
        "decodingTopK",
        "decodingFallbackCount",
        "decodingCompressionRatioThreshold",
        "decodingLogProbThreshold",
        "decodingNoSpeechThreshold",
        "localLLMPolishEnabled",
        "localLLMEndpoint",
        "localLLMPolishTimeoutMs",
        "localLLMPolishMaxChars",
        "localLLMInsightsEnabled",
        "localLLMInsightsContextTokens",
        "localLLMInsightsThinkingEnabled",
        "semanticMemoryEnabled",
        "semanticMemoryAutoIndexEnabled",
        "semanticEmbeddingFallbackEnabled",
        "modelSortMode",
        "homeSidebarCollapsed",
        "toneOfVoiceProfile",
        "chatAIConversations"
    ]

    var values: [String: UserDefaultsSyncValue]
    var modifiedAt: Date?

    var chatConversationCount: Int {
        guard case .data(let data)? = values["chatAIConversations"],
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return 0
        }
        return json.count
    }

    static func capture(defaults: UserDefaults = .standard, modifiedAt: Date = Date()) -> CloudProfileSnapshot {
        let values = capturedValues(defaults: defaults)
        let storedModifiedAt = defaults.double(forKey: modifiedAtKey)
        let resolvedModifiedAt = storedModifiedAt > 0
            ? Date(timeIntervalSince1970: storedModifiedAt)
            : modifiedAt
        return CloudProfileSnapshot(values: values, modifiedAt: resolvedModifiedAt)
    }

    static func capturedValues(defaults: UserDefaults = .standard) -> [String: UserDefaultsSyncValue] {
        var values: [String: UserDefaultsSyncValue] = [:]
        for key in syncedUserDefaultsKeys {
            guard let object = defaults.object(forKey: key),
                  let syncValue = UserDefaultsSyncValue(object: object) else {
                continue
            }
            values[key] = syncValue
        }
        return values
    }

    func apply(to defaults: UserDefaults = .standard) {
        CloudProfileChangeTracker.shared.performWithoutTracking {
            for key in Self.syncedUserDefaultsKeys where values[key] == nil {
                defaults.removeObject(forKey: key)
            }
            // Only apply listed keys: snapshots pushed by older app versions may
            // still carry device-specific keys that must not overwrite this Mac.
            let allowedKeys = Set(Self.syncedUserDefaultsKeys)
            for (key, value) in values where allowedKeys.contains(key) {
                defaults.set(value.object, forKey: key)
            }
            if let modifiedAt {
                defaults.set(modifiedAt.timeIntervalSince1970, forKey: Self.modifiedAtKey)
            }
            defaults.synchronize()
        }
    }
}

final class CloudProfileChangeTracker {
    static let shared = CloudProfileChangeTracker()

    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?
    private var baselineValues: [String: UserDefaultsSyncValue]
    private var isApplyingSnapshot = false
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.baselineValues = CloudProfileSnapshot.capturedValues(defaults: defaults)
    }

    func start() {
        lock.lock()
        guard observer == nil else {
            lock.unlock()
            return
        }
        baselineValues = CloudProfileSnapshot.capturedValues(defaults: defaults)
        let hasProfileValues = !baselineValues.isEmpty
        lock.unlock()

        if defaults.double(forKey: CloudProfileSnapshot.modifiedAtKey) <= 0, hasProfileValues {
            defaults.set(Date().timeIntervalSince1970, forKey: CloudProfileSnapshot.modifiedAtKey)
        }

        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: nil
        ) { [weak self] _ in
            self?.handleDefaultsChanged()
        }
    }

    func stop() {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
    }

    func performWithoutTracking(_ work: () -> Void) {
        lock.lock()
        isApplyingSnapshot = true
        lock.unlock()

        work()

        lock.lock()
        baselineValues = CloudProfileSnapshot.capturedValues(defaults: defaults)
        isApplyingSnapshot = false
        lock.unlock()
    }

    private func handleDefaultsChanged() {
        let currentValues = CloudProfileSnapshot.capturedValues(defaults: defaults)

        lock.lock()
        guard !isApplyingSnapshot else {
            lock.unlock()
            return
        }
        guard currentValues != baselineValues else {
            lock.unlock()
            return
        }
        baselineValues = currentValues
        lock.unlock()

        defaults.set(Date().timeIntervalSince1970, forKey: CloudProfileSnapshot.modifiedAtKey)
        CloudSyncScheduler.requestSync(reason: .profileChange)
    }
}
