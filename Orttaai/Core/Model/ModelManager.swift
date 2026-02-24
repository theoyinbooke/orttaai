// ModelManager.swift
// Orttaai

import Foundation
import WhisperKit
import os

enum ModelState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case loading
    case loaded
    case error(String)

    static func == (lhs: ModelState, rhs: ModelState) -> Bool {
        switch (lhs, rhs) {
        case (.notDownloaded, .notDownloaded),
             (.downloaded, .downloaded),
             (.loading, .loading),
             (.loaded, .loaded):
            return true
        case (.downloading(let a), .downloading(let b)):
            return a == b
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

enum SpeedLabel: String, Sendable {
    case fastest = "Fastest"
    case fast = "Fast"
    case moderate = "Moderate"
    case slow = "Slow"
}

enum AccuracyLabel: String, Sendable {
    case basic = "Basic"
    case good = "Good"
    case great = "Great"
    case best = "Best"
}

struct ModelInfo: Identifiable {
    let id: String
    let name: String
    let downloadSizeMB: Int
    let description: String
    let minimumTier: HardwareTier
    let speedLabel: SpeedLabel
    let accuracyLabel: AccuracyLabel
    let isDeviceRecommended: Bool
    let isDeviceSupported: Bool
    let isEnglishOnly: Bool
}

@Observable
final class ModelManager {
    /// Set by AppDelegate after initialization so views can access the shared instance.
    static var shared: ModelManager?

    private(set) var state: ModelState = .notDownloaded
    private(set) var currentModelId: String?
    private(set) var availableModels: [ModelInfo] = []
    private(set) var isFetchingModels: Bool = false
    private(set) var switchError: String?

    private let transcriptionService: TranscriptionService
    private let downloader: ModelDownloader
    private let modelsDirectory: URL

    init(
        transcriptionService: TranscriptionService,
        downloader: ModelDownloader = ModelDownloader()
    ) {
        self.transcriptionService = transcriptionService
        self.downloader = downloader

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        modelsDirectory = appSupport.appendingPathComponent("Orttaai/Models")

        setupHardcodedModels()
        checkExistingModels()
    }

    // MARK: - Model Fetching

    func fetchModels() async {
        isFetchingModels = true
        defer { isFetchingModels = false }

        do {
            let allModelNames = try await WhisperKit.fetchAvailableModels()
            let deviceSupport = WhisperKit.recommendedModels()
            let hardware = HardwareDetector.detect()

            var models = allModelNames.compactMap { name -> ModelInfo? in
                // Skip internal/test variants
                guard !name.contains("test") else { return nil }

                return ModelInfo(
                    id: name,
                    name: formatDisplayName(name),
                    downloadSizeMB: estimateSize(name),
                    description: descriptionFor(name),
                    minimumTier: tierFor(name, ramGB: hardware.ramGB),
                    speedLabel: speedLabelFor(name),
                    accuracyLabel: accuracyLabelFor(name),
                    isDeviceRecommended: name == deviceSupport.default,
                    isDeviceSupported: deviceSupport.supported.contains(name),
                    isEnglishOnly: isEnglishOnly(name)
                )
            }

            // Sort: recommended first, then supported, then by size ascending
            models.sort { a, b in
                if a.isDeviceRecommended != b.isDeviceRecommended {
                    return a.isDeviceRecommended
                }
                if a.isDeviceSupported != b.isDeviceSupported {
                    return a.isDeviceSupported
                }
                return a.downloadSizeMB < b.downloadSizeMB
            }

            availableModels = models
            Logger.model.info("Fetched \(models.count) available models")
        } catch {
            Logger.model.error("Failed to fetch models, using hardcoded list: \(error.localizedDescription)")
            setupHardcodedModels()
        }
    }

    // MARK: - Model Operations

    func download(model: ModelInfo) async throws {
        state = .downloading(progress: 0)

        Logger.model.info("Starting download of model: \(model.id)")

        do {
            state = .loading
            try await transcriptionService.loadModel(named: model.id)
            currentModelId = model.id
            state = .loaded
            Logger.model.info("Model loaded: \(model.id)")

            ModelDownloader.postDownloadNotification(modelName: model.name)
        } catch {
            state = .error(error.localizedDescription)
            Logger.model.error("Model download/load failed: \(error.localizedDescription)")
            throw error
        }
    }

    func loadModel() async throws {
        guard let modelId = currentModelId else {
            throw OrttaaiError.modelNotLoaded
        }

        state = .loading
        do {
            try await transcriptionService.loadModel(named: modelId)
            state = .loaded
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    func switchModel(to model: ModelInfo) async throws {
        await transcriptionService.unloadModel()
        currentModelId = model.id
        try await download(model: model)
    }

    func deleteModel(named modelId: String) throws {
        let modelDir = modelsDirectory.appendingPathComponent(modelId)
        if FileManager.default.fileExists(atPath: modelDir.path) {
            try FileManager.default.removeItem(at: modelDir)
        }
        if currentModelId == modelId {
            currentModelId = nil
            state = .notDownloaded
        }
        Logger.model.info("Model deleted: \(modelId)")
    }

    // MARK: - Private: Hardcoded Fallback

    private func setupHardcodedModels() {
        let deviceSupport = WhisperKit.recommendedModels()

        availableModels = [
            ModelInfo(
                id: "openai_whisper-large-v3_turbo",
                name: "Whisper Large V3 Turbo",
                downloadSizeMB: 950,
                description: "Best accuracy, recommended for 16GB+ RAM",
                minimumTier: .m1_16gb,
                speedLabel: .moderate,
                accuracyLabel: .best,
                isDeviceRecommended: "openai_whisper-large-v3_turbo" == deviceSupport.default,
                isDeviceSupported: deviceSupport.supported.contains("openai_whisper-large-v3_turbo"),
                isEnglishOnly: false
            ),
            ModelInfo(
                id: "openai_whisper-small",
                name: "Whisper Small",
                downloadSizeMB: 300,
                description: "Good accuracy, works on 8GB RAM",
                minimumTier: .m1_8gb,
                speedLabel: .fast,
                accuracyLabel: .great,
                isDeviceRecommended: "openai_whisper-small" == deviceSupport.default,
                isDeviceSupported: deviceSupport.supported.contains("openai_whisper-small"),
                isEnglishOnly: false
            ),
        ]
    }

    private func checkExistingModels() {
        guard FileManager.default.fileExists(atPath: modelsDirectory.path) else {
            state = .notDownloaded
            return
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: modelsDirectory.path)
            if !contents.isEmpty {
                state = .downloaded
            }
        } catch {
            Logger.model.error("Failed to check models directory: \(error.localizedDescription)")
        }
    }

    // MARK: - Private: Model Metadata

    private func formatDisplayName(_ id: String) -> String {
        // "openai_whisper-large-v3_turbo" → "Whisper Large V3 Turbo"
        var name = id
            .replacingOccurrences(of: "openai_whisper-", with: "Whisper ")
            .replacingOccurrences(of: "openai_whisper_", with: "Whisper ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        // Capitalize words
        name = name.split(separator: " ")
            .map { word in
                let w = String(word)
                // Keep version markers (v1, v2, v3) and size abbreviations as-is
                if w.hasPrefix("v") && w.count <= 3 { return w.uppercased() }
                if w == "en" { return "(English)" }
                return w.prefix(1).uppercased() + w.dropFirst()
            }
            .joined(separator: " ")

        return name
    }

    private func estimateSize(_ id: String) -> Int {
        let lowered = id.lowercased()
        if lowered.contains("tiny") { return 70 }
        if lowered.contains("base") { return 140 }
        if lowered.contains("small") { return 300 }
        if lowered.contains("medium") { return 770 }
        if lowered.contains("large") && lowered.contains("turbo") { return 950 }
        if lowered.contains("large") { return 1500 }
        if lowered.contains("distil") { return 400 }
        return 500 // Unknown
    }

    private func descriptionFor(_ id: String) -> String {
        let lowered = id.lowercased()
        let eng = isEnglishOnly(id) ? " (English only)" : ""

        if lowered.contains("tiny") { return "Quick notes, commands\(eng)" }
        if lowered.contains("base") { return "Short dictation\(eng)" }
        if lowered.contains("small") { return "General dictation\(eng)" }
        if lowered.contains("medium") { return "Longer dictation\(eng)" }
        if lowered.contains("large") && lowered.contains("turbo") { return "Maximum accuracy, optimized speed\(eng)" }
        if lowered.contains("large") { return "Highest accuracy, slowest\(eng)" }
        if lowered.contains("distil") { return "Distilled variant, fast\(eng)" }
        return "WhisperKit model\(eng)"
    }

    private func tierFor(_ id: String, ramGB: Int = 16) -> HardwareTier {
        let lowered = id.lowercased()
        if lowered.contains("tiny") || lowered.contains("base") || lowered.contains("small") {
            return .m1_8gb
        }
        if lowered.contains("medium") || (lowered.contains("large") && lowered.contains("turbo")) {
            return .m1_16gb
        }
        if lowered.contains("large") {
            return .m3_16gb
        }
        return .m1_8gb
    }

    private func speedLabelFor(_ id: String) -> SpeedLabel {
        let lowered = id.lowercased()
        if lowered.contains("tiny") { return .fastest }
        if lowered.contains("base") || lowered.contains("small") || lowered.contains("distil") { return .fast }
        if lowered.contains("medium") || (lowered.contains("large") && lowered.contains("turbo")) { return .moderate }
        if lowered.contains("large") { return .slow }
        return .moderate
    }

    private func accuracyLabelFor(_ id: String) -> AccuracyLabel {
        let lowered = id.lowercased()
        if lowered.contains("tiny") { return .basic }
        if lowered.contains("base") || lowered.contains("distil") { return .good }
        if lowered.contains("small") || lowered.contains("medium") { return .great }
        if lowered.contains("large") { return .best }
        return .good
    }

    private func isEnglishOnly(_ id: String) -> Bool {
        let lowered = id.lowercased()
        return lowered.hasSuffix(".en") || lowered.hasSuffix("-en") || lowered.hasSuffix("_en")
    }
}
