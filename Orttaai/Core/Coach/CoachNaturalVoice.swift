// CoachNaturalVoice.swift
// Orttaai
//
// Natural voices for Coach's scene partners, on this Mac: Pocket TTS by Kyutai
// through FluidAudio, speaking with voices that ship in the app. The model
// downloads once into the model folder; until then, and whenever it can't
// speak, Coach falls back to the Mac's own voice.

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

    static let downloadSize = "about 520 MB"

    /// Voices that ship in the app, by speaker, as resource names. Ola's was
    /// cloned with consent from a recording of its speaker (docs/coach-voices.md).
    static let voices: [String: String] = ["ola": "ola"]

    private static let marker = "installed.json"
    private var access: ModelStorageAccess?
    private var manager: PocketTtsManager?
    private var loading: Task<PocketTtsManager?, Never>?
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

    /// The speaker has a voice of their own, and the model is here to speak it.
    func canSpeak(as speaker: String) -> Bool {
        state == .ready && Self.voiceURL(for: speaker) != nil
    }

    func refresh() {
        if case .downloading = state { return }
        let base = ModelStorageLocation.selectedDownloadBaseURL()
        let installed = FileManager.default.fileExists(atPath: Self.folder(in: base).appendingPathComponent(Self.marker).path)
        state = installed ? .ready : .notInstalled
    }

    /// Downloads the model into the model folder, reporting progress.
    func install() async {
        if case .downloading = state { return }
        state = .downloading(0)
        do {
            let access = try ModelStorageLocation.beginAccess(createIfNeeded: true, requiresWrite: true)
            let folder = Self.folder(in: access.url)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            _ = try await PocketTtsResourceDownloader.ensureModels(language: .english, directory: folder) { progress in
                Task { @MainActor in
                    guard case .downloading = CoachNaturalVoice.shared.state else { return }
                    CoachNaturalVoice.shared.state = .downloading(progress.fractionCompleted)
                }
            }
            try Data(#"{"model":"pocket-tts v2.1 english"}"#.utf8).write(to: folder.appendingPathComponent(Self.marker))
            self.access = access
            state = .ready
        } catch {
            Logger.model.error("Coach couldn't download its voices: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    func remove() {
        manager = nil
        voiceData = [:]
        if let base = try? ModelStorageLocation.beginAccess(createIfNeeded: false, requiresWrite: true) {
            try? FileManager.default.removeItem(at: Self.folder(in: base.url))
        }
        access = nil
        refresh()
    }

    /// Loads the model once, so the first line isn't kept waiting. Nil when
    /// it isn't installed or won't load.
    @discardableResult
    func prepare() async -> PocketTtsManager? {
        if let manager { return manager }
        guard state == .ready else { return nil }
        if let loading { return await loading.value }
        let task = Task<PocketTtsManager?, Never> {
            do {
                let access = try ModelStorageLocation.beginAccess(createIfNeeded: false, requiresWrite: false)
                let manager = PocketTtsManager(directory: Self.folder(in: access.url))
                try await manager.initialize()
                self.access = access
                self.manager = manager
                return manager
            } catch {
                Logger.model.error("Coach's voices didn't load: \(error.localizedDescription, privacy: .public)")
                // Use the Mac's voice from now on rather than retrying every line;
                // Models offers Try again.
                self.state = .failed(error.localizedDescription)
                return nil
            }
        }
        loading = task
        let manager = await task.value
        loading = nil
        return manager
    }

    /// Loads the model and the speaker's voice, and says a word nobody hears,
    /// so the scene's first line comes as quickly as the rest.
    func warmUp(_ speaker: String) async {
        guard canSpeak(as: speaker) else { return }
        _ = await speech("Hello.", as: speaker)
    }

    /// The line as 24 kHz WAV in the speaker's own voice, or nil.
    func speech(_ text: String, as speaker: String) async -> Data? {
        let key = speaker.lowercased()
        guard let url = Self.voiceURL(for: key), let manager = await prepare() else { return nil }
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
}
