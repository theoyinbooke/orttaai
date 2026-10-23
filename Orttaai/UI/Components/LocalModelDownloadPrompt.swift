// LocalModelDownloadPrompt.swift
// Orttaai

import Combine
import SwiftUI

/// Makes sure a feature's model is on the user's local server before the
/// feature runs. When it isn't, it asks first ("Ollama will download
/// gemma4:e2b, about 7.2 GB"), has the server download it, then runs the
/// feature. The server stores and serves the model; Orttaai never holds
/// model files.
@MainActor
final class LocalModelDownloader: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        /// The model the feature uses.
        let model: String
        /// What to ask the server for; usually the same as `model`.
        let downloadName: String
        let provider: LocalLLMProviderKind
        /// What needs it, for the prompt ("Graph insights").
        let purpose: String
        let sizeText: String?
        let action: @MainActor () async -> Void
    }

    @Published var pendingRequest: Request?
    @Published private(set) var downloadingModel: String?
    @Published private(set) var progress: Double?
    @Published private(set) var status: String?
    @Published var errorMessage: String?

    var isDownloading: Bool { downloadingModel != nil }

    private let settings: AppSettings

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
    }

    /// Runs `action` straight away when `model` is installed, or when the
    /// server can't be reached (the feature then uses its own fallback).
    /// Otherwise asks to download it, and runs `action` once it's in.
    func run(
        model: String,
        downloadName: String? = nil,
        purpose: String,
        action: @escaping @MainActor () async -> Void
    ) async {
        errorMessage = nil
        let provider = settings.localLLMProvider
        let health = await settings.activeLocalLLMClient.checkHealth(
            baseURLString: settings.activeLocalLLMEndpoint,
            timeoutMs: 2_000
        )
        guard health.isReachable, !Self.isInstalled(model, in: health.installedModels) else {
            await action()
            return
        }
        pendingRequest = Request(
            model: model,
            downloadName: downloadName ?? model,
            provider: provider,
            purpose: purpose,
            sizeText: Self.sizeText(for: downloadName ?? model, provider: provider),
            action: action
        )
    }

    func confirm() {
        guard let request = pendingRequest else { return }
        pendingRequest = nil
        Task { await download(request) }
    }

    func cancel() {
        pendingRequest = nil
    }

    private func download(_ request: Request) async {
        downloadingModel = request.model
        progress = nil
        status = "Asking \(request.provider.displayName) to download \(request.model)…"
        defer {
            downloadingModel = nil
            progress = nil
            status = nil
        }
        do {
            try await settings.activeLocalLLMClient.downloadModel(
                baseURLString: settings.activeLocalLLMEndpoint,
                model: request.downloadName
            ) { [weak self] update in
                let text = Self.statusText(update, model: request.model, provider: request.provider)
                Task { @MainActor [weak self] in
                    self?.progress = update.fractionCompleted
                    self?.status = text
                }
            }
            status = "Downloaded \(request.model). Starting \(request.purpose.lowercased())…"
            await request.action()
        } catch {
            errorMessage = "Couldn't download \(request.model): \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    /// Ollama answers "gemma4:e2b" for "gemma4:e2b" and "nomic-embed-text:latest"
    /// for "nomic-embed-text"; LM Studio names are compared as they are.
    nonisolated static func isInstalled(_ model: String, in installed: [String]) -> Bool {
        func canonical(_ name: String) -> String {
            let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lowered.hasSuffix(":latest") ? String(lowered.dropLast(7)) : lowered
        }
        let target = canonical(model)
        guard !target.isEmpty else { return true }
        return installed.contains { canonical($0) == target }
    }

    nonisolated static func sizeText(for model: String, provider: LocalLLMProviderKind) -> String? {
        if model == provider.recommendedEmbeddingDownload, let size = provider.recommendedEmbeddingSize {
            return size
        }
        guard provider == .ollama, let bytes = OllamaClient.catalogSize(of: model) else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    nonisolated private static func statusText(_ update: OllamaPullProgress, model: String, provider: LocalLLMProviderKind) -> String {
        guard let done = update.completedBytes, let total = update.totalBytes, total > 0 else {
            return "\(provider.displayName) is downloading \(model)…"
        }
        let doneText = ByteCountFormatter.string(fromByteCount: done, countStyle: .file)
        let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return "\(provider.displayName) is downloading \(model): \(doneText) of \(totalText)"
    }
}

extension View {
    /// The "Download this model?" question for a `LocalModelDownloader`.
    func localModelDownloadPrompt(_ downloader: LocalModelDownloader) -> some View {
        alert(
            "Download \(downloader.pendingRequest?.model ?? "model")?",
            isPresented: Binding(
                get: { downloader.pendingRequest != nil },
                set: { if !$0 { downloader.cancel() } }
            ),
            presenting: downloader.pendingRequest
        ) { _ in
            Button("Download and Continue") { downloader.confirm() }
            Button("Cancel", role: .cancel) { downloader.cancel() }
        } message: { request in
            let size = request.sizeText.map { " (about \($0))" } ?? ""
            Text("\(request.purpose) uses \(request.model), which isn't in \(request.provider.displayName) yet. \(request.provider.displayName) will download it\(size) and run it on this Mac; Orttaai doesn't store models. Then \(request.purpose.lowercased()) continues.")
        }
    }
}

/// Download progress and errors for a `LocalModelDownloader`, shown where
/// the feature lives.
struct LocalModelDownloadStatus: View {
    @ObservedObject var downloader: LocalModelDownloader

    var body: some View {
        if let status = downloader.status {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(status)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .lineLimit(1)
                if downloader.isDownloading {
                    if let progress = downloader.progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(Color.Orttaai.accent)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(Color.Orttaai.accent)
                    }
                }
            }
            .padding(.vertical, Spacing.xs)
        }
        if let errorMessage = downloader.errorMessage {
            SettingsNotice(kind: .error, message: errorMessage) {
                downloader.errorMessage = nil
            }
        }
    }
}
