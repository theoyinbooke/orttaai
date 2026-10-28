// CoachNaturalVoice.swift
// Orttaai
//
// Natural voices for Coach's scene partners, on this Mac, through FluidAudio:
// Ola speaks in a voice cloned with Pocket TTS by Kyutai, and the others in
// Phonon 31M voices by Gradium (macOS 15 and later). Both models download
// once into the model folder; until then, and whenever they can't speak,
// Coach falls back to the Mac's own voice.

import AVFoundation
import Combine
import ExpressAudio
import Foundation
import os

@MainActor
final class CoachNaturalVoice: ObservableObject {
    static let shared = CoachNaturalVoice()

    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .notInstalled

    /// Voices that ship in the app, by speaker, as resource names. Ola's was
    /// cloned with consent from a recording of its speaker (docs/coach-voices.md).
    static let voices: [String: String] = ["ola": "ola"]

    /// Phonon's own voices, by speaker, chosen from its catalogue to suit
    /// each partner. Apache-2.0, like the model.
    static let presetVoices: [String: String] = [
        "atlas": "en_us_Preston",
        "dami": "en_us_Easton",
        "priya": "en_us_Delia",
        "sam": "en_us_Juniper",
    ]

    /// Phonon needs Core ML's stateful models.
    static var presetsSupported: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }

    private static let cloneMarker = "installed.json"
    private static let presetMarker = "phonon.json"
    private var hasClone = false
    private var hasPresets = false
    /// Engines that failed to load this launch; they aren't tried again until
    /// Try again.
    private var broken: Set<String> = []
    private var access: ModelStorageAccess?
    private var cloneManager: PocketTtsManager?
    private var cloneLoading: Task<PocketTtsManager?, Never>?
    private var presetManager: AnyObject?
    private var presetLoading: Task<AnyObject?, Never>?
    private var voiceData: [String: PocketTtsVoiceData] = [:]

    init() {
        refresh()
    }

    static func folder(in base: URL) -> URL {
        base.appendingPathComponent("Coach voices", isDirectory: true)
    }

    static func voiceURL(for speaker: String) -> URL? {
        guard let name = voices[speaker.lowercased()] else { return nil }
        return Bundle.main.url(forResource: name, withExtension: "pocketvoice")
    }

    /// What's left to download.
    var downloadSize: String {
        switch (hasClone, hasPresets || !Self.presetsSupported) {
        case (true, false): return "about 175 MB"
        case (false, true): return "about 520 MB"
        default: return "about 700 MB"
        }
    }

    /// The speaker has a voice of their own, and its model is here to speak it.
    func canSpeak(as speaker: String) -> Bool {
        let key = speaker.lowercased()
        if Self.voiceURL(for: key) != nil { return hasClone && !broken.contains("clone") }
        if Self.presetVoices[key] != nil { return hasPresets && Self.presetsSupported && !broken.contains("presets") }
        return false
    }

    func refresh() {
        if case .downloading = state { return }
        let folder = Self.folder(in: ModelStorageLocation.selectedDownloadBaseURL())
        hasClone = FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.cloneMarker).path)
        hasPresets = FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.presetMarker).path)
        state = hasClone && (hasPresets || !Self.presetsSupported) ? .ready : .notInstalled
    }

    /// Downloads both models into the model folder, reporting progress. A
    /// model that's already there isn't fetched again.
    func install() async {
        if case .downloading = state { return }
        broken = []
        state = .downloading(0)
        do {
            let access = try ModelStorageLocation.beginAccess(createIfNeeded: true, requiresWrite: true)
            let folder = Self.folder(in: access.url)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Pocket TTS is about three quarters of the download.
            let cloneShare = Self.presetsSupported ? 0.75 : 1.0
            _ = try await PocketTtsResourceDownloader.ensureModels(language: .english, directory: folder) { progress in
                Task { @MainActor in CoachNaturalVoice.shared.report(progress.fractionCompleted * cloneShare) }
            }
            try Data(#"{"model":"pocket-tts v2.1 english"}"#.utf8).write(to: folder.appendingPathComponent(Self.cloneMarker))
            hasClone = true
            if #available(macOS 15, *) {
                _ = try await PocketTtsSmallDownloader.ensurePack(.phonon31m, directory: folder) { progress in
                    Task { @MainActor in CoachNaturalVoice.shared.report(cloneShare + progress.fractionCompleted * (1 - cloneShare)) }
                }
                try Data(#"{"model":"phonon-31m-en"}"#.utf8).write(to: folder.appendingPathComponent(Self.presetMarker))
                hasPresets = true
            }
            self.access = access
            state = .ready
        } catch {
            Logger.model.error("Coach couldn't download its voices: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    private func report(_ fraction: Double) {
        guard case .downloading = state else { return }
        state = .downloading(min(1, fraction))
    }

    func remove() {
        cloneManager = nil
        presetManager = nil
        voiceData = [:]
        if let base = try? ModelStorageLocation.beginAccess(createIfNeeded: false, requiresWrite: true) {
            try? FileManager.default.removeItem(at: Self.folder(in: base.url))
        }
        access = nil
        refresh()
    }

    /// Loads the speaker's model and voice, and says a word nobody hears, so
    /// the scene's first line comes as quickly as the rest.
    func warmUp(_ speaker: String) async {
        guard canSpeak(as: speaker) else { return }
        _ = await speech("Hello.", as: speaker)
    }

    /// The line as 24 kHz WAV in the speaker's own voice, or nil.
    func speech(_ text: String, as speaker: String) async -> Data? {
        let key = speaker.lowercased()
        guard canSpeak(as: key) else { return nil }
        if let url = Self.voiceURL(for: key) {
            return await clonedSpeech(text, key: key, url: url)
        }
        if let preset = Self.presetVoices[key], #available(macOS 15, *) {
            return await presetSpeech(text, key: key, voice: preset)
        }
        return nil
    }

    // MARK: Pocket TTS, for cloned voices

    private func clonedSpeech(_ text: String, key: String, url: URL) async -> Data? {
        guard let manager = await prepareClone() else { return nil }
        do {
            let voice: PocketTtsVoiceData
            if let cached = voiceData[key] {
                voice = cached
            } else {
                voice = try manager.loadClonedVoice(from: url)
                voiceData[key] = voice
            }
            return try await manager.synthesize(text: text, voiceData: voice)
        } catch {
            Logger.model.error("Coach couldn't speak as \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Loads Pocket TTS once. Nil when it isn't installed or won't load.
    private func prepareClone() async -> PocketTtsManager? {
        if let cloneManager { return cloneManager }
        if let cloneLoading { return await cloneLoading.value }
        let task = Task<PocketTtsManager?, Never> {
            do {
                let access = try ModelStorageLocation.beginAccess(createIfNeeded: false, requiresWrite: false)
                let manager = PocketTtsManager(directory: Self.folder(in: access.url))
                try await manager.initialize()
                self.access = access
                self.cloneManager = manager
                return manager
            } catch {
                self.failed("clone", error)
                return nil
            }
        }
        cloneLoading = task
        let manager = await task.value
        cloneLoading = nil
        return manager
    }

    // MARK: Phonon, for its own voices

    @available(macOS 15, *)
    private func presetSpeech(_ text: String, key: String, voice: String) async -> Data? {
        guard let manager = await preparePresets() else { return nil }
        do {
            return try await manager.synthesize(text: text, voice: voice)
        } catch {
            Logger.model.error("Coach couldn't speak as \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Loads Phonon once. Nil when it isn't installed or won't load.
    @available(macOS 15, *)
    private func preparePresets() async -> PocketTtsSmallManager? {
        if let manager = presetManager as? PocketTtsSmallManager { return manager }
        if let presetLoading { return await presetLoading.value as? PocketTtsSmallManager }
        let task = Task<AnyObject?, Never> {
            do {
                let access = try ModelStorageLocation.beginAccess(createIfNeeded: false, requiresWrite: false)
                let manager = PocketTtsSmallManager(model: .phonon31m)
                // Finds the pack on disk; nothing is downloaded here.
                try await manager.initialize(directory: Self.folder(in: access.url))
                self.access = access
                self.presetManager = manager
                return manager
            } catch {
                self.failed("presets", error)
                return nil
            }
        }
        presetLoading = task
        let manager = await task.value
        presetLoading = nil
        return manager as? PocketTtsSmallManager
    }

    /// Uses the Mac's voice for that engine from now on rather than retrying
    /// every line; Models offers Try again.
    private func failed(_ engine: String, _ error: Error) {
        Logger.model.error("Coach's \(engine, privacy: .public) voices didn't load: \(error.localizedDescription, privacy: .public)")
        broken.insert(engine)
        state = .failed(error.localizedDescription)
    }
}
