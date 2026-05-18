// AppStoragePaths.swift
// Orttaai

import Foundation

enum AppStoragePaths {
    static var applicationSupportFolderName: String {
        isDebugBuild ? "Orttaai Debug" : "Orttaai"
    }

    static var backupFolderName: String {
        isDebugBuild ? "Orttaai Debug Backups" : "Orttaai Backups"
    }

    static var defaultBundleIdentifier: String {
        isDebugBuild ? "com.orttaai.Orttaai.debug" : "com.orttaai.Orttaai"
    }

    static var currentBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? defaultBundleIdentifier
    }

    static func applicationSupportRootURL() throws -> URL {
        guard let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw NSError(
                domain: "com.orttaai.storage",
                code: 100,
                userInfo: [NSLocalizedDescriptionKey: "Unable to locate Application Support."]
            )
        }

        return appSupportURL
    }

    static func applicationSupportURL(createDirectory: Bool = true) throws -> URL {
        let appSupportURL = try applicationSupportRootURL()
            .appendingPathComponent(applicationSupportFolderName, isDirectory: true)

        if createDirectory {
            try FileManager.default.createDirectory(
                at: appSupportURL,
                withIntermediateDirectories: true
            )
        }

        return appSupportURL
    }

    static func backupDirectoryURL(createDirectory: Bool = true) throws -> URL {
        let backupURL = try applicationSupportRootURL()
            .appendingPathComponent(backupFolderName, isDirectory: true)

        if createDirectory {
            try FileManager.default.createDirectory(
                at: backupURL,
                withIntermediateDirectories: true
            )
        }

        return backupURL
    }

    static func modelsDirectoryURL(createDirectory: Bool = false) throws -> URL {
        let modelsURL = try applicationSupportURL(createDirectory: createDirectory)
            .appendingPathComponent("Models", isDirectory: true)

        if createDirectory {
            try FileManager.default.createDirectory(
                at: modelsURL,
                withIntermediateDirectories: true
            )
        }

        return modelsURL
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
