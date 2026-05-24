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
    private let ollamaClient = OllamaClient()
    private let service = ToneOfVoiceService()
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
            let models = try await ollamaClient.fetchModelNames(
                baseURLString: settings.normalizedLocalLLMEndpoint,
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

    var icon: String {
        switch self {
        case .overview: "mic"
        case .style: "chart.bar"
        case .language: "text.bubble"
        case .guide: "slider.horizontal.3"
        }
    }
}

struct ToneOfVoiceView: View {
    @State private var viewModel = ToneOfVoiceViewModel()
    @State private var selectedSection: ToneVoiceSection = .overview

    private let overviewTopCardMinHeight: CGFloat = 282
    private let overviewGuideCardMinHeight: CGFloat = 220
    private let guideListCardMinHeight: CGFloat = 190

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                controlsCard

                if viewModel.isLoading, viewModel.profile == nil {
                    loadingCard
                } else if let profile = viewModel.profile {
                    profileContent(profile)
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, Spacing.xxl)
            .padding(.bottom, Spacing.xxl)
        }
        .task {
            viewModel.load()
        }
    }

    private var controlsCard: some View {
        HStack(alignment: .center, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label("Tone of Voice", systemImage: "mic")
                    .font(.Orttaai.heading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Text("Build a local tone profile from your writing history, then use it in ChatAI's My Tone mode.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Spacing.lg)

            HStack(spacing: Spacing.sm) {
                modelMenu

                Button {
                    Task {
                        await viewModel.refreshModels()
                    }
                } label: {
                    Image(systemName: viewModel.isLoadingModels ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .disabled(viewModel.isLoadingModels)
                .help("Refresh Ollama models")

                Button {
                    Task {
                        await viewModel.runAnalysis()
                    }
                } label: {
                    HStack(spacing: Spacing.sm) {
                        if viewModel.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise.circle")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Text("Rerun")
                    }
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.bgPrimary)
                    .padding(.horizontal, Spacing.md)
                    .frame(height: 32)
                    .background(Color.Orttaai.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isLoading)
            }
        }
        .padding(Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .fill(Color.Orttaai.bgSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .stroke(Color.Orttaai.border, lineWidth: BorderWidth.standard)
        )
        .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
    }

    private func profileContent(_ profile: ToneOfVoiceProfile) -> some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            sectionTabs

            switch selectedSection {
            case .overview:
                overviewSection(profile)
            case .style:
                styleSection(profile)
            case .language:
                languageSection(profile)
            case .guide:
                guideSection(profile)
            }
        }
    }

    private func scoreCard(_ profile: ToneOfVoiceProfile) -> some View {
        voiceCard(
            title: "Voice Match",
            icon: "target",
            accent: Color.Orttaai.accent,
            minHeight: overviewTopCardMinHeight
        ) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(alignment: .lastTextBaseline, spacing: Spacing.xs) {
                    Text("\(profile.overallScore)")
                        .font(.system(size: 68, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.Orttaai.textPrimary)
                    Text("/100")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.Orttaai.textTertiary)
                    Spacer()
                    confidenceBadge(profile.confidencePercent)
                }

                progressBar(Double(profile.overallScore) / 100, tint: Color.Orttaai.accent)

                tagCloud(profile.descriptors.prefix(5).map { $0.capitalized }, tint: Color.Orttaai.accent)

                Divider()
                    .background(Color.Orttaai.border)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("\(profile.wordCount.formatted()) words across \(profile.sampleCount.formatted()) samples")
                    Text("Model: \(profile.model.isEmpty ? "Local metrics" : profile.model)")
                    Text("Updated \(profile.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                }
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
            }
        }
    }

    private func summaryCard(_ profile: ToneOfVoiceProfile) -> some View {
        voiceCard(
            title: "Profile",
            icon: "person.text.rectangle",
            accent: Color.Orttaai.warning,
            minHeight: overviewTopCardMinHeight
        ) {
            Text(profile.summary)
                .font(.Orttaai.body)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            if !profile.recommendations.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Recommendations")
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.textPrimary)

                    ForEach(profile.recommendations.prefix(4), id: \.self) { recommendation in
                        Label(recommendation, systemImage: "checkmark.circle")
                            .font(.Orttaai.secondary)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            statusLine
        }
    }

    private func metricCard(_ metric: ToneOfVoiceMetric) -> some View {
        let tint = metricTint(metric.name)
        return voiceCard(title: metric.name, icon: metricIcon(metric.name), accent: tint, compact: true) {
            HStack {
                Text(metric.label)
                    .font(.Orttaai.caption)
                    .foregroundStyle(tint)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 4)
                    .background(tint.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Spacer()
                Text("\(Int((metric.value * 100).rounded()))%")
                    .font(.Orttaai.caption.monospacedDigit())
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }

            progressBar(metric.value, tint: tint)

            Text(metric.detail)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func profileListCard(
        title: String,
        icon: String? = nil,
        values: [String],
        accent: Color,
        minHeight: CGFloat? = nil
    ) -> some View {
        voiceCard(title: title, icon: icon, accent: accent, minHeight: minHeight) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(values.prefix(6), id: \.self) { value in
                    HStack(alignment: .top, spacing: Spacing.sm) {
                        Circle()
                            .fill(accent)
                            .frame(width: 5, height: 5)
                            .padding(.top, 6)
                        Text(value)
                            .font(.Orttaai.secondary)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func promptGuideCard(_ profile: ToneOfVoiceProfile) -> some View {
        voiceCard(title: "ChatAI Prompt Guide", icon: "text.badge.checkmark", accent: Color.Orttaai.accent) {
            HStack {
                Text("Used by My Tone")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.accent)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 5)
                    .background(Color.Orttaai.accentSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Spacer()
            }

            Text(profile.compactPromptGuide)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color.Orttaai.textSecondary)
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Spacing.md)
                .background(Color.Orttaai.bgTertiary.opacity(0.38))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        }
    }

    private func sampleCard(_ profile: ToneOfVoiceProfile) -> some View {
        voiceCard(title: "Sample Evidence", icon: "doc.text", accent: Color.Orttaai.success) {
            ForEach(profile.sampleExcerpts, id: \.self) { excerpt in
                Text(excerpt)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.md)
                    .background(Color.Orttaai.bgTertiary.opacity(0.32))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
            }
        }
    }

    private var sectionTabs: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(ToneVoiceSection.allCases, id: \.self) { section in
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        selectedSection = section
                    }
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: section.icon)
                            .font(.system(size: 12, weight: .semibold))
                        Text(section.rawValue)
                            .font(.Orttaai.bodyMedium)
                            .lineLimit(1)
                    }
                    .foregroundStyle(selectedSection == section ? Color.Orttaai.bgPrimary : Color.Orttaai.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous)
                            .fill(selectedSection == section ? Color.Orttaai.accent : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.Orttaai.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .stroke(Color.Orttaai.border, lineWidth: BorderWidth.standard)
        )
    }

    private func overviewSection(_ profile: ToneOfVoiceProfile) -> some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(alignment: .top, spacing: Spacing.lg) {
                scoreCard(profile)
                    .frame(minWidth: 300)
                summaryCard(profile)
            }

            ToneBalancedCardGrid(itemCount: 3, minimumColumnWidth: 260) {
                profileListCard(
                    title: "Signature",
                    icon: "quote.opening",
                    values: profile.signaturePhrases.isEmpty ? ["No repeated signature phrases detected yet."] : profile.signaturePhrases,
                    accent: Color.Orttaai.accent,
                    minHeight: overviewGuideCardMinHeight
                )
                profileListCard(
                    title: "Use This Voice",
                    icon: "slider.horizontal.3",
                    values: profile.signatureApproaches,
                    accent: Color.Orttaai.success,
                    minHeight: overviewGuideCardMinHeight
                )
                profileListCard(
                    title: "Avoid",
                    icon: "exclamationmark.triangle",
                    values: profile.avoidances,
                    accent: Color.Orttaai.error,
                    minHeight: overviewGuideCardMinHeight
                )
            }
        }
    }

    private func styleSection(_ profile: ToneOfVoiceProfile) -> some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            ToneBalancedCardGrid(itemCount: profile.metrics.count, minimumColumnWidth: 220) {
                ForEach(profile.metrics) { metric in
                    metricCard(metric)
                }
            }

            confidenceCard(profile)
        }
    }

    private func languageSection(_ profile: ToneOfVoiceProfile) -> some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            languageCard(profile)
            signatureElementsCard(profile)
            sampleCard(profile)
        }
    }

    private func guideSection(_ profile: ToneOfVoiceProfile) -> some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            promptGuideCard(profile)

            ToneBalancedCardGrid(itemCount: 3, minimumColumnWidth: 260) {
                profileListCard(
                    title: "Use This Voice",
                    icon: "checkmark.seal",
                    values: profile.signatureApproaches,
                    accent: Color.Orttaai.success,
                    minHeight: guideListCardMinHeight
                )
                profileListCard(
                    title: "Avoid",
                    icon: "exclamationmark.triangle",
                    values: profile.avoidances,
                    accent: Color.Orttaai.error,
                    minHeight: guideListCardMinHeight
                )
                profileListCard(
                    title: "Recommendations",
                    values: profile.recommendations,
                    accent: Color.Orttaai.warning,
                    minHeight: guideListCardMinHeight
                )
            }
        }
    }

    private func confidenceCard(_ profile: ToneOfVoiceProfile) -> some View {
        voiceCard(title: "Profile Confidence", icon: "checkmark.circle", accent: Color.Orttaai.success) {
            HStack(alignment: .center, spacing: Spacing.xxl) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("\(profile.confidencePercent)%")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.Orttaai.success)
                    Text("Overall confidence")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textPrimary.opacity(0.82))
                }

                Divider()
                    .background(Color.Orttaai.border)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Based on \(profile.wordCount.formatted()) words analyzed")
                    Text("\(profile.sampleCount.formatted()) samples")
                    Text(profile.wordCount >= 650 ? "Adequate sample" : "More samples will improve the profile")
                        .foregroundStyle(profile.wordCount >= 650 ? Color.Orttaai.success : Color.Orttaai.warning)
                }
                .font(.Orttaai.body)
                .foregroundStyle(Color.Orttaai.textPrimary.opacity(0.82))

                Spacer()
            }
        }
    }

    private func languageCard(_ profile: ToneOfVoiceProfile) -> some View {
        let wordsPerSentence = Double(profile.wordCount) / Double(max(1, profile.sentenceCount))
        let complexity = metric(named: "Complexity", in: profile)?.value ?? 0.5
        let conversation = metric(named: "Conversation", in: profile)?.value ?? 0.5
        let readingGrade = min(12, max(3, Int((4 + wordsPerSentence / 8 + complexity * 4).rounded())))

        return voiceCard(title: "Language", icon: "text.bubble", accent: Color(hex: "2F8F83")) {
            ToneBalancedCardGrid(itemCount: 4, minimumColumnWidth: 240) {
                statTile(title: "Grade \(readingGrade)", subtitle: "Reading Level", accent: Color(hex: "2F8F83"))
                statTile(title: "~\(Int(wordsPerSentence.rounded()))", subtitle: "Words/Sentence", accent: Color.Orttaai.warning)
                statTile(title: conversation > 0.68 ? "High" : conversation > 0.38 ? "Medium" : "Low", subtitle: "Contractions", accent: Color(hex: "A855F7"))
                statTile(title: complexity > 0.68 ? "Layered" : complexity > 0.38 ? "Clear" : "Simple", subtitle: "Vocabulary", accent: Color.Orttaai.accent)
            }

            Divider()
                .background(Color.Orttaai.border)

            HStack(spacing: Spacing.xxl) {
                languagePattern(title: "Opens with", value: profile.signatureApproaches.first ?? "Direct start")
                languagePattern(title: "Closes with", value: "No sign-off")
            }
        }
    }

    private func signatureElementsCard(_ profile: ToneOfVoiceProfile) -> some View {
        voiceCard(title: "Signature Elements", icon: "quote.bubble", accent: Color(hex: "2F8F83")) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Your phrases:")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                    tagCloud(profile.signaturePhrases.isEmpty ? ["No repeated phrases yet"] : Array(profile.signaturePhrases.prefix(8)), tint: Color(hex: "2F8F83"))
                }

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Notable traits:")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                    ForEach(profile.signatureApproaches.prefix(4), id: \.self) { trait in
                        Label(trait, systemImage: "smallcircle.filled.circle")
                            .font(.Orttaai.secondary)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func voiceCard<Content: View>(
        title: String,
        icon: String?,
        accent: Color,
        compact: Bool = false,
        minHeight: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: compact ? Spacing.sm : Spacing.md) {
            HStack(spacing: Spacing.sm) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 18)
                }
                Text(title)
                    .font(compact ? .Orttaai.bodyMedium : .Orttaai.heading)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Spacer()
            }

            content()
        }
        .padding(compact ? Spacing.md : Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .fill(Color.Orttaai.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .stroke(Color.Orttaai.border, lineWidth: BorderWidth.standard)
        )
        .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
    }

    private func confidenceBadge(_ percent: Int) -> some View {
        Text("\(percent)% confidence")
            .font(.Orttaai.caption)
            .foregroundStyle(Color.Orttaai.success)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 5)
            .background(Color.Orttaai.successSubtle)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func tagCloud(_ values: [String], tint: Color) -> some View {
        FlowLayout(spacing: Spacing.sm, rowSpacing: Spacing.sm) {
            ForEach(values, id: \.self) { value in
                Text(value)
                    .font(.Orttaai.caption)
                    .foregroundStyle(tint)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 5)
                    .background(tint.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func statTile(title: String, subtitle: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.Orttaai.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(subtitle)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textTertiary)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
    }

    private func languagePattern(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textTertiary)
            Text(value)
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadingCard: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
                .controlSize(.large)
            Text("Analyzing your tone of voice with Ollama...")
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
            Text("This uses your local writing history and stores the profile locally for ChatAI.")
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.xxl)
        .dashboardCard()
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Label("No tone profile yet", systemImage: "person.text.rectangle")
                .font(.Orttaai.heading)
                .foregroundStyle(Color.Orttaai.textPrimary)

            Text("Run analysis after you have some dictation history. Orttaai will use local metrics first and Ollama when it is available.")
                .font(.Orttaai.body)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            statusLine
        }
        .padding(Spacing.lg)
        .dashboardCard()
    }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let statusMessage = viewModel.statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.success)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
            HStack(spacing: Spacing.sm) {
                Image(systemName: "cpu")
                    .font(.system(size: 12, weight: .semibold))
                Text(viewModel.selectedModelDisplayName)
                    .font(.Orttaai.bodyMedium)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.Orttaai.textTertiary)
            }
            .foregroundStyle(Color.Orttaai.textPrimary)
            .padding(.horizontal, Spacing.md)
            .frame(height: 32)
            .frame(maxWidth: 190)
            .background(Color.Orttaai.bgTertiary.opacity(0.52))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .menuStyle(.borderlessButton)
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
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(Color.Orttaai.bgTertiary)
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(tint)
                    .frame(width: max(8, geometry.size.width * max(0, min(1, value))))
            }
        }
        .frame(height: 7)
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
