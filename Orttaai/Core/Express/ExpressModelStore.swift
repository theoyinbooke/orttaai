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

/// One pinned Hugging Face model package Express installs.
nonisolated struct ExpressModelPackage: Sendable, Equatable {
    struct File: Sendable, Equatable {
        /// Path in the Hugging Face repository.
        let remotePath: String
        /// Path inside the installed folder. Differs only for Mini's joint,
        /// which FluidAudio's `.ultra` loader reads as JointDecisionv3.mlmodelc.
        let localPath: String
        let size: Int64
        let sha256: String
    }

    let name: String
    /// "owner/name" on Hugging Face; also the folder path below `models/`.
    let repository: String
    let revision: String
    let files: [File]

    var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    var sourceBase: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/")!
    }
}

/// Express's model packages on disk. They live in the selected model storage
/// folder beside the Whisper models, in Hugging Face style paths, each pinned
/// to one repository revision: every file is checked against the size and
/// SHA-256 recorded here before it is used.
nonisolated enum ExpressModelStore {
    typealias File = ExpressModelPackage.File

    /// Fluid Speech Mini: everything `AsrModels.loadLocal(version: .ultra)`
    /// reads, plus the licence and notice its CC BY 4.0 attribution travels
    /// with. The revision benchmarked in gauntlet/asr_eval (2026-10-13).
    static let speech = ExpressModelPackage(
        name: "Fluid Speech Mini",
        repository: "FluidVoice-Labs/fluid-speech-mini-coreml",
        revision: "d81c3160dfe5a5e1f8f7267164a07d30617a3a1a",
        files: [
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
    )

    /// Parakeet CTC 110M, the Word Boost model: everything
    /// `CtcModels.loadDirect` and `CtcTokenizer.load` read, plus the model
    /// card that carries its licence (CC BY 4.0, from NVIDIA's original).
    static let wordBoost = ExpressModelPackage(
        name: "Parakeet CTC 110M",
        repository: "FluidInference/parakeet-ctc-110m-coreml",
        revision: "accdafd8cf8a2ff1cabe3c11e54416b405d409aa",
        files: [
            file("MelSpectrogram.mlmodelc/analytics/coremldata.bin", 243, "22f2a8cba1de25c984050566b534a1d8caf22a82f9fe6c1c6f3149a0dd7e8ae3"),
            file("MelSpectrogram.mlmodelc/coremldata.bin", 330, "3a32ec67c76aa0aa2faef518413c311493e89aeb7fa11289fa4b8653ab8a160c"),
            file("MelSpectrogram.mlmodelc/metadata.json", 1_962, "5e11d21a65c02bcfc37db43e941978e5d60d59e0efeadfda08e41f33b4f835d3"),
            file("MelSpectrogram.mlmodelc/model.mil", 12_584, "0a7cb5693b39667295218bac5c7c09053f6bcd4b32699a83d06ac35d14ac6b79"),
            file("MelSpectrogram.mlmodelc/weights/weight.bin", 567_712, "0a89c055bfde9022029d3cc59a23e949385e063974460d8eaec3a7614c3eaaa8"),
            file("AudioEncoder.mlmodelc/analytics/coremldata.bin", 243, "8906c823e9bb3bf6b16d9f0308f98cd70573526333ad85dd767dc3f9ae6b25fa"),
            file("AudioEncoder.mlmodelc/coremldata.bin", 505, "a88b002b58193b4c31211754cdfdf220a85f9651dc61caf336ab84400cbc191a"),
            file("AudioEncoder.mlmodelc/metadata.json", 3_456, "4f288bfe5cbe867ef1e592cdae33578b2fe59ada69182fc12209879558f985c2"),
            file("AudioEncoder.mlmodelc/model.mil", 1_060_924, "2f84ef93a69115e55f3b5d8ce695b3c937de1833d4d229620634fae967cd587e"),
            file("AudioEncoder.mlmodelc/weights/weight.bin", 100_778_304, "af0734b4a5d7465ad9e8bb170f0c53c5e6b91ebb75a9bdf88d3f59ae4ad6aebd"),
            file("vocab.json", 16_086, "319d386eead79aadc80df9c3ecc8340d1a727efb7c02a8847eb940380dd61e1f"),
            file("tokenizer.json", 360_106, "9f7c517c0bf644b1b690ab037bab4d4c53aecd38e047e7154d011013ab9160db"),
            file("tokenizer_config.json", 632, "7a29ed0fec88768d8666d65be8dc00ae41a60c4b7758c4df99a912108e62a23a"),
            file("special_tokens_map.json", 279, "af8c98917af6cb493513e5f1f8a35efdc28fa82cac15b2bb5f065d64f8bc904d"),
            file("config.json", 121, "1fd77c83ea89285c242608d95a7992f146867481adc3938be730a064f3a63305"),
            file("README.md", 7_419, "1aa99e33e37d4d36f01f15b7d81f878a43a85210c184aebebf1f27d5a4c3b189"),
        ]
    )

    /// S1-mini by Superwhisper, for Polish: Qwen3 0.6B fine-tuned for
    /// dictation clean-up, run in-process by PolishEngine. Its own download,
    /// not part of Express; the licence and notice travel with it (Apache 2.0,
    /// credited as "S1-mini" by "Superwhisper"). The revision Orttakey uses.
    static let s1Mini = ExpressModelPackage(
        name: "S1-mini",
        repository: "superwhisper/s1-mini-GGUF",
        revision: "34add00a48a2e5d24e5a4ee5405a99620a3a240c",
        files: [
            file("s1-mini-q4_k_m.gguf", 484_219_808, "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634"),
            file("LICENSE", 12_033, "f715982df6ce767ae64864d74b95644e5d658aab54717dbceeb252eb3cbcb421"),
            file("NOTICE", 507, "6eb1e98a0d0046dd1b71da19d3b64ebccc12622e7d62e5efcad10298b4d66292"),
        ]
    )

    static let packages = [speech, wordBoost]

    /// Everything turning Express on downloads.
    static var totalBytes: Int64 {
        packages.reduce(0) { $0 + $1.totalBytes }
    }

    /// `<storage base>/models/<owner>/<name>`, e.g.
    /// `models/FluidVoice-Labs/fluid-speech-mini-coreml`.
    static func folder(for package: ExpressModelPackage = speech, in storageBase: URL) -> URL {
        storageBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(package.repository, isDirectory: true)
    }

    /// Every file present at its recorded size. Checksums are verified once,
    /// at install; this check runs before each load and must stay cheap.
    static func isInstalled(
        _ package: ExpressModelPackage = speech,
        in storageBase: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let folder = folder(for: package, in: storageBase)
        return package.files.allSatisfy { file in
            let path = folder.appendingPathComponent(file.localPath).path
            let size = (try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
            return size == file.size
        }
    }

    /// Installs every package that is not already on disk, reporting progress
    /// across all of them.
    @concurrent
    static func installMissing(
        into storageBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let missing = packages.filter { !isInstalled($0, in: storageBase) }
        let total = Double(missing.reduce(0) { $0 + $1.totalBytes })
        var done: Int64 = 0
        for package in missing {
            let base = done
            try await install(package, into: storageBase) { fraction in
                progress(min(1, (Double(base) + fraction * Double(package.totalBytes)) / max(total, 1)))
            }
            done += package.totalBytes
        }
        progress(1)
    }

    /// Downloads one package's pinned revision into a staging folder beside
    /// the final one, verifies every file, then moves the folder into place. A
    /// failed or cancelled install leaves no partial package behind.
    /// `@concurrent` keeps the downloading and hashing off the caller's actor
    /// (Settings calls it from the main actor).
    @concurrent
    static func install(
        _ package: ExpressModelPackage,
        into storageBase: URL,
        sourceBase: URL? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        let destination = folder(for: package, in: storageBase)
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".\(destination.lastPathComponent).partial-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let source = sourceBase ?? package.sourceBase
        let total = Double(package.totalBytes)
        var completed: Int64 = 0
        progress(0)
        for file in package.files {
            try Task.checkCancellation()
            let target = staging.appendingPathComponent(file.localPath)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = completed
            try await ExpressFileDownload.fetch(
                source.appendingPathComponent(file.remotePath),
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
        Logger.model.info("\(package.name, privacy: .public) installed at \(destination.path, privacy: .public)")
    }

    /// Removes every Express package.
    @concurrent
    static func remove(from storageBase: URL) async throws {
        for package in packages {
            let folder = folder(for: package, in: storageBase)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            try FileManager.default.removeItem(at: folder)
        }
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
