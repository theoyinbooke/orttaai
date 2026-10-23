// HomeInsightsPanel.swift
// Orttaai

import SwiftUI

struct HomeInsightsPanel: View {
    let snapshot: WritingInsightSnapshot?
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
                // The insight comes first; options and history follow it.
                VStack(alignment: .leading, spacing: Spacing.md) {
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

                    if let freshness {
                        freshnessSection(freshness)
                    }

                    if !historyItems.isEmpty {
                        historySection
                    }

                    if let comparison {
                        comparisonSection(comparison)
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

    private var panelHeader: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            Text("Insights")
                .font(.Orttaai.subheading)
                .foregroundStyle(Color.Orttaai.textPrimary)

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
        DisclosureGroup {
            filterControls
                .padding(.top, Spacing.sm)
        } label: {
            HStack(spacing: Spacing.xs) {
                Text("Options")
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Text("\(request.timeRange.title) · \(request.generationMode.title) · \(request.appFilterMode.title)")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .lineLimit(1)
            }
        }
        .tint(Color.Orttaai.textSecondary)
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

    private func freshnessSection(_ freshness: WritingInsightFreshness) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .center, spacing: Spacing.sm) {
                Text("Freshness")
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Spacer()

                Text(freshness.status.title)
                    .font(.Orttaai.caption)
                    .foregroundStyle(freshnessStatusTint(freshness.status))
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 4)
                    .background(freshnessStatusBackground(freshness.status))
                    .clipShape(Capsule())
            }

            if let latestSessionAt = freshness.latestSessionAt {
                Text("Latest dictation: \(Self.timestampFormatter.string(from: latestSessionAt))")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
            }

            if freshness.newSessionCount > 0 {
                Button("Refresh with new sessions", action: onGenerate)
                    .buttonStyle(OrttaaiButtonStyle(.secondary))
                    .disabled(isGenerating)
            }
        }
        .padding(Spacing.md)
        .dashboardCard()
    }

    private func freshnessStatusTint(_ status: WritingInsightFreshnessStatus) -> Color {
        switch status {
        case .fresh:
            return Color.Orttaai.success
        case .aging:
            return Color.Orttaai.warning
        case .stale:
            return Color.Orttaai.error
        }
    }

    private func freshnessStatusBackground(_ status: WritingInsightFreshnessStatus) -> Color {
        switch status {
        case .fresh:
            return Color.Orttaai.successSubtle
        case .aging:
            return Color.Orttaai.warningSubtle
        case .stale:
            return Color.Orttaai.errorSubtle
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Recent runs")
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)

            ForEach(Array(historyItems.prefix(8))) { item in
                historyRow(item)
            }
        }
        .padding(Spacing.md)
        .dashboardCard()
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
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.xs) {
                infoPill(snapshot.analyzerName)
                infoPill("\(snapshot.sampleCount) sessions")
                if snapshot.usedFallback {
                    infoPill("Fallback")
                }
                Spacer(minLength: 0)
                Text(isPreliminary ? "AI analysis running" : snapshot.generatedAt.formatted(.relative(presentation: .named)))
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .lineLimit(1)
                    .help(Self.timestampFormatter.string(from: snapshot.generatedAt))
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Summary")
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Text(snapshot.summary)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }
            .padding(Spacing.md)
            .dashboardCard()

            if !snapshot.signals.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Signals")
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.textPrimary)

                    ForEach(snapshot.signals) { signal in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(signal.label)
                                    .font(.Orttaai.caption)
                                    .foregroundStyle(Color.Orttaai.textTertiary)
                                Text(signal.value)
                                    .font(.Orttaai.bodyMedium)
                                    .foregroundStyle(Color.Orttaai.textPrimary)
                            }
                            Spacer()
                            Text(signal.detail)
                                .font(.Orttaai.caption)
                                .foregroundStyle(Color.Orttaai.textTertiary)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
                        .background(Color.Orttaai.bgPrimary.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input))
                    }
                }
                .padding(Spacing.md)
                .dashboardCard()
            }

            if !snapshot.patterns.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Patterns")
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.textPrimary)

                    ForEach(snapshot.patterns) { pattern in
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(pattern.title)
                                .font(.Orttaai.secondary)
                                .foregroundStyle(Color.Orttaai.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(pattern.detail)
                                .font(.Orttaai.secondary)
                                .foregroundStyle(Color.Orttaai.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let evidence = pattern.evidence {
                                Text(evidence)
                                    .font(.Orttaai.caption)
                                    .foregroundStyle(Color.Orttaai.textTertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.Orttaai.bgPrimary.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.md)
                .dashboardCard()
            }

            if !snapshot.strengths.isEmpty {
                bulletSection(title: "Strengths", items: snapshot.strengths)
            }

            if !snapshot.opportunities.isEmpty {
                bulletSection(title: "Opportunities", items: snapshot.opportunities)
            }
        }
    }

    private func bulletSection(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)

            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: Spacing.xs) {
                    Text("•")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                    Text(item)
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(Spacing.md)
        .dashboardCard()
    }

    private func infoPill(_ value: String) -> some View {
        Text(value)
            .font(.Orttaai.caption)
            .foregroundStyle(Color.Orttaai.textTertiary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 4)
            .background(Color.Orttaai.bgTertiary.opacity(0.5))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.Orttaai.border.opacity(0.6), lineWidth: BorderWidth.standard)
            )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("No insights yet")
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
