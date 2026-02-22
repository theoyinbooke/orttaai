// ModelManager.swift
// Uttrai

import Foundation
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

struct ModelInfo: Identifiable {
    let id: String
    let name: String
    let downloadSizeMB: Int
    let description: String
    let minimumTier: HardwareTier
}

@Observable
final class ModelManager {
    private(set) var state: ModelState = .notDownloaded
    private(set) var currentModelId: String?
    private(set) var availableModels: [ModelInfo] = []

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
        modelsDirectory = appSupport.appendingPathComponent("Uttrai/Models")

        setupAvailableModels()
        checkExistingModels()
    }

    func download(model: ModelInfo) async throws {
        state = .downloading(progress: 0)

        // WhisperKit handles model downloads internally, but we track the state
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
            throw UttraiError.modelNotLoaded
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

    // MARK: - Private

    private func setupAvailableModels() {
        availableModels = [
            ModelInfo(
                id: "openai_whisper-large-v3_turbo",
                name: "Whisper Large V3 Turbo",
                downloadSizeMB: 950,
                description: "Best accuracy, recommended for 16GB+ RAM",
                minimumTier: .m1_16gb
            ),
            ModelInfo(
                id: "openai_whisper-small",
                name: "Whisper Small",
                downloadSizeMB: 300,
                description: "Good accuracy, works on 8GB RAM",
                minimumTier: .m1_8gb
            ),
        ]
    }

    private func checkExistingModels() {
        // Check if models directory exists and has content
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
}
