// S1MiniPolish.swift
// Orttaai
//
// Text Polish with S1-mini by Superwhisper, in-process (PolishEngine, on the
// GPU), the model Orttakey uses on the iPhone. No server has to be running,
// and measured on an M5 Max against Gemma 4 E2B through Ollama on 30 real
// dictations it was as fast once loaded (0.14 s for 29 words, 0.77 s for
// 206) while doing more of the clean-up. Each paragraph is polished and
// checked on its own, within a time budget that grows with the dictation, so
// long dictations are polished too instead of skipped.

import Foundation
import os
import PolishEngine

enum S1MiniStatus: Equatable {
    case checking
    case notInstalled
    case downloading(progress: Double)
    /// On disk, not loaded (Polish is off, or another engine is chosen).
    case installed
    case loading
    case ready
    case failed(String)
}

/// Downloads S1-mini when asked, loads it when Polish needs it, and keeps it
/// loaded (about 0.4 s to load, 0.5 GB memory-mapped) while it's in use.
@Observable
final class S1MiniPolishController {
    static let shared = S1MiniPolishController()

    static let modelFileName = "s1-mini-q4_k_m.gguf"

    private(set) var status: S1MiniStatus = .checking

    private let locator: ModelDirectoryLocator
    private var polisher: S1MiniPolisher?
    /// Held while the model is loaded: it's memory-mapped from the model
    /// folder, which may need a security scope.
    private var access: ModelStorageAccess?
    private var loading: Task<S1MiniPolisher?, Never>?

    init(locator: ModelDirectoryLocator = .shared) {
        self.locator = locator
    }

    /// Re-reads whether the model is on disk (Settings calls this).
    func refresh() async {
        if case .downloading = status { return }
        if polisher != nil {
            status = .ready
            return
        }
        status = await isInstalled() ? .installed : .notInstalled
    }

    func install() async {
        if case .downloading = status { return }
        status = .downloading(progress: 0)
        do {
            let access = try await locator.beginAccess(createIfNeeded: true, requiresWrite: true)
            var reported = 0.0
            try await ExpressModelStore.install(ExpressModelStore.s1Mini, into: access.url) { fraction in
                guard fraction - reported >= 0.01 || fraction >= 1 else { return }
                reported = fraction
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.status else { return }
                    self.status = .downloading(progress: fraction)
                }
            }
            Logger.model.info("S1-mini installed")
            status = .installed
            _ = await readyPolisher()
        } catch {
            Logger.model.error("Installing S1-mini failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }

    /// The loaded polisher, loading it first if it's on disk; nil when it
    /// isn't downloaded or couldn't load.
    func readyPolisher() async -> S1MiniPolisher? {
        if let polisher { return polisher }
        if let loading { return await loading.value }
        let task = Task { await load() }
        loading = task
        let loaded = await task.value
        loading = nil
        return loaded
    }

    /// Frees the model's memory when Polish is turned off or another engine
    /// is chosen.
    func unload() {
        guard polisher != nil else { return }
        polisher = nil
        access = nil
        status = .installed
        Logger.ai.info("S1-mini unloaded")
    }

    private func load() async -> S1MiniPolisher? {
        do {
            let access = try await locator.beginAccess(createIfNeeded: false, requiresWrite: false)
            guard await locator.probe({ ExpressModelStore.isInstalled(ExpressModelStore.s1Mini, in: access.url) }) == true else {
                status = .notInstalled
                return nil
            }
            status = .loading
            let path = ExpressModelStore.folder(for: ExpressModelStore.s1Mini, in: access.url)
                .appendingPathComponent(Self.modelFileName).path
            let loaded = S1MiniPolisher(modelPath: path)
            let seconds = try await loaded.load()
            self.access = access
            polisher = loaded
            status = .ready
            Logger.ai.info("S1-mini loaded in \(Int(seconds * 1_000), privacy: .public) ms")
            return loaded
        } catch {
            Logger.ai.error("Loading S1-mini failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
            return nil
        }
    }

    private func isInstalled() async -> Bool {
        guard let access = try? await locator.beginAccess(createIfNeeded: false, requiresWrite: false) else { return false }
        return await locator.probe({ ExpressModelStore.isInstalled(ExpressModelStore.s1Mini, in: access.url) }) == true
    }
}

/// Polishes the rules text with S1-mini when Text Polish is on and S1-mini is
/// the chosen engine; otherwise passes the text through. Whatever S1-mini
/// can't polish safely, or in time, keeps the rules text.
final class S1MiniPolishProcessor: TextProcessor {
    private let baseProcessor: TextProcessor
    private let settings: AppSettings
    private let controller: S1MiniPolishController

    init(baseProcessor: TextProcessor, settings: AppSettings, controller: S1MiniPolishController = .shared) {
        self.baseProcessor = baseProcessor
        self.settings = settings
        self.controller = controller
    }

    func process(_ input: TextProcessorInput) async throws -> TextProcessorOutput {
        let baseOutput = try await baseProcessor.process(input)
        guard settings.localLLMPolishEnabled, settings.usesS1MiniPolish, !input.deferPolish else {
            return baseOutput
        }
        let text = baseOutput.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 8, let polisher = await controller.readyPolisher() else {
            return baseOutput
        }

        let words = text.split(whereSeparator: \.isWhitespace).count
        let started = ContinuousClock.now
        let deadline = started.advanced(by: S1MiniPolisher.timeBudget(forWords: words))
        // Dictionary words must come through exactly as the user spells them.
        let protected = wordBoostTerms().map(\.text)
        do {
            let outcome = try await polisher.polish(text, protecting: protected, deadline: deadline)
            let elapsed = started.duration(to: .now)
            let milliseconds = Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            let kept = outcome.notes.isEmpty ? "" : " (kept the rules text: \(outcome.notes.joined(separator: "; ")))"
            Logger.ai.info(
                "S1-mini polish: \(outcome.polished, privacy: .public) of \(outcome.paragraphs, privacy: .public) paragraphs in \(milliseconds, privacy: .public) ms\(kept, privacy: .public)"
            )
            guard outcome.applied else { return baseOutput }

            var polishedText = outcome.text
            var changes = baseOutput.changes
            if settings.spokenFormattingEnabled {
                let formatted = SpokenFormattingFormatter.format(polishedText)
                polishedText = formatted.text
                for change in formatted.changes where !changes.contains(change) { changes.append(change) }
            }
            guard polishedText != text else { return baseOutput }
            changes.append("S1-mini polish applied")
            return TextProcessorOutput(text: polishedText, changes: changes)
        } catch {
            Logger.ai.debug("S1-mini polish unavailable: \(error.localizedDescription, privacy: .public)")
            return baseOutput
        }
    }

    func isAvailable() -> Bool {
        baseProcessor.isAvailable()
    }
}

extension S1MiniPolishProcessor: WordBoostVocabularyProviding {
    func wordBoostTerms() -> [WordBoostTerm] {
        (baseProcessor as? WordBoostVocabularyProviding)?.wordBoostTerms() ?? []
    }
}
