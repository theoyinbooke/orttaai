// ModelTokenizerLocation.swift
// Orttaai

import Foundation

/// Where WhisperKit finds a model's tokenizer.
///
/// WhisperKit and swift-transformers store a model at
/// `<root>/models/argmaxinc/whisperkit-coreml/<variant>` and its tokenizer at
/// `<root>/models/openai/whisper-*`. Left to its defaults WhisperKit looks for
/// the tokenizer under `~/Documents/huggingface` whatever root the model lives
/// in, which touches Documents for a model stored elsewhere and downloads the
/// tokenizer when it is not there. Loading passes the model's own root instead.
nonisolated enum ModelTokenizerLocation {
    private static let repositoryComponents = ["models", "argmaxinc", "whisperkit-coreml"]
    private static let tokenizerFamilies: Set<String> = [
        "tiny", "tiny.en", "base", "base.en", "small", "small.en",
        "medium", "medium.en", "large", "large-v2", "large-v3",
    ]

    /// The root that holds `folder`. For a model inside the standard layout it
    /// is the root above `models/argmaxinc/whisperkit-coreml`; for any other
    /// layout (the legacy Application Support folder, Hugging Face hub
    /// snapshots) it is the folder that contains the model.
    static func tokenizerBase(forModelFolder folder: URL) -> URL {
        let standardized = folder.standardizedFileURL
        let components = standardized.pathComponents
        let variantIndex = components.count - 1
        guard variantIndex > repositoryComponents.count,
              Array(components[(variantIndex - repositoryComponents.count)..<variantIndex]) == repositoryComponents
        else {
            return standardized.deletingLastPathComponent()
        }

        var base = standardized
        for _ in 0...repositoryComponents.count {
            base = base.deletingLastPathComponent()
        }
        return base
    }

    /// The tokenizer repository WhisperKit selects for a model build ("openai/whisper-large-v3"
    /// for every large-v3 build, turbo and quantized included), or nil for
    /// families this mapping does not cover, such as distilled models.
    static func tokenizerRepositoryName(forModelID modelID: String) -> String? {
        let canonical = ModelManager.canonicalModelListID(modelID).lowercased()
        let prefix = "openai_whisper-"
        guard canonical.hasPrefix(prefix) else { return nil }

        let family = canonical.dropFirst(prefix.count)
            .split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        return tokenizerFamilies.contains(family) ? "openai/whisper-\(family)" : nil
    }

    /// Whether the model's tokenizer is on disk under the model's own root.
    /// Every place WhisperKit searches once given that root is checked, so a
    /// tokenizer it would have found is never reported missing. Families the
    /// id mapping does not cover cannot be verified and count as present.
    static func hasLocalTokenizer(
        modelID: String,
        modelFolder: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let derivedBase = tokenizerBase(forModelFolder: modelFolder)
        guard let repositoryName = tokenizerRepositoryName(forModelID: modelID) else {
            return true
        }

        let searchFolders = [
            derivedBase.appendingPathComponent("models/\(repositoryName)", isDirectory: true),
            derivedBase,
            modelFolder,
            modelFolder.appendingPathComponent("models/\(repositoryName)", isDirectory: true),
        ]
        return searchFolders.contains {
            fileManager.fileExists(atPath: $0.appendingPathComponent("tokenizer.json").path)
        }
    }
}
