// ActivityOverviewView.swift
// Orttaai

import SwiftUI

/// "What's going on": the kind of work behind your dictation, what gets in
/// the way, how each project breaks down, and what you decided or left open.
struct ActivityOverviewView: View {
    @ObservedObject private var store = WorkActivityStore.shared
    @State private var range: ConceptTimeRange = .month
    @State private var report: ActivityReport?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var extraction: (done: Int, total: Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            controls

            if let loadError {
                SettingsNotice(kind: .error, message: loadError)
            } else if let report, report.sessionCount > 0 {
                content(report)
            } else if isLoading || report == nil {
                loadingCard
            } else {
                emptyCard
            }
        }
        .task(id: "\(range.rawValue)-\(store.revision)") {
            await load()
        }
        .onAppear {
            if case .idle = store.analysisState {
                store.startAnalysis(horizonDays: Self.horizon(for: range))
            }
        }
        .onChange(of: range) { _, newRange in
            if case .finished = store.analysisState {
                store.startAnalysis(horizonDays: Self.horizon(for: newRange))
            } else if case .idle = store.analysisState {
                store.startAnalysis(horizonDays: Self.horizon(for: newRange))
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            report = try await store.report(range: range)
            loadError = nil
        } catch {
            loadError = "Couldn't read your sessions: \(error.localizedDescription)"
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: Spacing.md) {
            OrttaaiSegmentedControl(
                title: "Time range",
                selection: $range,
                options: ConceptTimeRange.allCases.map { .init($0, $0.title) }
            )
            Spacer(minLength: Spacing.md)
            analysisStatus
        }
    }

    @ViewBuilder
    private var analysisStatus: some View {
        switch store.analysisState {
        case .idle:
            Button {
                store.startAnalysis(horizonDays: Self.horizon(for: range))
            } label: {
                Label("Read with local AI", systemImage: "cpu")
            }
            .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
            .help("A local model reads each working session once. Nothing leaves your Mac.")
        case .checking:
            statusText("Checking local AI…", showsProgress: true)
        case .running(let done, let total, let model):
            HStack(spacing: Spacing.sm) {
                ProgressView(value: Double(done), total: Double(max(1, total)))
                    .progressViewStyle(.linear)
                    .tint(Color.Orttaai.accent)
                    .frame(width: 90)
                Text("Reading \(done) of \(total) sessions")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .monospacedDigit()
                    .help("Reading with \(model), on this Mac. Pauses while you dictate.")
                Button("Stop") { store.stopAnalysis() }
                    .buttonStyle(OrttaaiButtonStyle(.ghost, size: .small))
            }
        case .pausedForDictation(let done, let total):
            statusText("Paused while you dictate · \(done) of \(total)", showsProgress: false)
        case .finished(let model):
            StatusChip(title: "Read by \(model)", systemImage: "checkmark.circle", tint: Color.Orttaai.success)
                .help("Every session in this range has been read by your local model.")
        case .unavailable(let message):
            HStack(spacing: Spacing.sm) {
                StatusChip(title: "Local AI off", systemImage: "exclamationmark.circle", tint: Color.Orttaai.warning)
                    .help(message)
                Button("Try Again") { store.startAnalysis(horizonDays: Self.horizon(for: range)) }
                    .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
                    .help(message)
            }
        }
    }

    private func statusText(_ text: String, showsProgress: Bool) -> some View {
        HStack(spacing: Spacing.xs) {
            if showsProgress {
                ProgressView().controlSize(.mini)
            }
            Text(text)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textSecondary)
        }
    }

    // MARK: - Content

    private func content(_ report: ActivityReport) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            summaryCard(report)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Spacing.md) {
                    timeCard(report)
                    frictionCard(report)
                }
                VStack(alignment: .leading, spacing: Spacing.md) {
                    timeCard(report)
                    frictionCard(report)
                }
            }

            if !report.projects.isEmpty {
                projectsCard(report)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Spacing.md) {
                    notesCard("Decisions", info: "Things you said you decided, newest first.", notes: report.decisions, empty: "No decisions stated in this range.")
                    notesCard("Open questions", info: "Things you asked or left unresolved, newest first.", notes: report.openQuestions, empty: "Nothing left open in this range.")
                }
                VStack(alignment: .leading, spacing: Spacing.md) {
                    notesCard("Decisions", info: "Things you said you decided, newest first.", notes: report.decisions, empty: "No decisions stated in this range.")
                    notesCard("Open questions", info: "Things you asked or left unresolved, newest first.", notes: report.openQuestions, empty: "Nothing left open in this range.")
                }
            }
        }
    }

    private func summaryCard(_ report: ActivityReport) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(report.headline.joined(separator: " "))
                    .font(.Orttaai.body)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if report.modelAnalyzedCount < report.sessionCount {
                    Label(
                        report.modelAnalyzedCount == 0
                            ? "Estimated from your wording. Local AI reading gives a deeper picture."
                            : "\(report.modelAnalyzedCount) of \(report.sessionCount) sessions read by local AI; the rest are estimated from wording.",
                        systemImage: "info.circle"
                    )
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                }
            }
            .padding(.vertical, Spacing.xs)
        }
    }

    private func timeCard(_ report: ActivityReport) -> some View {
        SettingsCard(
            "Where your time goes",
            info: "The main kind of work in each working session (dictations in one app, close together). The arrow compares with the period before."
        ) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(report.activities.prefix(7)) { share in
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: share.activity.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Self.color(for: share.activity))
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text(share.activity.title)
                            .font(.Orttaai.secondary)
                            .foregroundStyle(Color.Orttaai.textPrimary)
                            .frame(width: 150, alignment: .leading)
                            .lineLimit(1)
                        ShareBar(share: share.share, color: Self.color(for: share.activity))
                        Text("\(Int((share.share * 100).rounded()))%")
                            .font(.Orttaai.secondary.monospacedDigit())
                            .foregroundStyle(Color.Orttaai.textSecondary)
                            .frame(width: 34, alignment: .trailing)
                        changeLabel(share.change)
                            .frame(width: 34, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(share.activity.title), \(Int((share.share * 100).rounded())) percent of sessions")
                }
            }
            .padding(.bottom, Spacing.xs)
        }
    }

    private func frictionCard(_ report: ActivityReport) -> some View {
        SettingsCard(
            "What gets in the way",
            info: "Sessions where something went wrong or blocked you, grouped by kind, with your most recent examples."
        ) {
            StatusChip(
                title: "\(Int((report.frictionRate * 100).rounded()))% of sessions",
                systemImage: "exclamationmark.triangle",
                tint: report.frictionRate >= 0.3 ? Color.Orttaai.warning : Color.Orttaai.textSecondary
            )
        } content: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if report.frictions.isEmpty {
                    SettingsFootnote("Nothing got in the way in this range.")
                }
                ForEach(report.frictions.prefix(4)) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(group.type.title)
                                .font(.Orttaai.secondary.weight(.medium))
                                .foregroundStyle(Color.Orttaai.textPrimary)
                            Spacer()
                            Text("\(group.sessions) session\(group.sessions == 1 ? "" : "s")")
                                .font(.Orttaai.caption.monospacedDigit())
                                .foregroundStyle(Color.Orttaai.textTertiary)
                        }
                        if let example = group.examples.first {
                            Text("\u{201C}\(example.text)\u{201D}")
                                .font(.Orttaai.caption)
                                .foregroundStyle(Color.Orttaai.textSecondary)
                                .lineLimit(2)
                                .help(group.examples.map(\.text).joined(separator: "\n"))
                        }
                    }
                }
            }
            .padding(.bottom, Spacing.xs)
        }
    }

    private func projectsCard(_ report: ActivityReport) -> some View {
        SettingsCard(
            "Projects",
            info: "Named things you worked on, with the mix of work each got, what got in the way, and the latest goal."
        ) {
            ForEach(Array(report.projects.enumerated()), id: \.element.id) { index, project in
                if index > 0 {
                    SettingsDivider()
                }
                ProjectRow(project: project)
                    .padding(.vertical, Spacing.sm)
            }
        }
    }

    private func notesCard(_ title: String, info: String, notes: [SessionNote], empty: String) -> some View {
        SettingsCard(title, info: info) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if notes.isEmpty {
                    SettingsFootnote(empty)
                }
                ForEach(notes.prefix(6)) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.text)
                            .font(.Orttaai.secondary)
                            .foregroundStyle(Color.Orttaai.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Text(noteCaption(note))
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                    }
                }
            }
            .padding(.bottom, Spacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func noteCaption(_ note: SessionNote) -> String {
        var parts: [String] = []
        if let project = note.project { parts.append(project) }
        parts.append(note.date.formatted(.dateTime.month(.abbreviated).day()))
        if let app = note.appName { parts.append(app) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func changeLabel(_ change: Int?) -> some View {
        if let change, abs(change) >= 3 {
            Text("\(change > 0 ? "↑" : "↓")\(abs(change))")
                .font(.Orttaai.caption.monospacedDigit())
                .foregroundStyle(change > 0 ? Color.Orttaai.accent : Color.Orttaai.textTertiary)
                .help("\(change > 0 ? "Up" : "Down") \(abs(change)) points from the period before")
        } else {
            Text("")
        }
    }

    private var loadingCard: some View {
        SettingsCard {
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Reading your dictation history…")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }
            .padding(.vertical, Spacing.sm)
        }
    }

    private var emptyCard: some View {
        SettingsCard {
            SettingsFootnote("No working sessions in this range yet. Dictate a little more, or pick a longer range.")
                .padding(.vertical, Spacing.xs)
        }
    }

    /// Read twice the range so the "change from the period before" compares
    /// model readings with model readings.
    static func horizon(for range: ConceptTimeRange) -> Int? {
        range.days.map { $0 * 2 }
    }

    static func color(for activity: WorkActivity) -> Color {
        switch activity {
        case .building: return .blue
        case .fixing: return .orange
        case .designing: return .purple
        case .planning: return .teal
        case .researching: return .indigo
        case .writing: return .green
        case .communicating: return .pink
        case .setup: return .gray
        case .reviewing: return .mint
        case .other: return Color.Orttaai.textTertiary
        }
    }
}

private struct ShareBar: View {
    let share: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.Orttaai.bgTertiary.opacity(0.7))
                Capsule()
                    .fill(color.opacity(0.85))
                    .frame(width: max(3, proxy.size.width * share))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

private struct ProjectRow: View {
    let project: ProjectBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text(project.title)
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Text("\(project.sessions) sessions · last active \(project.lastActive.formatted(.relative(presentation: .named)))")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                Spacer(minLength: 0)
            }

            HStack(spacing: Spacing.xs) {
                ForEach(project.activities) { share in
                    Label("\(share.activity.title) \(Int((share.share * 100).rounded()))%", systemImage: share.activity.symbol)
                        .font(.Orttaai.caption)
                        .foregroundStyle(ActivityOverviewView.color(for: share.activity))
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, 2)
                        .background(ActivityOverviewView.color(for: share.activity).opacity(0.1))
                        .clipShape(Capsule())
                }
            }

            if project.frictionSessions > 0 || project.latestGoal != nil {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                    if let goal = project.latestGoal {
                        Text("Latest: \(goal)")
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                            .lineLimit(1)
                    }
                    if project.frictionSessions > 0 {
                        Text("Friction in \(project.frictionSessions), mostly \((project.topFriction ?? .other).title.lowercased())")
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.warning.opacity(0.9))
                            .lineLimit(1)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
