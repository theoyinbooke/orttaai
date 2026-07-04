// ChatAIView.swift
// Orttaai

import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

private enum ChatAIMessageRole: String, Codable {
    case user
    case assistant
}

private enum ChatAIThinkingDepth: String, CaseIterable, Codable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var numPredict: Int {
        switch self {
        case .low: return 600
        case .medium: return 1_200
        case .high: return 2_000
        }
    }

    var numContext: Int {
        switch self {
        case .low: return 4_096
        case .medium: return 8_192
        case .high: return 16_384
        }
    }

    var instruction: String {
        switch self {
        case .low:
            return "Work quickly. Prefer concise answers and ask only for essential clarification."
        case .medium:
            return "Reason through the writing task, then give a polished, practical answer."
        case .high:
            return "Think deeply about structure, tone, audience, and writing pattern before answering. Keep the final response organized and usable."
        }
    }
}

private enum ChatAIMode: String, CaseIterable, Identifiable {
    case regular = "Regular"
    case myTone = "My Tone"

    var id: String { rawValue }

    var title: String { rawValue }

    var systemImage: String {
        switch self {
        case .regular:
            return "text.bubble"
        case .myTone:
            return "person.wave.2"
        }
    }
}

private struct ChatAIMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let role: ChatAIMessageRole
    var content: String
    let createdAt: Date

    init(id: UUID = UUID(), role: ChatAIMessageRole, content: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

private struct ChatAIConversation: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var messages: [ChatAIMessage]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "New chat",
        messages: [ChatAIMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

private struct ChatAIUploadedDocument: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let content: String

    var wordCount: Int {
        content.split { $0.isWhitespace || $0.isNewline }.count
    }
}

private struct ChatAIStarterPrompt: Identifiable {
    let id = UUID()
    let title: String
    let prompt: String
    let systemImage: String
    let prefersMyTone: Bool
}

private struct HiddenScrollbarTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = NSColor.Orttaai.textPrimary
        textView.insertionPointColor = NSColor.Orttaai.textPrimary
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = NSColor.Orttaai.textPrimary
        textView.insertionPointColor = NSColor.Orttaai.textPrimary
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var textView: NSTextView?

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

private struct ChatAIRichMessageText: View {
    let content: String

    var body: some View {
        Text(Self.attributedContent(from: content))
            .font(.Orttaai.body)
            .foregroundStyle(Color.Orttaai.textPrimary)
            .textSelection(.enabled)
            .lineSpacing(3)
    }

    private static func attributedContent(from content: String) -> AttributedString {
        if containsHTML(content), let attributedHTML = htmlAttributedContent(from: content) {
            return attributedHTML
        }

        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let attributedMarkdown = try? AttributedString(markdown: content, options: options) {
            return attributedMarkdown
        }

        return AttributedString(content)
    }

    private static func containsHTML(_ content: String) -> Bool {
        let pattern = #"<\s*(p|br|div|span|strong|b|em|i|ul|ol|li|a|code|pre|blockquote|h[1-6]|table|thead|tbody|tr|td|th)\b[^>]*>"#
        return content.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func htmlAttributedContent(from content: String) -> AttributedString? {
        let html = """
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        body {
            color: #F5F3F0;
            font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            font-size: 13px;
            line-height: 1.42;
        }
        p { margin: 0 0 10px 0; }
        h1, h2, h3, h4, h5, h6 { margin: 12px 0 8px 0; font-weight: 650; }
        ul, ol { margin: 8px 0 10px 22px; padding: 0; }
        li { margin: 4px 0; }
        code, pre {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            background-color: #3A3A3C;
        }
        blockquote {
            margin: 8px 0;
            padding-left: 12px;
            color: #A1A1A6;
        }
        a { color: #D4952A; }
        </style>
        </head>
        <body>\(content)</body>
        </html>
        """

        guard let data = html.data(using: .utf8),
              let nsAttributedString = try? NSMutableAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
              ) else {
            return nil
        }

        nsAttributedString.addAttribute(
            .foregroundColor,
            value: NSColor.Orttaai.textPrimary,
            range: NSRange(location: 0, length: nsAttributedString.length)
        )

        return AttributedString(nsAttributedString)
    }
}

private struct ChatAIActivityIndicator: View {
    let title: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmerOffset: CGFloat = -1

    var body: some View {
        HStack(spacing: Spacing.sm) {
            animatedDots

            Text(title)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .fill(Color.Orttaai.bgSecondary.opacity(0.7))

                if !reduceMotion {
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.clear,
                                        Color.Orttaai.accent.opacity(0.16),
                                        Color.clear
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(geometry.size.width, 1) * 0.45)
                            .offset(x: shimmerOffset * max(geometry.size.width, 1))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .stroke(Color.Orttaai.border.opacity(0.52), lineWidth: BorderWidth.standard)
        )
        .onAppear {
            guard !reduceMotion else { return }
            shimmerOffset = -1
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) {
                shimmerOffset = 1.5
            }
        }
    }

    private var animatedDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.Orttaai.accent.opacity(0.72))
                    .frame(width: 6, height: 6)
                    .modifier(ChatAIDotPulse(index: index, reduceMotion: reduceMotion))
            }
        }
        .frame(width: 28, height: 16)
    }
}

private struct ChatAIDotPulse: ViewModifier {
    let index: Int
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.phaseAnimator([false, true]) { view, phase in
                view
                    .offset(y: phase ? -3 : 3)
                    .opacity(phase ? 1 : 0.42)
            } animation: { _ in
                .easeInOut(duration: 0.54)
                    .delay(Double(index) * 0.14)
                    .repeatForever(autoreverses: true)
            }
        }
    }
}

private struct ChatAIVoiceControlLabel: View {
    let isRecording: Bool
    let isProcessing: Bool
    let isEnabled: Bool

    var body: some View {
        Group {
            if isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 34, height: 34)
                    .background(Color.Orttaai.bgTertiary.opacity(0.72))
                    .clipShape(Circle())
            } else {
                ChatAIVoiceBars(
                    isActive: isRecording,
                    color: isRecording ? Color.Orttaai.bgPrimary : (isEnabled ? Color.Orttaai.textSecondary : Color.Orttaai.textTertiary)
                )
                    .frame(width: 34, height: 34)
                    .background(
                        isRecording
                            ? Color.Orttaai.accent
                            : (isEnabled ? Color.Orttaai.bgTertiary.opacity(0.48) : Color.Orttaai.bgTertiary.opacity(0.28))
                    )
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(
                                isRecording ? Color.Orttaai.accentRing : Color.Orttaai.border.opacity(0.38),
                                lineWidth: BorderWidth.standard
                            )
                    )
                    .opacity(isEnabled ? 1 : 0.54)
            }
        }
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.18), value: isRecording)
        .animation(.easeInOut(duration: 0.18), value: isProcessing)
        .animation(.easeInOut(duration: 0.18), value: isEnabled)
    }
}

private struct ChatAIVoiceBars: View {
    let isActive: Bool
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let inactiveHeights: [CGFloat] = [8, 14, 10]
    private let activeHeights: [CGFloat] = [16, 22, 13]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(color)
                    .frame(width: 3, height: barHeight(index))
                    .modifier(ChatAIVoiceBarPulse(index: index, isActive: isActive, reduceMotion: reduceMotion))
            }
        }
        .frame(width: 18, height: 22)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let heights = isActive ? activeHeights : inactiveHeights
        return heights[index % heights.count]
    }
}

private struct ChatAIVoiceBarPulse: ViewModifier {
    let index: Int
    let isActive: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if !isActive || reduceMotion {
            content
        } else {
            content.phaseAnimator([false, true]) { view, phase in
                view
                    .scaleEffect(y: phase ? 0.56 : 1.14, anchor: .center)
                    .opacity(phase ? 0.72 : 1)
            } animation: { _ in
                .easeInOut(duration: 0.42)
                    .delay(Double(index) * 0.08)
                    .repeatForever(autoreverses: true)
            }
        }
    }
}

@MainActor
private final class ChatAIViewModel: ObservableObject {
    @Published var conversations: [ChatAIConversation] = []
    @Published var selectedConversationID: UUID?
    @Published var draft: String = ""
    @Published var availableModels: [String] = []
    @Published var selectedModel: String = ""
    @Published var mode: ChatAIMode = .regular
    @Published var thinkingEnabled: Bool = false
    @Published var thinkingDepth: ChatAIThinkingDepth = .medium
    @Published var uploadedDocuments: [ChatAIUploadedDocument] = []
    @Published var isHistoryVisible: Bool = false
    @Published var isSending: Bool = false
    /// Partial assistant reply while a streaming provider is generating;
    /// nil when idle or when the provider doesn't stream.
    @Published var streamingReply: String?
    @Published var isLoadingModels: Bool = false
    @Published var isVoiceRecording: Bool = false
    @Published var isVoiceProcessing: Bool = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var searchText: String = ""

    private let storageKey = "chatAIConversations"
    private let settings = AppSettings()

    /// Resolved per use so provider switches take effect without a restart.
    private var client: any LocalLLMServing { settings.activeLocalLLMClient }
    private let semanticMemory = SemanticMemoryService()
    private let voiceAudioService = AudioCaptureService()
    /// Only used when the app-wide service isn't available (e.g. previews).
    private lazy var fallbackVoiceTranscriptionService = TranscriptionService()
    /// The shared warm transcription model — same instance the dictation
    /// hotkey uses, so chat voice pays no model load and no extra memory.
    private var voiceTranscriptionService: TranscriptionService {
        ModelManager.shared?.runtimeTranscriptionService ?? fallbackVoiceTranscriptionService
    }
    private var voiceLiveDecodeTask: Task<Void, Never>?
    private var didLoad = false
    private var voiceRecordingStartedAt: Date?

    var selectedConversation: ChatAIConversation? {
        guard let selectedConversationID else { return nil }
        return conversations.first { $0.id == selectedConversationID }
    }

    var filteredConversations: [ChatAIConversation] {
        let sorted = conversations.sorted { $0.updatedAt > $1.updatedAt }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sorted }
        return sorted.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(query)
                || conversation.messages.contains { $0.content.localizedCaseInsensitiveContains(query) }
        }
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var canRecordVoice: Bool {
        !isSending && !isVoiceProcessing
    }

    var selectedModelDisplayName: String {
        selectedModel.isEmpty ? "Choose model" : selectedModel
    }

    var selectedModelSupportsThinking: Bool {
        settings.localLLMProvider.supportsThinkFlag && Self.modelSupportsThinking(selectedModel)
    }

    var hasMessages: Bool {
        selectedConversation?.messages.isEmpty == false
    }

    var hasToneProfile: Bool {
        ToneOfVoiceProfileStore.load() != nil
    }

    var emptyGreeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let daypart: String
        switch hour {
        case 5..<12:
            daypart = "Good morning"
        case 12..<17:
            daypart = "Good afternoon"
        case 17..<22:
            daypart = "Good evening"
        default:
            daypart = "Late night"
        }

        if mode == .myTone || hasToneProfile {
            return "\(daypart). Ready to write in your voice?"
        }

        return "\(daypart). What should we write with ChatAI?"
    }

    var starterPrompts: [ChatAIStarterPrompt] {
        [
            ChatAIStarterPrompt(
                title: "Rewrite in my tone",
                prompt: "Rewrite this in my tone while keeping it clear and natural:",
                systemImage: "person.wave.2",
                prefersMyTone: true
            ),
            ChatAIStarterPrompt(
                title: "Draft a polished reply",
                prompt: "Draft a polished, concise reply for this situation:",
                systemImage: "pencil.line",
                prefersMyTone: false
            )
        ]
    }

    func load() {
        guard !didLoad else { return }
        didLoad = true
        loadConversations()
        selectedModel = settings.normalizedLocalLLMInsightsModel
        if !selectedModelSupportsThinking {
            thinkingEnabled = false
        }

        Task {
            await refreshModels()
        }
    }

    func refreshModels() async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }

        let providerName = settings.localLLMProvider.displayName
        do {
            let models = try await client.fetchModelNames(
                baseURLString: settings.activeLocalLLMEndpoint,
                timeoutMs: 2_400
            )
            availableModels = models.sorted()
            if selectedModel.isEmpty {
                selectedModel = availableModels.first ?? settings.normalizedLocalLLMInsightsModel
            } else if !availableModels.isEmpty && !availableModels.contains(selectedModel) {
                selectedModel = availableModels.first ?? selectedModel
            }
            if !selectedModelSupportsThinking {
                thinkingEnabled = false
            }
            statusMessage = availableModels.isEmpty
                ? "\(providerName) is reachable, but no local models were found."
                : "\(availableModels.count) \(providerName) model\(availableModels.count == 1 ? "" : "s") ready."
            errorMessage = nil
        } catch {
            availableModels = []
            if selectedModel.isEmpty {
                selectedModel = settings.normalizedLocalLLMInsightsModel
            }
            statusMessage = nil
            errorMessage = "\(providerName) is not reachable at \(settings.activeLocalLLMEndpoint). Start \(providerName), then refresh models."
        }
    }

    func newConversation() {
        let conversation = ChatAIConversation()
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        draft = ""
        errorMessage = nil
        persistConversations()
    }

    func selectConversation(_ conversation: ChatAIConversation) {
        selectedConversationID = conversation.id
        draft = ""
        errorMessage = nil
    }

    func deleteConversation(_ conversation: ChatAIConversation) {
        conversations.removeAll { $0.id == conversation.id }
        if selectedConversationID == conversation.id {
            selectedConversationID = conversations.first?.id
        }
        if conversations.isEmpty {
            newConversation()
        } else {
            persistConversations()
        }
    }

    func attachDocument(from result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            for url in urls {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                let content = try readTextFile(at: url)
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                uploadedDocuments.append(
                    ChatAIUploadedDocument(
                        name: url.lastPathComponent,
                        content: String(trimmed.prefix(120_000))
                    )
                )
            }

            if uploadedDocuments.isEmpty {
                errorMessage = "No readable text was found in the selected file."
            } else {
                statusMessage = "\(uploadedDocuments.count) document\(uploadedDocuments.count == 1 ? "" : "s") available for RAG."
                errorMessage = nil
            }
        } catch {
            errorMessage = "Could not attach file: \(error.localizedDescription)"
        }
    }

    func removeDocument(_ document: ChatAIUploadedDocument) {
        uploadedDocuments.removeAll { $0.id == document.id }
    }

    func sendMessage() async {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSending else { return }
        if selectedConversationID == nil {
            newConversation()
        }
        guard let selectedConversationID else { return }

        draft = ""
        errorMessage = nil
        isSending = true
        streamingReply = nil
        defer {
            isSending = false
            streamingReply = nil
        }

        appendMessage(ChatAIMessage(role: .user, content: prompt), to: selectedConversationID)

        do {
            let messages = try await ollamaMessages(for: selectedConversationID, latestPrompt: prompt)
            let response = try await client.chatStream(
                baseURLString: settings.activeLocalLLMEndpoint,
                model: selectedModel,
                messages: messages,
                timeoutMs: nil,
                think: selectedModelSupportsThinking ? thinkingEnabled : nil,
                temperature: 0.35,
                numPredict: thinkingDepth.numPredict,
                numContext: thinkingDepth.numContext,
                keepAlive: "5m",
                onDelta: { [weak self] partial in
                    Task { @MainActor [weak self] in
                        guard let self, self.isSending else { return }
                        self.streamingReply = partial
                    }
                }
            )
            appendMessage(ChatAIMessage(role: .assistant, content: assistantVisibleContent(from: response)), to: selectedConversationID)
            statusMessage = "Generated with \(selectedModelDisplayName)."
        } catch {
            appendMessage(
                ChatAIMessage(
                    role: .assistant,
                    content: "I could not reach \(settings.localLLMProvider.displayName) or the selected model. \(error.localizedDescription)"
                ),
                to: selectedConversationID
            )
            errorMessage = error.localizedDescription
        }
    }

    func toggleVoiceInput() {
        guard canRecordVoice else { return }
        if isVoiceRecording {
            stopVoiceInput()
        } else {
            startVoiceInput()
        }
    }

    private func startVoiceInput() {
        do {
            let selectedDeviceID = DictationCoordinator.resolvedInputDeviceID(from: settings.selectedAudioDevice)
            try voiceAudioService.startCapture(deviceID: selectedDeviceID)
            voiceRecordingStartedAt = Date()
            isVoiceRecording = true
            errorMessage = nil
            statusMessage = "Listening..."
            startVoiceLiveDecode()
        } catch {
            isVoiceRecording = false
            voiceRecordingStartedAt = nil
            errorMessage = "Microphone unavailable: \(error.localizedDescription)"
        }
    }

    /// Mirrors the main dictation pipeline: the model warms and 15s clips are
    /// transcribed WHILE the user speaks, so stopping only decodes the short
    /// tail instead of the whole recording.
    private func startVoiceLiveDecode() {
        voiceLiveDecodeTask?.cancel()
        voiceLiveDecodeTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let service = self.voiceTranscriptionService

            await self.settings.syncTranscriptionSettings(to: service)
            if await !service.isLoaded {
                // Overlapped with recording instead of paid after stop.
                try? await service.loadModel(named: self.settings.selectedModelId)
            }
            guard !Task.isCancelled else { return }
            await service.beginLiveTranscriptionSession()

            while !Task.isCancelled {
                let snapshot = self.voiceAudioService.currentSamplesSnapshot()
                await service.processLiveAudioSnapshot(snapshot)
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }
    }

    private func stopVoiceInput() {
        guard isVoiceRecording else { return }
        isVoiceRecording = false
        voiceLiveDecodeTask?.cancel()
        voiceLiveDecodeTask = nil
        let samples = voiceAudioService.stopCapture()
        let duration = voiceRecordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        voiceRecordingStartedAt = nil

        guard duration >= 0.5, !samples.isEmpty else {
            statusMessage = nil
            errorMessage = "Recording was too short."
            Task { await voiceTranscriptionService.cancelLiveTranscriptionSession() }
            return
        }

        isVoiceProcessing = true
        statusMessage = "Transcribing..."
        Task {
            do {
                let service = voiceTranscriptionService
                if await !service.isLoaded {
                    await settings.syncTranscriptionSettings(to: service)
                    try await service.loadModel(named: settings.selectedModelId)
                }
                let transcript = try await service.finalizeLiveTranscription(audioSamples: samples)
                await MainActor.run {
                    isVoiceProcessing = false
                    insertVoiceTranscript(transcript)
                    statusMessage = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil
                        : "Voice added to message."
                    errorMessage = nil
                }
            } catch {
                await MainActor.run {
                    isVoiceProcessing = false
                    statusMessage = nil
                    errorMessage = "Could not transcribe voice: \(error.localizedDescription)"
                }
            }
        }
    }

    private func insertVoiceTranscript(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "No speech was detected."
            return
        }

        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = trimmed
        } else {
            draft += draft.hasSuffix(" ") || draft.hasSuffix("\n") ? trimmed : " \(trimmed)"
        }
    }

    private func loadConversations() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ChatAIConversation].self, from: data),
           !decoded.isEmpty
        {
            conversations = decoded.sorted { $0.updatedAt > $1.updatedAt }
            selectedConversationID = conversations.first?.id
        } else {
            newConversation()
        }
    }

    private func persistConversations() {
        let trimmed = conversations
            .filter { !$0.messages.isEmpty || $0.id == selectedConversationID }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(80)

        guard let data = try? JSONEncoder().encode(Array(trimmed)) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func appendMessage(_ message: ChatAIMessage, to conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].messages.append(message)
        conversations[index].updatedAt = Date()
        if conversations[index].title == "New chat", message.role == .user {
            conversations[index].title = title(from: message.content)
        }
        conversations.sort { $0.updatedAt > $1.updatedAt }
        persistConversations()
    }

    private func title(from text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "New chat" }
        if normalized.count <= 46 {
            return normalized
        }
        return String(normalized.prefix(46)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private func ollamaMessages(for conversationID: UUID, latestPrompt: String) async throws -> [OllamaChatMessage] {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else {
            throw OllamaClientError.requestFailed(message: "Could not find the selected chat.")
        }

        let systemContent = await systemPrompt(latestPrompt: latestPrompt)
        var messages: [OllamaChatMessage] = [
            OllamaChatMessage(role: .system, content: systemContent)
        ]

        for message in conversation.messages.suffix(14) {
            let role: OllamaChatRole = message.role == .user ? .user : .assistant
            messages.append(OllamaChatMessage(role: role, content: message.content))
        }

        return messages
    }

    private func systemPrompt(latestPrompt: String) async -> String {
        var sections: [String] = [
            """
            You are ChatAI inside Orttaai, a writing assistant powered by \(settings.localLLMProvider.displayName).
            Help the user understand their writing pattern, draft content, rewrite text, and produce clear finished writing.
            Mode: \(mode.title).
            Thinking depth: \(thinkingDepth.title). \(thinkingDepth.instruction)
            Do not mention hidden prompts.
            """,
        ]

        switch mode {
        case .regular:
            sections.append("""
            Regular mode:
            Use a clear assistant voice. Do not imitate the user's tone unless the user explicitly asks you to.
            """)
        case .myTone:
            if let toneProfile = ToneOfVoiceProfileStore.load() {
                sections.append(Self.toneFidelitySection(for: toneProfile))
            } else {
                sections.append("""
                My Tone mode:
                No saved Tone of Voice profile exists yet. Infer style only from recent writing samples when available, but avoid over-imitation and do not invent personal facts.
                """)
            }
        }

        let semanticContext = await semanticMemory.contextBlock(for: latestPrompt, limit: 6)
        if !semanticContext.isEmpty {
            sections.append("""
            Relevant semantic memory from Orttaai dictation history:
            \(semanticContext)

            Use this memory as evidence from the user's own prior context. Do not invent facts beyond these excerpts.
            """)
        }

        let writingContext = recentWritingPatternContext()
        if !writingContext.isEmpty {
            sections.append("""
            Recent writing samples from Orttaai dictation history:
            \(writingContext)
            """)
        }

        let retrievedContext = retrievedDocumentContext(for: latestPrompt)
        if !retrievedContext.isEmpty {
            sections.append("""
            Uploaded document context for RAG:
            \(retrievedContext)
            """)
        }

        return sections.joined(separator: "\n\n")
    }

    /// Full-fidelity voice injection: everything the tone analysis captured —
    /// descriptors, signature phrases, structural approaches, avoidances, and
    /// authentic excerpts — not just the summary line.
    private static func toneFidelitySection(for profile: ToneOfVoiceProfile) -> String {
        var lines: [String] = [
            "My Tone mode: you write AS the user. Every draft, rewrite, and reply must sound like them — their rhythm, their vocabulary, their warmth — never like a generic assistant.",
            "",
            "Voice guide:",
            profile.compactPromptGuide,
            "",
            "Tone summary: \(profile.summary)"
        ]

        if !profile.descriptors.isEmpty {
            lines.append("Voice descriptors: \(profile.descriptors.joined(separator: ", ")).")
        }
        if !profile.signaturePhrases.isEmpty {
            lines.append("Signature phrases — weave these in where they fit naturally, never force them: \(profile.signaturePhrases.joined(separator: " · "))")
        }
        if !profile.signatureApproaches.isEmpty {
            lines.append("How the user structures ideas — mirror these moves:")
            lines.append(contentsOf: profile.signatureApproaches.map { "- \($0)" })
        }
        if !profile.avoidances.isEmpty {
            lines.append("The user avoids these — never use them:")
            lines.append(contentsOf: profile.avoidances.map { "- \($0)" })
        }
        if !profile.sampleExcerpts.isEmpty {
            lines.append("Authentic excerpts of the user's own voice — match this register and cadence:")
            lines.append(contentsOf: profile.sampleExcerpts.prefix(3).map { "«\($0.trimmingCharacters(in: .whitespacesAndNewlines))»" })
        }

        lines.append("")
        lines.append("Fidelity rules: match sentence length and rhythm to the excerpts; keep the user's level of directness and formality even when the content changes; reuse their characteristic transitions and phrasing; do not invent personal facts or experiences.")

        if profile.confidencePercent < 50 {
            lines.append("This profile has low confidence (\(profile.confidencePercent)% from \(profile.wordCount) words) — imitate the broad strokes, not fine details.")
        } else {
            lines.append("Profile confidence: \(profile.confidencePercent)% from \(profile.wordCount) words across \(profile.sampleCount) samples.")
        }

        return lines.joined(separator: "\n")
    }

    private func recentWritingPatternContext() -> String {
        do {
            let database = try DatabaseManager()
            let records = try database.fetchRecent(limit: 8)
            return records
                .map { record in
                    "- \(record.text.replacingOccurrences(of: "\n", with: " ").prefix(520))"
                }
                .joined(separator: "\n")
        } catch {
            return ""
        }
    }

    private func retrievedDocumentContext(for query: String) -> String {
        guard !uploadedDocuments.isEmpty else { return "" }
        let queryTerms = Set(
            query.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count > 2 }
        )

        let chunks = uploadedDocuments.flatMap { document in
            chunk(document.content, size: 1_200).map { chunk in
                (document: document.name, text: chunk)
            }
        }

        let ranked = chunks
            .map { item -> (document: String, text: String, score: Int) in
                let lower = item.text.lowercased()
                let score = queryTerms.reduce(0) { total, term in
                    total + (lower.contains(term) ? 1 : 0)
                }
                return (item.document, item.text, score)
            }
            .sorted {
                if $0.score == $1.score {
                    return $0.text.count > $1.text.count
                }
                return $0.score > $1.score
            }
            .prefix(5)

        return ranked
            .map { item in
                "[\(item.document)] \(item.text)"
            }
            .joined(separator: "\n\n")
    }

    private func chunk(_ text: String, size: Int) -> [String] {
        var chunks: [String] = []
        var start = text.startIndex

        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            let chunk = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                chunks.append(chunk)
            }
            start = end
        }

        return chunks
    }

    private func assistantVisibleContent(from content: String) -> String {
        let visible = Self.visibleAssistantContent(in: content)
        guard !visible.isEmpty else {
            return thinkingEnabled
                ? "I completed the reasoning step but did not receive a final answer. Try sending again with Thinking off."
                : "I could not produce a final answer. Try sending again."
        }
        return visible
    }

    private static func visibleAssistantContent(in content: String) -> String {
        guard content.contains("<think>") else {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var remaining = content[...]
        var visible = ""

        while let start = remaining.range(of: "<think>") {
            visible += String(remaining[..<start.lowerBound])
            guard let end = remaining.range(of: "</think>", range: start.upperBound..<remaining.endIndex) else {
                return visible.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            remaining = remaining[end.upperBound...]
        }

        visible += String(remaining)
        return visible.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func modelSupportsThinking(_ model: String) -> Bool {
        let normalized = model.lowercased()
        let reasoningFamilies = [
            "qwen3",
            "qwen-3",
            "deepseek-r1",
            "deepseek-r",
            "glm-4",
            "gpt-oss",
            "reasoning",
            "think"
        ]
        return reasoningFamilies.contains { normalized.contains($0) }
    }

    private func readTextFile(at url: URL) throws -> String {
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        if let content = try? String(contentsOf: url, encoding: .utf16) {
            return content
        }
        let data = try Data(contentsOf: url)
        return String(decoding: data, as: UTF8.self)
    }
}

struct ChatAIView: View {
    @StateObject private var viewModel = ChatAIViewModel()
    @State private var isImportingDocument = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let activeComposerMaxWidth: CGFloat = 760
    private let emptyComposerMaxWidth: CGFloat = 700
    private let starterPromptMaxWidth: CGFloat = 560
    private let titlebarControlTopPadding: CGFloat = Spacing.lg

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                if viewModel.isHistoryVisible {
                    historyPanel
                        .frame(width: 286)
                        .transition(reduceMotion ? .identity : .move(edge: .leading).combined(with: .opacity))

                    Divider()
                        .background(Color.Orttaai.border.opacity(0.7))
                }

                chatSurface
            }

            if !viewModel.isHistoryVisible {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        viewModel.isHistoryVisible.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .background(Color.Orttaai.bgSecondary.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                        .stroke(Color.Orttaai.border.opacity(0.75), lineWidth: BorderWidth.standard)
                )
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
                .padding(.leading, Spacing.lg)
                .padding(.top, titlebarControlTopPadding)
                .help("Show ChatAI history")
                .accessibilityLabel("Show ChatAI history")
            }
        }
        .background(Color.Orttaai.bgPrimary)
        .ignoresSafeArea(.container, edges: .top)
        .fileImporter(
            isPresented: $isImportingDocument,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: viewModel.attachDocument
        )
        .onAppear {
            viewModel.load()
        }
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ChatAI")
                        .font(.Orttaai.heading)
                        .foregroundStyle(Color.Orttaai.textPrimary)

                    Text("Writing sessions")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                }

                Spacer()

                Button {
                    viewModel.newConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .help("New chat")

                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        viewModel.isHistoryVisible = false
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .help("Hide ChatAI history")
                .accessibilityLabel("Hide ChatAI history")
            }

            HStack(spacing: Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.Orttaai.textTertiary)
                TextField("Search", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.Orttaai.body)
                    .foregroundStyle(Color.Orttaai.textPrimary)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(Color.Orttaai.bgTertiary.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.filteredConversations) { conversation in
                        historyRow(conversation)
                    }
                }
            }

            if let statusMessage = viewModel.statusMessage {
                Label(statusMessage, systemImage: "circle.grid.2x2")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, titlebarControlTopPadding)
        .padding(.bottom, Spacing.lg)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.Orttaai.bgSecondary.opacity(0.72))
    }

    private func historyRow(_ conversation: ChatAIConversation) -> some View {
        Button {
            viewModel.selectConversation(conversation)
        } label: {
            Text(conversation.title)
                .font(.Orttaai.bodyMedium)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Color.Orttaai.textPrimary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .fill(
                        viewModel.selectedConversationID == conversation.id
                            ? Color.Orttaai.accentSubtle
                            : Color.clear
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .stroke(
                        viewModel.selectedConversationID == conversation.id
                            ? Color.Orttaai.accent.opacity(0.42)
                            : Color.clear,
                        lineWidth: BorderWidth.standard
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete", role: .destructive) {
                viewModel.deleteConversation(conversation)
            }
        }
    }

    private var chatSurface: some View {
        VStack(spacing: 0) {
            if viewModel.hasMessages {
                messageList
                composer
                    .padding(.horizontal, Spacing.xxxl)
                    .padding(.bottom, Spacing.xxl)
                    .frame(maxWidth: activeComposerMaxWidth)
            } else {
                Spacer(minLength: 0)

                VStack(spacing: Spacing.xxl) {
                    Text(viewModel.emptyGreeting)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Color.Orttaai.textPrimary)
                        .multilineTextAlignment(.center)

                    VStack(spacing: Spacing.md) {
                        composer
                            .frame(maxWidth: emptyComposerMaxWidth)

                        starterPromptRow
                            .frame(maxWidth: starterPromptMaxWidth)
                    }
                }
                .padding(.horizontal, Spacing.xxxl)

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                    Spacer()
                        .frame(height: Spacing.xxxl)

                    ForEach(viewModel.selectedConversation?.messages ?? []) { message in
                        messageBubble(message)
                            .id(message.id)
                    }

                    if viewModel.isSending {
                        if let partial = viewModel.streamingReply, !partial.isEmpty {
                            streamingBubble(partial)
                                .id("streaming-reply")
                        } else {
                            assistantActivityRow
                        }
                    }
                }
                .padding(.horizontal, Spacing.xxxl)
                .padding(.bottom, Spacing.xl)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: viewModel.selectedConversation?.messages.count ?? 0) { _, _ in
                guard let last = viewModel.selectedConversation?.messages.last else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.streamingReply) { _, partial in
                guard partial != nil else { return }
                proxy.scrollTo("streaming-reply", anchor: .bottom)
            }
        }
    }

    private func messageBubble(_ message: ChatAIMessage) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            if message.role == .user {
                Spacer(minLength: 80)
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                if message.role == .assistant {
                    Text("ChatAI")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                }

                if message.role == .assistant {
                    ChatAIRichMessageText(content: message.content)
                } else {
                    Text(message.content)
                        .font(.Orttaai.body)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                        .textSelection(.enabled)
                        .lineSpacing(3)
                }
            }
            .padding(message.role == .user ? Spacing.md : 0)
            .background(messageBubbleBackground(for: message))
            .overlay(messageBubbleBorder(for: message))

            if message.role == .assistant {
                Spacer(minLength: 80)
            }
        }
    }

    private var assistantActivityRow: some View {
        ChatAIActivityIndicator(
            title: viewModel.thinkingEnabled && viewModel.selectedModelSupportsThinking
                ? "Thinking..."
                : "Writing..."
        )
        .padding(.top, Spacing.xs)
    }

    /// In-progress assistant reply, styled like a finished assistant bubble.
    private func streamingBubble(_ partial: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("ChatAI")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)

                ChatAIRichMessageText(content: partial)
            }

            Spacer(minLength: 80)
        }
    }

    private var starterPromptRow: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(viewModel.starterPrompts) { starter in
                Button {
                    if starter.prefersMyTone, viewModel.hasToneProfile {
                        viewModel.mode = .myTone
                    }
                    viewModel.draft = starter.prompt
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: starter.systemImage)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(starter.prefersMyTone ? Color.Orttaai.accent : Color.Orttaai.textSecondary)

                        Text(starter.title)
                            .font(.Orttaai.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.86)
                    }
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .padding(.horizontal, Spacing.md)
                    .frame(height: 30)
                    .frame(maxWidth: .infinity)
                    .background(Color.Orttaai.bgTertiary.opacity(0.44))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.Orttaai.border.opacity(0.52), lineWidth: BorderWidth.standard)
                    )
                }
                .buttonStyle(.plain)
                .help(starter.prompt)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HiddenScrollbarTextView(text: $viewModel.draft)
                .frame(height: viewModel.hasMessages ? 54 : 82)
                .padding(.horizontal, Spacing.xl)
                .padding(.top, viewModel.hasMessages ? Spacing.md : Spacing.lg)
                .overlay(alignment: .topLeading) {
                    if viewModel.draft.isEmpty {
                        Text("Ask about your writing pattern or generate content")
                            .font(.Orttaai.body)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                            .padding(.horizontal, Spacing.xl)
                            .padding(.top, viewModel.hasMessages ? Spacing.md : Spacing.lg)
                            .allowsHitTesting(false)
                    }
                }

            if !viewModel.uploadedDocuments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.sm) {
                        ForEach(viewModel.uploadedDocuments) { document in
                            documentChip(document)
                        }
                    }
                    .padding(.horizontal, Spacing.lg)
                }
            }

            HStack(spacing: Spacing.sm) {
                Button {
                    isImportingDocument = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .help("Upload files for RAG")

                Label(viewModel.uploadedDocuments.isEmpty ? "RAG" : "RAG on", systemImage: "doc.text.magnifyingglass")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(viewModel.uploadedDocuments.isEmpty ? Color.Orttaai.textTertiary : Color.Orttaai.accent)

                Spacer(minLength: Spacing.sm)

                Button {
                    Task {
                        await viewModel.refreshModels()
                    }
                } label: {
                    Image(systemName: viewModel.isLoadingModels ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.Orttaai.textTertiary)
                .disabled(viewModel.isLoadingModels)
                .help("Refresh available models")

                modeMenu

                modelMenu

                if viewModel.selectedModelSupportsThinking {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            viewModel.thinkingEnabled.toggle()
                        }
                    } label: {
                        Image(systemName: "brain")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 34, height: 30)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(viewModel.thinkingEnabled ? Color.Orttaai.accent : Color.Orttaai.textSecondary)
                    .background(viewModel.thinkingEnabled ? Color.Orttaai.accentSubtle : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .help("Thinking mode")
                }

                depthMenu

                Button {
                    viewModel.toggleVoiceInput()
                } label: {
                    ChatAIVoiceControlLabel(
                        isRecording: viewModel.isVoiceRecording,
                        isProcessing: viewModel.isVoiceProcessing,
                        isEnabled: viewModel.canRecordVoice || viewModel.isVoiceRecording
                    )
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canRecordVoice && !viewModel.isVoiceRecording)
                .help(viewModel.isVoiceRecording ? "Stop voice input" : "Start voice input")

                Button {
                    Task {
                        await viewModel.sendMessage()
                    }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(viewModel.canSend ? Color.Orttaai.textPrimary : Color.Orttaai.bgTertiary)
                        .foregroundStyle(viewModel.canSend ? Color.Orttaai.bgPrimary : Color.Orttaai.textTertiary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canSend)
                .keyboardShortcut(.return, modifiers: [.command])
                .help("Send")
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.bottom, Spacing.md)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.warning)
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, Spacing.sm)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.Orttaai.bgSecondary.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.Orttaai.textTertiary.opacity(0.28), lineWidth: BorderWidth.standard)
        )
        .shadow(color: .black.opacity(0.28), radius: 28, x: 0, y: 16)
    }

    private func messageBubbleBackground(for message: ChatAIMessage) -> some View {
        RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
            .fill(message.role == .user ? Color.Orttaai.bgTertiary.opacity(0.62) : Color.clear)
    }

    private func messageBubbleBorder(for message: ChatAIMessage) -> some View {
        RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
            .stroke(message.role == .user ? Color.Orttaai.border.opacity(0.58) : Color.clear, lineWidth: BorderWidth.standard)
    }

    private var modelMenu: some View {
        Menu {
            if viewModel.availableModels.isEmpty {
                Button(viewModel.selectedModelDisplayName) {}
                    .disabled(true)
            } else {
                ForEach(viewModel.availableModels, id: \.self) { model in
                    Button(model) {
                        viewModel.selectedModel = model
                    }
                }
            }
        } label: {
            Text(viewModel.selectedModelDisplayName)
                .font(.Orttaai.bodyMedium)
                .lineLimit(1)
            .foregroundStyle(Color.Orttaai.textPrimary)
            .padding(.horizontal, Spacing.md)
            .frame(height: 30)
            .frame(maxWidth: 164)
        }
        .menuStyle(.borderlessButton)
        .help("Chat model")
    }

    private var modeMenu: some View {
        Menu {
            ForEach(ChatAIMode.allCases) { mode in
                Button {
                    viewModel.mode = mode
                } label: {
                    Label(mode.title, systemImage: mode.systemImage)
                }
            }

            if !viewModel.hasToneProfile {
                Divider()
                Text("Run Tone of Voice in Analytics to improve My Tone.")
            }
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: viewModel.mode.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(viewModel.mode.title)
                    .font(.Orttaai.bodyMedium)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.Orttaai.textTertiary)
            }
            .foregroundStyle(viewModel.mode == .myTone ? Color.Orttaai.accent : Color.Orttaai.textPrimary)
            .padding(.horizontal, Spacing.md)
            .frame(height: 30)
            .background(viewModel.mode == .myTone ? Color.Orttaai.accentSubtle : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .help("ChatAI mode")
    }

    private var depthMenu: some View {
        Menu {
            ForEach(ChatAIThinkingDepth.allCases) { depth in
                Button(depth.title) {
                    viewModel.thinkingDepth = depth
                }
            }
        } label: {
            Text(viewModel.thinkingDepth.title)
                .font(.Orttaai.bodyMedium)
            .foregroundStyle(Color.Orttaai.textPrimary)
            .padding(.horizontal, Spacing.md)
            .frame(height: 30)
        }
        .menuStyle(.borderlessButton)
        .help("Thinking depth")
    }

    private func documentChip(_ document: ChatAIUploadedDocument) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "doc.text")
                .font(.system(size: 11, weight: .medium))
            Text(document.name)
                .font(.Orttaai.caption)
                .lineLimit(1)
            Text("\(document.wordCount)w")
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
            Button {
                viewModel.removeDocument(document)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.Orttaai.textTertiary)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 5)
        .background(Color.Orttaai.bgTertiary.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
    }

}
