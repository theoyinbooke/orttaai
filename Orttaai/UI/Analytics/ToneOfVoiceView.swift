// ToneOfVoiceView.swift
// Orttaai

import SwiftUI
import os

@MainActor
@Observable
final class ToneOfVoiceViewModel {
    var profile: ToneOfVoiceProfile?
    var availableModels: [String] = []
    var selectedModel: String = ""
    var isLoading = false
    var isLoadingModels = false
    var statusMessage: String?
    var errorMessage: String?
    var sampleCount = 0

    private let settings = AppSettings()
    private let service = ToneOfVoiceService()

    private var llmClient: any LocalLLMServing { settings.activeLocalLLMClient }
    private var didLoad = false

    var selectedModelDisplayName: String {
        selectedModel.isEmpty ? "Choose model" : selectedModel
    }

    func load() {
        guard !didLoad else { return }
        didLoad = true
        selectedModel = settings.normalizedLocalLLMInsightsModel
        profile = ToneOfVoiceProfileStore.load()

        Task {
            await refreshModels()
            await refreshSampleCount()
            if profile == nil, sampleCount > 0 {
                await runAnalysis()
            }
        }
    }

    func refreshModels() async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }

        do {
            let models = try await llmClient.fetchModelNames(
                baseURLString: settings.activeLocalLLMEndpoint,
                timeoutMs: 2_400
            )
            availableModels = models.sorted()
            if selectedModel.isEmpty {
                selectedModel = availableModels.first ?? settings.normalizedLocalLLMInsightsModel
            } else if !availableModels.isEmpty && !availableModels.contains(selectedModel) {
                selectedModel = availableModels.first ?? selectedModel
            }
            errorMessage = nil
        } catch {
            availableModels = []
            if selectedModel.isEmpty {
                selectedModel = settings.normalizedLocalLLMInsightsModel
            }
            errorMessage = "Ollama is not reachable at \(settings.normalizedLocalLLMEndpoint). Local metrics can still run."
        }
    }

    func runAnalysis() async {
        guard !isLoading else { return }
        isLoading = true
        statusMessage = "Analyzing tone of voice..."
        errorMessage = nil
        defer { isLoading = false }

        do {
            let db = try DatabaseManager()
            let records = try db.fetchRecent(limit: 800)
            sampleCount = records.count

            guard let result = await service.analyze(transcriptions: records, model: selectedModel) else {
                statusMessage = nil
                errorMessage = "No writing history is available yet. Dictate a few samples, then run tone analysis."
                return
            }

            profile = result.profile
            ToneOfVoiceProfileStore.save(result.profile)
            statusMessage = result.usedOllama
                ? "Tone profile updated with \(result.profile.model)."
                : "Tone profile updated from local metrics."
            errorMessage = result.errorMessage
        } catch {
            statusMessage = nil
            errorMessage = "Could not load transcription history."
            Logger.database.error("Tone of voice load failed: \(error.localizedDescription)")
        }
    }

    private func refreshSampleCount() async {
        do {
            let db = try DatabaseManager()
            sampleCount = try db.fetchRecent(limit: 800).count
        } catch {
            sampleCount = 0
        }
    }
}

private enum ToneVoiceSection: String, CaseIterable {
    case overview = "Overview"
    case style = "Tone & Style"
    case language = "Language"
    case guide = "Guide"
}

struct ToneOfVoiceView: View {
    @State private var viewModel = ToneOfVoiceViewModel()
    @State private var selectedSection: ToneVoiceSection = .overview

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                controls

                if let errorMessage = viewModel.errorMessage {
                    SettingsNotice(kind: .warning, message: errorMessage) {
                        viewModel.errorMessage = nil
                    }
                }

                if viewModel.isLoading, viewModel.profile == nil {
                    loadingCard
                } else if let profile = viewModel.profile {
                    switch selectedSection {
                    case .overview: overviewSection(profile)
                    case .style: styleSection(profile)
                    case .language: languageSection(profile)
                    case .guide: guideSection(profile)
                    }
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, WorkspaceLayout.contentHorizontalPadding)
            .padding(.bottom, Spacing.xxl)
        }
        .task {
            viewModel.load()
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: Spacing.md) {
            OrttaaiSegmentedControl(
                title: "Section",
                selection: $selectedSection,
                options: ToneVoiceSection.allCases.map { .init($0, $0.rawValue) }
            )

            Spacer(minLength: Spacing.md)

            if let statusMessage = viewModel.statusMessage, !viewModel.isLoading {
                Text(statusMessage)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }

            OrttaaiDropdown(
                selection: $viewModel.selectedModel,
                options: modelOptions,
                width: 170,
                placeholder: "Choose model"
            )
            .help("The model that analyzes your voice")

            Button {
                Task { await viewModel.refreshModels() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
            .disabled(viewModel.isLoadingModels)
            .help("Refresh the model list")
            .accessibilityLabel("Refresh the model list")

            Button {
                Task { await viewModel.runAnalysis() }
            } label: {
                HStack(spacing: Spacing.xs) {
                    if viewModel.isLoading {
                        ProgressView().controlSize(.mini)
                    }
                    Text(viewModel.isLoading ? "Analyzing…" : (viewModel.profile == nil ? "Analyze" : "Rerun"))
                }
            }
            .buttonStyle(OrttaaiButtonStyle(.primary, size: .small))
            .disabled(viewModel.isLoading)
            .help("Analyze your recent dictation again")
        }
    }

    private var modelOptions: [OrttaaiDropdown<String>.Option] {
        var names = viewModel.availableModels
        if !viewModel.selectedModel.isEmpty, !names.contains(viewModel.selectedModel) {
            names.insert(viewModel.selectedModel, at: 0)
        }
        return names.map { .init($0, $0) }
    }

    // MARK: - Overview

    private func overviewSection(_ profile: ToneOfVoiceProfile) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            heroCard(profile)

            if !profile.signaturePhrases.isEmpty {
                SettingsCard(
                    "Signature phrases",
                    info: "Phrases you use often enough that they sound like you."
                ) {
                    chips(Array(profile.signaturePhrases.prefix(10)).map { "\u{201C}\($0)\u{201D}" }, tint: Color.Orttaai.accent)
                        .padding(.bottom, Spacing.xs)
                }
            }

            equalHeightRow {
                listCard("Recommendations", icon: "checkmark.circle", values: profile.recommendations, tint: Color.Orttaai.warning)
                listCard("Use this voice", icon: "hand.thumbsup", values: profile.signatureApproaches, tint: Color.Orttaai.success)
                listCard("Avoid", icon: "hand.raised", values: profile.avoidances, tint: Color.Orttaai.error)
            }
        }
    }

    private func heroCard(_ profile: ToneOfVoiceProfile) -> some View {
        SettingsCard {
            HStack(alignment: .top, spacing: Spacing.xl) {
                ScoreRing(score: profile.overallScore)
                    .frame(width: 104, height: 104)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Voice match \(profile.overallScore) out of 100")

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    chips(profile.descriptors.prefix(6).map(\.capitalized), tint: Color.Orttaai.accent)
                    Text(profile.summary)
                        .font(.Orttaai.body)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(metaLine(profile))
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                }
            }
            .padding(.vertical, Spacing.sm)
        }
    }

    private func metaLine(_ profile: ToneOfVoiceProfile) -> String {
        [
            "\(profile.confidencePercent)% confidence",
            "\(profile.wordCount.formatted()) words from \(profile.sampleCount.formatted()) dictations",
            profile.model.isEmpty ? "local metrics" : profile.model,
            "updated \(profile.generatedAt.formatted(date: .abbreviated, time: .omitted))"
        ].joined(separator: " · ")
    }

    // MARK: - Tone & Style

    private func styleSection(_ profile: ToneOfVoiceProfile) -> some View {
        SettingsCard(
            "Tone and style",
            info: "How your dictation reads on each dimension, measured across your recent history."
        ) {
            StatusChip(
                title: "\(profile.confidencePercent)% confidence",
                systemImage: "checkmark.seal",
                tint: profile.wordCount >= 650 ? Color.Orttaai.success : Color.Orttaai.warning
            )
            .help(profile.wordCount >= 650 ? "Based on \(profile.wordCount.formatted()) words, an adequate sample." : "More dictation will make this more reliable.")
        } content: {
            ForEach(Array(profile.metrics.enumerated()), id: \.element.id) { index, metric in
                if index > 0 { SettingsDivider() }
                metricRow(metric)
            }
        }
    }

    private func metricRow(_ metric: ToneOfVoiceMetric) -> some View {
        let tint = metricTint(metric.name)
        return HStack(spacing: Spacing.md) {
            Image(systemName: metricIcon(metric.name))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
                .accessibilityHidden(true)
            SettingsLabel(title: metric.name, info: metric.detail)
                .frame(width: 150, alignment: .leading)
            Text(metric.label)
                .font(.Orttaai.caption.weight(.medium))
                .foregroundStyle(tint)
                .frame(width: 120, alignment: .leading)
                .lineLimit(1)
            progressBar(metric.value, tint: tint)
            Text("\(Int((metric.value * 100).rounded()))%")
                .font(.Orttaai.caption.monospacedDigit())
                .foregroundStyle(Color.Orttaai.textSecondary)
                .frame(width: 38, alignment: .trailing)
        }
        .frame(minHeight: 36)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Language

    private func languageSection(_ profile: ToneOfVoiceProfile) -> some View {
        let wordsPerSentence = Double(profile.wordCount) / Double(max(1, profile.sentenceCount))
        let complexity = metric(named: "Complexity", in: profile)?.value ?? 0.5
        let conversation = metric(named: "Conversation", in: profile)?.value ?? 0.5
        let readingGrade = min(12, max(3, Int((4 + wordsPerSentence / 8 + complexity * 4).rounded())))

        return VStack(alignment: .leading, spacing: Spacing.md) {
            equalHeightRow {
                statTile("Grade \(readingGrade)", "Reading level", info: "An estimate from sentence length and vocabulary.")
                statTile("~\(Int(wordsPerSentence.rounded()))", "Words per sentence", info: "Average sentence length in your dictation.")
                statTile(conversation > 0.68 ? "High" : conversation > 0.38 ? "Medium" : "Low", "Contractions", info: "How often you use contractions like \u{201C}it's\u{201D} and \u{201C}we'll\u{201D}.")
                statTile(complexity > 0.68 ? "Layered" : complexity > 0.38 ? "Clear" : "Simple", "Vocabulary", info: "How varied and complex your word choice is.")
            }

            if !profile.signatureApproaches.isEmpty {
                listCard("Notable traits", icon: "sparkle.magnifyingglass", values: Array(profile.signatureApproaches.prefix(5)), tint: Color.Orttaai.accent)
            }

            if !profile.sampleExcerpts.isEmpty {
                SettingsCard(
                    "In your words",
                    info: "Excerpts from your dictation the profile was built on."
                ) {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        ForEach(profile.sampleExcerpts, id: \.self) { excerpt in
                            HStack(alignment: .top, spacing: Spacing.sm) {
                                Rectangle()
                                    .fill(Color.Orttaai.accent.opacity(0.5))
                                    .frame(width: 2)
                                Text(excerpt)
                                    .font(.Orttaai.secondary)
                                    .foregroundStyle(Color.Orttaai.textSecondary)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.bottom, Spacing.xs)
                }
            }
        }
    }

    // MARK: - Guide

    private func guideSection(_ profile: ToneOfVoiceProfile) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SettingsCard(
                "ChatAI prompt guide",
                info: "What ChatAI's My Tone style sends to the model so replies sound like you."
            ) {
                CopyButton(title: "Copy", variant: .secondary, size: .small) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(profile.compactPromptGuide, forType: .string)
                }
            } content: {
                Text(profile.compactPromptGuide)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.Orttaai.bgPrimary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))
                    .padding(.bottom, Spacing.xs)
            }

            equalHeightRow {
                listCard("Use this voice", icon: "hand.thumbsup", values: profile.signatureApproaches, tint: Color.Orttaai.success)
                listCard("Avoid", icon: "hand.raised", values: profile.avoidances, tint: Color.Orttaai.error)
                listCard("Recommendations", icon: "checkmark.circle", values: profile.recommendations, tint: Color.Orttaai.warning)
            }
        }
    }

    // MARK: - Building blocks

    /// Cards in one row, all as tall as the tallest.
    private func equalHeightRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            content()
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func listCard(_ title: String, icon: String, values: [String], tint: Color) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Label(title, systemImage: icon)
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .labelStyle(TintedIconLabelStyle(tint: tint))
                if values.isEmpty {
                    SettingsFootnote("Nothing yet. Rerun after more dictation.")
                }
                ForEach(values.prefix(5), id: \.self) { value in
                    HStack(alignment: .top, spacing: Spacing.sm) {
                        Circle()
                            .fill(tint)
                            .frame(width: 5, height: 5)
                            .padding(.top, 6)
                            .accessibilityHidden(true)
                        Text(value)
                            .font(.Orttaai.secondary)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, Spacing.xs)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func statTile(_ value: String, _ label: String, info: String) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                SettingsLabel(title: label, info: info, font: .Orttaai.caption)
            }
            .padding(.vertical, Spacing.xs)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func chips(_ values: [String], tint: Color) -> some View {
        FlowLayout(spacing: Spacing.xs, rowSpacing: Spacing.xs) {
            ForEach(values, id: \.self) { value in
                Text(value)
                    .font(.Orttaai.caption)
                    .foregroundStyle(tint)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 4)
                    .background(tint.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
    }

    private var loadingCard: some View {
        SettingsCard {
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Analyzing your tone of voice…")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }
            .padding(.vertical, Spacing.sm)
        }
    }

    private var emptyState: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("No tone profile yet")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Text("Analyze your dictation history to see how you sound and get a guide ChatAI can write in.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, Spacing.xs)
        }
    }

    private func metric(named name: String, in profile: ToneOfVoiceProfile) -> ToneOfVoiceMetric? {
        profile.metrics.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    private func metricIcon(_ name: String) -> String {
        switch name {
        case "Formality": "building.columns"
        case "Warmth": "heart"
        case "Directness": "arrow.right.circle"
        case "Enthusiasm": "flame"
        case "Complexity": "square.stack.3d.up"
        case "Conversation": "bubble.left.and.bubble.right"
        default: "chart.bar"
        }
    }

    private func metricTint(_ name: String) -> Color {
        switch name {
        case "Formality": Color.Orttaai.accent
        case "Warmth": Color(hex: "E86F51")
        case "Directness": Color(hex: "E0B14A")
        case "Enthusiasm": Color(hex: "F97316")
        case "Complexity": Color(hex: "A855F7")
        case "Conversation": Color.Orttaai.success
        default: Color.Orttaai.accent
        }
    }

    private func progressBar(_ value: Double, tint: Color = Color.Orttaai.accent) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.Orttaai.bgTertiary)
                Capsule()
                    .fill(tint)
                    .frame(width: max(6, geometry.size.width * max(0, min(1, value))))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// The voice-match score as a ring that fills to the score.
private struct ScoreRing: View {
    let score: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.Orttaai.bgTertiary, lineWidth: 9)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, score))) / 100)
                .stroke(Color.Orttaai.accent, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(score)")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Text("voice match")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.Orttaai.textTertiary)
            }
        }
        .padding(5)
    }
}

private struct TintedIconLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Spacing.sm) {
            configuration.icon
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            configuration.title
        }
    }
}

private struct ToneBalancedCardGrid<Content: View>: View {
    let itemCount: Int
    let minimumColumnWidth: CGFloat
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(
        itemCount: Int,
        minimumColumnWidth: CGFloat,
        spacing: CGFloat = Spacing.md,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.itemCount = itemCount
        self.minimumColumnWidth = minimumColumnWidth
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        ToneBalancedGridLayout(
            itemCount: itemCount,
            minimumColumnWidth: minimumColumnWidth,
            spacing: spacing
        ) {
            content()
        }
    }
}

private struct ToneBalancedGridLayout: Layout {
    let itemCount: Int
    let minimumColumnWidth: CGFloat
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? requiredWidth(for: max(1, resolvedItemCount(subviews)))
        let columnCount = columnCount(for: width, subviews: subviews)
        let itemWidth = itemWidth(for: width, columns: columnCount)
        let rowHeights = rowHeights(for: subviews, columns: columnCount, itemWidth: itemWidth)
        let totalSpacing = spacing * CGFloat(max(0, rowHeights.count - 1))

        return CGSize(width: width, height: rowHeights.reduce(0, +) + totalSpacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columnCount = columnCount(for: bounds.width, subviews: subviews)
        let itemWidth = itemWidth(for: bounds.width, columns: columnCount)
        let rowHeights = rowHeights(for: subviews, columns: columnCount, itemWidth: itemWidth)
        var y = bounds.minY

        for row in 0..<rowHeights.count {
            let rowStart = row * columnCount
            let rowEnd = min(rowStart + columnCount, subviews.count)

            for index in rowStart..<rowEnd {
                let column = index - rowStart
                let x = bounds.minX + CGFloat(column) * (itemWidth + spacing)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: itemWidth, height: rowHeights[row])
                )
            }

            y += rowHeights[row] + spacing
        }
    }

    private func columnCount(for width: CGFloat, subviews: Subviews) -> Int {
        let count = max(1, resolvedItemCount(subviews))
        let options = (1...count).filter { count % $0 == 0 }.sorted(by: >)
        return options.first { requiredWidth(for: $0) <= width } ?? 1
    }

    private func resolvedItemCount(_ subviews: Subviews) -> Int {
        subviews.isEmpty ? itemCount : subviews.count
    }

    private func requiredWidth(for columns: Int) -> CGFloat {
        CGFloat(columns) * minimumColumnWidth + CGFloat(max(0, columns - 1)) * spacing
    }

    private func itemWidth(for width: CGFloat, columns: Int) -> CGFloat {
        let totalSpacing = spacing * CGFloat(max(0, columns - 1))
        return max(1, (width - totalSpacing) / CGFloat(max(1, columns)))
    }

    private func rowHeights(for subviews: Subviews, columns: Int, itemWidth: CGFloat) -> [CGFloat] {
        guard !subviews.isEmpty else { return [] }

        let rowCount = Int(ceil(Double(subviews.count) / Double(max(1, columns))))
        var heights = Array(repeating: CGFloat.zero, count: rowCount)

        for index in subviews.indices {
            let row = index / max(1, columns)
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: itemWidth, height: nil))
            heights[row] = max(heights[row], size.height)
        }

        return heights
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + rowSpacing
                rowHeight = 0
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
