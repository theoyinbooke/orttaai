// SemanticMemoryView.swift
// Orttaai

import SwiftUI
import Combine
import AppKit

@MainActor
final class SemanticMemoryViewModel: ObservableObject {
    @Published var stats: SemanticMemoryStats?
    @Published var graph = SemanticMemoryGraph(nodes: [], edges: [])
    @Published var insightReport: SemanticInsightReport?
    @Published var isIndexing = false
    @Published var isGeneratingInsights = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var insightFreshness: SemanticInsightFreshness?
    @Published var openLoops: [InsightFinding] = []

    private let service: any SemanticMemoryServiceProviding

    init(service: (any SemanticMemoryServiceProviding)? = nil) {
        self.service = service ?? SemanticMemoryService()
    }

    func load() {
        stats = service.stats()
        let loadedGraph = service.graph(limitNodes: 180, limitEdges: 360)
        graph = loadedGraph
        insightReport = service.loadLatestInsightReport()
        refreshOpenLoops()
        refreshInsightFreshness()
    }

    func refreshOpenLoops() {
        openLoops = service.insightFindings(kinds: [.openCommitment, .openQuestion], limit: 12)
            .sorted { ($0.windowStart ?? .distantPast) > ($1.windowStart ?? .distantPast) }
    }

    func resolveFinding(_ finding: InsightFinding) {
        guard let id = finding.id else { return }
        service.setFindingStatus(id: id, status: .resolved)
        refreshOpenLoops()
    }

    func dismissFinding(_ finding: InsightFinding) {
        guard let id = finding.id else { return }
        service.setFindingStatus(id: id, status: .dismissed)
        refreshOpenLoops()
    }

    func buildIndex() async {
        guard !isIndexing else { return }
        isIndexing = true
        errorMessage = nil
        statusMessage = "Building semantic memory..."

        let result = await service.indexPendingTranscriptions(limit: 1_000)
        if let errorMessage = result.errorMessage {
            self.errorMessage = errorMessage
            self.statusMessage = nil
        } else {
            let fallbackNote = result.usedFallback ? " using lexical fallback" : ""
            statusMessage = "Indexed \(result.embeddedCount) new chunk\(result.embeddedCount == 1 ? "" : "s") with \(result.modelID)\(fallbackNote)."
        }
        load()
        isIndexing = false
    }

    func generateInsights() async {
        guard !isGeneratingInsights else { return }
        isGeneratingInsights = true
        errorMessage = nil
        let report = await service.generateInsights(limitCards: 8)
        stats = service.stats()
        graph = service.graph(limitNodes: 180, limitEdges: 360)
        insightReport = report
        refreshOpenLoops()
        refreshInsightFreshness()
        if report.cards.isEmpty {
            statusMessage = "Build more semantic memory before insights can be generated."
        } else if let modelName = report.summaryModelName {
            statusMessage = "Generated \(report.cards.count) graph insight\(report.cards.count == 1 ? "" : "s") with \(modelName)."
        } else if report.usedFallback {
            if let fallbackReason = report.coverageNotes.first(where: { $0.hasPrefix("Local Ollama fallback:") }) {
                statusMessage = fallbackReason
            } else {
                statusMessage = "Generated \(report.cards.count) heuristic graph insight\(report.cards.count == 1 ? "" : "s")."
            }
        } else {
            statusMessage = "Generated \(report.cards.count) graph insight\(report.cards.count == 1 ? "" : "s")."
        }
        isGeneratingInsights = false
    }

    private func refreshInsightFreshness() {
        guard let insightReport else {
            insightFreshness = nil
            return
        }
        insightFreshness = service.freshness(for: insightReport, currentGraph: graph)
    }
}

private enum SemanticMemoryTab: String, CaseIterable, Identifiable {
    case activity = "Activity"
    case map = "Map"
    case insights = "Insights"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .activity: return "chart.bar.doc.horizontal"
        case .map: return "point.3.connected.trianglepath.dotted"
        case .insights: return "lightbulb"
        }
    }

    /// Insights reads the semantic index; the other tabs don't. (Searching
    /// your dictation happens in Chat AI, which reads the same index.)
    var usesSemanticIndex: Bool { self == .insights }

    /// Activity and Map read a time range; Insights covers everything.
    var usesRange: Bool { self == .activity || self == .map }
}

struct SemanticMemoryView: View {
    /// Opens Chat AI with a question about your dictation.
    var onAskChat: (String) -> Void = { _ in }
    /// Opens Model › AI Features, where semantic memory is set up.
    var onOpenAISettings: () -> Void = {}
    @StateObject private var viewModel = SemanticMemoryViewModel()
    /// Asks before a missing model is downloaded by the local server.
    @StateObject private var modelDownloader = LocalModelDownloader()
    @State private var selectedTab: SemanticMemoryTab = .activity
    @AppStorage("memoryGraphRange") private var range: ConceptTimeRange = .month
    @State private var isInfoPresented = false
    @AppStorage("localLLMProvider") private var localLLMProviderRaw = LocalLLMProviderKind.ollama.rawValue
    @AppStorage("semanticInsightSummaryEnabled") private var semanticInsightSummaryEnabled = true

    var body: some View {
        Group {
            if selectedTab == .map {
                // The map fills the page instead of scrolling.
                VStack(alignment: .leading, spacing: Spacing.md) {
                    statusStrip
                    ConceptMapView(range: range)
                }
                .padding(WorkspaceLayout.contentInsets)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        statusStrip

                        switch selectedTab {
                        case .activity:
                            ActivityOverviewView(range: range, onAskChat: onAskChat)
                        case .map:
                            EmptyView()
                        case .insights:
                            insightsContent
                        }
                    }
                    .padding(WorkspaceLayout.contentInsets)
                }
            }
        }
        .background(Color.Orttaai.bgPrimary)
        .workspaceHeader("Memory Graph") {
            HStack(spacing: Spacing.lg) {
                infoButton
                OrttaaiTabBar(
                    tabs: SemanticMemoryTab.allCases,
                    selection: $selectedTab,
                    title: \.rawValue,
                    icon: \.systemImage
                )
            }
        } trailing: {
            headerActions
        }
        .localModelDownloadPrompt(modelDownloader)
        .onAppear {
            viewModel.load()
        }
    }

    private var infoButton: some View {
        Button {
            isInfoPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.Orttaai.textTertiary)
        .help("About Memory Graph")
        .accessibilityLabel("About Memory Graph")
        .popover(isPresented: $isInfoPresented, arrowEdge: .bottom) {
            Text("Local map of your dictations.")
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .padding(Spacing.md)
                .frame(width: 260, alignment: .leading)
                .presentationBackground(Color.Orttaai.bgSecondary)
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        if selectedTab.usesSemanticIndex {
            Button(action: onOpenAISettings) {
                Label("AI Settings", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
            .help("Semantic memory, its index and the insight model live in Model › AI Features")
        } else if selectedTab.usesRange {
            HeaderSegmentedPicker(
                options: ConceptTimeRange.allCases,
                selection: $range,
                title: \.title
            )
        }
    }

    @ViewBuilder
    private var statusStrip: some View {
        if let errorMessage = viewModel.errorMessage {
            statusRow(message: errorMessage, systemImage: "exclamationmark.triangle.fill", color: Color.Orttaai.error)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(Color.Orttaai.errorSubtle.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))
        } else if let statusMessage = viewModel.statusMessage {
            statusRow(message: statusMessage, systemImage: "checkmark.circle.fill", color: Color.Orttaai.success)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(Color.Orttaai.success.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))
        }
    }

    // MARK: - Insights

    private var insightsContent: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            LocalModelDownloadStatus(downloader: modelDownloader)

            if viewModel.graph.nodes.isEmpty {
                emptyInsightsState
            } else if viewModel.insightReport == nil, viewModel.isGeneratingInsights || modelDownloader.isDownloading {
                generatingInsightsState
            } else if let report = viewModel.insightReport {
                insightReportView(report)
            } else {
                readyInsightsState
            }
        }
    }

    private var insightIcon: some View {
        Image(systemName: "brain")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Color.Orttaai.accent)
            .frame(width: 40, height: 40)
            .background(Color.Orttaai.accentSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }

    /// Before the first report: what insights are, what they'll read, which
    /// model phrases them, and the one Generate button.
    private var readyInsightsState: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(alignment: .top, spacing: Spacing.md) {
                insightIcon
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("See what your notes add up to")
                        .font(.Orttaai.heading)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                    Text("Orttaai reads how your notes connect across topics, people and projects, then points out patterns, open loops and what's changing. Every insight links back to what you said.")
                        .font(.Orttaai.body)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: Spacing.sm) {
                insightMetric((viewModel.stats?.chunkCount ?? 0).formatted(), "notes")
                insightMetric(viewModel.graph.nodes.count.formatted(), "concepts")
                insightMetric(viewModel.graph.edges.count.formatted(), "links")
            }

            HStack(alignment: .center, spacing: Spacing.md) {
                modelLine
                Spacer(minLength: Spacing.sm)
                generateButton(prominent: true)
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    /// Which model phrases the insights, with a way to change it.
    private var modelLine: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "cpu")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.Orttaai.textTertiary)
            Text(semanticInsightSummaryEnabled
                 ? "Phrased by \(insightModel) on \(providerName)"
                 : "Plain phrasing, no model")
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .lineLimit(1)
            Button("Change", action: onOpenAISettings)
                .buttonStyle(.plain)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.accent)
        }
    }

    private var emptyInsightsState: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(alignment: .top, spacing: Spacing.md) {
                insightIcon
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Your memory graph is still empty")
                        .font(.Orttaai.heading)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                    Text("It fills in as Orttaai indexes your dictations. Index now to build it from everything you've dictated so far.")
                        .font(.Orttaai.body)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button {
                    Task {
                        await modelDownloader.run(model: AppSettings().normalizedSemanticEmbeddingModel, purpose: "Semantic memory") {
                            await viewModel.buildIndex()
                        }
                    }
                } label: {
                    Label(viewModel.isIndexing ? "Indexing…" : "Index Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(OrttaaiButtonStyle(.primary))
                .disabled(viewModel.isIndexing || modelDownloader.isDownloading)
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    private var generatingInsightsState: some View {
        HStack(spacing: Spacing.md) {
            ChatAIWaitingMark(size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(modelDownloader.isDownloading
                     ? "Getting the insight model ready"
                     : "Reading \((viewModel.stats?.chunkCount ?? 0).formatted()) notes and how they connect")
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Text(semanticInsightSummaryEnabled ? "\(insightModel) on \(providerName) phrases what it finds" : "Plain phrasing, no model")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    private func generateButton(prominent: Bool) -> some View {
        Button {
            startGeneratingInsights()
        } label: {
            if viewModel.isGeneratingInsights {
                Label("Generating…", systemImage: "brain")
            } else {
                Label(viewModel.insightReport == nil ? "Generate Insights" : "Regenerate", systemImage: "brain")
            }
        }
        .buttonStyle(OrttaaiButtonStyle(prominent ? .primary : .secondary, size: prominent ? .regular : .small))
        .disabled(viewModel.isGeneratingInsights || modelDownloader.isDownloading || viewModel.graph.nodes.isEmpty)
    }

    /// Makes sure the insight model is on the local server first; if it
    /// isn't, the user is asked before the server downloads it.
    private func startGeneratingInsights() {
        Task {
            guard semanticInsightSummaryEnabled else {
                await viewModel.generateInsights()
                return
            }
            await modelDownloader.run(model: insightModel, purpose: "Graph insights") {
                await viewModel.generateInsights()
            }
        }
    }

    private var insightModel: String {
        AppSettings().normalizedSemanticInsightSummaryModel
    }

    private var providerName: String {
        (LocalLLMProviderKind(rawValue: localLLMProviderRaw) ?? .ollama).displayName
    }

    /// Honesty footer: sample size and how the words were produced. Insights
    /// are always computed from evidence; a model only phrases them.
    private func insightCaveatLine(_ report: SemanticInsightReport) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.Orttaai.textTertiary)
            Text(caveatText(report))
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.xs)
    }

    private func caveatText(_ report: SemanticInsightReport) -> String {
        var parts = ["Computed from \(report.sourceChunkCount) transcript segments"]
        if let model = report.summaryModelName {
            parts.append("phrased by \(model); claims remain evidence-linked")
        } else {
            parts.append("deterministic phrasing (local model offline)")
        }
        if report.sourceChunkCount < 40 {
            parts.append("early days: patterns sharpen as you dictate more")
        }
        return parts.joined(separator: " · ")
    }

    private func openLoopsSection(_ loops: [InsightFinding]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "arrow.uturn.left.circle")
                    .foregroundStyle(Color.Orttaai.accent)
                Text("Open Loops & Commitments")
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Spacer()
            }

            VStack(spacing: Spacing.sm) {
                ForEach(loops) { loop in
                    openLoopRow(loop)
                }
            }
        }
        .padding(Spacing.md)
        .dashboardCard()
    }

    private func openLoopRow(_ loop: InsightFinding) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            let isQuestion = loop.kind == InsightFindingKind.openQuestion.rawValue
            Image(systemName: isQuestion ? "questionmark.circle" : "hand.raised")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isQuestion ? Color.Orttaai.warning : Color.Orttaai.accent)
                .frame(width: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(loop.detail)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .lineLimit(3)
                Text(ageBadgeText(for: loop))
                    .font(.Orttaai.caption)
                    .foregroundStyle(ageBadgeColor(for: loop))
            }

            Spacer(minLength: Spacing.sm)

            HStack(spacing: Spacing.xs) {
                Button {
                    viewModel.resolveFinding(loop)
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.Orttaai.success)
                .help("Mark as done")
                .accessibilityLabel("Mark resolved")

                Button {
                    viewModel.dismissFinding(loop)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.Orttaai.textTertiary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(Spacing.sm)
        .background(Color.Orttaai.bgTertiary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func ageBadgeText(for loop: InsightFinding) -> String {
        guard let start = loop.windowStart else { return "recent" }
        let days = max(0, Int(Date().timeIntervalSince(start) / 86_400))
        switch days {
        case 0: return "today"
        case 1: return "1 day open"
        default: return "\(days) days open"
        }
    }

    private func ageBadgeColor(for loop: InsightFinding) -> Color {
        guard let start = loop.windowStart else { return Color.Orttaai.textTertiary }
        let days = Date().timeIntervalSince(start) / 86_400
        if days >= 7 { return Color.Orttaai.error }
        if days >= 3 { return Color.Orttaai.warning }
        return Color.Orttaai.textTertiary
    }

    private func insightReportView(_ report: SemanticInsightReport) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            insightSummaryCard(report)

            insightCaveatLine(report)

            if let freshness = viewModel.insightFreshness, freshness.isStale {
                insightFreshnessBanner(freshness)
            }

            if !viewModel.openLoops.isEmpty {
                openLoopsSection(viewModel.openLoops)
            }

            if !report.charts.isEmpty {
                insightChartSection(report.charts)
            }

            if !report.clusters.isEmpty {
                insightClusterSection(report.clusters)
            }

            if !report.comparisons.isEmpty {
                insightComparisonSection(report.comparisons)
            }

            if !report.coverageNotes.isEmpty {
                insightCoverageSection(report.coverageNotes)
            }

            if report.cards.isEmpty {
                Text("Not enough connected evidence yet.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dashboardCard()
            } else {
                HStack(alignment: .top, spacing: Spacing.md) {
                    ForEach(Array(insightMasonryColumns(report.cards).enumerated()), id: \.offset) { _, columnCards in
                        LazyVStack(spacing: Spacing.md) {
                            ForEach(columnCards) { card in
                                insightCard(card)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
            }
        }
    }

    private func insightMasonryColumns(_ cards: [SemanticInsightCard]) -> [[SemanticInsightCard]] {
        guard cards.count > 1 else { return [cards] }
        var columns: [[SemanticInsightCard]] = [[], []]
        var estimatedHeights = [0.0, 0.0]

        for card in cards {
            let targetColumn = estimatedHeights[0] <= estimatedHeights[1] ? 0 : 1
            columns[targetColumn].append(card)
            estimatedHeights[targetColumn] += estimatedInsightCardHeight(card)
        }

        return columns.filter { !$0.isEmpty }
    }

    private func estimatedInsightCardHeight(_ card: SemanticInsightCard) -> Double {
        let textWeight = Double(card.title.count + card.body.count + card.actionText.count) / 42.0
        let evidenceWeight = Double(card.evidence.count) * 76.0
        let excerptWeight = Double(card.evidence.reduce(0) { $0 + $1.excerpt.count }) / 58.0
        return 220.0 + textWeight * 18.0 + evidenceWeight + excerptWeight * 16.0
    }

    private func insightSummaryCard(_ report: SemanticInsightReport) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .center, spacing: Spacing.sm) {
                Text("Summary")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Spacer()

                if let modelName = report.summaryModelName {
                    Text(modelName)
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.accent)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, 4)
                        .background(Color.Orttaai.accent.opacity(0.12))
                        .clipShape(Capsule())
                }

                Text(Self.insightDateFormatter.string(from: report.generatedAt))
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)

                generateButton(prominent: false)
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(report.summary, id: \.self) { line in
                    HStack(alignment: .top, spacing: Spacing.xs) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.Orttaai.accent)
                            .padding(.top, 3)
                        Text(line)
                            .font(.Orttaai.secondary)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                    }
                }
            }

            HStack(spacing: Spacing.sm) {
                insightMetric("\(report.sourceNodeCount)", "nodes")
                insightMetric("\(report.sourceEdgeCount)", "links")
                insightMetric("\(report.sourceChunkCount)", "chunks")
                insightMetric(report.analyzerName, report.usedFallback ? "fallback" : "analyzer")
            }
        }
        .padding(Spacing.md)
        .dashboardCard()
    }

    private func insightFreshnessBanner(_ freshness: SemanticInsightFreshness) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.Orttaai.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("Snapshot is older than the current graph")
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Text("Regenerate to update the snapshot.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }
            Spacer()
        }
        .padding(Spacing.md)
        .dashboardCard()
    }

    private func insightChartSection(_ charts: [SemanticInsightChart]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Life Graph Charts")
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 280), spacing: Spacing.md)],
                spacing: Spacing.md
            ) {
                ForEach(charts.prefix(3)) { chart in
                    insightChartCard(chart)
                }
            }
        }
    }

    private func insightChartCard(_ chart: SemanticInsightChart) -> some View {
        let points = Array(chart.points.prefix(8))
        let maxValue = max(points.map(\.value).max() ?? 0, 1)

        return VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text(chart.title)
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                Text(chart.unit)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 4)
                    .background(Color.Orttaai.bgTertiary.opacity(0.55))
                    .clipShape(Capsule())
            }

            Text(chart.subtitle)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    insightChartBarRow(point, maxValue: maxValue, color: insightChartColor(index))
                }
            }

            if let evidence = points.first(where: { !$0.evidence.isEmpty })?.evidence.first {
                Divider()
                    .background(Color.Orttaai.border.opacity(0.7))
                insightEvidenceRow(evidence)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    private func insightChartBarRow(
        _ point: SemanticInsightChartPoint,
        maxValue: Double,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text(point.label)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text(formattedChartValue(point.value))
                    .font(.Orttaai.mono)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }

            GeometryReader { proxy in
                let ratio = max(0, min(1, point.value / maxValue))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.Orttaai.bgTertiary.opacity(0.7))
                        .frame(height: 8)
                    Capsule()
                        .fill(color)
                        .frame(width: max(6, proxy.size.width * CGFloat(ratio)), height: 8)
                }
            }
            .frame(height: 8)

            if let detail = point.detail, !detail.isEmpty {
                Text(detail)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.sm)
        .background(Color.Orttaai.bgTertiary.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))
    }

    private func insightChartColor(_ index: Int) -> Color {
        switch index % 5 {
        case 0: return Color.Orttaai.accent
        case 1: return Color.Orttaai.success
        case 2: return Color.Orttaai.warning
        case 3: return .blue
        default: return .purple
        }
    }

    private func formattedChartValue(_ value: Double) -> String {
        if value.rounded() == value {
            return "\(Int(value))"
        }
        return String(format: "%.1f", value)
    }

    private func insightClusterSection(_ clusters: [SemanticInsightCluster]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Life & Work Areas")
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
            HStack(alignment: .top, spacing: Spacing.md) {
                ForEach(clusters.prefix(3)) { cluster in
                    insightClusterCard(cluster)
                }
            }
            // Sizes the row to its tallest card so the flexible cards all
            // stretch to the same height.
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func insightClusterCard(_ cluster: SemanticInsightCluster) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(cluster.title)
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(cluster.summary)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let evidence = cluster.evidence.first {
                insightEvidenceRow(evidence)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Spacing.md)
        .dashboardCard()
    }

    private func insightComparisonSection(_ comparisons: [SemanticInsightComparison]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Comparative Signals")
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
            VStack(spacing: Spacing.md) {
                ForEach(comparisons.prefix(3)) { comparison in
                    insightComparisonRow(comparison)
                }
            }
        }
    }

    private func insightComparisonRow(_ comparison: SemanticInsightComparison) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(comparison.title)
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Spacer()
                Text(comparison.trend.capitalized)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.accent)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 4)
                    .background(Color.Orttaai.accent.opacity(0.12))
                    .clipShape(Capsule())
            }
            Text(comparison.detail)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !comparison.evidence.isEmpty {
                ForEach(comparison.evidence.prefix(2)) { evidence in
                    insightEvidenceRow(evidence)
                }
            }
        }
        .padding(Spacing.md)
        .dashboardCard()
    }

    private func insightCoverageSection(_ notes: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Coverage Notes")
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
            ForEach(notes, id: \.self) { note in
                HStack(alignment: .top, spacing: Spacing.xs) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.Orttaai.textTertiary)
                        .padding(.top, 3)
                    Text(note)
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Spacing.md)
        .dashboardCard()
    }

    private func insightMetric(_ value: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textPrimary)
            Text(label)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 4)
        .background(Color.Orttaai.bgTertiary.opacity(0.55))
        .clipShape(Capsule())
    }

    private func insightCard(_ card: SemanticInsightCard) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(card.kind)
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.accent)
                    Text(card.title)
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Text("\(Int((card.confidence * 100).rounded()))%")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 4)
                    .background(Color.Orttaai.bgTertiary.opacity(0.55))
                    .clipShape(Capsule())
            }

            Text(card.body)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: Spacing.xs) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.Orttaai.accent)
                    .padding(.top, 3)
                Text(card.actionText)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !card.evidence.isEmpty {
                Divider()
                    .background(Color.Orttaai.border.opacity(0.7))

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Evidence")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                    ForEach(card.evidence) { evidence in
                        insightEvidenceRow(evidence)
                    }
                }
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    private func insightEvidenceRow(_ evidence: SemanticInsightEvidence) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Text(evidence.sourceAppName?.isEmpty == false ? evidence.sourceAppName! : "Dictation")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                if let date = evidence.sourceCreatedAt {
                    Text(Self.insightDateFormatter.string(from: date))
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                }
                Spacer(minLength: 0)
            }
            Text(evidence.excerpt)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .lineLimit(3)
        }
        .padding(Spacing.sm)
        .background(Color.Orttaai.bgTertiary.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))
    }

    private func statusRow(message: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            Text(message)
                .font(.Orttaai.caption)
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }

    private static let insightDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
