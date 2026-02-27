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
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.lg)
                .padding(.bottom, Spacing.sm)

            Divider()
                .background(Color.Orttaai.border)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    controlRow
                    filterControls
                    if let freshness {
                        freshnessSection(freshness)
                    }

                    if !historyItems.isEmpty {
                        historySection
                    }

                    if let comparison {
                        comparisonSection(comparison)
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

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                    }

                    if isGenerating {
                        HStack(spacing: Spacing.sm) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Generating writing insights...")
                                .font(.Orttaai.secondary)
                                .foregroundStyle(Color.Orttaai.textSecondary)
                        }
                        .padding(Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .dashboardCard()
                    }

                    if let snapshot {
                        snapshotBody(snapshot)
                    } else if !isGenerating {
                        emptyState
                    }
                }
                .padding(Spacing.lg)
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
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Insights")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Text("Understand your writing patterns and opportunities.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }

            Spacer()

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

    private var controlRow: some View {
        HStack(spacing: Spacing.sm) {
            if isGenerating {
                HStack(spacing: Spacing.xs) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating...")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(Color.Orttaai.bgPrimary.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous)
                        .stroke(Color.Orttaai.border.opacity(0.5), lineWidth: BorderWidth.standard)
                )
            } else {
                Button(action: onGenerate) {
                    Label(snapshot == nil ? "Generate" : "Regenerate", systemImage: "sparkles")
                        .font(.Orttaai.secondary)
                }
                .buttonStyle(OrttaaiButtonStyle(.primary))
            }

            if let snapshot {
                Text(Self.timestampFormatter.string(from: snapshot.generatedAt))
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private var filterControls: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Filters")
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)

            HStack(alignment: .top, spacing: Spacing.sm) {
                controlPickerCard(title: "Range") {
                    Picker("Range", selection: Binding(
                        get: { request.timeRange },
                        set: { onTimeRangeChange($0) }
                    )) {
                        ForEach(WritingInsightsTimeRange.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                controlPickerCard(title: "Mode") {
                    Picker("Mode", selection: Binding(
                        get: { request.generationMode },
                        set: { onGenerationModeChange($0) }
                    )) {
                        ForEach(WritingInsightsGenerationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                controlPickerCard(title: "Apps") {
                    Picker("Apps", selection: Binding(
                        get: { request.appFilterMode },
                        set: { onAppFilterModeChange($0) }
                    )) {
                        ForEach(WritingInsightsAppFilterMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
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

            Text(freshnessSummaryText(freshness))
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)

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

    private func freshnessSummaryText(_ freshness: WritingInsightFreshness) -> String {
        if freshness.newSessionCount == 0 {
            return "This insight includes your latest dictation history."
        }

        let sessionLabel = freshness.newSessionCount == 1 ? "session" : "sessions"
        switch freshness.status {
        case .fresh:
            return "\(freshness.newSessionCount) new \(sessionLabel) since this snapshot."
        case .aging:
            return "\(freshness.newSessionCount) new \(sessionLabel) available. Consider regenerating."
        case .stale:
            return "\(freshness.newSessionCount) new \(sessionLabel) available. Regenerate for updated patterns."
        }
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
                            Text(pattern.detail)
                                .font(.Orttaai.secondary)
                                .foregroundStyle(Color.Orttaai.textSecondary)
                            if let evidence = pattern.evidence {
                                Text(evidence)
                                    .font(.Orttaai.caption)
                                    .foregroundStyle(Color.Orttaai.textTertiary)
                            }
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
            Text("Click Generate to analyze your recent dictation history.")
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
        }
        .padding(Spacing.md)
        .dashboardCard()
    }
}
