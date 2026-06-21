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

    private let service = SemanticMemoryService()

    func load() {
        stats = service.stats()
        let loadedGraph = service.graph()
        graph = loadedGraph
        if insightReport?.graphSignature != semanticGraphSignature(for: loadedGraph) {
            insightReport = nil
        }
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
        let report = await service.generateInsights()
        insightReport = report
        if report.cards.isEmpty {
            statusMessage = "Build more semantic memory before insights can be generated."
        } else if let modelName = report.summaryModelName {
            statusMessage = "Generated \(report.cards.count) graph insight\(report.cards.count == 1 ? "" : "s") with \(modelName) TLDR."
        } else {
            statusMessage = "Generated \(report.cards.count) graph insight\(report.cards.count == 1 ? "" : "s")."
        }
        isGeneratingInsights = false
    }

    func generateInsightsIfNeeded() async {
        guard insightReport == nil || insightReport?.graphSignature != semanticGraphSignature(for: graph) else { return }
        await generateInsights()
    }
}

private enum SemanticMemoryTab: String, CaseIterable, Identifiable {
    case graph = "Graph"
    case search = "Search"
    case insights = "Insights"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .graph: return "point.3.connected.trianglepath.dotted"
        case .search: return "magnifyingglass"
        case .insights: return "lightbulb"
        }
    }
}

struct SemanticMemoryView: View {
    @StateObject private var viewModel = SemanticMemoryViewModel()
    @State private var selectedTab: SemanticMemoryTab = .graph
    @State private var isSetupPresented = false
    @State private var isInfoPresented = false
    @State private var graphPopoutController: SemanticGraphPopoutController?
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
    @AppStorage("localLLMEndpoint") private var localLLMEndpoint = "http://127.0.0.1:11434"
    @AppStorage("semanticMemoryEnabled") private var semanticMemoryEnabled = true
    @AppStorage("semanticMemoryAutoIndexEnabled") private var semanticMemoryAutoIndexEnabled = true
    @AppStorage("semanticEmbeddingFallbackEnabled") private var semanticEmbeddingFallbackEnabled = true
    @AppStorage("semanticEmbeddingModel") private var semanticEmbeddingModel = "all-minilm"
    @AppStorage("semanticActiveIndexModelID") private var semanticActiveIndexModelID = ""
    @AppStorage("semanticInsightSummaryEnabled") private var semanticInsightSummaryEnabled = true
    @AppStorage("semanticInsightSummaryModel") private var semanticInsightSummaryModel = "qwen3.5:0.8b"

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                header
                tabStatusRow

                switch selectedTab {
                case .graph:
                    statsGrid
                    graphCard
                case .search:
                    searchCard
                case .insights:
                    insightsContent
                }
            }
            .padding(WorkspaceLayout.contentInsets)
        }
        .background(Color.Orttaai.bgPrimary)
        .sheet(isPresented: $isSetupPresented) {
            setupSheet
        }
        .onChange(of: graphSignature) { _, _ in
            graphPopoutController?.update(graph: viewModel.graph)
        }
        .onAppear {
            viewModel.load()
        }
        .onChange(of: selectedTab) { _, newValue in
            guard newValue == .insights else { return }
            Task { await viewModel.generateInsightsIfNeeded() }
        }
    }

    private var graphSignature: String {
        semanticGraphSignature(for: viewModel.graph)
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

    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.lg) {
            HStack(alignment: .center, spacing: Spacing.xs) {
                Text("Memory Graph")
                    .font(.Orttaai.heading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Button {
                    isInfoPresented.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.Orttaai.textTertiary)
                .help("About Memory Graph")
                .popover(isPresented: $isInfoPresented, arrowEdge: .bottom) {
                    Text("Local semantic map of your dictation history, app contexts, and recurring themes.")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .padding(Spacing.lg)
                        .frame(width: 280, alignment: .leading)
                        .background(Color.Orttaai.bgSecondary)
                }
            }

            Spacer()

            HStack(spacing: Spacing.sm) {
                Button {
                    isSetupPresented = true
                } label: {
                    Label("Setup", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary))

                Button {
                    Task { await viewModel.buildIndex() }
                } label: {
                    if viewModel.isIndexing {
                        Label("Building...", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("Build Index", systemImage: "bolt.horizontal.circle")
                    }
                }
                .buttonStyle(OrttaaiButtonStyle(.primary))
                .disabled(viewModel.isIndexing || !semanticMemoryEnabled)

                Button {
                    viewModel.load()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary))
            }
        }
    }

    private var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach(SemanticMemoryTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        selectedTab = tab
                    }
                } label: {
                    Label(tab.rawValue, systemImage: tab.systemImage)
                        .font(.Orttaai.bodyMedium)
                        .lineLimit(1)
                        .foregroundStyle(selectedTab == tab ? Color.Orttaai.bgPrimary : Color.Orttaai.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selectedTab == tab ? Color.Orttaai.accent : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .frame(width: 420)
        .background(Color.Orttaai.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var tabStatusRow: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            tabPicker
            statusStrip
            Spacer(minLength: 0)
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
                Picker("Embedding Model", selection: $selectedEmbeddingCatalogModel) {
                    if embeddingModelOptions.isEmpty {
                        let fallbackModel = normalizedSemanticEmbeddingModel.isEmpty ? "all-minilm" : normalizedSemanticEmbeddingModel
                        Text(fallbackModel)
                            .tag(fallbackModel)
                    } else {
                        ForEach(embeddingModelOptions) { model in
                            Text(embeddingModelOptionLabel(for: model))
                                .tag(model.name)
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
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
                Text("TLDR Summary Model")
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Spacer()

                Toggle("Model TLDR", isOn: $semanticInsightSummaryEnabled)
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
                Picker("TLDR Summary Model", selection: $selectedInsightCatalogModel) {
                    if insightModelOptions.isEmpty {
                        let fallbackModel = normalizedSemanticInsightSummaryModel.isEmpty ? "qwen3.5:0.8b" : normalizedSemanticInsightSummaryModel
                        Text(fallbackModel)
                            .tag(fallbackModel)
                    } else {
                        ForEach(insightModelOptions) { model in
                            Text(insightModelOptionLabel(for: model))
                                .tag(model.name)
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
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

    private var statsGrid: some View {
        let stats = viewModel.stats
        return LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: 160), spacing: Spacing.md),
                GridItem(.flexible(minimum: 160), spacing: Spacing.md),
                GridItem(.flexible(minimum: 160), spacing: Spacing.md),
                GridItem(.flexible(minimum: 160), spacing: Spacing.md),
            ],
            spacing: Spacing.md
        ) {
            metricCard(title: "Chunks", value: "\(stats?.chunkCount ?? 0)", detail: "Transcript segments")
            metricCard(title: "Embedded", value: "\(stats?.embeddedChunkCount ?? 0)", detail: stats?.activeModelID ?? semanticEmbeddingModel)
            metricCard(title: "Nodes", value: "\(stats?.nodeCount ?? 0)", detail: "Graph concepts")
            metricCard(title: "Edges", value: "\(stats?.edgeCount ?? 0)", detail: "Semantic links")
        }
    }

    private var graphCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Graph View")
                        .font(.Orttaai.subheading)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                    Text("Topics, app contexts, and transcript chunks connected by inferred relationships.")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }
                Spacer()
                HStack(spacing: Spacing.sm) {
                    graphLegend
                    graphHeaderIconButton(
                        systemImage: graphPopoutController == nil ? "arrow.up.left.and.arrow.down.right" : "macwindow",
                        help: graphPopoutController == nil ? "Open graph in separate window" : "Show graph window",
                        action: openGraphPopout
                    )
                    .disabled(viewModel.graph.nodes.isEmpty)
                    .opacity(viewModel.graph.nodes.isEmpty ? 0.45 : 1)
                }
            }

            if viewModel.graph.nodes.isEmpty {
                emptyGraphState
            } else if graphPopoutController != nil {
                poppedOutGraphState
            } else {
                SemanticGraphCanvas(graph: viewModel.graph)
                    .frame(height: 430)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                            .stroke(Color.Orttaai.border.opacity(0.8), lineWidth: BorderWidth.standard)
                    )
            }
        }
        .padding(Spacing.lg)
        .dashboardCard()
    }

    private var poppedOutGraphState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "macwindow")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.Orttaai.accent)
            Text("Graph is open in a separate window.")
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
            Button {
                graphPopoutController?.show()
            } label: {
                Label("Show Window", systemImage: "arrow.up.forward")
            }
            .buttonStyle(OrttaaiButtonStyle(.secondary))
        }
        .frame(maxWidth: .infinity, minHeight: 430)
        .background(Color.Orttaai.bgTertiary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .stroke(Color.Orttaai.border.opacity(0.8), lineWidth: BorderWidth.standard)
        )
    }

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Semantic Search")
                        .font(.Orttaai.subheading)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                    Text("Find related dictations by meaning, not exact words.")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }
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
                Text("Search results will appear here after the index has been built.")
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
        .padding(Spacing.lg)
        .dashboardCard()
    }

    private var insightsContent: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(alignment: .center, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Graph Insights")
                        .font(.Orttaai.subheading)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                    Text("Synthesized from graph structure, app context, and supporting transcript excerpts.")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }

                Spacer()

                Button {
                    Task { await viewModel.generateInsights() }
                } label: {
                    if viewModel.isGeneratingInsights {
                        Label("Generating", systemImage: "arrow.triangle.2.circlepath")
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
            Text("Insights need graph nodes, semantic links, and transcript evidence.")
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .background(Color.Orttaai.bgTertiary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
    }

    private var generatingInsightsState: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Synthesizing graph TLDR, cards, and transcript evidence...")
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    private var readyInsightsState: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Ready to synthesize insights.")
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
            Text("Generate insight cards and a TLDR summary from the current semantic graph. The TLDR uses the selected Ollama model when available.")
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
            Button {
                Task { await viewModel.generateInsights() }
            } label: {
                Label("Generate Insights", systemImage: "brain.head.profile")
            }
            .buttonStyle(OrttaaiButtonStyle(.secondary))
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    private func insightReportView(_ report: SemanticInsightReport) -> some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            insightSummaryCard(report)

            if report.cards.isEmpty {
                Text("The graph exists, but there is not enough connected evidence yet for meaningful insight cards.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .padding(Spacing.lg)
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
                Text("TLDR Insight Summary")
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
            }
        }
        .padding(Spacing.lg)
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
        .padding(Spacing.lg)
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

    private var emptyGraphState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.Orttaai.accent)
            Text("Build the semantic index to generate your local memory graph.")
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
            Text("Orttaai will chunk recent dictations, create embeddings locally, and connect related themes.")
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .background(Color.Orttaai.bgTertiary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
    }

    private var graphLegend: some View {
        HStack(spacing: Spacing.sm) {
            legendItem("Topic", color: .purple)
            legendItem("Entity", color: .green)
            legendItem("App", color: .blue)
            legendItem("Chunk", color: Color.Orttaai.accent)
        }
    }

    private func metricCard(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
            Text(value)
                .font(.Orttaai.title)
                .foregroundStyle(Color.Orttaai.textPrimary)
            Text(detail)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .lineLimit(1)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
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

    private func legendItem(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textSecondary)
        }
    }

    private func graphHeaderIconButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.Orttaai.textPrimary)
        .background(Color.Orttaai.bgTertiary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.Orttaai.border.opacity(0.65), lineWidth: BorderWidth.standard)
        )
        .help(help)
    }

    private func openGraphPopout() {
        if let graphPopoutController {
            graphPopoutController.show()
            return
        }

        let controller = SemanticGraphPopoutController(graph: viewModel.graph) {
            graphPopoutController = nil
        }
        graphPopoutController = controller
        controller.show()
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

    private func loadEmbeddingModelCatalog() async {
        await MainActor.run {
            normalizeSemanticEmbeddingSelection()
            normalizeInsightSummarySelection()
            isCheckingEmbeddingModels = true
            embeddingInstallError = nil
            insightInstallError = nil
        }

        let health = await OllamaClient().checkHealth(
            baseURLString: localLLMEndpoint,
            timeoutMs: 1_500
        )

        await MainActor.run {
            installedOllamaModels = health.installedModels
            isCheckingEmbeddingModels = false
        }

        guard health.isReachable else {
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
            let catalog = try await OllamaClient().fetchEmbeddingLibraryModels(limit: 20)
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
            let catalog = try await OllamaClient().fetchLibraryModels(limit: 80)
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
        insightInstallSuccessMessage = "Selected \(normalized) for TLDR summaries."
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

        await installEmbeddingModel(named: normalized)
    }

    private func useOrInstallSelectedInsightModel() async {
        let normalized = normalizedSelectedInsightModel
        guard !normalized.isEmpty else {
            await MainActor.run {
                insightInstallError = "Choose a TLDR model first."
                insightInstallSuccessMessage = nil
            }
            return
        }

        if isOllamaModelInstalled(normalized) {
            await MainActor.run {
                semanticInsightSummaryModel = normalized
                insightInstallSuccessMessage = "Selected \(normalized) for TLDR summaries."
                insightInstallError = nil
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
            try await OllamaClient().pullModel(baseURLString: localLLMEndpoint, model: modelName) { progress in
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
            try await OllamaClient().pullModel(baseURLString: localLLMEndpoint, model: modelName) { progress in
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
                insightInstallSuccessMessage = "Installed and selected \(modelName) for TLDR summaries."
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

private func semanticGraphSignature(for graph: SemanticMemoryGraph) -> String {
    let nodePart = graph.nodes
        .map { "\($0.nodeID):\($0.weight)" }
        .joined(separator: "|")
    let edgePart = graph.edges
        .enumerated()
        .map { "\($0.offset):\($0.element.sourceNodeID)>\($0.element.targetNodeID):\($0.element.weight)" }
        .joined(separator: "|")
    return "\(graph.nodes.count)#\(graph.edges.count)#\(nodePart)#\(edgePart)"
}

@MainActor
private final class SemanticGraphPopoutController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var hostingView: NSHostingView<SemanticGraphPopoutView>?
    private let onClose: () -> Void
    private var hasCenteredWindow = false

    init(graph: SemanticMemoryGraph, onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()

        let size = CGSize(width: 1_120, height: 760)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(rootView: SemanticGraphPopoutView(graph: graph))
        window.title = "Memory Graph"
        window.minSize = CGSize(width: 780, height: 520)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor.Orttaai.bgPrimary
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self

        self.window = window
        self.hostingView = hostingView
    }

    func show() {
        guard let window else { return }
        if !hasCenteredWindow {
            window.center()
            hasCenteredWindow = true
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.unhide(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(graph: SemanticMemoryGraph) {
        hostingView?.rootView = SemanticGraphPopoutView(graph: graph)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        hostingView = nil
        onClose()
    }
}

private struct SemanticGraphPopoutView: View {
    let graph: SemanticMemoryGraph

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .center, spacing: Spacing.md) {
                Text("Memory Graph")
                    .font(.Orttaai.heading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Spacer()

                graphLegend
            }

            SemanticGraphCanvas(graph: graph)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                        .stroke(Color.Orttaai.border.opacity(0.8), lineWidth: BorderWidth.standard)
                )
        }
        .padding(Spacing.lg)
        .frame(minWidth: 780, minHeight: 520)
        .background(Color.Orttaai.bgPrimary)
    }

    private var graphLegend: some View {
        HStack(spacing: Spacing.sm) {
            legendItem("Topic", color: .purple)
            legendItem("Entity", color: .green)
            legendItem("App", color: .blue)
            legendItem("Chunk", color: Color.Orttaai.accent)
        }
    }

    private func legendItem(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textSecondary)
        }
    }
}

private struct SemanticGraphCanvas: View {
    let graph: SemanticMemoryGraph

    @State private var layout = SemanticGraphLayout.empty
    @State private var layoutSignature = ""
    @State private var viewport = GraphViewport()
    @State private var hoveredNodeID: String?
    @State private var selectedNodeID: String?

    var body: some View {
        GeometryReader { proxy in
            let currentSignature = semanticGraphSignature(for: graph)

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawGraph(context: &context, size: size)
                }
                .background(Color.Orttaai.bgPrimary.opacity(0.92))

                GraphInteractionOverlay(
                    layout: layout,
                    viewport: $viewport,
                    hoveredNodeID: $hoveredNodeID,
                    selectedNodeID: $selectedNodeID,
                    onFit: {
                        fitGraph(in: proxy.size)
                    }
                )

                graphControls(size: proxy.size)
                    .padding(Spacing.sm)

                if let focusNode {
                    focusPanel(for: focusNode)
                        .padding(Spacing.sm)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .clipped()
            .onAppear {
                rebuildLayoutIfNeeded(signature: currentSignature, size: proxy.size)
            }
            .onChange(of: currentSignature) { _, newSignature in
                rebuildLayoutIfNeeded(signature: newSignature, size: proxy.size)
            }
        }
    }

    private var activeFocusID: String? {
        hoveredNodeID ?? selectedNodeID
    }

    private var focusNode: SemanticGraphLayoutNode? {
        guard let activeFocusID else { return nil }
        return layout.node(id: activeFocusID)
    }

    private var activeFocusIDs: Set<String> {
        guard let activeFocusID else { return [] }
        var ids = layout.neighborIDs[activeFocusID] ?? []
        ids.insert(activeFocusID)
        return ids
    }

    private func drawGraph(context: inout GraphicsContext, size: CGSize) {
        guard !layout.nodes.isEmpty else { return }
        let focusIDs = activeFocusIDs
        let viewportRect = CGRect(origin: .zero, size: size).insetBy(dx: -80, dy: -80)
        drawEdges(context: &context, size: size, viewportRect: viewportRect, focusIDs: focusIDs)
        drawNodes(context: &context, size: size, viewportRect: viewportRect, focusIDs: focusIDs)
    }

    private func drawEdges(
        context: inout GraphicsContext,
        size: CGSize,
        viewportRect: CGRect,
        focusIDs: Set<String>
    ) {
        for edge in layout.edges {
            guard shouldDrawEdge(edge, focusIDs: focusIDs) else { continue }
            guard let startNode = layout.node(id: edge.sourceID),
                  let endNode = layout.node(id: edge.targetID) else { continue }

            let start = viewport.project(startNode.position, in: size)
            let end = viewport.project(endNode.position, in: size)
            let edgeRect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(start.x - end.x),
                height: abs(start.y - end.y)
            )
            .insetBy(dx: -24, dy: -24)
            guard edgeRect.intersects(viewportRect) else { continue }

            let touchesFocus = activeFocusID.map { edge.sourceID == $0 || edge.targetID == $0 } ?? false
            let insideFocus = focusIDs.isEmpty || (focusIDs.contains(edge.sourceID) && focusIDs.contains(edge.targetID))
            let opacity: Double
            if touchesFocus {
                opacity = min(0.88, 0.34 + edge.weight * 0.42)
            } else if insideFocus {
                opacity = min(0.55, 0.16 + edge.weight * 0.32)
            } else {
                opacity = 0.045
            }

            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(
                path,
                with: .color(edgeColor(edge.kind).opacity(opacity)),
                lineWidth: edgeLineWidth(edge)
            )
        }
    }

    private func drawNodes(
        context: inout GraphicsContext,
        size: CGSize,
        viewportRect: CGRect,
        focusIDs: Set<String>
    ) {
        let sortedNodes = layout.nodes.sorted { lhs, rhs in
            if lhs.kind == rhs.kind {
                return lhs.importance < rhs.importance
            }
            return nodeLayer(lhs.kind) < nodeLayer(rhs.kind)
        }

        for node in sortedNodes {
            let position = viewport.project(node.position, in: size)
            guard viewportRect.contains(position) else { continue }
            let radius = nodeScreenRadius(node)
            let isFocused = activeFocusID == node.id
            let isRelated = focusIDs.isEmpty || focusIDs.contains(node.id)
            let opacity = isRelated ? 0.9 : 0.22

            let rect = CGRect(
                x: position.x - radius,
                y: position.y - radius,
                width: radius * 2,
                height: radius * 2
            )

            if isFocused {
                context.fill(
                    Path(ellipseIn: rect.insetBy(dx: -8, dy: -8)),
                    with: .color(nodeColor(node.kind).opacity(0.18))
                )
            }

            context.fill(Path(ellipseIn: rect), with: .color(nodeColor(node.kind).opacity(opacity)))
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(Color.white.opacity(isFocused ? 0.62 : 0.16)),
                lineWidth: isFocused ? 1.6 : 1
            )

            if shouldDrawLabel(for: node, isRelated: isRelated, isFocused: isFocused) {
                drawLabel(for: node, at: position, radius: radius, isFocused: isFocused, context: &context)
            }
        }
    }

    private func drawLabel(
        for node: SemanticGraphLayoutNode,
        at position: CGPoint,
        radius: CGFloat,
        isFocused: Bool,
        context: inout GraphicsContext
    ) {
        let label = truncatedLabel(node.title, limit: labelLimit(for: node))
        let opacity = labelOpacity(for: node, isFocused: isFocused)
        let fontSize = isFocused ? 12.5 : max(9.5, min(12, 9.5 + viewport.scale * 1.4))
        context.draw(
            Text(label)
                .font(.system(size: fontSize, weight: isFocused ? .semibold : .medium))
                .foregroundStyle(Color.Orttaai.textPrimary.opacity(opacity)),
            at: CGPoint(x: position.x, y: position.y + radius + 7),
            anchor: .top
        )
    }

    private func shouldDrawEdge(_ edge: SemanticGraphLayoutEdge, focusIDs: Set<String>) -> Bool {
        if let activeFocusID, (edge.sourceID == activeFocusID || edge.targetID == activeFocusID) {
            return true
        }
        if !focusIDs.isEmpty {
            return focusIDs.contains(edge.sourceID) && focusIDs.contains(edge.targetID)
        }
        if viewport.scale < 0.55 {
            return edge.weight >= 0.52 || edge.rank < 90
        }
        if viewport.scale < 0.95 {
            return edge.weight >= 0.28 || edge.rank < 180
        }
        return true
    }

    private func shouldDrawLabel(for node: SemanticGraphLayoutNode, isRelated: Bool, isFocused: Bool) -> Bool {
        if isFocused { return true }
        if !isRelated {
            return false
        }
        switch viewport.detailLevel {
        case .overview:
            return node.kind != "chunk" && node.importance >= 9
        case .context:
            return node.kind == "app" || node.importance >= (node.kind == "chunk" ? 14 : 6)
        case .detail:
            return node.kind != "chunk" || node.importance >= 5
        case .inspection:
            return true
        }
    }

    private func labelOpacity(for node: SemanticGraphLayoutNode, isFocused: Bool) -> Double {
        if isFocused { return 1 }
        switch viewport.detailLevel {
        case .overview:
            return min(0.78, 0.42 + node.importance / 30)
        case .context:
            return min(0.86, 0.46 + node.importance / 24)
        case .detail:
            return 0.9
        case .inspection:
            return 0.96
        }
    }

    private func labelLimit(for node: SemanticGraphLayoutNode) -> Int {
        switch viewport.detailLevel {
        case .overview:
            return 14
        case .context:
            return node.kind == "chunk" ? 18 : 22
        case .detail:
            return node.kind == "chunk" ? 28 : 30
        case .inspection:
            return 42
        }
    }

    private func nodeScreenRadius(_ node: SemanticGraphLayoutNode) -> CGFloat {
        max(3.8, min(node.baseRadius * pow(viewport.scale, 0.58), node.baseRadius * 1.8))
    }

    private func edgeLineWidth(_ edge: SemanticGraphLayoutEdge) -> CGFloat {
        max(0.45, min(2.8, (0.45 + edge.weight * 1.8) * pow(viewport.scale, 0.24)))
    }

    private func nodeLayer(_ kind: String) -> Int {
        switch kind {
        case "chunk": return 0
        case "topic": return 1
        case "entity": return 2
        case "app": return 3
        default: return 1
        }
    }

    private func nodeColor(_ kind: String) -> Color {
        switch kind {
        case "topic": return .purple
        case "entity": return .green
        case "app": return .blue
        default: return Color.Orttaai.accent
        }
    }

    private func edgeColor(_ kind: String) -> Color {
        switch kind {
        case "semantic": return Color.Orttaai.accent
        case "entity": return .green
        case "app-context": return .blue
        default: return .purple
        }
    }

    private func graphControls(size: CGSize) -> some View {
        HStack(spacing: 4) {
            graphControlButton(systemImage: "minus.magnifyingglass", help: "Zoom out") {
                viewport.zoom(by: 0.78, around: CGPoint(x: size.width / 2, y: size.height / 2), in: size)
            }
            Text("\(Int((viewport.scale * 100).rounded()))%")
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .frame(width: 46)
            graphControlButton(systemImage: "plus.magnifyingglass", help: "Zoom in") {
                viewport.zoom(by: 1.28, around: CGPoint(x: size.width / 2, y: size.height / 2), in: size)
            }
            Divider()
                .frame(height: 18)
                .background(Color.Orttaai.border.opacity(0.65))
            graphControlButton(systemImage: "viewfinder", help: "Fit graph") {
                fitGraph(in: size)
            }
        }
        .padding(5)
        .background(Color.Orttaai.bgSecondary.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous)
                .stroke(Color.Orttaai.border.opacity(0.72), lineWidth: BorderWidth.standard)
        )
    }

    private func graphControlButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.Orttaai.textPrimary)
        .background(Color.Orttaai.bgTertiary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help(help)
    }

    private func focusPanel(for node: SemanticGraphLayoutNode) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Circle()
                    .fill(nodeColor(node.kind))
                    .frame(width: 8, height: 8)
                Text(node.kind.capitalized)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                Spacer(minLength: 0)
                Text("\(layout.degree(for: node.id)) links")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
            }

            Text(node.title)
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .lineLimit(2)

            if let subtitle = node.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .lineLimit(3)
            }
        }
        .padding(Spacing.md)
        .frame(width: 230, alignment: .leading)
        .background(Color.Orttaai.bgSecondary.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .stroke(Color.Orttaai.border.opacity(0.8), lineWidth: BorderWidth.standard)
        )
        .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 8)
    }

    private func fitGraph(in size: CGSize) {
        viewport.fit(bounds: layout.bounds, in: size)
    }

    private func rebuildLayoutIfNeeded(signature: String, size: CGSize) {
        guard signature != layoutSignature else { return }
        layoutSignature = signature
        layout = SemanticGraphLayoutEngine.build(for: graph)
        hoveredNodeID = nil
        selectedNodeID = nil
        fitGraph(in: size)
    }

    private func truncatedLabel(_ label: String, limit: Int) -> String {
        guard label.count > limit else { return label }
        return String(label.prefix(max(0, limit - 1))) + "…"
    }
}

private enum GraphDetailLevel {
    case overview
    case context
    case detail
    case inspection
}

private struct GraphViewport {
    static let minimumScale: CGFloat = 0.28
    static let maximumScale: CGFloat = 4.2

    var scale: CGFloat = 1
    var pan: CGSize = .zero

    var detailLevel: GraphDetailLevel {
        if scale < 0.58 { return .overview }
        if scale < 1.05 { return .context }
        if scale < 1.85 { return .detail }
        return .inspection
    }

    func project(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width / 2 + point.x * scale + pan.width,
            y: size.height / 2 + point.y * scale + pan.height
        )
    }

    func unproject(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: (point.x - size.width / 2 - pan.width) / scale,
            y: (point.y - size.height / 2 - pan.height) / scale
        )
    }

    mutating func zoom(by factor: CGFloat, around screenPoint: CGPoint, in size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let oldScale = scale
        let newScale = min(Self.maximumScale, max(Self.minimumScale, oldScale * factor))
        guard newScale != oldScale else { return }
        let worldPoint = unproject(screenPoint, in: size)
        scale = newScale
        pan = CGSize(
            width: screenPoint.x - size.width / 2 - worldPoint.x * newScale,
            height: screenPoint.y - size.height / 2 - worldPoint.y * newScale
        )
    }

    mutating func pan(by delta: CGSize) {
        pan = CGSize(width: pan.width + delta.width, height: pan.height + delta.height)
    }

    mutating func fit(bounds: CGRect, in size: CGSize) {
        guard !bounds.isEmpty, bounds.width > 1, bounds.height > 1, size.width > 1, size.height > 1 else {
            scale = 1
            pan = .zero
            return
        }
        let horizontalScale = (size.width - 72) / bounds.width
        let verticalScale = (size.height - 72) / bounds.height
        let nextScale = min(Self.maximumScale, max(Self.minimumScale, min(horizontalScale, verticalScale)))
        scale = nextScale
        pan = CGSize(
            width: -bounds.midX * nextScale,
            height: -bounds.midY * nextScale
        )
    }
}

private struct SemanticGraphLayout {
    var nodes: [SemanticGraphLayoutNode]
    var edges: [SemanticGraphLayoutEdge]
    var nodeByID: [String: SemanticGraphLayoutNode]
    var neighborIDs: [String: Set<String>]
    var bounds: CGRect

    static let empty = SemanticGraphLayout(nodes: [], edges: [], nodeByID: [:], neighborIDs: [:], bounds: .zero)

    func node(id: String) -> SemanticGraphLayoutNode? {
        nodeByID[id]
    }

    func degree(for id: String) -> Int {
        neighborIDs[id]?.count ?? 0
    }
}

private struct SemanticGraphLayoutNode: Identifiable {
    let id: String
    let kind: String
    let title: String
    let subtitle: String?
    let weight: Double
    let importance: Double
    let baseRadius: CGFloat
    let position: CGPoint
}

private struct SemanticGraphLayoutEdge: Identifiable {
    let id: String
    let sourceID: String
    let targetID: String
    let kind: String
    let weight: Double
    let rank: Int
}

private enum SemanticGraphLayoutEngine {
    private struct SimNode {
        let source: SemanticGraphNode
        let degree: Int
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat = 0
        var vy: CGFloat = 0

        var radius: CGFloat {
            SemanticGraphLayoutEngine.baseRadius(kind: source.kind, weight: source.weight, degree: degree)
        }
    }

    private struct SimEdge {
        let sourceIndex: Int
        let targetIndex: Int
        let sourceID: String
        let targetID: String
        let kind: String
        let weight: Double
    }

    static func build(for graph: SemanticMemoryGraph) -> SemanticGraphLayout {
        guard !graph.nodes.isEmpty else { return .empty }
        let sourceNodes = graph.nodes.sorted { lhs, rhs in
            if lhs.kind == rhs.kind {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return kindRank(lhs.kind) < kindRank(rhs.kind)
        }
        let nodeIDSet = Set(sourceNodes.map(\.nodeID))
        let sourceEdges = graph.edges.filter {
            nodeIDSet.contains($0.sourceNodeID) && nodeIDSet.contains($0.targetNodeID)
        }

        var degrees: [String: Int] = [:]
        var neighbors: [String: Set<String>] = [:]
        for edge in sourceEdges {
            degrees[edge.sourceNodeID, default: 0] += 1
            degrees[edge.targetNodeID, default: 0] += 1
            neighbors[edge.sourceNodeID, default: []].insert(edge.targetNodeID)
            neighbors[edge.targetNodeID, default: []].insert(edge.sourceNodeID)
        }

        let groupedCounts = Dictionary(grouping: sourceNodes, by: \.kind).mapValues(\.count)
        var groupedIndexes: [String: Int] = [:]
        var simNodes = sourceNodes.map { node -> SimNode in
            let index = groupedIndexes[node.kind, default: 0]
            groupedIndexes[node.kind, default: 0] = index + 1
            let position = initialPosition(
                node: node,
                index: index,
                count: max(1, groupedCounts[node.kind] ?? 1)
            )
            return SimNode(
                source: node,
                degree: degrees[node.nodeID, default: 0],
                x: position.x,
                y: position.y
            )
        }

        let indexByID = Dictionary(uniqueKeysWithValues: sourceNodes.enumerated().map { ($0.element.nodeID, $0.offset) })
        let simEdges = sourceEdges.compactMap { edge -> SimEdge? in
            guard let sourceIndex = indexByID[edge.sourceNodeID],
                  let targetIndex = indexByID[edge.targetNodeID] else { return nil }
            return SimEdge(
                sourceIndex: sourceIndex,
                targetIndex: targetIndex,
                sourceID: edge.sourceNodeID,
                targetID: edge.targetNodeID,
                kind: edge.kind,
                weight: max(0.05, min(1, edge.weight))
            )
        }

        relax(nodes: &simNodes, edges: simEdges)

        let layoutNodes = simNodes.map { node in
            let importance = node.source.weight + Double(node.degree) * 0.65
            return SemanticGraphLayoutNode(
                id: node.source.nodeID,
                kind: node.source.kind,
                title: node.source.title,
                subtitle: node.source.subtitle,
                weight: node.source.weight,
                importance: importance,
                baseRadius: node.radius,
                position: CGPoint(x: node.x, y: node.y)
            )
        }
        let nodeByID = Dictionary(uniqueKeysWithValues: layoutNodes.map { ($0.id, $0) })
        let layoutEdges = simEdges
            .sorted {
                if $0.weight == $1.weight {
                    return $0.sourceID < $1.sourceID
                }
                return $0.weight > $1.weight
            }
            .enumerated()
            .map { index, edge in
                SemanticGraphLayoutEdge(
                    id: "\(edge.sourceID)>\(edge.targetID)>\(index)",
                    sourceID: edge.sourceID,
                    targetID: edge.targetID,
                    kind: edge.kind,
                    weight: edge.weight,
                    rank: index
                )
            }
        let bounds = layoutBounds(for: layoutNodes)
        return SemanticGraphLayout(
            nodes: layoutNodes,
            edges: layoutEdges,
            nodeByID: nodeByID,
            neighborIDs: neighbors,
            bounds: bounds
        )
    }

    private static func relax(nodes: inout [SimNode], edges: [SimEdge]) {
        guard nodes.count > 1 else { return }
        let iterations = nodes.count > 140 ? 220 : 260
        for _ in 0..<iterations {
            applyRepulsion(to: &nodes)
            applyLinks(edges, to: &nodes)
            applyCentering(to: &nodes)
            integrate(&nodes)
        }
    }

    private static func applyRepulsion(to nodes: inout [SimNode]) {
        guard nodes.count > 1 else { return }
        for lhsIndex in 0..<(nodes.count - 1) {
            for rhsIndex in (lhsIndex + 1)..<nodes.count {
                var dx = nodes[rhsIndex].x - nodes[lhsIndex].x
                var dy = nodes[rhsIndex].y - nodes[lhsIndex].y
                var distanceSquared = dx * dx + dy * dy
                if distanceSquared < 0.01 {
                    let jitter = deterministicJitter(for: nodes[lhsIndex].source.nodeID + nodes[rhsIndex].source.nodeID)
                    dx = jitter.x
                    dy = jitter.y
                    distanceSquared = max(1, dx * dx + dy * dy)
                }
                let distance = sqrt(distanceSquared)
                let minimumDistance = nodes[lhsIndex].radius + nodes[rhsIndex].radius + 16
                let repel = CGFloat(360 + min(22, nodes[lhsIndex].degree + nodes[rhsIndex].degree) * 9) / max(36, distanceSquared)
                let collision = distance < minimumDistance ? (minimumDistance - distance) * 0.022 : 0
                let force = repel + collision
                let fx = dx / distance * force
                let fy = dy / distance * force
                nodes[lhsIndex].vx -= fx
                nodes[lhsIndex].vy -= fy
                nodes[rhsIndex].vx += fx
                nodes[rhsIndex].vy += fy
            }
        }
    }

    private static func applyLinks(_ edges: [SimEdge], to nodes: inout [SimNode]) {
        for edge in edges {
            var dx = nodes[edge.targetIndex].x - nodes[edge.sourceIndex].x
            var dy = nodes[edge.targetIndex].y - nodes[edge.sourceIndex].y
            var distance = sqrt(dx * dx + dy * dy)
            if distance < 0.01 {
                let jitter = deterministicJitter(for: edge.sourceID + edge.targetID)
                dx = jitter.x
                dy = jitter.y
                distance = max(1, sqrt(dx * dx + dy * dy))
            }
            let targetDistance = linkDistance(for: edge)
            let strength = CGFloat(0.006 + edge.weight * 0.018)
            let force = (distance - targetDistance) * strength
            let fx = dx / distance * force
            let fy = dy / distance * force
            nodes[edge.sourceIndex].vx += fx
            nodes[edge.sourceIndex].vy += fy
            nodes[edge.targetIndex].vx -= fx
            nodes[edge.targetIndex].vy -= fy
        }
    }

    private static func applyCentering(to nodes: inout [SimNode]) {
        for index in nodes.indices {
            let strength: CGFloat = nodes[index].source.kind == "chunk" ? 0.0014 : 0.0024
            nodes[index].vx -= nodes[index].x * strength
            nodes[index].vy -= nodes[index].y * strength
        }
    }

    private static func integrate(_ nodes: inout [SimNode]) {
        for index in nodes.indices {
            nodes[index].vx = max(-12, min(12, nodes[index].vx * 0.84))
            nodes[index].vy = max(-12, min(12, nodes[index].vy * 0.84))
            nodes[index].x += nodes[index].vx
            nodes[index].y += nodes[index].vy
        }
    }

    private static func initialPosition(node: SemanticGraphNode, index: Int, count: Int) -> CGPoint {
        let phase = phase(for: node.kind)
        let angle = phase + (Double(index) / Double(max(1, count))) * Double.pi * 2
        let radius = initialRadius(for: node.kind) - min(38, CGFloat(node.weight) * 2.8)
        let jitter = deterministicJitter(for: node.nodeID)
        return CGPoint(
            x: cos(angle) * radius + jitter.x,
            y: sin(angle) * radius + jitter.y
        )
    }

    private static func layoutBounds(for nodes: [SemanticGraphLayoutNode]) -> CGRect {
        guard let first = nodes.first else { return .zero }
        var minX = first.position.x - first.baseRadius
        var maxX = first.position.x + first.baseRadius
        var minY = first.position.y - first.baseRadius
        var maxY = first.position.y + first.baseRadius
        for node in nodes.dropFirst() {
            minX = min(minX, node.position.x - node.baseRadius)
            maxX = max(maxX, node.position.x + node.baseRadius)
            minY = min(minY, node.position.y - node.baseRadius)
            maxY = max(maxY, node.position.y + node.baseRadius)
        }
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    private static func linkDistance(for edge: SimEdge) -> CGFloat {
        switch edge.kind {
        case "app-context":
            return 86
        case "entity":
            return 74
        case "semantic":
            return 118
        default:
            return 96
        }
    }

    private static func baseRadius(kind: String, weight: Double, degree: Int) -> CGFloat {
        let influence = CGFloat(min(7, sqrt(max(0, weight)) * 2.2 + Double(degree) * 0.18))
        switch kind {
        case "topic":
            return 8.5 + influence
        case "entity":
            return 9 + influence
        case "app":
            return 11 + influence
        default:
            return 4.8 + min(4.5, influence * 0.7)
        }
    }

    private static func initialRadius(for kind: String) -> CGFloat {
        switch kind {
        case "app": return 74
        case "entity": return 124
        case "topic": return 184
        default: return 238
        }
    }

    private static func phase(for kind: String) -> Double {
        switch kind {
        case "app": return 0.55
        case "entity": return 1.3
        case "topic": return -0.35
        default: return 2.1
        }
    }

    private static func kindRank(_ kind: String) -> Int {
        switch kind {
        case "app": return 0
        case "entity": return 1
        case "topic": return 2
        case "chunk": return 3
        default: return 4
        }
    }

    private static func deterministicJitter(for value: String) -> CGPoint {
        let hash = stableHash(for: value)
        let x = CGFloat(Int(hash % 41) - 20)
        let y = CGFloat(Int((hash / 41) % 41) - 20)
        return CGPoint(x: x * 0.75, y: y * 0.75)
    }

    private static func stableHash(for value: String) -> UInt64 {
        var hash: UInt64 = 5381
        for scalar in value.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ UInt64(scalar.value)
        }
        return hash
    }
}

private struct GraphInteractionOverlay: NSViewRepresentable {
    let layout: SemanticGraphLayout
    @Binding var viewport: GraphViewport
    @Binding var hoveredNodeID: String?
    @Binding var selectedNodeID: String?
    let onFit: () -> Void

    func makeNSView(context: Context) -> GraphInteractionNSView {
        let view = GraphInteractionNSView()
        view.onViewportChange = { viewport = $0 }
        view.onHoverChange = { hoveredNodeID = $0 }
        view.onSelect = { selectedNodeID = $0 }
        view.onFit = onFit
        return view
    }

    func updateNSView(_ nsView: GraphInteractionNSView, context: Context) {
        nsView.layout = layout
        nsView.viewport = viewport
        nsView.hoveredNodeID = hoveredNodeID
        nsView.selectedNodeID = selectedNodeID
        nsView.onFit = onFit
    }
}

private final class GraphInteractionNSView: NSView {
    var layout = SemanticGraphLayout.empty
    var viewport = GraphViewport()
    var hoveredNodeID: String?
    var selectedNodeID: String?
    var onViewportChange: (GraphViewport) -> Void = { _ in }
    var onHoverChange: (String?) -> Void = { _ in }
    var onSelect: (String?) -> Void = { _ in }
    var onFit: () -> Void = {}

    private var trackingAreaRef: NSTrackingArea?
    private var lastDragPoint: CGPoint?
    private var mouseDownPoint: CGPoint?
    private var didDrag = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredNodeID = nil
        onHoverChange(nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        lastDragPoint = point
        didDrag = false
        updateHover(at: point)
        if event.clickCount == 2 {
            if let nodeID = hitNode(at: point) {
                selectedNodeID = nodeID
                onSelect(nodeID)
                zoomTowardNode(id: nodeID, point: point)
            } else {
                onFit()
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let lastDragPoint else {
            self.lastDragPoint = point
            return
        }
        let delta = CGSize(width: point.x - lastDragPoint.x, height: point.y - lastDragPoint.y)
        if abs(delta.width) > 0.1 || abs(delta.height) > 0.1 {
            didDrag = true
            viewport.pan(by: delta)
            onViewportChange(viewport)
        }
        self.lastDragPoint = point
        updateHover(at: point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer {
            mouseDownPoint = nil
            lastDragPoint = nil
            didDrag = false
        }

        if didDrag {
            return
        }

        if let nodeID = hitNode(at: point) {
            selectedNodeID = nodeID
            onSelect(nodeID)
        } else {
            selectedNodeID = nil
            onSelect(nil)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let nodeID = hitNode(at: point) else {
            selectedNodeID = nil
            onSelect(nil)
            return
        }
        selectedNodeID = nodeID
        onSelect(nodeID)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let horizontal = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX * 8
        let vertical = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 8

        if abs(horizontal) > abs(vertical) * 1.4 {
            viewport.pan(by: CGSize(width: horizontal, height: 0))
        } else {
            let factor = exp(vertical * 0.006)
            viewport.zoom(by: factor, around: point, in: bounds.size)
        }
        onViewportChange(viewport)
        updateHover(at: point)
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        viewport.zoom(by: max(0.2, 1 + event.magnification), around: point, in: bounds.size)
        onViewportChange(viewport)
        updateHover(at: point)
    }

    override func keyDown(with event: NSEvent) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        switch event.keyCode {
        case 24, 69:
            viewport.zoom(by: 1.18, around: center, in: bounds.size)
            onViewportChange(viewport)
        case 27, 78:
            viewport.zoom(by: 0.84, around: center, in: bounds.size)
            onViewportChange(viewport)
        case 29, 82:
            onFit()
        case 53:
            selectedNodeID = nil
            onSelect(nil)
        case 123, 124, 125, 126:
            let distance: CGFloat = event.modifierFlags.contains(.shift) ? 72 : 28
            switch event.keyCode {
            case 123:
                viewport.pan(by: CGSize(width: distance, height: 0))
            case 124:
                viewport.pan(by: CGSize(width: -distance, height: 0))
            case 125:
                viewport.pan(by: CGSize(width: 0, height: -distance))
            default:
                viewport.pan(by: CGSize(width: 0, height: distance))
            }
            onViewportChange(viewport)
        default:
            super.keyDown(with: event)
        }
    }

    private func updateHover(at point: CGPoint) {
        let nextID = hitNode(at: point)
        guard nextID != hoveredNodeID else { return }
        hoveredNodeID = nextID
        onHoverChange(nextID)
    }

    private func hitNode(at point: CGPoint) -> String? {
        guard !layout.nodes.isEmpty else { return nil }
        var best: (id: String, distance: CGFloat)?
        for node in layout.nodes {
            let screenPoint = viewport.project(node.position, in: bounds.size)
            let radius = max(7, min(node.baseRadius * pow(viewport.scale, 0.58), node.baseRadius * 1.8) + 4)
            let distance = hypot(point.x - screenPoint.x, point.y - screenPoint.y)
            guard distance <= radius else { continue }
            if best == nil || distance < best!.distance {
                best = (node.id, distance)
            }
        }
        return best?.id
    }

    private func zoomTowardNode(id: String, point: CGPoint) {
        guard layout.node(id: id) != nil else { return }
        viewport.zoom(by: 1.55, around: point, in: bounds.size)
        onViewportChange(viewport)
    }
}
