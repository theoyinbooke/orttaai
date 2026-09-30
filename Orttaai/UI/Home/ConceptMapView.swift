// ConceptMapView.swift
// Orttaai

import SwiftUI

/// The Map tab: the people, projects, and topics in your dictation, how they
/// connect, and what stands out. Click a concept to see what you actually
/// said about it.
struct ConceptMapView: View {
    private enum KindFilter: String, CaseIterable, Identifiable {
        case all, people, names, topics
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .people: return "People"
            case .names: return "Projects and names"
            case .topics: return "Topics"
            }
        }
        func includes(_ kind: ConceptKind) -> Bool {
            switch self {
            case .all: return true
            case .people: return kind == .person
            case .names: return kind == .product || kind == .organization || kind == .place
            case .topics: return kind == .topic
            }
        }
    }

    @State private var range: ConceptTimeRange = .quarter
    @State private var kindFilter: KindFilter = .all
    @State private var graph: ConceptGraph?
    @State private var extraction: (done: Int, total: Int)?
    @State private var loadError: String?
    @State private var selectedID: String?
    @State private var focusedThemeID: String?
    @State private var mentions: [ConceptMention] = []
    @State private var brief: String?
    @State private var briefError: String?
    @State private var isWritingBrief = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            controls

            if let loadError {
                SettingsNotice(kind: .error, message: loadError)
            } else if let graph, !graph.nodes.isEmpty {
                if !graph.highlights.isEmpty {
                    highlights(graph)
                }
                mapCard(graph)
            } else if graph == nil {
                progressCard
            } else {
                SettingsCard {
                    SettingsFootnote("Not enough dictation in this range to map yet. Pick a longer range.")
                        .padding(.vertical, Spacing.xs)
                }
            }
        }
        .task(id: range) { await load() }
        .onChange(of: selectedID) { _, _ in loadSelection() }
    }

    private func load() async {
        do {
            let next = try await ConceptGraphStore.shared.graph(range: range) { done, total in
                extraction = total > 40 ? (done, total) : nil
            }
            graph = next
            extraction = nil
            loadError = nil
            if let selectedID, next.node(id: selectedID) == nil {
                self.selectedID = nil
            }
        } catch {
            loadError = "Couldn't build the map: \(error.localizedDescription)"
        }
    }

    private func loadSelection() {
        brief = nil
        briefError = nil
        guard let selectedID, let node = graph?.node(id: selectedID) else {
            mentions = []
            return
        }
        mentions = ConceptGraphStore.shared.mentions(of: node, limit: 4)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: Spacing.md) {
            OrttaaiSegmentedControl(
                title: "Time range",
                selection: $range,
                options: ConceptTimeRange.allCases.map { .init($0, $0.title) }
            )
            OrttaaiSegmentedControl(
                title: "Show",
                selection: $kindFilter,
                options: KindFilter.allCases.map { .init($0, $0.title) }
            )
            Spacer(minLength: Spacing.sm)
            if let graph, !graph.nodes.isEmpty {
                Text("\(visibleNodes(graph).count) concepts from \(graph.dictationCount) dictations")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
        }
    }

    // MARK: - Highlights

    /// One row; every card stretches to the tallest so the row reads evenly.
    private func highlights(_ graph: ConceptGraph) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            ForEach(graph.highlights) { highlight in
                Button {
                    focusedThemeID = nil
                    selectedID = highlight.conceptIDs.first
                } label: {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Label(highlight.title, systemImage: symbol(for: highlight.kind))
                            .font(.Orttaai.secondary.weight(.semibold))
                            .foregroundStyle(Color.Orttaai.textPrimary)
                            .lineLimit(2)
                        Text(highlight.detail)
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .dashboardCard()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show on the map")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func symbol(for kind: ConceptHighlightKind) -> String {
        switch kind {
        case .rising: return "arrow.up.right"
        case .new: return "sparkle.magnifyingglass"
        case .pair: return "link"
        case .person: return "person"
        case .fading: return "moon.zzz"
        case .focus: return "app.badge"
        }
    }

    // MARK: - Map

    private func visibleNodes(_ graph: ConceptGraph) -> [ConceptNode] {
        graph.nodes.filter { kindFilter.includes($0.kind) }
    }

    private func canvasModel(_ graph: ConceptGraph) -> GraphCanvasModel {
        let nodes = visibleNodes(graph)
        let ids = Set(nodes.map(\.id))
        let maxSalience = nodes.map(\.salience).max() ?? 1
        return GraphCanvasModel(
            nodes: nodes.map { node in
                GraphCanvasNode(
                    id: node.id,
                    title: node.title,
                    color: themeColor(node.themeID, in: graph),
                    size: sqrt(node.salience / max(0.0001, maxSalience)),
                    group: node.themeID
                )
            },
            edges: graph.edges
                .filter { ids.contains($0.sourceID) && ids.contains($0.targetID) }
                .map { GraphCanvasEdge(sourceID: $0.sourceID, targetID: $0.targetID, strength: $0.strength) }
        )
    }

    private func mapCard(_ graph: ConceptGraph) -> some View {
        HStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                ConceptGraphCanvas(
                    model: canvasModel(graph),
                    selectedNodeID: $selectedID,
                    highlightedIDs: Set(graph.themes.first { $0.id == focusedThemeID }?.conceptIDs ?? [])
                )
                Text("Color is theme · size is how often it comes up")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 4)
                    .background(Color.Orttaai.bgSecondary.opacity(0.85))
                    .clipShape(Capsule())
                    .padding(Spacing.sm)
            }
            .frame(minHeight: 460)

            Divider()
                .overlay(Color.Orttaai.border)

            ScrollView(showsIndicators: false) {
                Group {
                    if let selectedID, let node = graph.node(id: selectedID) {
                        conceptDetail(node, graph: graph)
                    } else {
                        themeList(graph)
                    }
                }
                .padding(Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 290)
        }
        .frame(height: 480)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .fill(Color.Orttaai.bgSecondary)
        )
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .stroke(Color.Orttaai.border, lineWidth: BorderWidth.standard)
        )
    }

    // MARK: - Side panel

    private func themeList(_ graph: ConceptGraph) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SettingsLabel(
                title: "Themes",
                info: "Groups of concepts that come up in the same working sessions more than chance would suggest.",
                font: .Orttaai.subheading
            )
            if graph.themes.isEmpty {
                SettingsFootnote("No clear themes in this range yet.")
            }
            ForEach(graph.themes.prefix(10)) { theme in
                Button {
                    focusedThemeID = focusedThemeID == theme.id ? nil : theme.id
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Spacing.xs) {
                            Circle()
                                .fill(themeColor(theme.id, in: graph))
                                .frame(width: 8, height: 8)
                                .accessibilityHidden(true)
                            Text(theme.title)
                                .font(.Orttaai.secondary.weight(.semibold))
                                .foregroundStyle(Color.Orttaai.textPrimary)
                        }
                        Text(theme.conceptIDs.prefix(5).compactMap { graph.node(id: $0)?.title }.joined(separator: ", "))
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                            .lineLimit(2)
                    }
                    .padding(Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                            .fill(focusedThemeID == theme.id ? Color.Orttaai.accentSubtle : Color.Orttaai.bgPrimary.opacity(0.35))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(focusedThemeID == theme.id ? [.isSelected] : [])
            }
            SettingsFootnote("Click a concept on the map to see what you said about it.")
                .padding(.top, Spacing.xs)
        }
    }

    private func conceptDetail(_ node: ConceptNode, graph: ConceptGraph) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.xs) {
                Circle().fill(Self.color(for: node.kind)).frame(width: 8, height: 8)
                Text(node.kind.displayName)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                if let trend = node.trend.label {
                    Text(trend)
                        .font(.Orttaai.caption.weight(.semibold))
                        .foregroundStyle(node.trend == .fading ? Color.Orttaai.textTertiary : Color.Orttaai.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.Orttaai.accentSubtle)
                        .clipShape(Capsule())
                }
                Spacer()
                Button {
                    selectedID = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to themes")
                .accessibilityLabel("Close")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(node.title)
                    .font(.Orttaai.heading)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Text("\(node.mentionCount) dictations on \(node.dayCount) day\(node.dayCount == 1 ? "" : "s") · since \(node.firstSeen.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                Text("Last came up \(node.lastSeen.formatted(.relative(presentation: .named)))")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
            }

            if !node.apps.isEmpty {
                detailSection("Where it comes up") {
                    Text(node.apps.prefix(3).map { "\($0.appName) \(Int(($0.share * 100).rounded()))%" }.joined(separator: " · "))
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }
            }

            let related = graph.related(to: node.id)
            if !related.isEmpty {
                detailSection("Comes up with") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(related.prefix(6), id: \.node.id) { item in
                            Button {
                                selectedID = item.node.id
                            } label: {
                                HStack(spacing: Spacing.xs) {
                                    Circle().fill(Self.color(for: item.node.kind)).frame(width: 6, height: 6)
                                    Text(item.node.title)
                                        .font(.Orttaai.caption)
                                        .foregroundStyle(Color.Orttaai.textPrimary)
                                    Spacer(minLength: Spacing.xs)
                                    Text("\(item.edge.sharedSessions)×")
                                        .font(.Orttaai.caption.monospacedDigit())
                                        .foregroundStyle(Color.Orttaai.textTertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("In the same working session \(item.edge.sharedSessions) times")
                        }
                    }
                }
            }

            if !mentions.isEmpty {
                detailSection("What you said") {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        ForEach(mentions) { mention in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mention.excerpt)
                                    .font(.Orttaai.caption)
                                    .foregroundStyle(Color.Orttaai.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                Text([mention.date.formatted(.dateTime.month(.abbreviated).day()), mention.appName].compactMap { $0 }.joined(separator: " · "))
                                    .font(.Orttaai.caption)
                                    .foregroundStyle(Color.Orttaai.textTertiary)
                            }
                        }
                    }
                }
            }

            detailSection("Summary") {
                if let brief {
                    Text(brief)
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Button {
                            writeBrief(for: node, graph: graph)
                        } label: {
                            Label(isWritingBrief ? "Summarizing…" : "Summarize with local AI", systemImage: "text.alignleft")
                        }
                        .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
                        .disabled(isWritingBrief)
                        .help("A local model reads your recent mentions and says what this is to you. Nothing leaves your Mac.")
                        if let briefError {
                            Text(briefError)
                                .font(.Orttaai.caption)
                                .foregroundStyle(Color.Orttaai.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.Orttaai.textTertiary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func writeBrief(for node: ConceptNode, graph: ConceptGraph) {
        isWritingBrief = true
        briefError = nil
        let related = graph.related(to: node.id).map(\.node.title)
        let mentions = ConceptGraphStore.shared.mentions(of: node, limit: 8)
        let local = ConceptBriefWriter.localModel(settings: AppSettings())
        Task {
            do {
                let text = try await ConceptBriefWriter.brief(for: node, related: related, mentions: mentions, using: local)
                if selectedID == node.id { brief = text }
            } catch {
                briefError = error.localizedDescription
            }
            isWritingBrief = false
        }
    }

    // MARK: - States

    private var progressCard: some View {
        SettingsCard {
            HStack(spacing: Spacing.sm) {
                if let extraction {
                    ProgressView(value: Double(extraction.done), total: Double(max(1, extraction.total)))
                        .tint(Color.Orttaai.accent)
                        .frame(width: 140)
                    Text("Reading your dictations for the first time · \(extraction.done) of \(extraction.total)")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                    Text("Building your map…")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }
            }
            .padding(.vertical, Spacing.sm)
        }
    }

    /// Themes get distinct colors in rank order; unthemed concepts stay grey.
    private func themeColor(_ themeID: String?, in graph: ConceptGraph) -> Color {
        guard let themeID, let index = graph.themes.firstIndex(where: { $0.id == themeID }) else {
            return Color.Orttaai.textTertiary
        }
        let palette: [Color] = [Color.Orttaai.accent, .purple, .teal, .pink, .blue, .green, .indigo, .mint, .red, .yellow]
        return palette[index % palette.count]
    }

    static func color(for kind: ConceptKind) -> Color {
        switch kind {
        case .person: return .green
        case .organization: return .teal
        case .place: return .pink
        case .product: return Color.Orttaai.accent
        case .topic: return .purple
        }
    }
}
