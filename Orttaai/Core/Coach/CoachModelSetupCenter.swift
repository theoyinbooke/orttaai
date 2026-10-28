// CoachModelSetupCenter.swift
// Orttaai
//
// Setting Coach up in one go: the models it recommends for this Mac,
// downloaded through the person's own Ollama, the judge checked, Ola's voice
// fetched, and each job pointed at the right model.

import AppKit
import CoachCore
import Combine
import Foundation
import os

/// A model Coach recommends, and the jobs it does.
struct CoachStarterModel: Identifiable, Equatable, Sendable {
    let name: String
    let jobs: [String]
    let size: String

    var id: String { name }
}

nonisolated enum CoachStarterModels {
    /// Quick enough to feel like talking: first sentence in about 0.05 s.
    static let partner = "nemotron-3.5-bolt:e4b"
    /// The best judge on the judge check (98%), but it needs the room.
    static let bigJudge = "gemma4:26b"
    /// Memory for the big judge and the partner to stay loaded together.
    static let roomForBigJudge: UInt64 = 48 << 30

    /// Bolt plays the scene partners on any Mac. With room for both, Gemma 4
    /// 26B judges and writes the notes; otherwise Bolt does every job (it
    /// passed the judge check at 90%).
    static func recommended(memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> [CoachStarterModel] {
        if memory >= roomForBigJudge {
            return [
                CoachStarterModel(name: partner, jobs: ["Scene partner"], size: "7.2 GB"),
                CoachStarterModel(name: bigJudge, jobs: ["Judge", "Coach"], size: "18.7 GB"),
            ]
        }
        return [CoachStarterModel(name: partner, jobs: ["Scene partner", "Judge", "Coach"], size: "7.2 GB")]
    }

    static func judge(memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> String {
        memory >= roomForBigJudge ? bigJudge : partner
    }
}

@MainActor
final class CoachModelSetupCenter: ObservableObject {
    static let shared = CoachModelSetupCenter()

    enum Server: Equatable {
        case checking
        case notRunning
        case running(installed: [String])
    }

    enum Step: Equatable {
        case idle
        case downloading(model: String, fraction: Double?)
        case voice
        case checkingJudge
        case done
        case failed(String)
    }

    @Published private(set) var server: Server = .checking
    @Published private(set) var step: Step = .idle
    /// Fetch Ola's natural voice along with the models.
    @Published var includeVoice = true
    /// The setup card is showing over Coach.
    @Published private(set) var presenting = false
    /// Opened from Models: straight to the setup, past the tour.
    private(set) var startsAtSetup = false

    func present(atSetup: Bool = false) {
        startsAtSetup = atSetup
        presenting = true
    }

    let models = CoachStarterModels.recommended()
    let judge = CoachStarterModels.judge()

    static let ollamaDownloadURL = URL(string: "https://ollama.com/download")!

    var provider: LocalLLMProviderKind { CoachModels.current().provider }

    var isWorking: Bool {
        switch step {
        case .downloading, .voice, .checkingJudge: return true
        case .idle, .done, .failed: return false
        }
    }

    /// What the main button says.
    var actionTitle: String {
        if isSetUp || step == .done { return "All set" }
        if isWorking { return "Setting up…" }
        let voiceNeeded = includeVoice && CoachNaturalVoice.shared.state != .ready
        return missing.isEmpty && !voiceNeeded ? "Use these" : "Download and set up"
    }

    var canAct: Bool {
        guard case .running = server else { return false }
        return !isWorking && !isSetUp && step != .done
    }

    /// How far the current download is, for pictures of it.
    var progress: Double? {
        switch step {
        case .downloading(_, let fraction): return fraction
        case .voice:
            if case .downloading(let fraction) = CoachNaturalVoice.shared.state { return fraction }
            return nil
        case .checkingJudge:
            if case .checking(_, let done, let total) = CoachCenter.shared.judgeState { return Double(done) / Double(max(total, 1)) }
            return nil
        case .done: return 1
        case .idle, .failed: return isSetUp ? 1 : 0
        }
    }

    func close() {
        UserDefaults.standard.set(true, forKey: CoachPreferences.modelSetupSeenKey)
        presenting = false
    }

    func isInstalled(_ model: String) -> Bool {
        guard case .running(let installed) = server else { return false }
        return installed.contains(model)
    }

    var missing: [CoachStarterModel] {
        models.filter { !isInstalled($0.name) }
    }

    /// Everything Coach recommends is here, the recommended judge has been
    /// checked, and the jobs have a partner and a judge that passed.
    var isSetUp: Bool {
        guard case .running = server, missing.isEmpty, CoachPreferences.judgeGrade(for: judge) != nil else { return false }
        let setup = CoachModels.current()
        return setup.sceneModel == CoachStarterModels.partner && CoachModels.judgeTrusted(setup)
    }

    func refresh() async {
        if case .running = server {} else { server = .checking }
        if let installed = await CoachModels.installed() {
            server = .running(installed: installed)
        } else {
            server = .notRunning
        }
    }

    /// Ollama.app, when it's installed but not running.
    var ollamaApp: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.ollama")
            ?? ["/Applications/Ollama.app", NSHomeDirectory() + "/Applications/Ollama.app"]
                .map { URL(fileURLWithPath: $0) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Opens Ollama, or its download page, then looks again once it's had a moment.
    func startOllama() async {
        if let app = ollamaApp {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(1))
                await refresh()
                if case .running = server { return }
            }
        } else {
            NSWorkspace.shared.open(Self.ollamaDownloadURL)
        }
    }

    /// Downloads what's missing, fetches the voice, checks the judge, and
    /// points each job at its model.
    func setUp() async {
        guard !isWorking else { return }
        await refresh()
        guard case .running = server else {
            step = .failed("Start Ollama first.")
            return
        }
        let setup = CoachModels.current()
        let client = LocalLLM.client(for: setup.provider)
        for model in missing {
            guard setup.provider.supportsModelInstall else {
                step = .failed("Download \(model.name) in \(setup.provider.displayName), then try again.")
                return
            }
            step = .downloading(model: model.name, fraction: nil)
            do {
                try await client.downloadModel(baseURLString: setup.endpoint, model: model.name) { progress in
                    Task { @MainActor in
                        let center = CoachModelSetupCenter.shared
                        guard case .downloading(let current, _) = center.step, current == model.name else { return }
                        center.step = .downloading(model: model.name, fraction: progress.fractionCompleted)
                    }
                }
            } catch {
                Logger.model.error("Coach couldn't download \(model.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                step = .failed("\(model.name) didn't download: \(error.localizedDescription)")
                return
            }
        }
        await refresh()

        let voice = CoachNaturalVoice.shared
        if includeVoice, voice.state != .ready {
            step = .voice
            await voice.install()
        }

        if CoachPreferences.judgeGrade(for: judge) == nil {
            step = .checkingJudge
            await CoachCenter.shared.checkJudges([judge])
        }

        let defaults = UserDefaults.standard
        defaults.set(CoachStarterModels.partner, forKey: CoachPreferences.partnerModelKey)
        // Automatic: the best model that passed the judge check.
        defaults.removeObject(forKey: CoachPreferences.coachModelKey)
        defaults.removeObject(forKey: CoachPreferences.judgeModelKey)
        defaults.set(true, forKey: CoachPreferences.modelSetupSeenKey)
        NotificationCenter.default.post(name: .coachPreferencesDidChange, object: nil)
        await CoachCenter.shared.refreshJudgeState()
        step = .done
    }
}
