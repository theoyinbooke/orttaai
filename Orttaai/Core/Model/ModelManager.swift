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
    private let settings: AppSettings

    /// The app-wide warm transcription service. Features like ChatAI voice
    /// input reuse it instead of owning a second copy of the Whisper model.
    var runtimeTranscriptionService: TranscriptionService { transcriptionService }
    private let downloader: ModelDownloader
    private let modelsDirectory: URL
    nonisolated private static let requiredModelComponents = [
        "MelSpectrogram",
        "AudioEncoder",
        "TextDecoder",
    ]

    init(
        transcriptionService: TranscriptionService,
        settings: AppSettings = AppSettings(),
        downloader: ModelDownloader = ModelDownloader()
    ) {
        self.transcriptionService = transcriptionService
        self.settings = settings
        self.downloader = downloader

        modelsDirectory = (try? AppStoragePaths.modelsDirectoryURL(createDirectory: true))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Orttaai/Models")

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
                // Skip families whose value is duplicated by a better option:
                // large-v2 is superseded by large-v3, and the distil variants
                // by the official large-v3 turbo (smaller and more accurate).
                let lowered = name.lowercased()
                guard !lowered.contains("large-v2"), !lowered.contains("distil") else { return nil }

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

            let deduplicatedModels = Self.deduplicateModelsByNormalizedID(models)
            availableModels = Self.sortModelsBySize(deduplicatedModels)
            Logger.model.info("Fetched \(models.count) available models (\(deduplicatedModels.count) unique)")
        } catch {
            Logger.model.error("Failed to fetch models, using hardcoded list: \(error.localizedDescription)")
            setupHardcodedModels()
        }
    }

    // MARK: - Model Operations

    func download(model: ModelInfo) async throws {
        let normalizedModelID = Self.normalizedModelID(model.id)
        let isAlreadyDownloaded = Self.detectDownloadedModelMetrics().downloadedModelIDs.contains(normalizedModelID)
        state = isAlreadyDownloaded ? .loading : .downloading(progress: 0)

        if isAlreadyDownloaded {
            Logger.model.info("Loading downloaded model: \(model.id)")
        } else {
            Logger.model.info("Starting download of model: \(model.id)")
        }

        do {
            await settings.syncTranscriptionSettings(to: transcriptionService)
            if !isAlreadyDownloaded {
                state = .loading
            }
            try await transcriptionService.loadModel(named: model.id)
            await transcriptionService.warmUp()
            currentModelId = model.id
            AppSettings().activeModelId = model.id
            state = .loaded
            Logger.model.info("Model loaded and warmed up: \(model.id)")

            if !isAlreadyDownloaded {
                ModelDownloader.postDownloadNotification(modelName: model.name)
            }
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
            await settings.syncTranscriptionSettings(to: transcriptionService)
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
        // Keep the exact variant id for the download target; the normalized
        // id (size suffix stripped) is only for matching existing entries.
        let exactModelId = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModelId = Self.normalizedModelID(exactModelId)

        if let available = availableModels.first(where: { Self.normalizedModelID($0.id) == normalizedModelId }) {
            try await switchModel(to: available)
            return
        }

        let support = WhisperKit.recommendedModels()
        let hardware = HardwareDetector.detect()
        let fallback = ModelInfo(
            id: exactModelId,
            name: formatDisplayName(exactModelId),
            downloadSizeMB: estimateSize(exactModelId),
            description: descriptionFor(exactModelId),
            minimumTier: tierFor(exactModelId, ramGB: hardware.ramGB),
            speedLabel: speedLabelFor(exactModelId),
            accuracyLabel: accuracyLabelFor(exactModelId),
            isDeviceRecommended: normalizedModelId == Self.normalizedModelID(support.default),
            isDeviceSupported: support.supported.map(Self.normalizedModelID).contains(normalizedModelId),
            isEnglishOnly: isEnglishOnly(exactModelId)
        )
        try await switchModel(to: fallback)
    }

    func deleteModel(named modelId: String) throws {
        // A list row represents a whole model family (quantized builds and
        // date-stamped aliases merged), so deleting it removes every variant
        // directory in that family — no orphaned duplicates left on disk.
        var removedAny = false
        let canonicalTargetID = Self.canonicalModelListID(modelId)
        let detectedMetrics = Self.detectDownloadedModelMetrics()
        for (detectedID, detectedModelDir) in detectedMetrics.modelDirectories
        where Self.canonicalModelListID(detectedID) == canonicalTargetID {
            if FileManager.default.fileExists(atPath: detectedModelDir.path) {
                try FileManager.default.removeItem(at: detectedModelDir)
                removedAny = true
            }
        }

        if FileManager.default.fileExists(atPath: modelsDirectory.path),
           let entries = try? FileManager.default.contentsOfDirectory(
               at: modelsDirectory,
               includingPropertiesForKeys: nil,
               options: [.skipsHiddenFiles]
           )
        {
            for entry in entries where Self.canonicalModelListID(entry.lastPathComponent) == canonicalTargetID {
                if FileManager.default.fileExists(atPath: entry.path) {
                    try FileManager.default.removeItem(at: entry)
                    removedAny = true
                }
            }
        }

        if Self.canonicalModelListID(currentModelId ?? "") == canonicalTargetID {
            currentModelId = nil
            state = .notDownloaded
        }
        if removedAny {
            Logger.model.info("Model family deleted: \(canonicalTargetID)")
        } else {
            Logger.model.info("No local model files found for: \(canonicalTargetID)")
        }
    }

    // MARK: - Private: Hardcoded Fallback

    private func setupHardcodedModels() {
        let deviceSupport = WhisperKit.recommendedModels()

        let supportedFamilies = Set(deviceSupport.supported.map(Self.canonicalModelListID))
        let defaultFamily = Self.canonicalModelListID(deviceSupport.default)

        availableModels = Self.sortModelsBySize([
            ModelInfo(
                id: "openai_whisper-large-v3-v20240930_626MB",
                name: "Whisper Large V3 Turbo",
                downloadSizeMB: 626,
                description: "Best accuracy, recommended for 16GB+ RAM",
                minimumTier: .m1_16gb,
                speedLabel: .moderate,
                accuracyLabel: .best,
                isDeviceRecommended: defaultFamily == "openai_whisper-large-v3_turbo",
                isDeviceSupported: supportedFamilies.contains("openai_whisper-large-v3_turbo"),
                isEnglishOnly: false
            ),
            ModelInfo(
                id: "openai_whisper-large-v3_947MB",
                name: "Whisper Large V3",
                downloadSizeMB: 947,
                description: "Highest accuracy, slowest",
                minimumTier: .m3_16gb,
                speedLabel: .slow,
                accuracyLabel: .best,
                isDeviceRecommended: defaultFamily == "openai_whisper-large-v3",
                isDeviceSupported: supportedFamilies.contains("openai_whisper-large-v3"),
                isEnglishOnly: false
            ),
            ModelInfo(
                id: "openai_whisper-small_216MB",
                name: "Whisper Small",
                downloadSizeMB: 216,
                description: "Good accuracy, works on 8GB RAM",
                minimumTier: .m1_8gb,
                speedLabel: .fast,
                accuracyLabel: .great,
                isDeviceRecommended: defaultFamily == "openai_whisper-small",
                isDeviceSupported: supportedFamilies.contains("openai_whisper-small"),
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

    nonisolated static func deduplicateModelsByNormalizedID(_ models: [ModelInfo]) -> [ModelInfo] {
        let grouped = Dictionary(grouping: models) { canonicalModelListID($0.id) }
        return grouped.compactMap { _, variants in
            guard !variants.isEmpty else { return nil }
            let preferred = preferredModelVariant(for: variants)

            return ModelInfo(
                id: preferred.id,
                name: preferred.name,
                // Show the size of the variant that will actually download,
                // not the smallest size across merged aliases.
                downloadSizeMB: preferred.downloadSizeMB,
                description: preferred.description,
                minimumTier: preferred.minimumTier,
                speedLabel: preferred.speedLabel,
                accuracyLabel: preferred.accuracyLabel,
                isDeviceRecommended: variants.contains(where: { $0.isDeviceRecommended }),
                isDeviceSupported: variants.contains(where: { $0.isDeviceSupported }),
                isEnglishOnly: variants.contains(where: { $0.isEnglishOnly })
            )
        }
    }

    /// Quantized (mixed-bit palettized) variants Argmax publishes alongside
    /// each full-precision model. Preferring these keeps accuracy within ~1%
    /// WER while cutting download size, RAM, and load time by 2-5x.
    nonisolated static let curatedDownloadVariants: [String: String] = [
        "openai_whisper-large-v3_turbo": "openai_whisper-large-v3-v20240930_626MB",
        "openai_whisper-large-v3": "openai_whisper-large-v3_947MB",
        "openai_whisper-small": "openai_whisper-small_216MB",
        "openai_whisper-small.en": "openai_whisper-small.en_217MB",
    ]

    nonisolated static func curatedDownloadVariantID(forFamily familyID: String) -> String? {
        curatedDownloadVariants[familyID]
    }

    nonisolated private static func preferredModelVariant(for variants: [ModelInfo]) -> ModelInfo {
        if let familyID = variants.first.map({ canonicalModelListID($0.id) }),
           let curatedID = curatedDownloadVariants[familyID],
           let curated = variants.first(where: { $0.id == curatedID }) {
            return curated
        }

        return variants.sorted { a, b in
            let aIsCanonical = canonicalModelListID(a.id) == a.id
            let bIsCanonical = canonicalModelListID(b.id) == b.id
            if aIsCanonical != bIsCanonical {
                return aIsCanonical
            }
            if a.isDeviceRecommended != b.isDeviceRecommended {
                return a.isDeviceRecommended
            }
            if a.downloadSizeMB != b.downloadSizeMB {
                return a.downloadSizeMB < b.downloadSizeMB
            }
            if a.id.count != b.id.count {
                return a.id.count < b.id.count
            }
            return a.id.localizedCaseInsensitiveCompare(b.id) == .orderedAscending
        }.first ?? variants[0]
    }

    nonisolated static func canonicalModelListID(_ modelId: String) -> String {
        var canonical = normalizedModelID(modelId)
        guard !canonical.isEmpty else { return canonical }

        // "openai_whisper-large-v3-v20240930" is the official large-v3-turbo
        // release (4 decoder layers), not a date-stamped alias of large-v3
        // (32 layers) — its whole subtree belongs to the turbo family.
        if canonical.lowercased().hasPrefix("openai_whisper-large-v3-v20240930") {
            return "openai_whisper-large-v3_turbo"
        }

        // Collapse date-stamped aliases such as "...-v20240930_turbo" to a stable family id.
        let dateTagPattern = #"([-_])v\d{8}(?=([-_]|$))"#
        if let regex = try? NSRegularExpression(pattern: dateTagPattern, options: [.caseInsensitive]) {
            let range = NSRange(canonical.startIndex..<canonical.endIndex, in: canonical)
            canonical = regex.stringByReplacingMatches(in: canonical, options: [], range: range, withTemplate: "$1")
        }

        while canonical.contains("__") { canonical = canonical.replacingOccurrences(of: "__", with: "_") }
        while canonical.contains("--") { canonical = canonical.replacingOccurrences(of: "--", with: "-") }
        canonical = canonical.replacingOccurrences(of: "_-", with: "-")
        canonical = canonical.replacingOccurrences(of: "-_", with: "-")
        canonical = canonical.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return canonical
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
        // Normalization strips quantized-variant size suffixes ("_626MB"), so
        // it is only safe for the already-downloaded check — downloading must
        // use the exact variant id or it silently fetches the full-size model.
        let exactModelId = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModelId = normalizedModelID(exactModelId)
        guard !normalizedModelId.isEmpty else {
            return .failed(message: "Missing model id.")
        }

        let downloadedModelIDs = Set(detectDownloadedModelMetrics().modelDirectories.keys)
        if downloadedModelIDs.contains(normalizedModelId) {
            return .alreadyAvailable
        }

        do {
            _ = try await WhisperKit.download(variant: exactModelId)
            return .downloaded
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    nonisolated private static func modelStorageRoots() -> [URL] {
        let fileManager = FileManager.default
        let appSupport = try? AppStoragePaths.applicationSupportRootURL()
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        let home = URL.homeDirectory

        let env = ProcessInfo.processInfo.environment
        var roots: [URL] = [
            appSupport?
                .appendingPathComponent(AppStoragePaths.applicationSupportFolderName)
                .appendingPathComponent("Models"),
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

    // MARK: - Model Metadata

    /// True for the fast 4-decoder-layer turbo family, whether named "_turbo"
    /// or via the official "v20240930" release id.
    nonisolated static func isTurboFamily(_ id: String) -> Bool {
        let lowered = id.lowercased()
        return lowered.contains("turbo") || lowered.contains("v20240930")
    }

    /// Parses an explicit size suffix like "_626MB" or "_1GB" from a variant id.
    nonisolated static func parsedSizeSuffixMB(_ id: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"_(\d+)(mb|gb)$"#, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(id.startIndex..<id.endIndex, in: id)
        guard let match = regex.firstMatch(in: id, options: [], range: range),
              let numberRange = Range(match.range(at: 1), in: id),
              let unitRange = Range(match.range(at: 2), in: id),
              let value = Int(id[numberRange]) else {
            return nil
        }
        return id[unitRange].lowercased() == "gb" ? value * 1024 : value
    }

    nonisolated static func formatDisplayName(_ id: String) -> String {
        // Variants display their family name: size/date suffixes describe the
        // build, not the model ("...-v20240930_626MB" → "Whisper Large V3 Turbo").
        var name = canonicalModelListID(id)
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

    private func formatDisplayName(_ id: String) -> String {
        Self.formatDisplayName(id)
    }

    /// Download size in MB. Exact for size-suffixed quantized variants;
    /// full-precision sizes measured from the WhisperKit Hugging Face repo.
    nonisolated static func estimateSize(_ id: String) -> Int {
        if let parsed = parsedSizeSuffixMB(id) { return parsed }

        let lowered = id.lowercased()
        if lowered.contains("tiny") { return 75 }
        if lowered.contains("base") { return 145 }
        if lowered.contains("small") { return 465 }
        if lowered.contains("medium") { return 1450 }
        if lowered.contains("distil") { return 1200 }
        if isTurboFamily(lowered) { return 1550 }
        if lowered.contains("large") { return 2950 }
        return 500 // Unknown
    }

    private func estimateSize(_ id: String) -> Int {
        Self.estimateSize(id)
    }

    private func descriptionFor(_ id: String) -> String {
        let lowered = id.lowercased()
        let eng = isEnglishOnly(id) ? " (English only)" : ""

        if lowered.contains("tiny") { return "Quick notes, commands\(eng)" }
        if lowered.contains("base") { return "Short dictation\(eng)" }
        if lowered.contains("small") { return "General dictation\(eng)" }
        if lowered.contains("medium") { return "Longer dictation\(eng)" }
        if Self.isTurboFamily(lowered) { return "Maximum accuracy, optimized speed\(eng)" }
        if lowered.contains("large") { return "Highest accuracy, slowest\(eng)" }
        if lowered.contains("distil") { return "Distilled variant, fast\(eng)" }
        return "WhisperKit model\(eng)"
    }

    private func tierFor(_ id: String, ramGB: Int = 16) -> HardwareTier {
        let lowered = id.lowercased()
        if lowered.contains("tiny") || lowered.contains("base") || lowered.contains("small") {
            return .m1_8gb
        }
        if lowered.contains("medium") || Self.isTurboFamily(lowered) {
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
        if lowered.contains("medium") || Self.isTurboFamily(lowered) { return .moderate }
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
        let withoutSizeSuffix = Self.normalizedModelID(lowered)
        return withoutSizeSuffix.hasSuffix(".en") || withoutSizeSuffix.hasSuffix("-en") || withoutSizeSuffix.hasSuffix("_en")
    }
}
