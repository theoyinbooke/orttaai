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

private struct ChatAIHistoryGroup: Identifiable {
    let title: String
    var conversations: [ChatAIConversation]
    var id: String { title }
}

extension ChatAIConversation {
    /// One line of what the chat is about: the latest reply (or message),
    /// with Markdown marks stripped.
    var preview: String {
        guard let message = messages.last(where: { $0.role == .assistant }) ?? messages.last else { return "" }
        let line = message.content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") } ?? ""
        return line
            .replacingOccurrences(of: #"^(#{1,6}\s+|>\s*|[*+\-]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
    }

    /// "3:32 PM" today, "Tue" this week, "Oct 4" before.
    var shortTimestamp: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(updatedAt) {
            return updatedAt.formatted(date: .omitted, time: .shortened)
        }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: updatedAt), to: calendar.startOfDay(for: Date())).day, days < 7 {
            return updatedAt.formatted(.dateTime.weekday(.abbreviated))
        }
        return updatedAt.formatted(.dateTime.month(.abbreviated).day())
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
    /// One line under the title saying what it does.
    let detail: String
    let prompt: String
    let systemImage: String
    let prefersMyTone: Bool
    /// Sends at once; otherwise the prompt seeds the composer to finish.
    var sendsImmediately = false
}

private struct HiddenScrollbarTextView: NSViewRepresentable {
    @Binding var text: String
    /// Return sends; Shift-Return inserts a new line.
    var onSubmit: () -> Void = {}
    /// Escape.
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onCancel: onCancel)
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
        textView.disableWritingAssistance()
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
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onCancel = onCancel
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
        var onSubmit: () -> Void
        var onCancel: () -> Void
        weak var textView: NSTextView?

        init(text: Binding<String>, onSubmit: @escaping () -> Void, onCancel: @escaping () -> Void) {
            _text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onCancel()
                return true
            }
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  !textView.hasMarkedText() else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSubmit()
            }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

/// An assistant reply: Markdown rendered block by block (headings, lists,
/// tables, code), or HTML when a model answers in HTML.
private struct ChatAIRichMessageText: View {
    let content: String

    var body: some View {
        if Self.containsHTML(content) {
            Text(Self.attributedContent(from: content))
                .font(.Orttaai.body)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .textSelection(.enabled)
                .lineSpacing(3)
        } else {
            ChatAIMarkdownView(markdown: content)
        }
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
    /// Remembered, so the history panel stays as you left it.
    @Published var isHistoryVisible: Bool = UserDefaults.standard.bool(forKey: "chatAIHistoryVisible") {
        didSet { UserDefaults.standard.set(isHistoryVisible, forKey: "chatAIHistoryVisible") }
    }
    @Published var isSending: Bool = false
    /// Partial assistant reply while a streaming provider is generating;
    /// nil when idle or when the provider doesn't stream.
    @Published var streamingReply: String?
    /// The model's reasoning so far, when it streams any, updated at most
    /// once per `thoughtHoldSeconds` so each thought stays readable.
    @Published var streamingThought: String?
    private var thoughtShownAt: Date?
    private static let thoughtHoldSeconds: TimeInterval = 1.2
    /// When the reply in progress was requested; nil when idle.
    @Published var replyStartedAt: Date?
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

    var providerName: String { settings.localLLMProvider.displayName }
    /// The Memory Graph's Activity reading of the last 30 days, kept ready so
    /// "what did I decide?" doesn't wait on it; refreshed after each reply.
    private var workSummary = ""
    private let voiceAudioService = AudioCaptureService()
    /// Only used when the app-wide service isn't available (e.g. previews).
    private lazy var fallbackVoiceTranscriptionService = TranscriptionService()
    /// The shared warm transcription model — same instance the dictation
    /// hotkey uses, so chat voice pays no model load and no extra memory.
    private var voiceTranscriptionService: TranscriptionService {
        ModelManager.shared?.runtimeTranscriptionService ?? fallbackVoiceTranscriptionService
    }
    private var voiceModelWarmupTask: Task<Void, Never>?
    private var didLoad = false
    @Published private(set) var voiceRecordingStartedAt: Date?
    /// Models the provider says can't chat (an Ollama model without the
    /// completion capability) are left out of `availableModels`; this holds
    /// which of the rest can think, when the provider says.
    private var modelThinkingSupport: [String: Bool] = [:]

    /// The microphone level while recording, 0...1.
    var voiceInputLevel: Float { voiceAudioService.audioLevel }

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
        guard settings.localLLMProvider.supportsThinkFlag else { return false }
        return modelThinkingSupport[selectedModel] ?? Self.modelSupportsThinking(selectedModel)
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

        return daypart
    }

    var emptySubtitle: String {
        hasToneProfile
            ? "Draft, rewrite in your own voice, or ask how you write. Everything stays on this Mac."
            : "Draft, rewrite, or ask about how you write. Everything stays on this Mac."
    }

    /// The latest conversations with something in them, newest first.
    var recentConversations: [ChatAIConversation] {
        Array(conversations
            .filter { !$0.messages.isEmpty && $0.id != selectedConversationID }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(3))
    }

    var starterPrompts: [ChatAIStarterPrompt] {
        [
            ChatAIStarterPrompt(
                title: "Draft a polished reply",
                detail: "Turn a rough idea into a clear message",
                prompt: "Draft a polished, concise reply for this situation:",
                systemImage: "pencil.line",
                prefersMyTone: false
            ),
            ChatAIStarterPrompt(
                title: "Rewrite in my tone",
                detail: hasToneProfile ? "Sounds like you, not a template" : "Builds on Tone of Voice in Analytics",
                prompt: "Rewrite this in my tone while keeping it clear and natural:",
                systemImage: "person.wave.2",
                prefersMyTone: true
            ),
            ChatAIStarterPrompt(
                title: "Search my dictations",
                detail: "Ask what you said about anything",
                prompt: "What have I said about ",
                systemImage: "magnifyingglass",
                prefersMyTone: false
            ),
            ChatAIStarterPrompt(
                title: "How do I write?",
                detail: "Patterns from your recent dictation",
                prompt: "Look at how I've been writing lately. What patterns, habits and favourite phrases stand out, and what could I tighten?",
                systemImage: "text.magnifyingglass",
                prefersMyTone: false,
                sendsImmediately: true
            ),
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
        Task {
            await refreshWorkSummary()
        }
    }

    func refreshWorkSummary() async {
        guard let report = try? await WorkActivityStore.shared.report(range: .month), report.sessionCount > 0 else {
            workSummary = ""
            return
        }
        workSummary = Self.workSummary(from: report)
    }

    /// The headline, projects, decisions and open questions, each line short.
    static func workSummary(from report: ActivityReport) -> String {
        func day(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day()) }
        var lines = [report.headline.joined(separator: " ")]
        if !report.projects.isEmpty {
            lines.append("Projects: " + report.projects.prefix(5).map {
                "\($0.title) (\($0.sessions) sessions, last \(day($0.lastActive)))"
            }.joined(separator: "; "))
        }
        if !report.decisions.isEmpty {
            lines.append("Decisions:")
            lines += report.decisions.prefix(5).map { "- \(day($0.date)): \($0.text)" }
        }
        if !report.openQuestions.isEmpty {
            lines.append("Still open:")
            lines += report.openQuestions.prefix(5).map { "- \(day($0.date)): \($0.text)" }
        }
        return lines.joined(separator: "\n")
    }

    func refreshModels() async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }

        let providerName = settings.localLLMProvider.displayName
        do {
            let endpoint = settings.activeLocalLLMEndpoint
            let client = self.client
            let models = try await client.fetchModelNames(baseURLString: endpoint, timeoutMs: 2_400)
            let capabilities = await withTaskGroup(of: (String, Set<String>?).self) { group in
                for model in models {
                    group.addTask { (model, await client.modelCapabilities(baseURLString: endpoint, model: model, timeoutMs: 2_000)) }
                }
                return await group.reduce(into: [String: Set<String>?]()) { $0[$1.0] = $1.1 }
            }
            modelThinkingSupport = capabilities.compactMapValues { $0.map { $0.contains("thinking") } }
            availableModels = models
                .filter { capabilities[$0].flatMap { $0 }?.contains("completion") ?? true }
                .sorted()
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

    /// Chats with something in them, newest first, grouped by when they
    /// were last used: Today, Yesterday, Previous 7 Days, Previous 30 Days,
    /// then by month.
    var historyGroups: [ChatAIHistoryGroup] {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        var groups: [ChatAIHistoryGroup] = []
        for conversation in filteredConversations where !conversation.messages.isEmpty {
            let day = calendar.startOfDay(for: conversation.updatedAt)
            let daysAgo = calendar.dateComponents([.day], from: day, to: startOfToday).day ?? 0
            let title: String
            switch daysAgo {
            case ..<1: title = "Today"
            case 1: title = "Yesterday"
            case 2..<7: title = "Previous 7 Days"
            case 7..<30: title = "Previous 30 Days"
            default: title = conversation.updatedAt.formatted(.dateTime.month(.wide).year())
            }
            if let index = groups.firstIndex(where: { $0.title == title }) {
                groups[index].conversations.append(conversation)
            } else {
                groups.append(ChatAIHistoryGroup(title: title, conversations: [conversation]))
            }
        }
        return groups
    }

    var historyCount: Int {
        conversations.filter { !$0.messages.isEmpty }.count
    }

    func renameConversation(_ conversation: ChatAIConversation, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[index].title = trimmed
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
                statusMessage = "\(uploadedDocuments.count) document\(uploadedDocuments.count == 1 ? "" : "s") attached."
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
        streamingThought = nil
        thoughtShownAt = nil
        replyStartedAt = Date()
        defer {
            isSending = false
            streamingReply = nil
            streamingThought = nil
            thoughtShownAt = nil
            replyStartedAt = nil
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
                        let parts = ChatAIReplyStatus.splitInlineThinking(partial)
                        self.streamingReply = parts.visible.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let thought = parts.thought {
                            self.showThought(thought)
                        }
                    }
                },
                onThinking: { [weak self] thinking in
                    Task { @MainActor [weak self] in
                        guard let self, self.isSending else { return }
                        self.showThought(thinking)
                    }
                }
            )
            appendMessage(ChatAIMessage(role: .assistant, content: assistantVisibleContent(from: response)), to: selectedConversationID)
            statusMessage = "Generated with \(selectedModelDisplayName)."
            Task { await refreshWorkSummary() }
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

    /// A fast thinking model finishes a sentence many times a second; a new
    /// one replaces the status line only after the last has been readable.
    private func showThought(_ thinking: String) {
        let latest = ChatAIReplyStatus.latestThought(in: thinking)
        guard latest != nil, latest != ChatAIReplyStatus.latestThought(in: streamingThought) else { return }
        let now = Date()
        if let shownAt = thoughtShownAt, now.timeIntervalSince(shownAt) < Self.thoughtHoldSeconds { return }
        streamingThought = thinking
        thoughtShownAt = now
    }

    func toggleVoiceInput() {
        guard canRecordVoice else { return }
        if isVoiceRecording {
            stopVoiceInput()
        } else {
            startVoiceInput()
        }
    }

    /// Escape while recording: the recording is dropped.
    func cancelVoiceInput() {
        guard isVoiceRecording else { return }
        isVoiceRecording = false
        voiceModelWarmupTask?.cancel()
        voiceModelWarmupTask = nil
        _ = voiceAudioService.stopCapture()
        voiceRecordingStartedAt = nil
        statusMessage = nil
    }

    private func startVoiceInput() {
        do {
            let selectedDeviceID = DictationCoordinator.resolvedInputDeviceID(from: settings.selectedAudioDevice)
            try voiceAudioService.startCapture(deviceID: selectedDeviceID)
            voiceRecordingStartedAt = Date()
            isVoiceRecording = true
            errorMessage = nil
            statusMessage = "Listening..."
            prepareVoiceTranscriptionModel()
        } catch {
            isVoiceRecording = false
            voiceRecordingStartedAt = nil
            errorMessage = "Microphone unavailable: \(error.localizedDescription)"
        }
    }

    /// Warm the selected model while audio is captured, but do not decode
    /// partial clips. The complete recording is transcribed once at stop.
    private func prepareVoiceTranscriptionModel() {
        voiceModelWarmupTask?.cancel()
        voiceModelWarmupTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let service = self.voiceTranscriptionService

            await self.settings.syncTranscriptionSettings(to: service)
            if await !service.isLoaded {
                try? await service.loadModel(named: self.settings.dictationModelID())
            }
        }
    }

    private func stopVoiceInput() {
        guard isVoiceRecording else { return }
        isVoiceRecording = false
        voiceModelWarmupTask?.cancel()
        voiceModelWarmupTask = nil
        let samples = voiceAudioService.stopCapture()
        let duration = voiceRecordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        voiceRecordingStartedAt = nil

        guard duration >= 0.5, !samples.isEmpty else {
            statusMessage = nil
            errorMessage = "Recording was too short."
            return
        }

        isVoiceProcessing = true
        statusMessage = "Transcribing..."
        Task {
            do {
                let service = voiceTranscriptionService
                if await !service.isLoaded {
                    await settings.syncTranscriptionSettings(to: service)
                    try await service.loadModel(named: settings.dictationModelID())
                }
                let transcript = try await service.transcribe(audioSamples: samples)
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

        let semanticContext = await semanticMemory.contextBlock(for: latestPrompt, limit: 8)
        if !semanticContext.isEmpty {
            sections.append("""
            Relevant excerpts from the user's own Orttaai dictation history (app, date, relevance):
            \(semanticContext)
            """)
        }

        if !workSummary.isEmpty {
            sections.append("""
            What the user has been working on, read from their dictation over the last 30 days:
            \(workSummary)
            """)
        }

        if !semanticContext.isEmpty || !workSummary.isEmpty {
            sections.append("""
            Answering about the user's own past:
            When they ask what they said, did, decided or left open, answer from the excerpts and summary above. Lead with the answer, then a few short bullets. Say briefly when and where (for example "Oct 21, Slack"). Summarise instead of quoting long passages. If the memory doesn't cover it, say so plainly; never invent facts beyond it.
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
            "My Tone mode: you write AS the user. Every draft, rewrite, and reply must sound like their rhythm, vocabulary, and warmth, never like a generic assistant.",
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
            lines.append("Signature phrases. Use them naturally and never force them: \(profile.signaturePhrases.joined(separator: " · "))")
        }
        if !profile.signatureApproaches.isEmpty {
            lines.append("How the user structures ideas. Mirror these moves:")
            lines.append(contentsOf: profile.signatureApproaches.map { "- \($0)" })
        }
        if !profile.avoidances.isEmpty {
            lines.append("The user avoids these. Never use them:")
            lines.append(contentsOf: profile.avoidances.map { "- \($0)" })
        }
        if !profile.sampleExcerpts.isEmpty {
            lines.append("Authentic excerpts of the user's own voice. Match this register and cadence:")
            lines.append(contentsOf: profile.sampleExcerpts.prefix(3).map { "«\($0.trimmingCharacters(in: .whitespacesAndNewlines))»" })
        }

        lines.append("")
        lines.append("Fidelity rules: match sentence length and rhythm to the excerpts; keep the user's level of directness and formality even when the content changes; reuse their characteristic transitions and phrasing; do not invent personal facts or experiences.")

        if profile.confidencePercent < 50 {
            lines.append("This profile has low confidence (\(profile.confidencePercent)% from \(profile.wordCount) words). Imitate broad strokes, not fine details.")
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
    /// A question handed over from another page, sent in a new chat.
    @Binding var pendingPrompt: String?
    /// Opens Model › AI Features.
    var onOpenAISettings: () -> Void = {}
    @StateObject private var viewModel = ChatAIViewModel()
    @State private var isImportingDocument = false
    @State private var renamingConversation: ChatAIConversation?
    @State private var renameText = ""
    @State private var deletingConversation: ChatAIConversation?
    @State private var isSendHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let activeComposerMaxWidth: CGFloat = 760
    private let emptyComposerMaxWidth: CGFloat = 700

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

        }
        .background(Color.Orttaai.bgPrimary)
        .workspaceHeader("ChatAI") {
            HStack(spacing: Spacing.xs) {
                headerIconButton(
                    viewModel.isHistoryVisible ? "Hide chat history" : "Show chat history",
                    systemImage: "clock.arrow.circlepath",
                    isActive: viewModel.isHistoryVisible
                ) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        viewModel.isHistoryVisible.toggle()
                    }
                }

                headerIconButton("New chat", systemImage: "square.and.pencil") {
                    viewModel.newConversation()
                }
            }
        }
        .fileImporter(
            isPresented: $isImportingDocument,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: viewModel.attachDocument
        )
        .onAppear {
            viewModel.load()
            sendPendingPrompt()
        }
        .onChange(of: pendingPrompt) { _, _ in
            sendPendingPrompt()
        }
        .onChange(of: viewModel.isSending) { _, isSending in
            if !isSending {
                sendPendingPrompt()
            }
        }
    }

    /// Starts a new chat with a question another page handed over.
    private func sendPendingPrompt() {
        guard let prompt = pendingPrompt, !viewModel.isSending else { return }
        pendingPrompt = nil
        viewModel.newConversation()
        viewModel.draft = prompt
        Task {
            await viewModel.sendMessage()
        }
    }

    /// Chats grouped by date, with search, a preview of each, and rename and
    /// delete on hover or right-click.
    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text("Chats")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                if viewModel.historyCount > 0 {
                    Text(viewModel.historyCount.formatted())
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                }
                Spacer()
                headerIconButton("New chat", systemImage: "square.and.pencil") {
                    viewModel.newConversation()
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.sm)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.Orttaai.textTertiary)
                TextField("Search chats", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.Orttaai.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.Orttaai.bgPrimary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.Orttaai.border.opacity(0.6), lineWidth: BorderWidth.standard)
            )
            .padding(.horizontal, Spacing.md)
            .padding(.bottom, Spacing.sm)

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                    ForEach(viewModel.historyGroups) { group in
                        Section {
                            ForEach(group.conversations) { conversation in
                                ChatAIHistoryRow(
                                    conversation: conversation,
                                    isSelected: viewModel.selectedConversationID == conversation.id,
                                    onSelect: { viewModel.selectConversation(conversation) },
                                    onRename: {
                                        renameText = conversation.title
                                        renamingConversation = conversation
                                    },
                                    onDelete: { deletingConversation = conversation }
                                )
                            }
                        } header: {
                            Text(group.title)
                                .font(.Orttaai.caption.weight(.semibold))
                                .foregroundStyle(Color.Orttaai.textTertiary)
                                .padding(.horizontal, 10)
                                .padding(.top, Spacing.sm)
                                .padding(.bottom, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.Orttaai.bgSecondary)
                        }
                    }

                    if viewModel.historyGroups.isEmpty {
                        historyEmptyState
                    }
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.bottom, Spacing.md)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.Orttaai.bgSecondary)
        .alert("Rename chat", isPresented: Binding(
            get: { renamingConversation != nil },
            set: { if !$0 { renamingConversation = nil } }
        )) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let renamingConversation {
                    viewModel.renameConversation(renamingConversation, to: renameText)
                }
                renamingConversation = nil
            }
            Button("Cancel", role: .cancel) { renamingConversation = nil }
        }
        .confirmationDialog(
            "Delete this chat?",
            isPresented: Binding(
                get: { deletingConversation != nil },
                set: { if !$0 { deletingConversation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let deletingConversation {
                    viewModel.deleteConversation(deletingConversation)
                }
                deletingConversation = nil
            }
            Button("Cancel", role: .cancel) { deletingConversation = nil }
        } message: {
            Text("\u{201C}\(deletingConversation?.title ?? "")\u{201D} and its messages will be removed. This can't be undone.")
        }
    }

    private var historyEmptyState: some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: viewModel.searchText.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.Orttaai.textTertiary)
            Text(viewModel.searchText.isEmpty ? "No chats yet" : "No chats match \u{201C}\(viewModel.searchText)\u{201D}")
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.xxl)
    }

    /// Plain icon button for the ChatAI header, matching the sidebar toggle.
    private func headerIconButton(
        _ label: String,
        systemImage: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(isActive ? Color.Orttaai.accent : Color.Orttaai.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
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

                VStack(spacing: Spacing.xl) {
                    VStack(spacing: Spacing.sm) {
                        OrttaaiBrandMark()
                            .frame(width: 30 * SignalCursorGlyph.aspectRatio, height: 30)
                            .padding(.bottom, Spacing.xs)
                        Text(viewModel.emptyGreeting)
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.Orttaai.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Text(viewModel.emptySubtitle)
                            .font(.Orttaai.body)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                    }
                    .multilineTextAlignment(.center)

                    composer
                        .frame(maxWidth: emptyComposerMaxWidth)

                    starterPromptGrid
                        .frame(maxWidth: emptyComposerMaxWidth)

                    // The history panel already lists them when it's open.
                    if !viewModel.recentConversations.isEmpty, !viewModel.isHistoryVisible {
                        recentChats
                            .frame(maxWidth: emptyComposerMaxWidth)
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
                        .frame(height: Spacing.sm)

                    ForEach(viewModel.selectedConversation?.messages ?? []) { message in
                        messageBubble(message)
                            .id(message.id)
                    }

                    if viewModel.isSending {
                        replyInProgress
                            .id("streaming-reply")
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
                    ChatAIReplyHeader(startedAt: nil, hasWords: true, thinking: false, thought: nil)
                }

                if message.role == .assistant {
                    ChatAIRichMessageText(content: message.content)
                    ChatAICopyButton(text: message.content)
                        .padding(.top, 2)
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

    /// The reply being written: the beating mark with what it is doing,
    /// then its words streaming straight onto the background.
    private var replyInProgress: some View {
        let text = viewModel.streamingReply ?? ""
        return HStack(alignment: .top, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ChatAIReplyHeader(
                    startedAt: viewModel.replyStartedAt ?? Date(),
                    hasWords: !text.isEmpty,
                    thinking: viewModel.thinkingEnabled && viewModel.selectedModelSupportsThinking,
                    thought: viewModel.streamingThought
                )

                if !text.isEmpty {
                    ChatAIRichMessageText(content: text)
                }
            }

            Spacer(minLength: 80)
        }
    }

    private var starterPromptGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: Spacing.sm), GridItem(.flexible(), spacing: Spacing.sm)],
            spacing: Spacing.sm
        ) {
            ForEach(viewModel.starterPrompts) { starter in
                Button {
                    if starter.prefersMyTone, viewModel.hasToneProfile {
                        viewModel.mode = .myTone
                    }
                    viewModel.draft = starter.prompt
                    if starter.sendsImmediately {
                        Task {
                            await viewModel.sendMessage()
                        }
                    }
                } label: {
                    HStack(spacing: Spacing.md) {
                        Image(systemName: starter.systemImage)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.Orttaai.accent)
                            .frame(width: 30, height: 30)
                            .background(Color.Orttaai.accentSubtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(starter.title)
                                .font(.Orttaai.bodyMedium)
                                .foregroundStyle(Color.Orttaai.textPrimary)
                            Text(starter.detail)
                                .font(.Orttaai.caption)
                                .foregroundStyle(Color.Orttaai.textTertiary)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        if starter.sendsImmediately {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.Orttaai.textTertiary)
                        }
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(ChatAIStarterCardStyle())
                .help(starter.sendsImmediately ? "Ask now" : starter.prompt)
            }
        }
    }

    private var recentChats: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent")
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
                .padding(.horizontal, Spacing.sm)
                .padding(.bottom, 2)
            ForEach(viewModel.recentConversations) { conversation in
                Button {
                    viewModel.selectConversation(conversation)
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.Orttaai.textTertiary)
                        Text(conversation.title)
                            .font(.Orttaai.secondary)
                            .lineLimit(1)
                        Spacer(minLength: Spacing.sm)
                        Text(conversation.updatedAt, format: .relative(presentation: .named))
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                    }
                    .padding(.horizontal, Spacing.sm)
                    .frame(height: 28)
                }
                .buttonStyle(ChatAIComposerChipStyle())
            }
        }
    }

    /// Laid out like Codex's: a context strip tucked behind the top (what the
    /// reply draws on, and settings), then the input card with attach and
    /// mode on the left, and model, voice and send on the right.
    private var composer: some View {
        VStack(spacing: 0) {
            contextStrip
                .padding(.horizontal, 14)
                .padding(.top, 7)
                .padding(.bottom, 17)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14, style: .continuous)
                        .fill(Color.Orttaai.bgSecondary.opacity(0.55))
                )
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14, style: .continuous)
                        .stroke(Color.Orttaai.border.opacity(0.45), lineWidth: BorderWidth.standard)
                )
                .padding(.horizontal, 18)
                .padding(.bottom, -10)

            inputCard
                .zIndex(1)
        }
    }

    /// What the reply draws on: your dictation, the model server on this
    /// Mac, attached files; settings at the end.
    private var contextStrip: some View {
        HStack(spacing: Spacing.lg) {
            contextLabel("text.book.closed", "Your dictation")
                .help("Replies draw on your dictation history and recent work")
            contextLabel("laptopcomputer", "\(viewModel.providerName) · This Mac")
                .help("Runs on your own hardware")
            if !viewModel.uploadedDocuments.isEmpty {
                contextLabel("paperclip", viewModel.uploadedDocuments.count == 1 ? "1 file" : "\(viewModel.uploadedDocuments.count) files")
            }
            Spacer(minLength: Spacing.sm)
            Menu {
                Button {
                    Task { await viewModel.refreshModels() }
                } label: {
                    Label("Refresh Models", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoadingModels)
                Divider()
                Button {
                    onOpenAISettings()
                } label: {
                    Label("AI Settings…", systemImage: "slider.horizontal.3")
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .chatAIComposerMenu()
            .help("Chat settings")
        }
    }

    private func contextLabel(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
            Text(title)
                .font(.Orttaai.caption)
                .lineLimit(1)
        }
        .foregroundStyle(Color.Orttaai.textSecondary)
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HiddenScrollbarTextView(
                text: $viewModel.draft,
                onSubmit: {
                    if viewModel.isVoiceRecording {
                        viewModel.toggleVoiceInput()
                        return
                    }
                    guard viewModel.canSend else { return }
                    Task {
                        await viewModel.sendMessage()
                    }
                },
                onCancel: { viewModel.cancelVoiceInput() }
            )
                .frame(height: viewModel.hasMessages ? 44 : 64)
                .opacity(isVoiceActive ? 0 : 1)
                .allowsHitTesting(!isVoiceActive)
                .padding(.horizontal, Spacing.lg)
                .padding(.top, 14)
                .overlay(alignment: .topLeading) {
                    if isVoiceActive {
                        ChatAIVoiceStrip(
                            isProcessing: viewModel.isVoiceProcessing,
                            startedAt: viewModel.voiceRecordingStartedAt,
                            level: { viewModel.voiceInputLevel },
                            onCancel: { viewModel.cancelVoiceInput() }
                        )
                        .padding(.horizontal, Spacing.lg)
                        .padding(.top, 14)
                    } else if viewModel.draft.isEmpty {
                        Text("Ask about your dictation, or ask for a draft")
                            .font(.Orttaai.body)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                            .padding(.horizontal, Spacing.lg)
                            .padding(.top, 14)
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
                    .padding(.horizontal, Spacing.md)
                }
            }

            HStack(spacing: Spacing.xs) {
                Button {
                    isImportingDocument = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(ChatAIComposerChipStyle())
                .help("Attach documents")

                modeMenu

                Spacer(minLength: Spacing.sm)

                engineMenu

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
                .pointingHandCursor(when: viewModel.canRecordVoice || viewModel.isVoiceRecording)
                .help(viewModel.isVoiceRecording ? "Finish voice input (Return)" : "Speak your message")

                Button {
                    Task {
                        await viewModel.sendMessage()
                    }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(viewModel.canSend ? Color.Orttaai.textPrimary : Color.Orttaai.bgTertiary)
                        .foregroundStyle(viewModel.canSend ? Color.Orttaai.bgPrimary : Color.Orttaai.textTertiary)
                        .clipShape(Circle())
                        .scaleEffect(isSendHovered && viewModel.canSend ? 1.06 : 1)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isSendHovered)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canSend)
                .onHover { isSendHovered = $0 }
                .pointingHandCursor(when: viewModel.canSend)
                .keyboardShortcut(.return, modifiers: [.command])
                .help("Send (Return). Shift-Return adds a new line.")
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.bottom, Spacing.sm)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.warning)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.bottom, Spacing.sm)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.Orttaai.bgSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.Orttaai.textTertiary.opacity(0.26), lineWidth: BorderWidth.standard)
        )
        .shadow(color: .black.opacity(0.22), radius: 16, x: 0, y: 8)
    }

    private func messageBubbleBackground(for message: ChatAIMessage) -> some View {
        RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
            .fill(message.role == .user ? Color.Orttaai.bgTertiary.opacity(0.62) : Color.clear)
    }

    private func messageBubbleBorder(for message: ChatAIMessage) -> some View {
        RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
            .stroke(message.role == .user ? Color.Orttaai.border.opacity(0.58) : Color.clear, lineWidth: BorderWidth.standard)
    }

    private var isVoiceActive: Bool {
        viewModel.isVoiceRecording || viewModel.isVoiceProcessing
    }

    /// Model, reply depth and thinking in one menu, shown as
    /// "⚡ gemma4:e2b  Medium" like Codex's model and effort.
    private var engineMenu: some View {
        Menu {
            Section("Model") {
                if viewModel.availableModels.isEmpty {
                    Text("No chat models found")
                } else {
                    ForEach(viewModel.availableModels, id: \.self) { model in
                        Button {
                            viewModel.selectedModel = model
                        } label: {
                            if model == viewModel.selectedModel {
                                Label(model, systemImage: "checkmark")
                            } else {
                                Text(model)
                            }
                        }
                    }
                }
            }

            Section("Reply depth") {
                ForEach(ChatAIThinkingDepth.allCases) { depth in
                    Button {
                        viewModel.thinkingDepth = depth
                    } label: {
                        if depth == viewModel.thinkingDepth {
                            Label(depth.title, systemImage: "checkmark")
                        } else {
                            Text(depth.title)
                        }
                    }
                }
            }

            if viewModel.selectedModelSupportsThinking {
                Divider()
                Toggle("Thinking", isOn: $viewModel.thinkingEnabled)
            }
        } label: {
            ChatAIComposerChip {
                HStack(spacing: 5) {
                    Image(systemName: viewModel.thinkingEnabled && viewModel.selectedModelSupportsThinking ? "brain" : "bolt.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.Orttaai.textPrimary)
                    Text(viewModel.selectedModelDisplayName)
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 150, alignment: .leading)
                    Text(viewModel.thinkingDepth.title)
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .opacity(0.6)
                }
                .padding(.horizontal, 9)
                .frame(height: 30)
            }
        }
        .chatAIComposerMenu()
        .help("Model, reply depth and thinking")
    }

    private var modeMenu: some View {
        Menu {
            ForEach(ChatAIMode.allCases) { mode in
                Button {
                    viewModel.mode = mode
                } label: {
                    Label(mode.title, systemImage: mode.systemImage)
                }
                .disabled(mode == .myTone && !viewModel.hasToneProfile)
            }
        } label: {
            ChatAIComposerMenuLabel(
                systemImage: viewModel.mode.systemImage,
                title: viewModel.mode.title,
                isActive: viewModel.mode == .myTone
            )
        }
        .chatAIComposerMenu()
        .help(viewModel.hasToneProfile ? "Chat mode" : "Chat mode. My Tone needs a Tone of Voice profile from Analytics.")
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

/// One chat in the history: title and time, a line of preview; the
/// selected chat has an amber edge, and hovering swaps the time for delete.
private struct ChatAIHistoryRow: View {
    let conversation: ChatAIConversation
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.sm) {
                    Text(conversation.title)
                        .font(.Orttaai.secondary.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(Color.Orttaai.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: Spacing.xs)
                    if isHovered {
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.Orttaai.textTertiary)
                                .frame(width: 18, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Delete chat")
                    } else {
                        Text(conversation.shortTimestamp)
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                            .monospacedDigit()
                    }
                }
                if !conversation.preview.isEmpty {
                    Text(conversation.preview)
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.Orttaai.accentSubtle : (isHovered ? Color.Orttaai.bgTertiary.opacity(0.55) : Color.clear))
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(Color.Orttaai.accent)
                        .frame(width: 3, height: 18)
                        .padding(.leading, 3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Rename…", action: onRename)
            Divider()
            Button("Delete…", role: .destructive, action: onDelete)
        }
        .accessibilityLabel("\(conversation.title), \(conversation.shortTimestamp)")
    }
}

/// Copies a whole reply as written (Markdown included).
private struct ChatAICopyButton: View {
    let text: String
    @State private var didCopy = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            didCopy = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                didCopy = false
            }
        } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 22)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(ChatAIComposerChipStyle())
        .help(didCopy ? "Copied" : "Copy reply")
        .accessibilityLabel("Copy reply")
    }
}

/// A starter on the empty chat: a quiet card that lifts on hover.
private struct ChatAIStarterCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChatAIStarterCard(isPressed: configuration.isPressed) {
            configuration.label
        }
    }
}

private struct ChatAIStarterCard<Content: View>: View {
    var isPressed = false
    @ViewBuilder let content: () -> Content
    @State private var isHovered = false

    var body: some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovered ? Color.Orttaai.bgSecondary : Color.Orttaai.bgSecondary.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isHovered ? Color.Orttaai.accentRing : Color.Orttaai.border.opacity(0.5), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(isPressed ? 0.985 : 1)
            .onHover { isHovered = $0 }
            .pointingHandCursor(when: true)
            .animation(.easeOut(duration: 0.14), value: isHovered)
    }
}

/// The look every composer control shares: quiet until hovered, accent
/// when on, and the hand pointer whenever it can be clicked.
private struct ChatAIComposerChipStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        ChatAIComposerChip(isActive: isActive, isPressed: configuration.isPressed) {
            configuration.label
        }
    }
}

private struct ChatAIComposerChip<Content: View>: View {
    var isActive = false
    var isPressed = false
    @ViewBuilder let content: () -> Content

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        content()
            .foregroundStyle(isActive ? Color.Orttaai.accent : (isHovered && isEnabled ? Color.Orttaai.textPrimary : Color.Orttaai.textSecondary))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? Color.Orttaai.accentSubtle : (isHovered && isEnabled ? Color.Orttaai.bgTertiary.opacity(0.7) : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(isPressed ? 0.96 : 1)
            .onHover { isHovered = $0 }
            .pointingHandCursor(when: isEnabled)
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private struct ChatAIComposerMenuLabel: View {
    var systemImage: String?
    let title: String
    var isActive = false
    var maxTitleWidth: CGFloat?

    var body: some View {
        ChatAIComposerChip(isActive: isActive) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(title)
                    .font(.Orttaai.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: maxTitleWidth, alignment: .leading)
                    .fixedSize(horizontal: maxTitleWidth == nil, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.6)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
        }
    }
}

/// Shown in place of the text while a voice message is recorded or
/// transcribed: a live level meter and the time, with how to finish.
private struct ChatAIVoiceStrip: View {
    let isProcessing: Bool
    let startedAt: Date?
    let level: () -> Float
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Spacing.sm) {
            if isProcessing {
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing your voice…")
                    .font(.Orttaai.body)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                Spacer(minLength: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion)) { context in
                    HStack(spacing: Spacing.sm) {
                        Circle()
                            .fill(Color.Orttaai.error)
                            .frame(width: 8, height: 8)
                            .opacity(reduceMotion ? 1 : 0.55 + 0.45 * abs(sin(context.date.timeIntervalSinceReferenceDate * 2.4)))
                        Text(elapsed(at: context.date))
                            .font(.Orttaai.mono)
                            .foregroundStyle(Color.Orttaai.textPrimary)
                            .monospacedDigit()
                        meter(at: context.date)
                    }
                }
                Spacer(minLength: Spacing.sm)
                Text("Return to finish · Esc to cancel")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                Button("Cancel", action: onCancel)
                    .buttonStyle(ChatAIComposerChipStyle())
                    .font(.Orttaai.caption)
            }
        }
        .frame(height: 28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isProcessing ? "Transcribing your voice" : "Recording your voice")
    }

    private func elapsed(at now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(startedAt ?? now))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func meter(at now: Date) -> some View {
        let boosted = Double(min(Float(1), level() * 2.5 + 0.08))
        let time = now.timeIntervalSinceReferenceDate
        return HStack(alignment: .center, spacing: 2) {
            ForEach(0..<24, id: \.self) { index in
                let wave = reduceMotion ? 0.6 : 0.45 + 0.55 * abs(sin(Double(index) * 0.9 + time * 7))
                Capsule()
                    .fill(Color.Orttaai.accent.opacity(0.85))
                    .frame(width: 2.5, height: max(3, 20 * boosted * wave))
            }
        }
        .frame(height: 20)
    }
}

private extension View {
    func chatAIComposerMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

private extension View {
    /// The hand pointer over a control that can be clicked, and the arrow
    /// over one that can't. Saying so explicitly matters next to the
    /// composer's text view, whose I-beam otherwise lingers over buttons.
    @ViewBuilder
    func pointingHandCursor(when enabled: Bool) -> some View {
        if #available(macOS 15, *) {
            pointerStyle(enabled ? .link : .default)
        } else {
            modifier(ChatAILegacyPointer(enabled: enabled))
        }
    }
}

/// macOS 14 has no `pointerStyle`; push the cursor while hovered.
private struct ChatAILegacyPointer: ViewModifier {
    let enabled: Bool
    @State private var pushed = false

    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside, !pushed {
                (enabled ? NSCursor.pointingHand : NSCursor.arrow).push()
                pushed = true
            } else if !inside, pushed {
                NSCursor.pop()
                pushed = false
            }
        }
    }
}
