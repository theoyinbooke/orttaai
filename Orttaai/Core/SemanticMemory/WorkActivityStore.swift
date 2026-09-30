// WorkActivityStore.swift
// Orttaai

import Foundation
import Combine
import os

/// Reads the user's working sessions: what kind of work each was, what got
/// in the way, what was decided and left open. A local model (Ollama or LM
/// Studio, never the cloud) reads each session once, newest first, in the
/// background; until it has, an on-device estimate stands in. Readings are
/// cached, so after the first pass only new sessions cost anything.
final class WorkActivityStore: ObservableObject {
    static let shared = WorkActivityStore()

    enum AnalysisState: Equatable {
        case idle
        case checking
        case running(done: Int, total: Int, model: String)
        case pausedForDictation(done: Int, total: Int)
        case finished(model: String)
        case unavailable(String)
    }

    @Published private(set) var analysisState: AnalysisState = .idle
    /// Bumps whenever new readings land, so open views rebuild their report.
    @Published private(set) var revision = 0

    private let conceptStore: ConceptGraphStore
    private let databaseManager: DatabaseManager?
    private let settings: AppSettings
    private var analysisTask: Task<Void, Never>?
    private var isDictating = false
    private var dictationObserver: NSObjectProtocol?

    /// Sessions shorter than this carry too little to read.
    private static let minimumSessionLength = 120

    init(
        conceptStore: ConceptGraphStore = .shared,
        databaseManager: DatabaseManager? = nil,
        settings: AppSettings = AppSettings()
    ) {
        self.conceptStore = conceptStore
        self.databaseManager = databaseManager ?? (try? DatabaseManager())
        self.settings = settings
        dictationObserver = NotificationCenter.default.addObserver(
            forName: .dictationStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let raw = notification.userInfo?[DictationNotificationKey.state] as? String
            let state = raw.flatMap(DictationStateSignal.init(rawValue:))
            MainActor.assumeIsolated {
                self?.isDictating = state == .recording || state == .processing || state == .injecting
            }
        }
    }

    deinit {
        if let dictationObserver {
            NotificationCenter.default.removeObserver(dictationObserver)
        }
    }

    var isAnalyzing: Bool {
        switch analysisState {
        case .running, .pausedForDictation, .checking: return true
        default: return false
        }
    }

    // MARK: - Report

    func report(range: ConceptTimeRange, now: Date = Date()) async throws -> ActivityReport {
        let (sources, concepts) = try await conceptStore.prepared()
        let catalog = try await conceptStore.projectCatalog()
        let cached = (try? databaseManager?.fetchSessionAnalyses(promptVersion: SessionModelAnalyzer.promptVersion)) ?? [:]
        let readings = cached.compactMapValues(\.analysis)
        return await Task.detached(priority: .userInitiated) {
            let sessions = WorkSessionBuilder.sessions(sources: sources, conceptsByDictation: concepts)
            let analyzed = sessions.map { session in
                AnalyzedSession(session: session, analysis: readings[session.key] ?? SessionHeuristics.analyze(session))
            }
            return ActivityReportBuilder.build(
                sessions: analyzed,
                range: range,
                projects: catalog.projects,
                aliases: catalog.aliases,
                now: now
            )
        }.value
    }

    // MARK: - Background analysis

    /// Reads unread sessions with a local model, newest first. `horizonDays`
    /// bounds the backlog (nil reads everything).
    func startAnalysis(horizonDays: Int?) {
        guard analysisTask == nil else { return }
        analysisState = .checking
        analysisTask = Task { [weak self] in
            await self?.runAnalysis(horizonDays: horizonDays)
            self?.analysisTask = nil
        }
    }

    func stopAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        analysisState = .idle
    }

    private func runAnalysis(horizonDays: Int?) async {
        guard let databaseManager else {
            analysisState = .unavailable("The history database is unavailable.")
            return
        }
        let local = ConceptBriefWriter.localModel(settings: settings)
        let providerName = local.client.providerKind.displayName

        let installed: [String]
        do {
            installed = try await local.client.fetchModelNames(baseURLString: local.endpoint, timeoutMs: 3_000)
        } catch {
            analysisState = .unavailable("\(providerName) isn't running. Open it to read sessions with local AI.")
            return
        }
        let canonicalInstalled = Set(installed.map(Self.canonicalModelName))
        guard let model = local.candidates.first(where: { canonicalInstalled.contains(Self.canonicalModelName($0)) }) else {
            analysisState = .unavailable("No suitable model is installed in \(providerName). Install one in Model › AI Features.")
            return
        }

        let pending: [WorkSession]
        do {
            let (sources, concepts) = try await conceptStore.prepared()
            let done = try databaseManager.fetchSessionAnalyses(promptVersion: SessionModelAnalyzer.promptVersion)
            let horizonStart = horizonDays.map { Date().addingTimeInterval(-Double($0) * 86_400) }
            pending = await Task.detached(priority: .utility) {
                WorkSessionBuilder.sessions(sources: sources, conceptsByDictation: concepts)
                    .filter { done[$0.key] == nil && $0.text.count >= Self.minimumSessionLength }
                    .filter { horizonStart == nil || $0.end >= horizonStart! }
                    .sorted { $0.end > $1.end }
            }.value
        } catch {
            analysisState = .unavailable("Couldn't read your sessions: \(error.localizedDescription)")
            return
        }

        guard !pending.isEmpty else {
            analysisState = .finished(model: model)
            return
        }

        var failures = 0
        for (index, session) in pending.enumerated() {
            if Task.isCancelled { return }
            // Dictation polish shares the local model; it always goes first.
            while isDictating, !Task.isCancelled {
                analysisState = .pausedForDictation(done: index, total: pending.count)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            analysisState = .running(done: index, total: pending.count, model: model)
            do {
                let response = try await local.client.generate(
                    baseURLString: local.endpoint,
                    model: model,
                    prompt: SessionModelAnalyzer.prompt(for: session),
                    timeoutMs: 90_000,
                    think: false,
                    format: nil,
                    formatJSONSchema: SessionModelAnalyzer.schemaJSON,
                    temperature: 0.1,
                    numPredict: 240,
                    numContext: 4_096,
                    keepAlive: "2m"
                )
                failures = 0
                if let analysis = SessionModelAnalyzer.decode(response, model: model) {
                    try databaseManager.saveSessionAnalysis(SessionAnalysisRecord(
                        sessionKey: session.key,
                        promptVersion: SessionModelAnalyzer.promptVersion,
                        analysis: analysis,
                        sessionEnd: session.end,
                        analyzedAt: Date()
                    ))
                }
            } catch {
                if Task.isCancelled { return }
                failures += 1
                Logger.memory.warning("Session analysis failed: \(error.localizedDescription)")
                if failures >= 3 {
                    analysisState = .unavailable("\(providerName) stopped responding. Reading will resume next time.")
                    revision += 1
                    return
                }
            }
            if (index + 1) % 6 == 0 {
                revision += 1
            }
        }
        revision += 1
        analysisState = .finished(model: model)
    }

    private static func canonicalModelName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.contains(":") ? trimmed : "\(trimmed):latest"
    }
}
