// ActivityOverviewView.swift
// Orttaai

import SwiftUI

/// "What's going on": the kind of work behind your dictation, what gets in
/// the way, how each project breaks down, and what you decided or left open.
/// Anything here can be handed to Chat AI as a question.
struct ActivityOverviewView: View {
    /// Picked in the page header.
    let range: ConceptTimeRange
    var onAskChat: (String) -> Void = { _ in }
    @ObservedObject private var store = WorkActivityStore.shared
    @State private var report: ActivityReport?
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if let loadError {
                SettingsNotice(kind: .error, message: loadError)
            } else if let report, report.sessionCount > 0 {
                ActivityReportContent(report: report, range: range, onAskChat: onAskChat)
            } else if isLoading || report == nil {
                messageCard {
                    HStack(spacing: Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("Reading your dictation history…")
                            .font(.Orttaai.secondary)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                    }
                }
            } else {
                messageCard {
                    Text("No working sessions in \(ActivityOverviewView.phrase(for: range)) yet. Dictate a little more, or pick a longer range.")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }
            }
        }
        .task(id: "\(range.rawValue)-\(store.revision)") {
            await load()
        }
        .onAppear {
            if case .idle = store.analysisState {
                store.startAnalysis(horizonDays: ActivityOverviewView.horizon(for: range))
            }
        }
        .onChange(of: range) { _, newRange in
            switch store.analysisState {
            case .finished, .idle:
                store.startAnalysis(horizonDays: ActivityOverviewView.horizon(for: newRange))
            default:
                break
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

    private func messageCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dashboardCard()
    }

    /// "the last 30 days", "all time".
    static func phrase(for range: ConceptTimeRange) -> String {
        range.days.map { "the last \($0) days" } ?? "all time"
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

/// The report itself: summary, time and friction, projects, decisions and
/// open questions.
struct ActivityReportContent: View {
    let report: ActivityReport
    let range: ConceptTimeRange
    var onAskChat: (String) -> Void = { _ in }
    @ObservedObject private var store = WorkActivityStore.shared

    var body: some View {
        content(report)
    }

    // MARK: - Content

    private func content(_ report: ActivityReport) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            summaryCard(report)

            pairedRow {
                timeCard(report)
            } right: {
                frictionCard(report)
            }

            if !report.projects.isEmpty {
                projectsCard(report)
            }

            pairedRow {
                notesCard(
                    "Decisions",
                    info: "Things you said you decided, newest first.",
                    systemImage: "checkmark.seal",
                    notes: report.decisions,
                    empty: "No decisions stated in this range.",
                    asksChat: false
                )
            } right: {
                notesCard(
                    "Open questions",
                    info: "Things you asked or left unresolved, newest first.",
                    systemImage: "questionmark.circle",
                    notes: report.openQuestions,
                    empty: "Nothing left open in this range.",
                    asksChat: true
                )
            }
        }
    }

    // MARK: - Summary

    /// What the range was about in a sentence or two, the numbers behind it,
    /// and a way to ask Chat AI for more.
    private func summaryCard(_ report: ActivityReport) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text(ActivityOverviewView.phrase(for: range).prefix(1).uppercased() + ActivityOverviewView.phrase(for: range).dropFirst())
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Spacer(minLength: Spacing.sm)
                analysisStatus
            }

            HStack(spacing: Spacing.sm) {
                stat(icon: "waveform", value: report.sessionCount.formatted(), label: report.sessionCount == 1 ? "working session" : "working sessions")
                stat(icon: "calendar", value: report.dayCount.formatted(), label: report.dayCount == 1 ? "active day" : "active days")
                if let top = report.activities.first {
                    stat(
                        icon: top.activity.symbol,
                        value: "\(Int((top.share * 100).rounded()))%",
                        label: top.activity.title.lowercased(),
                        tint: ActivityOverviewView.color(for: top.activity)
                    )
                }
                stat(
                    icon: report.frictionRate > 0 ? "exclamationmark.triangle" : "checkmark.circle",
                    value: "\(Int((report.frictionRate * 100).rounded()))%",
                    label: "hit a snag",
                    tint: report.frictionRate >= 0.3 ? Color.Orttaai.warning : Color.Orttaai.accent
                )
            }

            if let story = storyText(report) {
                Text(story)
                    .font(.Orttaai.body)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack(alignment: .center, spacing: Spacing.md) {
                if report.modelAnalyzedCount < report.sessionCount {
                    Label(
                        report.modelAnalyzedCount == 0
                            ? "Estimated from your wording until local AI reads these sessions."
                            : "\(report.modelAnalyzedCount) of \(report.sessionCount) sessions read by local AI; the rest are estimated.",
                        systemImage: "info.circle"
                    )
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .lineLimit(1)
                }
                Spacer(minLength: Spacing.sm)
                Button {
                    onAskChat(summaryQuestion)
                } label: {
                    Label("Ask Chat AI", systemImage: "bubble.left.and.text.bubble.right")
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
                .help("Open Chat AI with a summary of this range: projects, decisions, what's open and what got in the way")
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    /// The headline minus its first sentence, which the stats already say.
    private func storyText(_ report: ActivityReport) -> String? {
        let rest = report.headline.dropFirst().joined(separator: " ")
        return rest.isEmpty ? nil : rest
    }

    private var summaryQuestion: String {
        "Look at my dictation from \(ActivityOverviewView.phrase(for: range)). In short sections, tell me what I've been working on, the decisions I made, what's still open, and anything that kept getting in my way."
    }

    /// One line, built like the stat rows on the Overview's Today card.
    private func stat(icon: String, value: String, label: String, tint: Color = Color.Orttaai.accent) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(value)
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .monospacedDigit()
            Text(label)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Orttaai.bgPrimary.opacity(0.7), in: RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }

    @ViewBuilder
    private var analysisStatus: some View {
        switch store.analysisState {
        case .idle:
            Button {
                store.startAnalysis(horizonDays: ActivityOverviewView.horizon(for: range))
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
                    .frame(width: 80)
                Text("Reading \(done) of \(total)")
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
                Button("Try Again") { store.startAnalysis(horizonDays: ActivityOverviewView.horizon(for: range)) }
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

    // MARK: - Time and friction

    private func timeCard(_ report: ActivityReport) -> some View {
        let shares = Array(report.activities.prefix(6))
        return activityCard(
            "Where your time goes",
            info: "The main kind of work in each working session (dictations in one app, close together). The arrow compares with the period before."
        ) {
            // One bar split by kind of work, then the key with the numbers.
            GeometryReader { geometry in
                let gaps = CGFloat(max(0, shares.count - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(shares) { share in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(ActivityOverviewView.color(for: share.activity).opacity(0.85))
                            .frame(width: max(4, (geometry.size.width - gaps) * share.share))
                    }
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(shares) { share in
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: share.activity.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ActivityOverviewView.color(for: share.activity))
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text(share.activity.title)
                            .font(.Orttaai.secondary)
                            .foregroundStyle(Color.Orttaai.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: Spacing.sm)
                        Text(share.sessions == 1 ? "1 session" : "\(share.sessions) sessions")
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                            .monospacedDigit()
                        Text("\(Int((share.share * 100).rounded()))%")
                            .font(.Orttaai.secondary.monospacedDigit())
                            .foregroundStyle(Color.Orttaai.textSecondary)
                            .frame(width: 38, alignment: .trailing)
                        changeLabel(share.change)
                            .frame(width: 32, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(share.activity.title), \(Int((share.share * 100).rounded())) percent of sessions")
                }
            }
        }
    }

    private func frictionCard(_ report: ActivityReport) -> some View {
        let snagged = Int((report.frictionRate * Double(report.sessionCount)).rounded())
        return activityCard(
            "What gets in the way",
            info: "Sessions where something went wrong or blocked you, grouped by kind, with your most recent example."
        ) {
            if report.frictions.isEmpty {
                Label("Nothing got in the way in this range.", systemImage: "checkmark.circle")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            } else {
                Text("\(snagged) of \(report.sessionCount) sessions hit a snag")
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(report.frictionRate >= 0.3 ? Color.Orttaai.warning : Color.Orttaai.textPrimary)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ForEach(report.frictions.prefix(4)) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(group.type.title)
                                    .font(.Orttaai.secondary.weight(.medium))
                                    .foregroundStyle(Color.Orttaai.textPrimary)
                                Spacer()
                                Text(group.sessions == 1 ? "1 session" : "\(group.sessions) sessions")
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
            }
        }
    }

    // MARK: - Projects

    private func projectsCard(_ report: ActivityReport) -> some View {
        activityCard(
            "Projects",
            info: "Named things you worked on, with the mix of work each got, what got in the way, and the latest goal."
        ) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(report.projects.enumerated()), id: \.element.id) { index, project in
                    if index > 0 {
                        SettingsDivider()
                    }
                    ProjectRow(project: project)
                        .padding(.vertical, Spacing.sm)
                }
            }
        }
    }

    // MARK: - Notes

    private func notesCard(
        _ title: String,
        info: String,
        systemImage: String,
        notes: [SessionNote],
        empty: String,
        asksChat: Bool
    ) -> some View {
        activityCard(title, info: info, count: notes.count) {
            if notes.isEmpty {
                Text(empty)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ForEach(notes.prefix(5)) { note in
                        NoteRow(
                            note: note,
                            caption: noteCaption(note),
                            systemImage: systemImage,
                            onAsk: asksChat ? { onAskChat(openQuestionPrompt(note)) } : nil
                        )
                    }
                    if notes.count > 5 {
                        Text("+\(notes.count - 5) more")
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                    }
                }
            }
        }
    }

    private func openQuestionPrompt(_ note: SessionNote) -> String {
        let when = note.date.formatted(.dateTime.month(.wide).day())
        return "On \(when) I left this open: \u{201C}\(note.text)\u{201D}. Using what I've dictated about it, help me think it through and suggest a next step."
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

    // MARK: - Building blocks

    /// Title with an info hover and an optional count, then the content;
    /// fills its row so paired cards match in height.
    private func activityCard<Content: View>(
        _ title: String,
        info: String,
        count: Int? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text(title)
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Image(systemName: "info.circle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .help(info)
                    .accessibilityLabel(info)
                Spacer(minLength: Spacing.sm)
                if let count, count > 0 {
                    Text(count.formatted())
                        .font(.Orttaai.caption.monospacedDigit())
                        .foregroundStyle(Color.Orttaai.textTertiary)
                }
            }
            content()
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dashboardCard()
    }

    /// Side by side with equal heights; the text wraps to fit.
    private func pairedRow<Left: View, Right: View>(
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right
    ) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            left()
            right()
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A decision or open question: the words, where they came from, and for
/// open questions a way to take them to Chat AI.
private struct NoteRow: View {
    let note: SessionNote
    let caption: String
    let systemImage: String
    let onAsk: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.Orttaai.accent)
                .frame(width: 16, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.text)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(note.text)
                Text(caption)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
            }
            Spacer(minLength: Spacing.sm)
            if let onAsk {
                Button(action: onAsk) {
                    Label("Ask", systemImage: "bubble.left")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(OrttaaiButtonStyle(.ghost, size: .small))
                .opacity(isHovered ? 1 : 0.55)
                .help("Ask Chat AI to help with this")
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

private struct ProjectRow: View {
    let project: ProjectBreakdown

    private var lastActive: String {
        Calendar.current.isDateInToday(project.lastActive)
            ? "today"
            : project.lastActive.formatted(.relative(presentation: .named))
    }

    /// Lowercases a title for use mid-sentence, leaving acronyms like "UI".
    private func midSentence(_ title: String) -> String {
        title.split(separator: " ").map { word in
            word.count > 1 && word.allSatisfy(\.isUppercase) ? String(word) : word.lowercased()
        }.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text(project.title)
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Text("\(project.sessions) sessions · last active \(lastActive)")
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
                        Text("Friction in \(project.frictionSessions), mostly \(midSentence((project.topFriction ?? .other).title))")
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
