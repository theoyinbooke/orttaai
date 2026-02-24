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

struct DownloadedModelMetrics: Sendable {
    let modelDirectories: [String: URL]
    let totalBytes: Int64

    var downloadedModelIDs: Set<String> {
        Set(modelDirectories.keys)
    }
}

enum ModelPrefetchOutcome: Sendable, Equatable {
    case alreadyAvailable
    case downloaded
    case failed(message: String)
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
    nonisolated private static let requiredModelComponents = [
        "MelSpectrogram",
        "AudioEncoder",
        "TextDecoder",
    ]

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

            let models = allModelNames.compactMap { name -> ModelInfo? in
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

            availableModels = Self.sortModelsBySize(models)
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
            AppSettings().activeModelId = model.id
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
            AppSettings().activeModelId = modelId
            state = .loaded
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    func switchModel(to model: ModelInfo) async throws {
        AppSettings().activeModelId = ""
        await transcriptionService.unloadModel()
        currentModelId = model.id
        try await download(model: model)
    }

    func switchModel(toModelId modelId: String) async throws {
        let normalizedModelId = Self.normalizedModelID(modelId)

        if let available = availableModels.first(where: { Self.normalizedModelID($0.id) == normalizedModelId }) {
            try await switchModel(to: available)
            return
        }

        let support = WhisperKit.recommendedModels()
        let hardware = HardwareDetector.detect()
        let fallback = ModelInfo(
            id: normalizedModelId,
            name: formatDisplayName(normalizedModelId),
            downloadSizeMB: estimateSize(normalizedModelId),
            description: descriptionFor(normalizedModelId),
            minimumTier: tierFor(normalizedModelId, ramGB: hardware.ramGB),
            speedLabel: speedLabelFor(normalizedModelId),
            accuracyLabel: accuracyLabelFor(normalizedModelId),
            isDeviceRecommended: normalizedModelId == Self.normalizedModelID(support.default),
            isDeviceSupported: support.supported.map(Self.normalizedModelID).contains(normalizedModelId),
            isEnglishOnly: isEnglishOnly(normalizedModelId)
        )
        try await switchModel(to: fallback)
    }

    func deleteModel(named modelId: String) throws {
        var removedAny = false
        let normalizedTargetID = Self.normalizedModelID(modelId)
        let detectedMetrics = Self.detectDownloadedModelMetrics()
        if let detectedModelDir = detectedMetrics.modelDirectories[normalizedTargetID],
           FileManager.default.fileExists(atPath: detectedModelDir.path)
        {
            try FileManager.default.removeItem(at: detectedModelDir)
            removedAny = true
        }

        let appSupportModelDir = modelsDirectory.appendingPathComponent(normalizedTargetID)
        if FileManager.default.fileExists(atPath: appSupportModelDir.path) {
            try FileManager.default.removeItem(at: appSupportModelDir)
            removedAny = true
        }

        if FileManager.default.fileExists(atPath: modelsDirectory.path),
           let entries = try? FileManager.default.contentsOfDirectory(
               at: modelsDirectory,
               includingPropertiesForKeys: nil,
               options: [.skipsHiddenFiles]
           )
        {
            for entry in entries where Self.normalizedModelID(entry.lastPathComponent) == normalizedTargetID {
                if FileManager.default.fileExists(atPath: entry.path) {
                    try FileManager.default.removeItem(at: entry)
                    removedAny = true
                }
            }
        }

        if Self.normalizedModelID(currentModelId ?? "") == normalizedTargetID {
            currentModelId = nil
            state = .notDownloaded
        }
        if removedAny {
            Logger.model.info("Model deleted: \(normalizedTargetID)")
        } else {
            Logger.model.info("No local model files found for: \(normalizedTargetID)")
        }
    }

    // MARK: - Private: Hardcoded Fallback

    private func setupHardcodedModels() {
        let deviceSupport = WhisperKit.recommendedModels()

        availableModels = Self.sortModelsBySize([
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
        ])
    }

    private func checkExistingModels() {
        state = Self.detectDownloadedModelMetrics().downloadedModelIDs.isEmpty ? .notDownloaded : .downloaded
    }

    nonisolated static func sortModelsBySize(_ models: [ModelInfo]) -> [ModelInfo] {
        models.sorted { a, b in
            if a.downloadSizeMB != b.downloadSizeMB {
                return a.downloadSizeMB < b.downloadSizeMB
            }
            if a.name != b.name {
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            return a.id < b.id
        }
    }

    nonisolated static func sortModelsByRecommendation(_ models: [ModelInfo]) -> [ModelInfo] {
        models.sorted { a, b in
            if a.isDeviceRecommended != b.isDeviceRecommended {
                return a.isDeviceRecommended
            }
            if a.isDeviceSupported != b.isDeviceSupported {
                return a.isDeviceSupported
            }
            if a.downloadSizeMB != b.downloadSizeMB {
                return a.downloadSizeMB < b.downloadSizeMB
            }
            if a.name != b.name {
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            return a.id < b.id
        }
    }

    nonisolated static func normalizedModelID(_ modelId: String) -> String {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let pattern = #"_\d+(mb|gb)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return trimmed
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        if let match = regex.firstMatch(in: trimmed, options: [], range: range),
           match.range.location != NSNotFound,
           let swiftRange = Range(match.range, in: trimmed),
           swiftRange.upperBound == trimmed.endIndex
        {
            return String(trimmed[..<swiftRange.lowerBound])
        }
        return trimmed
    }

    nonisolated static func detectDownloadedModelMetrics(in roots: [URL]? = nil) -> DownloadedModelMetrics {
        let modelRoots = roots ?? modelStorageRoots()
        let downloadedDirectories = detectDownloadedModelDirectories(in: modelRoots)
        let totalBytes = downloadedDirectories.values.reduce(Int64(0)) { total, directory in
            total + directoryByteSize(directory)
        }
        return DownloadedModelMetrics(modelDirectories: downloadedDirectories, totalBytes: totalBytes)
    }

    nonisolated static func prefetchModelIfNeeded(_ modelId: String) async -> ModelPrefetchOutcome {
        let normalizedModelId = normalizedModelID(modelId)
        guard !normalizedModelId.isEmpty else {
            return .failed(message: "Missing model id.")
        }

        let downloadedModelIDs = Set(detectDownloadedModelMetrics().modelDirectories.keys)
        if downloadedModelIDs.contains(normalizedModelId) {
            return .alreadyAvailable
        }

        do {
            _ = try await WhisperKit.download(variant: normalizedModelId)
            return .downloaded
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    nonisolated private static func modelStorageRoots() -> [URL] {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        let home = URL.homeDirectory

        let env = ProcessInfo.processInfo.environment
        var roots: [URL] = [
            appSupport?.appendingPathComponent("Orttaai/Models"),
            documents?.appendingPathComponent("huggingface"),
            home.appendingPathComponent(".cache/huggingface"),
            home.appendingPathComponent("Library/Caches/huggingface"),
        ].compactMap { $0 }

        if let hfHome = env["HF_HOME"], !hfHome.isEmpty {
            roots.append(URL(fileURLWithPath: hfHome))
        }
        if let hfHubCache = env["HF_HUB_CACHE"], !hfHubCache.isEmpty {
            roots.append(URL(fileURLWithPath: hfHubCache))
        }

        var dedupedRoots: [URL] = []
        var seenPaths = Set<String>()
        for root in roots {
            if seenPaths.insert(root.path).inserted {
                dedupedRoots.append(root)
            }
        }
        return dedupedRoots
    }

    nonisolated private static func detectDownloadedModelDirectories(in roots: [URL]) -> [String: URL] {
        let fileManager = FileManager.default
        var downloadedDirectories: [String: URL] = [:]

        for root in roots where fileManager.fileExists(atPath: root.path) {
            if root.lastPathComponent.hasPrefix("openai_whisper-"), isValidModelDirectory(root) {
                insertDownloadedModelDirectory(root, into: &downloadedDirectories)
            }

            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { continue }

                let modelID = url.lastPathComponent
                guard modelID.hasPrefix("openai_whisper-") else { continue }

                if isValidModelDirectory(url) {
                    insertDownloadedModelDirectory(url, into: &downloadedDirectories)
                    enumerator.skipDescendants()
                }
            }
        }

        return downloadedDirectories
    }

    nonisolated private static func insertDownloadedModelDirectory(
        _ directoryURL: URL,
        into downloadedDirectories: inout [String: URL]
    ) {
        let rawID = directoryURL.lastPathComponent
        let normalizedID = normalizedModelID(rawID)
        if normalizedID.isEmpty {
            return
        }

        guard let existing = downloadedDirectories[normalizedID] else {
            downloadedDirectories[normalizedID] = directoryURL
            return
        }

        // Prefer canonical model directories over size-suffixed aliases.
        let existingIsCanonical = existing.lastPathComponent == normalizedID
        let candidateIsCanonical = rawID == normalizedID
        if candidateIsCanonical && !existingIsCanonical {
            downloadedDirectories[normalizedID] = directoryURL
        }
    }

    nonisolated private static func isValidModelDirectory(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        return requiredModelComponents.allSatisfy { component in
            let compiledModelPath = directory.appendingPathComponent("\(component).mlmodelc").path
            let packageModelPath = directory
                .appendingPathComponent("\(component).mlpackage/Data/com.apple.CoreML/model.mlmodel")
                .path
            return fileManager.fileExists(atPath: compiledModelPath) || fileManager.fileExists(atPath: packageModelPath)
        }
    }

    nonisolated private static func directoryByteSize(_ directory: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total = Int64(0)
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
            )
            guard values?.isRegularFile == true else { continue }
            let fileBytes = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? values?.fileSize ?? 0
            total += Int64(fileBytes)
        }
        return total
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
