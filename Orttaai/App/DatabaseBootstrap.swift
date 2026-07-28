// DatabaseBootstrap.swift
// Orttaai

import Foundation
import os

/// Startup recovery ladder for the local database. The app must never launch
/// into a silently broken state: either the store opens (possibly after
/// recovery), or the caller gets a failure it must surface to the user.
enum DatabaseBootstrap {

    enum Outcome<Store> {
        case ready(Store, recoveryApplied: RecoveryStep?)
        case failed(message: String)
    }

    enum RecoveryStep: String, Equatable {
        /// A plain second attempt succeeded (transient failure at first open).
        case retried
        /// The store was sidelined (kept on disk) and a fresh one was created.
        case sidelinedCorruptStore
    }

    /// Attempts to open the store, retrying once for transient failures, then
    /// sidelining a corrupt store (preserving it on disk) and starting fresh.
    /// `create` and `sidelineStore` are injected so tests can drive every
    /// branch of the real decision logic.
    static func bootstrap<Store>(
        create: () throws -> Store,
        sidelineStore: (Error) -> Bool
    ) -> Outcome<Store> {
        let firstError: Error
        do {
            return .ready(try create(), recoveryApplied: nil)
        } catch {
            firstError = error
        }

        // Transient failures (file lock, momentary I/O) often clear on retry.
        if let store = try? create() {
            return .ready(store, recoveryApplied: .retried)
        }

        // Persistent failure: sideline the (likely corrupt) store and recreate.
        guard sidelineStore(firstError) else {
            return .failed(message: firstError.localizedDescription)
        }

        do {
            return .ready(try create(), recoveryApplied: .sidelinedCorruptStore)
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    /// Moves the default database file aside with a timestamped `.corrupt`
    /// suffix so a fresh store can be created without destroying user data.
    /// Returns false when there is nothing to sideline or the move failed.
    static func sidelineDefaultDatabase() -> Bool {
        do {
            let databaseURL = try DatabaseManager.defaultDatabaseURL(createDirectory: false)
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: databaseURL.path) else {
                return false
            }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let sidelinedURL = databaseURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(formatter.string(from: Date())).db")

            try fileManager.moveItem(at: databaseURL, to: sidelinedURL)
            // SQLite sidecar files must move with the store or the fresh
            // database would replay the old WAL.
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
                if fileManager.fileExists(atPath: sidecar.path) {
                    try? fileManager.moveItem(
                        at: sidecar,
                        to: URL(fileURLWithPath: sidelinedURL.path + suffix)
                    )
                }
            }

            Logger.database.error(
                "Sidelined unreadable database to \(sidelinedURL.lastPathComponent, privacy: .public)"
            )
            return true
        } catch {
            Logger.database.error("Could not sideline database: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
