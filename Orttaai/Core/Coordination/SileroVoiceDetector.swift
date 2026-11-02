// SileroVoiceDetector.swift
// Orttaai
//
// Silero VAD (through FluidAudio) for hands-free auto-stop: it tells a voice
// from silence however loud or quiet the microphone, where a loudness check
// can't. On the real-voice corpus it heard 95–96% of speech at every level
// and noticed silence over fan noise, which loudness never did.

@preconcurrency import CoreML
import ExpressAudio
import Foundation
import os

/// Hears whether stretches of a recording hold a voice.
nonisolated protocol VoiceActivityDetecting: AnyObject, Sendable {
    /// Samples behind each verdict.
    var chunkSampleCount: Int { get }
    /// Forgets the previous recording.
    func reset() async
    /// One verdict per whole chunk in `samples`, continuing from the last call.
    func speech(in samples: [Float]) async throws -> [Bool]
}

actor SileroVoiceDetector: VoiceActivityDetecting {
    static let modelFileName = "silero-vad-unified-256ms-v6.2.1.mlmodelc"
    /// Speech from this probability up: the threshold the bench measured.
    static let speechProbability: Float = 0.5

    /// 256 ms at 16 kHz.
    nonisolated let chunkSampleCount = VadManager.chunkSize

    private let manager: VadManager
    private var state: VadStreamState

    init(modelFolder: URL) async throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(
            contentsOf: modelFolder.appendingPathComponent(Self.modelFileName),
            configuration: configuration
        )
        let manager = VadManager(config: VadConfig(defaultThreshold: Self.speechProbability), vadModel: model)
        self.manager = manager
        state = await manager.makeStreamState()
    }

    func reset() async {
        state = await manager.makeStreamState()
    }

    func speech(in samples: [Float]) async throws -> [Bool] {
        var verdicts: [Bool] = []
        var start = 0
        while start + chunkSampleCount <= samples.count {
            let result = try await manager.processStreamingChunk(
                Array(samples[start..<start + chunkSampleCount]),
                state: state
            )
            state = result.state
            verdicts.append(result.probability >= Self.speechProbability)
            start += chunkSampleCount
        }
        return verdicts
    }
}

/// Downloads Silero VAD (about 1 MB, pinned and checksum-verified) into the
/// model folder the first time hands-free auto-stop needs it, and loads it.
/// Until then, or if it can't, hands-free falls back to the loudness check.
@MainActor
final class SileroVoiceDetectorLoader {
    private let locator: ModelDirectoryLocator
    private var detector: SileroVoiceDetector?
    /// Held while the model is loaded, for a model folder that needs a
    /// security scope.
    private var access: ModelStorageAccess?
    private var loading: Task<SileroVoiceDetector?, Never>?

    init(locator: ModelDirectoryLocator = .shared) {
        self.locator = locator
    }

    /// The loaded detector, installing and loading it first if needed; nil
    /// when it can't be had right now (offline, folder unavailable).
    func readyDetector() async -> SileroVoiceDetector? {
        if let detector { return detector }
        if let loading { return await loading.value }
        let task = Task { await load() }
        loading = task
        let loaded = await task.value
        loading = nil
        return loaded
    }

    private func load() async -> SileroVoiceDetector? {
        let package = ExpressModelStore.voiceDetector
        do {
            let installed: Bool
            if let readAccess = try? await locator.beginAccess(createIfNeeded: false, requiresWrite: false) {
                installed = await locator.probe({ ExpressModelStore.isInstalled(package, in: readAccess.url) }) == true
            } else {
                installed = false
            }
            if !installed {
                let writeAccess = try await locator.beginAccess(createIfNeeded: true, requiresWrite: true)
                try await ExpressModelStore.install(package, into: writeAccess.url) { _ in }
            }
            let access = try await locator.beginAccess(createIfNeeded: false, requiresWrite: false)
            let started = Date()
            let loaded = try await SileroVoiceDetector(
                modelFolder: ExpressModelStore.folder(for: package, in: access.url)
            )
            self.access = access
            detector = loaded
            Logger.dictation.info(
                "Silero voice detector ready in \(Int(Date().timeIntervalSince(started) * 1_000), privacy: .public) ms"
            )
            return loaded
        } catch {
            Logger.dictation.error(
                "Silero voice detector unavailable, using loudness: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
