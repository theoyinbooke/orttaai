// ExpressModelStore.swift
// Orttaai

import CryptoKit
import Foundation
import os

nonisolated enum ExpressModelStoreError: LocalizedError, Equatable {
    case downloadFailed(file: String, status: Int)
    case verificationFailed(file: String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let file, let status):
            return "Downloading \(file) failed (HTTP \(status))."
        case .verificationFailed(let file):
            return "\(file) did not match its published checksum, so it was not installed."
        }
    }
}

/// The Fluid Speech Mini Core ML package on disk. It lives in the selected
/// model storage folder beside the Whisper models, in a Hugging Face style
/// path, and is pinned to one repository revision: every file is checked
/// against the size and SHA-256 recorded here before the package is used.
nonisolated enum ExpressModelStore {
    struct File: Sendable, Equatable {
        /// Path in the Hugging Face repository.
        let remotePath: String
        /// Path inside the installed folder. Differs only for the joint,
        /// which FluidAudio's `.ultra` loader reads as JointDecisionv3.mlmodelc.
        let localPath: String
        let size: Int64
        let sha256: String
    }

    static let repository = "FluidVoice-Labs/fluid-speech-mini-coreml"
    /// The revision benchmarked in gauntlet/asr_eval (published 2026-10-13).
    static let revision = "d81c3160dfe5a5e1f8f7267164a07d30617a3a1a"

    /// Everything `AsrModels.loadLocal(version: .ultra)` reads, plus the
    /// licence and notice the CC BY 4.0 attribution travels with.
    static let files: [File] = [
        file("Preprocessor.mlmodelc/analytics/coremldata.bin", 243, "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
        file("Preprocessor.mlmodelc/coremldata.bin", 486, "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
        file("Preprocessor.mlmodelc/metadata.json", 2_841, "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
        file("Preprocessor.mlmodelc/model.mil", 28_181, "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
        file("Preprocessor.mlmodelc/weights/weight.bin", 491_072, "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
        file("Encoder.mlmodelc/analytics/coremldata.bin", 243, "3a3caa2c6aec983d94a5659eff09a00f77077147ea6726b8ddfdf022f0238ce9"),
        file("Encoder.mlmodelc/coremldata.bin", 427, "494d8e2ce30b37bcdf494b3ba7ddf6e1bc921b9a59e369a9efd44d013ca3bf7d"),
        file("Encoder.mlmodelc/metadata.json", 2_906, "1a2229e2cc4c271e4876715c9e36aef18bc7287e35690022c7f3939d85260ea9"),
        file("Encoder.mlmodelc/model.mil", 712_643, "f96b7707936ea7ce5517c5b0f5c15cc634006bc58af1fe2587ac5979dd180343"),
        file("Encoder.mlmodelc/weights/weight.bin", 233_096_704, "cf0b61022de8c698984a8c7185c2d093fa744694621881ff062c46fee2546131"),
        file("Decoder.mlmodelc/analytics/coremldata.bin", 243, "d4beee43a6eab29b2adcc298f2e8582e8fb79d5fe3aa9f1ab692ade681ca369d"),
        file("Decoder.mlmodelc/coremldata.bin", 491, "6094d06d05c1ca4599c7b13c9a4ca7c00826ee2396796cf3084ce602a9884468"),
        file("Decoder.mlmodelc/metadata.json", 3_373, "13fcb358af8b028703dc7f424fd149ce9524642de510f3d682b75d471b1a001d"),
        file("Decoder.mlmodelc/model.mil", 13_411, "4ccd8ecbc7eb59bed7ad38d471bf6b78ef52a24500bf64619c549ed45fbee4e9"),
        file("Decoder.mlmodelc/weights/weight.bin", 11_845_120, "d173e381488d07fd7648e2ccecbfb1bceff0457d75461550b26ba7fa2d23309a"),
        file("JointDecision.mlmodelc/analytics/coremldata.bin", 243, "9e767d69e1092b27b28d9f236b9cbcded58ff3891e320cba7855e2c24e803d69"),
        file("JointDecision.mlmodelc/coremldata.bin", 462, "284b235c08cd4769202af017f854deace69c0209c29f2253a2073bb68d58d38d"),
        file("JointDecision.mlmodelc/metadata.json", 2_790, "fe1ce083f9ff57524926a92fc264b0cf7d88f3ba9852f7acf9f59dcdf427e01f"),
        file("JointDecision.mlmodelc/model.mil", 7_547, "1109ce72f6d014a6b99e49b41e83b3082d7555d74a6275838e7cbea42a6bd0ee"),
        file("JointDecision.mlmodelc/weights/weight.bin", 6_350_284, "f991f65979c1b3fee3db39a645aa87e6bef1a304ed1816d074b17479bea797fc"),
        file("parakeet_vocab.json", 151_122, "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
        file("config.json", 314, "5e6e1189fd8e9da59633b929a977c716d696b84aff6ab9b040423bc8b9c8b3be"),
        file("LICENSE", 18_657, "9ba9550ad48438d0836ddab3da480b3b69ffa0aac7b7878b5a0039e7ab429411"),
        file("NOTICE", 690, "05119420d65cf41d7434a83027c23f1360740d7e8c25d6b47263698ffe1f4c86"),
    ]

    static var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    /// `<storage base>/models/FluidVoice-Labs/fluid-speech-mini-coreml`.
    static func folder(in storageBase: URL) -> URL {
        storageBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("FluidVoice-Labs", isDirectory: true)
            .appendingPathComponent("fluid-speech-mini-coreml", isDirectory: true)
    }

    /// Every file present at its recorded size. Checksums are verified once,
    /// at install; this check runs before each load and must stay cheap.
    static func isInstalled(
        in storageBase: URL,
        files: [File] = files,
        fileManager: FileManager = .default
    ) -> Bool {
        let folder = folder(in: storageBase)
        return files.allSatisfy { file in
            let path = folder.appendingPathComponent(file.localPath).path
            let size = (try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
            return size == file.size
        }
    }

    /// Downloads the pinned revision into a staging folder beside the final
    /// one, verifies every file, then moves the folder into place. A failed or
    /// cancelled install leaves no partial package behind. `@concurrent` keeps
    /// the downloading and hashing off the caller's actor (Settings calls it
    /// from the main actor).
    @concurrent
    static func install(
        into storageBase: URL,
        files: [File] = files,
        sourceBase: URL = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/")!,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        let destination = folder(in: storageBase)
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".\(destination.lastPathComponent).partial-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let total = Double(files.reduce(0) { $0 + $1.size })
        var completed: Int64 = 0
        progress(0)
        for file in files {
            try Task.checkCancellation()
            let target = staging.appendingPathComponent(file.localPath)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = completed
            try await ExpressFileDownload.fetch(
                sourceBase.appendingPathComponent(file.remotePath),
                to: target,
                onBytes: { written in progress(min(1, Double(base + written) / total)) }
            )
            guard verify(target, size: file.size, sha256: file.sha256) else {
                throw ExpressModelStoreError.verificationFailed(file: file.remotePath)
            }
            completed += file.size
            progress(min(1, Double(completed) / total))
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
        Logger.model.info("Express model installed at \(destination.path, privacy: .public)")
    }

    @concurrent
    static func remove(from storageBase: URL) async throws {
        let folder = folder(in: storageBase)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    /// Size and SHA-256, hashed in 1 MB chunks so a 233 MB weight file is
    /// never held in memory at once.
    static func verify(_ url: URL, size: Int64, sha256: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.int64Value == size,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == sha256.lowercased()
    }

    private static func file(_ remotePath: String, _ size: Int64, _ sha256: String) -> File {
        let localPath = remotePath.replacingOccurrences(
            of: "JointDecision.mlmodelc/",
            with: "JointDecisionv3.mlmodelc/"
        )
        return File(remotePath: remotePath, localPath: localPath, size: size, sha256: sha256)
    }
}

/// One file download with byte progress. A per-download session with its own
/// delegate: the file must be moved out of the temporary location before the
/// delegate callback returns, which the async `download(from:)` API hides.
nonisolated private final class ExpressFileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onBytes: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?

    private init(destination: URL, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.onBytes = onBytes
    }

    static func fetch(_ source: URL, to destination: URL, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        let download = ExpressFileDownload(destination: destination, onBytes: onBytes)
        let session = URLSession(configuration: .default, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: source)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onBytes(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            moveError = ExpressModelStoreError.downloadFailed(
                file: downloadTask.originalRequest?.url?.lastPathComponent ?? "file",
                status: http.statusCode
            )
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error ?? moveError {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
