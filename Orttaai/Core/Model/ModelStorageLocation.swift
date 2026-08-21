// ModelStorageLocation.swift
// Orttaai

import Foundation

nonisolated struct ModelStorageSnapshot: Sendable, Equatable {
    let url: URL
    let isCustom: Bool
    let isAvailable: Bool
    let isWritable: Bool
}

/// Keeps a user-approved model folder accessible for the lifetime of a
/// WhisperKit download or loaded Core ML model.
nonisolated final class ModelStorageAccess: @unchecked Sendable {
    let url: URL

    private let didStartSecurityScope: Bool

    init(url: URL, startsSecurityScope: Bool) {
        self.url = url
        didStartSecurityScope = startsSecurityScope
    }

    deinit {
        if didStartSecurityScope {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

nonisolated enum ModelStorageLocation {
    static let customPathKey = "modelStorageCustomPath"
    static let customBookmarkKey = "modelStorageCustomBookmark"
    static let didChangeNotification = Notification.Name("ModelStorageLocationDidChange")

    static func defaultDownloadBaseURL(fileManager: FileManager = .default) -> URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        // This is swift-transformers/WhisperKit's existing default, and is the
        // conventional library Reelmify already knows how to share.
        return documents.appendingPathComponent("huggingface", isDirectory: true).standardizedFileURL
    }

    static func selectedDownloadBaseURL(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> URL {
        resolvedCustomURL(defaults: defaults) ?? defaultDownloadBaseURL(fileManager: fileManager)
    }

    static func snapshot(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> ModelStorageSnapshot {
        let isCustom = defaults.string(forKey: customPathKey) != nil
            || defaults.data(forKey: customBookmarkKey) != nil
        let url = selectedDownloadBaseURL(defaults: defaults, fileManager: fileManager)
        let didAccess = isCustom ? url.startAccessingSecurityScopedResource() : false
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isCustom {
            return ModelStorageSnapshot(
                url: url,
                isCustom: true,
                isAvailable: exists && isDirectory.boolValue,
                isWritable: exists && isDirectory.boolValue && fileManager.isWritableFile(atPath: url.path)
            )
        }

        let parent = url.deletingLastPathComponent()
        let parentIsWritable = fileManager.isWritableFile(atPath: parent.path)
        return ModelStorageSnapshot(
            url: url,
            isCustom: false,
            isAvailable: (!exists || isDirectory.boolValue) && parentIsWritable,
            isWritable: (!exists || isDirectory.boolValue) && parentIsWritable
        )
    }

    static func setCustomLocation(
        _ url: URL,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ModelStorageLocationError.folderMissing(standardized.path)
        }

        let didAccess = standardized.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                standardized.stopAccessingSecurityScopedResource()
            }
        }

        try verifyWritableDirectory(standardized, fileManager: fileManager)
        let bookmark = try standardized.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        defaults.set(standardized.path, forKey: customPathKey)
        defaults.set(bookmark, forKey: customBookmarkKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func resetToDefault(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: customPathKey)
        defaults.removeObject(forKey: customBookmarkKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func beginAccess(
        createIfNeeded: Bool,
        requiresWrite: Bool,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws -> ModelStorageAccess {
        let isCustom = defaults.string(forKey: customPathKey) != nil
            || defaults.data(forKey: customBookmarkKey) != nil
        let url = selectedDownloadBaseURL(defaults: defaults, fileManager: fileManager)
        let didAccess = isCustom ? url.startAccessingSecurityScopedResource() : false
        let access = ModelStorageAccess(url: url, startsSecurityScope: didAccess)

        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists && !isDirectory.boolValue {
            throw ModelStorageLocationError.notDirectory(url.path)
        }
        if !exists {
            guard createIfNeeded && !isCustom else {
                throw ModelStorageLocationError.folderMissing(url.path)
            }
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw ModelStorageLocationError.cannotCreate(url.path, error.localizedDescription)
            }
        }
        if requiresWrite {
            try verifyWritableDirectory(url, fileManager: fileManager)
        }
        return access
    }

    static func contains(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private static func resolvedCustomURL(defaults: UserDefaults) -> URL? {
        if let bookmark = defaults.data(forKey: customBookmarkKey) {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                let standardized = resolved.standardizedFileURL
                if isStale,
                   let refreshed = try? standardized.bookmarkData(
                       options: [.withSecurityScope],
                       includingResourceValuesForKeys: nil,
                       relativeTo: nil
                   ) {
                    defaults.set(refreshed, forKey: customBookmarkKey)
                }
                return standardized
            }
        }

        guard let path = defaults.string(forKey: customPathKey), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private static func verifyWritableDirectory(_ url: URL, fileManager: FileManager) throws {
        guard fileManager.isWritableFile(atPath: url.path) else {
            throw ModelStorageLocationError.notWritable(url.path)
        }

        let probeURL = url.appendingPathComponent(".orttaai-write-probe-\(UUID().uuidString)")
        do {
            try Data([0]).write(to: probeURL, options: .withoutOverwriting)
            try fileManager.removeItem(at: probeURL)
        } catch {
            try? fileManager.removeItem(at: probeURL)
            throw ModelStorageLocationError.notWritable(url.path)
        }
    }
}

nonisolated enum ModelStorageLocationError: LocalizedError, Equatable {
    case folderMissing(String)
    case notDirectory(String)
    case notWritable(String)
    case cannotCreate(String, String)

    var errorDescription: String? {
        switch self {
        case .folderMissing(let path):
            return "The model folder is unavailable at \(path). Reconnect the drive or choose another folder."
        case .notDirectory(let path):
            return "The selected model location is not a folder: \(path)"
        case .notWritable(let path):
            return "OrttaAI cannot write to \(path). Choose a writable folder."
        case .cannotCreate(let path, let detail):
            return "OrttaAI could not create the model folder at \(path). \(detail)"
        }
    }
}
