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
    @Published var query: String = ""
    @Published var results: [SemanticRetrievedContext] = []
    @Published var isIndexing = false
    @Published var isSearching = false
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

    func clearIndex() {
        do {
            try service.clearIndex()
            results = []
            query = ""
            statusMessage = "Semantic memory cleared."
            errorMessage = nil
            load()
        } catch {
            errorMessage = "Could not clear semantic memory: \(error.localizedDescription)"
        }
    }

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            return
        }

        isSearching = true
        errorMessage = nil
        results = await service.retrieveContext(for: trimmed, limit: 8, minimumScore: 0.08)
        if results.isEmpty {
            statusMessage = "No semantic matches yet."
        } else {
            statusMessage = "Found \(results.count) semantic match\(results.count == 1 ? "" : "es")."
        }
        load()
        isSearching = false
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
    case search = "Search"
    case insights = "Insights"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .activity: return "chart.bar.doc.horizontal"
        case .map: return "point.3.connected.trianglepath.dotted"
        case .search: return "magnifyingglass"
        case .insights: return "lightbulb"
        }
    }

    /// Search and Insights read the semantic index; the other tabs don't.
    var usesSemanticIndex: Bool { self == .search || self == .insights }
}

struct SemanticMemoryView: View {
    @StateObject private var viewModel = SemanticMemoryViewModel()
    @State private var selectedTab: SemanticMemoryTab = .activity
    @State private var isSetupPresented = false
    @State private var isInfoPresented = false
    @State private var installedOllamaModels: [String] = []
    @State private var embeddingCatalogModels: [OllamaCatalogModel] = []
    @State private var insightCatalogModels: [OllamaCatalogModel] = []
    @State private var selectedEmbeddingCatalogModel = ""
    @State private var selectedInsightCatalogModel = ""
    @State private var isCheckingEmbeddingModels = false
    @State private var isLoadingEmbeddingCatalog = false
    @State private var isLoadingInsightCatalog = false
    @State private var isInstallingEmbeddingModel = false
    @State private var isInstallingInsightModel = false
    @State private var installingEmbeddingModelName: String?
    @State private var installingInsightModelName: String?
    @State private var embeddingInstallStatusMessage: String?
    @State private var insightInstallStatusMessage: String?
    @State private var embeddingInstallProgress: Double?
    @State private var insightInstallProgress: Double?
    @State private var embeddingInstallError: String?
    @State private var insightInstallError: String?
    @State private var embeddingInstallSuccessMessage: String?
    @State private var insightInstallSuccessMessage: String?
    @AppStorage("localLLMProvider") private var localLLMProviderRaw = LocalLLMProviderKind.ollama.rawValue
    @AppStorage("localLLMEndpoint") private var localLLMEndpoint = "http://127.0.0.1:11434"
    @AppStorage("lmStudioEndpoint") private var lmStudioEndpoint = "http://127.0.0.1:1234"
    @AppStorage("semanticMemoryEnabled") private var semanticMemoryEnabled = true
    @AppStorage("semanticMemoryAutoIndexEnabled") private var semanticMemoryAutoIndexEnabled = true
    @AppStorage("semanticEmbeddingFallbackEnabled") private var semanticEmbeddingFallbackEnabled = true
    @AppStorage("semanticEmbeddingModel") private var semanticEmbeddingModel = "all-minilm"
    @AppStorage("semanticActiveIndexModelID") private var semanticActiveIndexModelID = ""
    @AppStorage("semanticInsightSummaryEnabled") private var semanticInsightSummaryEnabled = true
    @AppStorage("semanticInsightSummaryModel") private var semanticInsightSummaryModel = "qwen3.5:0.8b"

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                statusStrip

                switch selectedTab {
                case .activity:
                    ActivityOverviewView()
                case .map:
                    ConceptMapView()
                case .search:
                    searchCard
                case .insights:
                    insightsContent
                }
            }
            .padding(WorkspaceLayout.contentInsets)
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
        .sheet(isPresented: $isSetupPresented) {
            setupSheet
        }
        .onAppear {
            viewModel.load()
        }
    }

    private var normalizedSemanticEmbeddingModel: String {
        semanticEmbeddingModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedSelectedEmbeddingModel: String {
        selectedEmbeddingCatalogModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedSemanticInsightSummaryModel: String {
        semanticInsightSummaryModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedSelectedInsightModel: String {
        selectedInsightCatalogModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var embeddingModelOptions: [OllamaCatalogModel] {
        var seen: Set<String> = []
        var options: [OllamaCatalogModel] = []

        func append(_ model: OllamaCatalogModel) {
            let canonical = canonicalOllamaModelName(model.name)
            guard !canonical.isEmpty, !seen.contains(canonical) else { return }
            seen.insert(canonical)
            options.append(model)
        }

        embeddingCatalogModels.forEach(append)

        for modelName in installedOllamaModels where isLikelyEmbeddingModel(modelName) {
            append(OllamaCatalogModel(name: modelName, sizeBytes: nil))
        }

        if !normalizedSemanticEmbeddingModel.isEmpty {
            append(OllamaCatalogModel(name: normalizedSemanticEmbeddingModel, sizeBytes: nil))
        }

        return options.sorted { lhs, rhs in
            let lhsInstalled = isOllamaModelInstalled(lhs.name)
            let rhsInstalled = isOllamaModelInstalled(rhs.name)
            if lhsInstalled != rhsInstalled {
                return lhsInstalled
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var embeddingDropdownOptions: [OrttaaiDropdown<String>.Option] {
        guard !embeddingModelOptions.isEmpty else {
            let fallback = normalizedSemanticEmbeddingModel.isEmpty ? "all-minilm" : normalizedSemanticEmbeddingModel
            return [.init(fallback, fallback)]
        }
        return embeddingModelOptions.map { .init($0.name, embeddingModelOptionLabel(for: $0)) }
    }

    private var insightDropdownOptions: [OrttaaiDropdown<String>.Option] {
        guard !insightModelOptions.isEmpty else {
            let fallback = normalizedSemanticInsightSummaryModel.isEmpty ? "qwen3.5:0.8b" : normalizedSemanticInsightSummaryModel
            return [.init(fallback, fallback)]
        }
        return insightModelOptions.map { .init($0.name, insightModelOptionLabel(for: $0)) }
    }

    private var insightModelOptions: [OllamaCatalogModel] {
        var seen: Set<String> = []
        var options: [OllamaCatalogModel] = []

        func append(_ model: OllamaCatalogModel) {
            let canonical = canonicalOllamaModelName(model.name)
            guard !canonical.isEmpty, !seen.contains(canonical) else { return }
            seen.insert(canonical)
            options.append(model)
        }

        insightCatalogModels.forEach(append)

        for modelName in installedOllamaModels where !isLikelyEmbeddingModel(modelName) {
            append(OllamaCatalogModel(name: modelName, sizeBytes: nil))
        }

        if !normalizedSemanticInsightSummaryModel.isEmpty {
            append(OllamaCatalogModel(name: normalizedSemanticInsightSummaryModel, sizeBytes: nil))
        }

        return options.sorted { lhs, rhs in
            let lhsInstalled = isOllamaModelInstalled(lhs.name)
            let rhsInstalled = isOllamaModelInstalled(rhs.name)
            if lhsInstalled != rhsInstalled {
                return lhsInstalled
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var isSelectedEmbeddingModelInstalled: Bool {
        isOllamaModelInstalled(normalizedSelectedEmbeddingModel)
    }

    private var isSelectedEmbeddingModelCurrent: Bool {
        canonicalOllamaModelName(normalizedSelectedEmbeddingModel) == canonicalOllamaModelName(normalizedSemanticEmbeddingModel)
    }

    private var isEmbeddingActionDisabled: Bool {
        normalizedSelectedEmbeddingModel.isEmpty ||
            isCheckingEmbeddingModels ||
            isLoadingEmbeddingCatalog ||
            isInstallingEmbeddingModel ||
            (isSelectedEmbeddingModelInstalled && isSelectedEmbeddingModelCurrent)
    }

    private var isSelectedInsightModelInstalled: Bool {
        isOllamaModelInstalled(normalizedSelectedInsightModel)
    }

    private var isSelectedInsightModelCurrent: Bool {
        canonicalOllamaModelName(normalizedSelectedInsightModel) == canonicalOllamaModelName(normalizedSemanticInsightSummaryModel)
    }

    private var isInsightActionDisabled: Bool {
        normalizedSelectedInsightModel.isEmpty ||
            isCheckingEmbeddingModels ||
            isLoadingInsightCatalog ||
            isInstallingInsightModel ||
            (isSelectedInsightModelInstalled && isSelectedInsightModelCurrent)
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
            indexActions
        }
    }

    private var indexActions: some View {
        HStack(spacing: Spacing.sm) {
            Button {
                isSetupPresented = true
            } label: {
                Label("Setup", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))

            Button {
                Task { await viewModel.buildIndex() }
            } label: {
                if viewModel.isIndexing {
                    Label("Building…", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("Build Index", systemImage: "bolt.horizontal.circle")
                }
            }
            .buttonStyle(OrttaaiButtonStyle(.primary, size: .small))
            .disabled(viewModel.isIndexing || !semanticMemoryEnabled)

            Button {
                viewModel.load()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
            .help("Reload")
            .accessibilityLabel("Reload")
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

    private var setupSheet: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(alignment: .firstTextBaseline) {
                Text("Semantic Memory Setup")
                    .font(.Orttaai.heading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Spacer()

                Button {
                    isSetupPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .help("Close")
            }

            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.lg) {
                    Toggle("Semantic Memory", isOn: $semanticMemoryEnabled)
                        .toggleStyle(OrttaaiToggleStyle())
                    Toggle("Auto Index", isOn: $semanticMemoryAutoIndexEnabled)
                        .toggleStyle(OrttaaiToggleStyle())
                    Toggle("Lexical Fallback", isOn: $semanticEmbeddingFallbackEnabled)
                        .toggleStyle(OrttaaiToggleStyle())
                }

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    embeddingModelPickerSection
                }

                Divider()
                    .background(Color.Orttaai.border.opacity(0.7))

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    insightSummaryModelPickerSection
                }

                Button(role: .destructive) {
                    viewModel.clearIndex()
                } label: {
                    Label("Clear Index", systemImage: "trash")
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary, destructive: true))
                .disabled(viewModel.isIndexing)
            }
            .padding(Spacing.lg)
            .dashboardCard()
        }
        .padding(Spacing.xxl)
        .frame(width: 660)
            .background(Color.Orttaai.bgPrimary)
            .task {
                normalizeSemanticEmbeddingSelection()
                normalizeInsightSummarySelection()
                await loadEmbeddingModelCatalog()
            }
    }

    private var embeddingModelPickerSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .center, spacing: Spacing.sm) {
                Text("Embedding Model")
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Spacer()

                Button {
                    Task { await loadEmbeddingModelCatalog() }
                } label: {
                    if isCheckingEmbeddingModels || isLoadingEmbeddingCatalog {
                        Label("Syncing", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("Sync", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary))
                .disabled(isCheckingEmbeddingModels || isLoadingEmbeddingCatalog || isInstallingEmbeddingModel)
            }

            HStack(spacing: Spacing.sm) {
                OrttaaiDropdown(
                    selection: $selectedEmbeddingCatalogModel,
                    options: embeddingDropdownOptions
                )
                .frame(maxWidth: .infinity)
                .onChange(of: selectedEmbeddingCatalogModel) { _, newValue in
                    selectEmbeddingModelIfInstalled(newValue)
                }

                Button {
                    Task { await useOrInstallSelectedEmbeddingModel() }
                } label: {
                    embeddingActionLabel
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary))
                .disabled(isEmbeddingActionDisabled)
            }

            if let embeddingInstallStatusMessage {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.xs) {
                        ProgressView()
                            .controlSize(.small)
                        Text(embeddingInstallStatusMessage)
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                    }
                    if let embeddingInstallProgress {
                        ProgressView(value: embeddingInstallProgress)
                            .progressViewStyle(.linear)
                    }
                }
            }

            if let embeddingInstallSuccessMessage {
                statusRow(message: embeddingInstallSuccessMessage, systemImage: "checkmark.circle.fill", color: Color.Orttaai.success)
            }

            if let embeddingInstallError {
                statusRow(message: embeddingInstallError, systemImage: "exclamationmark.triangle.fill", color: Color.Orttaai.error)
            }
        }
    }

    @ViewBuilder
    private var embeddingActionLabel: some View {
        if isInstallingEmbeddingModel && installingEmbeddingModelName == normalizedSelectedEmbeddingModel {
            Label("Installing", systemImage: "arrow.down.circle")
        } else if isSelectedEmbeddingModelInstalled {
            if isSelectedEmbeddingModelCurrent {
                Label("Selected", systemImage: "checkmark.circle")
            } else {
                Label("Use Model", systemImage: "checkmark.circle")
            }
        } else {
            Label("Download", systemImage: "arrow.down.circle")
        }
    }

    private var insightSummaryModelPickerSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .center, spacing: Spacing.sm) {
                Text("Graph Insight Model")
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Spacer()

                Toggle("Model Insights", isOn: $semanticInsightSummaryEnabled)
                    .toggleStyle(OrttaaiToggleStyle())

                Button {
                    Task { await loadEmbeddingModelCatalog() }
                } label: {
                    if isCheckingEmbeddingModels || isLoadingInsightCatalog {
                        Label("Syncing", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("Sync", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary))
                .disabled(isCheckingEmbeddingModels || isLoadingInsightCatalog || isInstallingInsightModel)
            }

            HStack(spacing: Spacing.sm) {
                OrttaaiDropdown(
                    selection: $selectedInsightCatalogModel,
                    options: insightDropdownOptions
                )
                .frame(maxWidth: .infinity)
                .onChange(of: selectedInsightCatalogModel) { _, newValue in
                    selectInsightModelIfInstalled(newValue)
                }

                Button {
                    Task { await useOrInstallSelectedInsightModel() }
                } label: {
                    insightActionLabel
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary))
                .disabled(isInsightActionDisabled)
            }
            .disabled(!semanticInsightSummaryEnabled)

            if !activeProviderKind.isLocal {
                Text("Local fallback for \(activeProviderKind.displayName) insights.")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }

            if let insightInstallStatusMessage {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.xs) {
                        ProgressView()
                            .controlSize(.small)
                        Text(insightInstallStatusMessage)
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                    }
                    if let insightInstallProgress {
                        ProgressView(value: insightInstallProgress)
                            .progressViewStyle(.linear)
                    }
                }
            }

            if let insightInstallSuccessMessage {
                statusRow(message: insightInstallSuccessMessage, systemImage: "checkmark.circle.fill", color: Color.Orttaai.success)
            }

            if let insightInstallError {
                statusRow(message: insightInstallError, systemImage: "exclamationmark.triangle.fill", color: Color.Orttaai.error)
            }
        }
    }

    @ViewBuilder
    private var insightActionLabel: some View {
        if isInstallingInsightModel && installingInsightModelName == normalizedSelectedInsightModel {
            Label("Installing", systemImage: "arrow.down.circle")
        } else if isSelectedInsightModelInstalled {
            if isSelectedInsightModelCurrent {
                Label("Selected", systemImage: "checkmark.circle")
            } else {
                Label("Use Model", systemImage: "checkmark.circle")
            }
        } else {
            Label("Download", systemImage: "arrow.down.circle")
        }
    }

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text("Semantic Search")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Spacer()
            }

            HStack(spacing: Spacing.sm) {
                OrttaaiTextField(placeholder: "Search a project, person, idea, or commitment", text: $viewModel.query)
                    .onSubmit {
                        Task { await viewModel.search() }
                    }

                Button {
                    Task { await viewModel.search() }
                } label: {
                    if viewModel.isSearching {
                        Label("Searching...", systemImage: "magnifyingglass")
                    } else {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary))
                .disabled(viewModel.isSearching || viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if viewModel.results.isEmpty {
                Text("Build the index to search.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .padding(.vertical, Spacing.sm)
            } else {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ForEach(viewModel.results) { result in
                        resultRow(result)
                    }
                }
            }
        }
        .padding(Spacing.md)
        .dashboardCard()
    }

    private var insightsContent: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .center, spacing: Spacing.md) {
                Text("Graph Insights")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Spacer()

                Button {
                    Task { await viewModel.generateInsights() }
                } label: {
                    if viewModel.isGeneratingInsights {
                        Label("Generating", systemImage: "arrow.triangle.2.circlepath")
                    } else if viewModel.insightReport != nil {
                        Label("Regenerate", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("Generate Insights", systemImage: "brain.head.profile")
                    }
                }
                .buttonStyle(OrttaaiButtonStyle(.primary))
                .disabled(viewModel.isGeneratingInsights || viewModel.graph.nodes.isEmpty)
            }

            if viewModel.graph.nodes.isEmpty {
                emptyInsightsState
            } else if viewModel.isGeneratingInsights && viewModel.insightReport == nil {
                generatingInsightsState
            } else if let report = viewModel.insightReport {
                insightReportView(report)
            } else {
                readyInsightsState
            }
        }
    }

    private var emptyInsightsState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "lightbulb.min")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(Color.Orttaai.accent)
            Text("Build the graph before generating insights.")
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(Color.Orttaai.bgTertiary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
    }

    private var generatingInsightsState: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Generating insights...")
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
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

    private var readyInsightsState: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button {
                Task { await viewModel.generateInsights() }
            } label: {
                Label("Generate Insights", systemImage: "brain.head.profile")
            }
            .buttonStyle(OrttaaiButtonStyle(.secondary))
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
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
            HStack(alignment: .firstTextBaseline) {
                Text("Graph Insight Summary")
                    .font(.Orttaai.bodyMedium)
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

    private func normalizeSemanticEmbeddingSelection() {
        semanticEmbeddingModel = normalizedSemanticEmbeddingModel.isEmpty ? "all-minilm" : normalizedSemanticEmbeddingModel
        semanticActiveIndexModelID = semanticActiveIndexModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedEmbeddingCatalogModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectedEmbeddingCatalogModel = semanticEmbeddingModel
        }
    }

    private func normalizeInsightSummarySelection() {
        semanticInsightSummaryModel = normalizedSemanticInsightSummaryModel.isEmpty ? "qwen3.5:0.8b" : normalizedSemanticInsightSummaryModel
        if selectedInsightCatalogModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectedInsightCatalogModel = semanticInsightSummaryModel
        }
    }

    /// The provider the user actually selected, cloud or local. Distinct from
    /// `providerKind`, which resolves to the local provider this view manages.
    private var activeProviderKind: LocalLLMProviderKind {
        LocalLLMProviderKind(rawValue: localLLMProviderRaw) ?? .ollama
    }

    private var providerKind: LocalLLMProviderKind {
        let active = activeProviderKind
        if active.supportsEmbeddings { return active }
        // This view manages on-device embedding/graph models; while a cloud
        // provider is active those stay on the last local provider.
        let storedRaw = UserDefaults.standard.string(forKey: "lastLocalLLMProvider") ?? ""
        let stored = LocalLLMProviderKind(rawValue: storedRaw) ?? .ollama
        return stored.isLocal ? stored : .ollama
    }

    private var activeLLMEndpoint: String {
        providerKind == .ollama ? localLLMEndpoint : lmStudioEndpoint
    }

    private func loadEmbeddingModelCatalog() async {
        await MainActor.run {
            normalizeSemanticEmbeddingSelection()
            normalizeInsightSummarySelection()
            isCheckingEmbeddingModels = true
            embeddingInstallError = nil
            insightInstallError = nil
        }

        let health = await LocalLLM.client(for: providerKind).checkHealth(
            baseURLString: activeLLMEndpoint,
            timeoutMs: 1_500
        )

        await MainActor.run {
            installedOllamaModels = health.installedModels
            isCheckingEmbeddingModels = false
        }

        // Curated download catalogs are Ollama-specific; for LM Studio the
        // option lists are built purely from installed models.
        guard health.isReachable, providerKind.supportsModelInstall else {
            await MainActor.run {
                embeddingCatalogModels = []
                insightCatalogModels = []
                syncSelectedEmbeddingModel()
                syncSelectedInsightModel()
            }
            return
        }

        await fetchEmbeddingLibraryModels()
        await fetchInsightLibraryModels()
    }

    private func fetchEmbeddingLibraryModels() async {
        await MainActor.run {
            isLoadingEmbeddingCatalog = true
        }

        do {
            let catalog = try await LocalLLM.ollamaClient.fetchEmbeddingLibraryModels(limit: 20)
            await MainActor.run {
                embeddingCatalogModels = catalog
                syncSelectedEmbeddingModel()
            }
        } catch {
            await MainActor.run {
                embeddingCatalogModels = []
                syncSelectedEmbeddingModel()
            }
        }

        await MainActor.run {
            isLoadingEmbeddingCatalog = false
        }
    }

    private func fetchInsightLibraryModels() async {
        await MainActor.run {
            isLoadingInsightCatalog = true
        }

        do {
            let catalog = try await LocalLLM.ollamaClient.fetchLibraryModels(limit: 80)
            let textModels = catalog.filter { !isLikelyEmbeddingModel($0.name) }
            await MainActor.run {
                insightCatalogModels = textModels
                syncSelectedInsightModel()
            }
        } catch {
            await MainActor.run {
                insightCatalogModels = []
                syncSelectedInsightModel()
            }
        }

        await MainActor.run {
            isLoadingInsightCatalog = false
        }
    }

    private func syncSelectedEmbeddingModel() {
        let options = embeddingModelOptions.map(\.name)
        if options.isEmpty {
            selectedEmbeddingCatalogModel = normalizedSemanticEmbeddingModel.isEmpty ? "all-minilm" : normalizedSemanticEmbeddingModel
            return
        }

        if !options.contains(where: { canonicalOllamaModelName($0) == canonicalOllamaModelName(selectedEmbeddingCatalogModel) }) {
            selectedEmbeddingCatalogModel = options.first(where: {
                canonicalOllamaModelName($0) == canonicalOllamaModelName(normalizedSemanticEmbeddingModel)
            }) ?? options.first ?? "all-minilm"
        }

        selectEmbeddingModelIfInstalled(selectedEmbeddingCatalogModel)
    }

    private func syncSelectedInsightModel() {
        let options = insightModelOptions.map(\.name)
        if options.isEmpty {
            selectedInsightCatalogModel = normalizedSemanticInsightSummaryModel.isEmpty ? "qwen3.5:0.8b" : normalizedSemanticInsightSummaryModel
            return
        }

        if !options.contains(where: { canonicalOllamaModelName($0) == canonicalOllamaModelName(selectedInsightCatalogModel) }) {
            selectedInsightCatalogModel = options.first(where: {
                canonicalOllamaModelName($0) == canonicalOllamaModelName(normalizedSemanticInsightSummaryModel)
            }) ?? options.first ?? "qwen3.5:0.8b"
        }

        selectInsightModelIfInstalled(selectedInsightCatalogModel)
    }

    private func selectEmbeddingModelIfInstalled(_ modelName: String) {
        let normalized = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, isOllamaModelInstalled(normalized) else { return }
        guard canonicalOllamaModelName(normalized) != canonicalOllamaModelName(normalizedSemanticEmbeddingModel) else { return }
        semanticEmbeddingModel = normalized
        semanticActiveIndexModelID = ""
        embeddingInstallSuccessMessage = "Selected \(normalized). Rebuild the index to use it."
        embeddingInstallError = nil
    }

    private func selectInsightModelIfInstalled(_ modelName: String) {
        let normalized = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, isOllamaModelInstalled(normalized) else { return }
        guard canonicalOllamaModelName(normalized) != canonicalOllamaModelName(normalizedSemanticInsightSummaryModel) else { return }
        semanticInsightSummaryModel = normalized
        insightInstallSuccessMessage = "Selected \(normalized) for graph insights."
        insightInstallError = nil
    }

    private func useOrInstallSelectedEmbeddingModel() async {
        let normalized = normalizedSelectedEmbeddingModel
        guard !normalized.isEmpty else {
            await MainActor.run {
                embeddingInstallError = "Choose an embedding model first."
                embeddingInstallSuccessMessage = nil
            }
            return
        }

        if isOllamaModelInstalled(normalized) {
            await MainActor.run {
                semanticEmbeddingModel = normalized
                semanticActiveIndexModelID = ""
                embeddingInstallSuccessMessage = "Selected \(normalized). Rebuild the index to use it."
                embeddingInstallError = nil
            }
            return
        }

        guard providerKind.supportsModelInstall else {
            await MainActor.run {
                embeddingInstallError = "\(normalized) is not available in \(providerKind.displayName). Download it in the \(providerKind.displayName) app first."
                embeddingInstallSuccessMessage = nil
            }
            return
        }

        await installEmbeddingModel(named: normalized)
    }

    private func useOrInstallSelectedInsightModel() async {
        let normalized = normalizedSelectedInsightModel
        guard !normalized.isEmpty else {
            await MainActor.run {
                insightInstallError = "Choose a graph insight model first."
                insightInstallSuccessMessage = nil
            }
            return
        }

        if isOllamaModelInstalled(normalized) {
            await MainActor.run {
                semanticInsightSummaryModel = normalized
                insightInstallSuccessMessage = "Selected \(normalized) for graph insights."
                insightInstallError = nil
            }
            return
        }

        guard providerKind.supportsModelInstall else {
            await MainActor.run {
                insightInstallError = "\(normalized) is not available in \(providerKind.displayName). Download it in the \(providerKind.displayName) app first."
                insightInstallSuccessMessage = nil
            }
            return
        }

        await installInsightModel(named: normalized)
    }

    private func installEmbeddingModel(named modelName: String) async {
        await MainActor.run {
            isInstallingEmbeddingModel = true
            installingEmbeddingModelName = modelName
            embeddingInstallStatusMessage = "Starting download for \(modelName)..."
            embeddingInstallProgress = nil
            embeddingInstallError = nil
            embeddingInstallSuccessMessage = nil
        }

        do {
            try await LocalLLM.ollamaClient.pullModel(baseURLString: localLLMEndpoint, model: modelName) { progress in
                let message = formattedInstallMessage(progress)
                Task { @MainActor in
                    embeddingInstallStatusMessage = message
                    embeddingInstallProgress = progress.fractionCompleted
                }
            }

            await MainActor.run {
                semanticEmbeddingModel = modelName
                semanticActiveIndexModelID = ""
                embeddingInstallStatusMessage = nil
                embeddingInstallProgress = nil
                embeddingInstallSuccessMessage = "Installed and selected \(modelName). Rebuild the index to use it."
            }

            await loadEmbeddingModelCatalog()
        } catch {
            await MainActor.run {
                embeddingInstallProgress = nil
                embeddingInstallError = "Install failed for \(modelName): \(error.localizedDescription)"
            }
        }

        await MainActor.run {
            isInstallingEmbeddingModel = false
            installingEmbeddingModelName = nil
            if embeddingInstallError != nil {
                embeddingInstallStatusMessage = nil
            }
        }
    }

    private func installInsightModel(named modelName: String) async {
        await MainActor.run {
            isInstallingInsightModel = true
            installingInsightModelName = modelName
            insightInstallStatusMessage = "Starting download for \(modelName)..."
            insightInstallProgress = nil
            insightInstallError = nil
            insightInstallSuccessMessage = nil
        }

        do {
            try await LocalLLM.ollamaClient.pullModel(baseURLString: localLLMEndpoint, model: modelName) { progress in
                let message = formattedInstallMessage(progress)
                Task { @MainActor in
                    insightInstallStatusMessage = message
                    insightInstallProgress = progress.fractionCompleted
                }
            }

            await MainActor.run {
                semanticInsightSummaryModel = modelName
                insightInstallStatusMessage = nil
                insightInstallProgress = nil
                insightInstallSuccessMessage = "Installed and selected \(modelName) for graph insights."
            }

            await loadEmbeddingModelCatalog()
        } catch {
            await MainActor.run {
                insightInstallProgress = nil
                insightInstallError = "Install failed for \(modelName): \(error.localizedDescription)"
            }
        }

        await MainActor.run {
            isInstallingInsightModel = false
            installingInsightModelName = nil
            if insightInstallError != nil {
                insightInstallStatusMessage = nil
            }
        }
    }

    private func embeddingModelOptionLabel(for model: OllamaCatalogModel) -> String {
        var parts = [model.name]
        if let sizeBytes = model.sizeBytes, sizeBytes > 0 {
            parts.append(formattedByteCount(sizeBytes))
        }
        parts.append(isOllamaModelInstalled(model.name) ? "Downloaded" : "Not downloaded")
        return parts.joined(separator: " · ")
    }

    private func insightModelOptionLabel(for model: OllamaCatalogModel) -> String {
        var parts = [model.name]
        if let sizeBytes = model.sizeBytes, sizeBytes > 0 {
            parts.append(formattedByteCount(sizeBytes))
        }
        parts.append(isOllamaModelInstalled(model.name) ? "Downloaded" : "Not downloaded")
        return parts.joined(separator: " · ")
    }

    private func formattedInstallMessage(_ progress: OllamaPullProgress) -> String {
        let status = progress.status.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanStatus = status.isEmpty ? "Downloading \(progress.model)..." : status
        guard let completedBytes = progress.completedBytes, let totalBytes = progress.totalBytes, totalBytes > 0 else {
            return cleanStatus
        }

        let completed = formattedByteCount(completedBytes)
        let total = formattedByteCount(totalBytes)
        let percent = Int((Double(completedBytes) / Double(totalBytes)) * 100)
        return "\(cleanStatus) (\(percent)% · \(completed)/\(total))"
    }

    private func formattedByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func isOllamaModelInstalled(_ modelName: String) -> Bool {
        let canonical = canonicalOllamaModelName(modelName)
        guard !canonical.isEmpty else { return false }
        return installedOllamaModels.contains { canonicalOllamaModelName($0) == canonical }
    }

    private func canonicalOllamaModelName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }
        if trimmed.contains(":") {
            return trimmed
        }
        return "\(trimmed):latest"
    }

    private func isLikelyEmbeddingModel(_ modelName: String) -> Bool {
        let normalized = modelName.lowercased()
        return normalized.contains("embed") ||
            normalized.contains("minilm") ||
            normalized.contains("nomic")
    }

    private func resultRow(_ result: SemanticRetrievedContext) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Text(result.targetAppName?.isEmpty == false ? result.targetAppName! : "Unknown App")
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Text(Self.resultDateFormatter.string(from: result.sourceCreatedAt))
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                Spacer()
                Text("\(Int((result.score * 100).rounded()))%")
                    .font(.Orttaai.mono)
                    .foregroundStyle(Color.Orttaai.accent)
            }

            Text(result.text)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .lineLimit(4)
        }
        .padding(Spacing.md)
        .background(Color.Orttaai.bgTertiary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))
    }

    private static let resultDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let insightDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
