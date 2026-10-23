// HomeInsightsPanel.swift
// Orttaai

import SwiftUI

/// The Overview's Insights panel: a ticker of the numbers behind the
/// insight, the summary, a few patterns and takeaways, and options folded
/// away, sized to read on one screen.
struct HomeInsightsPanel: View {
    let snapshot: WritingInsightSnapshot?
    /// Counted from your dictation for the ticker (dictations, words, WPM…).
    var stats: [InsightStat] = []
    let request: WritingInsightsRequest
    let availableApps: [String]
    let historyItems: [WritingInsightHistoryItem]
    let selectedHistoryID: Int64?
    let compareItemIDs: [Int64]
    let comparison: WritingInsightsComparison?
    let freshness: WritingInsightFreshness?
    let isGenerating: Bool
    /// When the running analysis started; drives the progress lines.
    var generationStartedAt: Date?
    /// The snapshot is the instant quick look, not yet the AI analysis.
    var isPreliminary = false
    let errorMessage: String?
    let statusMessage: String?
    let onGenerate: () -> Void
    let onTimeRangeChange: (WritingInsightsTimeRange) -> Void
    let onGenerationModeChange: (WritingInsightsGenerationMode) -> Void
    let onAppFilterModeChange: (WritingInsightsAppFilterMode) -> Void
    let onToggleAppSelection: (String) -> Void
    let onClearAppSelection: () -> Void
    let onLoadSnapshot: (WritingInsightHistoryItem) -> Void
    let onTogglePinHistory: (WritingInsightHistoryItem) -> Void
    let onDeleteHistoryItem: (WritingInsightHistoryItem) -> Void
    let onToggleCompareItem: (WritingInsightHistoryItem) -> Void
    let onClearComparison: () -> Void
    let onClose: () -> Void
    @State private var isAboutPresented = false
    @State private var isOptionsExpanded = false
    @State private var isHistoryExpanded = false

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.sm)

            Divider()
                .background(Color.Orttaai.border)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    if !tickerStats.isEmpty {
                        InsightStatTicker(stats: tickerStats, isScanning: isGenerating)
                    }

                    if isGenerating {
                        progressRow
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.Orttaai.secondary)
                            .foregroundStyle(Color.Orttaai.error)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.sm)
                            .background(Color.Orttaai.errorSubtle)
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
                    }

                    if let snapshot {
                        snapshotBody(snapshot)
                    } else if !isGenerating {
                        emptyState
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                    }

                    optionsSection
                        .padding(.top, Spacing.xs)

                    if !historyItems.isEmpty {
                        historyDisclosure
                    }
                }
                .padding(Spacing.md)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.Orttaai.bgSecondary.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .stroke(Color.Orttaai.border, lineWidth: BorderWidth.standard)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Writing insights panel")
    }

    /// The counted statistics, plus any number the model counted itself.
    private var tickerStats: [InsightStat] {
        let fromModel = (snapshot?.signals ?? []).compactMap { signal -> InsightStat? in
            let label = signal.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty,
                  !stats.contains(where: { $0.label.localizedCaseInsensitiveContains(label) }) else { return nil }
            let cleaned = signal.value.replacingOccurrences(of: ",", with: "")
            if let number = Double(cleaned) {
                return InsightStat(id: "signal-\(label)", icon: "number", number: number, label: label.lowercased())
            }
            return InsightStat(id: "signal-\(label)", icon: "number", text: signal.value, label: label.lowercased())
        }
        return Array((stats + fromModel).prefix(6))
    }

    private var panelHeader: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Insights")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                if let snapshot {
                    aboutButton(snapshot)
                }
            }

            Spacer()

            Button(action: onGenerate) {
                Label(snapshot == nil ? "Generate" : "Regenerate", systemImage: "arrow.clockwise")
                    .font(.Orttaai.caption)
            }
            .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
            .disabled(isGenerating)
            .help("Analyze your dictation history again")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(Color.Orttaai.bgPrimary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Close insights panel")
        }
    }

    /// The beating mark and what the analysis is doing, moving on as the
    /// wait grows.
    private var progressRow: some View {
        HStack(spacing: Spacing.sm) {
            ChatAIWaitingMark(size: 15)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(generationStartedAt ?? context.date)
                Text(Self.progressLine(elapsed: elapsed, sampleCount: snapshot?.sampleCount))
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .lineLimit(1)
                    .id(Self.progressLine(elapsed: elapsed, sampleCount: snapshot?.sampleCount))
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
                    .animation(.easeInOut(duration: 0.28), value: Self.progressLine(elapsed: elapsed, sampleCount: snapshot?.sampleCount))
            }
            Spacer(minLength: 0)
        }
        .clipped()
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.Orttaai.bgPrimary.opacity(0.45), in: RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    static func progressLine(elapsed: TimeInterval, sampleCount: Int?) -> String {
        switch elapsed {
        case ..<3:
            return sampleCount.map { "Reading your last \($0.formatted()) dictations" } ?? "Reading your recent dictations"
        case ..<10: return "Finding patterns in how you write"
        case ..<25: return "Writing your summary"
        case ..<60: return "Still working. Larger models take a little longer"
        default: return "Almost there"
        }
    }

    /// Range, depth and app filters, folded away until wanted.
    private var optionsSection: some View {
        CollapsibleRow(
            title: "Options",
            detail: "\(request.timeRange.title) · \(request.generationMode.title) · \(request.appFilterMode.title)",
            isExpanded: $isOptionsExpanded
        ) {
            filterControls
        }
    }

    private var filterControls: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                controlPickerCard(title: "Range") {
                    OrttaaiDropdown(
                        selection: Binding(
                            get: { request.timeRange },
                            set: { onTimeRangeChange($0) }
                        ),
                        options: WritingInsightsTimeRange.allCases.map { .init($0, $0.title) }
                    )
                }

                controlPickerCard(title: "Mode") {
                    OrttaaiDropdown(
                        selection: Binding(
                            get: { request.generationMode },
                            set: { onGenerationModeChange($0) }
                        ),
                        options: WritingInsightsGenerationMode.allCases.map { .init($0, $0.title) }
                    )
                }

                controlPickerCard(title: "Apps") {
                    OrttaaiDropdown(
                        selection: Binding(
                            get: { request.appFilterMode },
                            set: { onAppFilterModeChange($0) }
                        ),
                        options: WritingInsightsAppFilterMode.allCases.map { .init($0, $0.title) }
                    )
                }
            }

            if request.appFilterMode != .allApps {
                appSelectionSection
            }
        }
        .padding(Spacing.md)
        .dashboardCard()
    }

    private func controlPickerCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appSelectionSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Menu {
                    if availableApps.isEmpty {
                        Text("No recent apps")
                    } else {
                        ForEach(availableApps, id: \.self) { app in
                            Button {
                                onToggleAppSelection(app)
                            } label: {
                                if request.selectedApps.contains(app) {
                                    Label(app, systemImage: "checkmark")
                                } else {
                                    Text(app)
                                }
                            }
                        }
                    }
                } label: {
                    Label(
                        request.selectedApps.isEmpty ? "Select apps" : "Apps (\(request.selectedApps.count))",
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                    .font(.Orttaai.secondary)
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary))

                if !request.selectedApps.isEmpty {
                    Button("Clear", action: onClearAppSelection)
                        .buttonStyle(OrttaaiButtonStyle(.secondary, destructive: true))
                }
            }

            if !request.selectedApps.isEmpty {
                Text(request.selectedApps.joined(separator: ", "))
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
            }
        }
    }

    /// The model that wrote it, with an info icon in front; clicking shows
    /// when it ran, what it read, and whether there's newer dictation.
    private func aboutButton(_ snapshot: WritingInsightSnapshot) -> some View {
        Button {
            isAboutPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10, weight: .semibold))
                Text(Self.analyzerDisplayName(snapshot.analyzerName))
                    .lineLimit(1)
                if (freshness?.newSessionCount ?? 0) > 0, !isPreliminary {
                    Circle()
                        .fill(Color.Orttaai.warning)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel("Newer dictation since this ran")
                }
            }
            .font(.Orttaai.caption)
            .foregroundStyle(Color.Orttaai.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("About this insight")
        .popover(isPresented: $isAboutPresented, arrowEdge: .bottom) {
            aboutCard(snapshot)
        }
    }

    private func aboutCard(_ snapshot: WritingInsightSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("About this insight")
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
            aboutRow("cpu", "Analysed by \(Self.analyzerDisplayName(snapshot.analyzerName))")
            aboutRow(
                "clock",
                isPreliminary
                    ? "Quick look now; the AI analysis is running"
                    : "Ran \(snapshot.generatedAt.formatted(.relative(presentation: .named))), \(Self.timestampFormatter.string(from: snapshot.generatedAt))"
            )
            aboutRow("doc.text.magnifyingglass", "Read \(snapshot.sampleCount == 1 ? "1 dictation" : "\(snapshot.sampleCount.formatted()) dictations")")
            aboutRow("slider.horizontal.3", "\(request.timeRange.title) · \(request.generationMode.title) · \(request.appFilterMode.title)")
            if let freshness, !isPreliminary {
                if freshness.newSessionCount > 0 {
                    aboutRow(
                        "plus.circle",
                        "\(freshness.newSessionCount) new \(freshness.newSessionCount == 1 ? "dictation" : "dictations") since. Regenerate to include them.",
                        tint: Color.Orttaai.warning
                    )
                } else {
                    aboutRow("checkmark.circle", "Up to date with your dictation", tint: Color.Orttaai.success)
                }
            }
        }
        .padding(Spacing.md)
        .frame(width: 280, alignment: .leading)
        .presentationBackground(Color.Orttaai.bgSecondary)
    }

    private func aboutRow(_ icon: String, _ text: String, tint: Color = Color.Orttaai.textSecondary) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(text)
                .font(.Orttaai.caption)
                .foregroundStyle(tint == Color.Orttaai.textSecondary ? Color.Orttaai.textSecondary : tint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Apple Foundation Models" is Apple Intelligence to the person using it.
    static func analyzerDisplayName(_ name: String) -> String {
        name.replacingOccurrences(of: "Apple Foundation Models", with: "Apple Intelligence")
    }

    /// Earlier runs and comparison, folded away.
    private var historyDisclosure: some View {
        CollapsibleRow(
            title: "Recent runs",
            detail: "\(historyItems.count)",
            isExpanded: $isHistoryExpanded
        ) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(Array(historyItems.prefix(8))) { item in
                    historyRow(item)
                }
                if let comparison {
                    comparisonSection(comparison)
                }
            }
        }
    }

    private func historyRow(_ item: WritingInsightHistoryItem) -> some View {
        let isSelected = selectedHistoryID == item.id
        let compareIndex = compareItemIDs.firstIndex(of: item.id)

        return HStack(alignment: .center, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text(Self.timestampFormatter.string(from: item.snapshot.generatedAt))
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                        .lineLimit(1)

                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.Orttaai.accent)
                    }

                    if let compareIndex {
                        comparePill(compareIndex == 0 ? "A" : "B")
                    }
                }

                Text("\(item.snapshot.sampleCount) sessions • \(item.snapshot.analyzerName)")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.sm)

            Button(isSelected ? "Loaded" : "Load") {
                onLoadSnapshot(item)
            }
            .buttonStyle(OrttaaiButtonStyle(.secondary))
            .disabled(isSelected)

            Menu {
                Button(item.isPinned ? "Unpin" : "Pin") {
                    onTogglePinHistory(item)
                }

                Button(compareIndex == nil ? "Add to Compare" : "Remove from Compare") {
                    onToggleCompareItem(item)
                }

                Button(role: .destructive) {
                    onDeleteHistoryItem(item)
                } label: {
                    Text("Delete")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.Orttaai.bgPrimary.opacity(0.4))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                .stroke(
                    isSelected ? Color.Orttaai.accent.opacity(0.45) : Color.Orttaai.border.opacity(0.35),
                    lineWidth: BorderWidth.standard
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))
    }

    private func comparePill(_ text: String) -> some View {
        Text(text)
            .font(.Orttaai.caption)
            .foregroundStyle(Color.Orttaai.accent)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 2)
            .background(Color.Orttaai.accentSubtle)
            .clipShape(Capsule())
    }

    private func comparisonSection(_ comparison: WritingInsightsComparison) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .center, spacing: Spacing.sm) {
                Text("Comparison")
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Spacer()

                Button("Clear", action: onClearComparison)
                    .buttonStyle(OrttaaiButtonStyle(.secondary, destructive: true))
            }

            Text(comparison.headline)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)

            ForEach(comparison.bullets, id: \.self) { bullet in
                HStack(alignment: .top, spacing: Spacing.xs) {
                    Text("•")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                    Text(bullet)
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(Spacing.md)
        .dashboardCard()
    }

    private func snapshotBody(_ snapshot: WritingInsightSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Summary", systemImage: "text.quote")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.accent)
                Text(snapshot.summary)
                    .font(.Orttaai.body)
                    .foregroundStyle(Color.Orttaai.textPrimary.opacity(0.92))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dashboardCard()

            if !snapshot.patterns.isEmpty {
                card(title: "Patterns", icon: "point.3.connected.trianglepath.dotted") {
                    ForEach(Array(snapshot.patterns.prefix(3))) { pattern in
                        HStack(alignment: .top, spacing: Spacing.sm) {
                            Circle()
                                .fill(Color.Orttaai.accent)
                                .frame(width: 5, height: 5)
                                .padding(.top, 6)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(pattern.title.prefix(1).uppercased() + pattern.title.dropFirst())
                                    .font(.Orttaai.secondary.weight(.semibold))
                                    .foregroundStyle(Color.Orttaai.textPrimary)
                                    .lineLimit(1)
                                Text(pattern.detail)
                                    .font(.Orttaai.caption)
                                    .foregroundStyle(Color.Orttaai.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                        .help(pattern.evidence.map { "\(pattern.detail)\n\n\($0)" } ?? pattern.detail)
                    }
                }
            }

            if !snapshot.strengths.isEmpty || !snapshot.opportunities.isEmpty {
                card(title: "Takeaways", icon: "lightbulb") {
                    ForEach(Array(snapshot.strengths.prefix(3)), id: \.self) { item in
                        takeaway(item, icon: "checkmark.circle.fill", tint: Color.Orttaai.success, kind: "Keep doing")
                    }
                    ForEach(Array(snapshot.opportunities.prefix(3)), id: \.self) { item in
                        takeaway(item, icon: "arrow.up.right.circle.fill", tint: Color.Orttaai.accent, kind: "Try next")
                    }
                }
            }
        }
    }

    private func card<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label(title, systemImage: icon)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
            content()
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    private func takeaway(_ text: String, icon: String, tint: Color, kind: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .lineLimit(2)
                .help("\(kind): \(text)")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind): \(text)")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label("No insights yet", systemImage: "brain")
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
            Text("Generate an analysis of how you write, from your dictation history.")
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
        }
        .padding(Spacing.md)
        .dashboardCard()
    }
}

/// A folding section whose whole header row opens and closes it, not just
/// the chevron.
private struct CollapsibleRow<Content: View>: View {
    let title: String
    let detail: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                    Text(title)
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                    Text(detail)
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                        .fill(isHovered ? Color.Orttaai.bgTertiary.opacity(0.5) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
