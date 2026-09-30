// ActivityReport.swift
// Orttaai

import Foundation

nonisolated struct AnalyzedSession: Sendable {
    let session: WorkSession
    let analysis: SessionAnalysis
}

nonisolated struct ActivityShare: Identifiable, Hashable, Sendable {
    let activity: WorkActivity
    let sessions: Int
    let share: Double
    /// Share in the previous period of the same length, when there is one.
    let previousShare: Double?

    var id: String { activity.rawValue }

    /// Change in percentage points against the previous period.
    var change: Int? {
        previousShare.map { Int(((share - $0) * 100).rounded()) }
    }
}

/// A sentence the user said (or the model summarized) in one session.
nonisolated struct SessionNote: Identifiable, Hashable, Sendable {
    let id: String
    let text: String
    let date: Date
    let appName: String?
    let project: String?
    let isEstimate: Bool
}

nonisolated struct FrictionGroup: Identifiable, Hashable, Sendable {
    let type: FrictionType
    let sessions: Int
    let examples: [SessionNote]

    var id: String { type.rawValue }
}

nonisolated struct ProjectBreakdown: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let sessions: Int
    let lastActive: Date
    let activities: [ActivityShare]
    let frictionSessions: Int
    let topFriction: FrictionType?
    let latestGoal: String?
}

nonisolated struct ActivityReport: Sendable {
    let range: ConceptTimeRange
    let sessionCount: Int
    let dayCount: Int
    let modelAnalyzedCount: Int
    let headline: [String]
    let activities: [ActivityShare]
    let frictionRate: Double
    let frictions: [FrictionGroup]
    let projects: [ProjectBreakdown]
    let decisions: [SessionNote]
    let openQuestions: [SessionNote]

    static func empty(range: ConceptTimeRange) -> ActivityReport {
        ActivityReport(
            range: range, sessionCount: 0, dayCount: 0, modelAnalyzedCount: 0, headline: [],
            activities: [], frictionRate: 0, frictions: [], projects: [], decisions: [], openQuestions: []
        )
    }
}

/// A named thing the concept graph knows about, used to attribute sessions
/// to projects.
nonisolated struct ProjectCandidate: Sendable {
    let key: String
    let title: String
    let salience: Double
}

nonisolated enum ActivityReportBuilder {
    static func build(
        sessions: [AnalyzedSession],
        range: ConceptTimeRange,
        projects catalog: [ProjectCandidate],
        aliases: [String: String] = [:],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ActivityReport {
        let start = range.days.map { now.addingTimeInterval(-Double($0) * 86_400) }
        let current = sessions.filter { start == nil || $0.session.end >= start! }
        guard !current.isEmpty else { return .empty(range: range) }

        let previous: [AnalyzedSession]
        if let days = range.days, let start {
            let previousStart = start.addingTimeInterval(-Double(days) * 86_400)
            previous = sessions.filter { $0.session.end >= previousStart && $0.session.end < start }
        } else {
            previous = []
        }

        let catalogByKey = Dictionary(catalog.map { ($0.key, $0) }) { first, _ in first }
        func project(for item: AnalyzedSession) -> ProjectCandidate? {
            let named = item.session.conceptKeys.compactMap { catalogByKey[aliases[$0] ?? $0] }
            if let best = named.max(by: { $0.salience < $1.salience }) { return best }
            if let subject = item.analysis.subject {
                let key = ConceptExtractor.normalizedKey(subject, kind: .product)
                return catalogByKey[aliases[key] ?? key]
            }
            return nil
        }

        // A shift only means something when both periods were read the same
        // way; model readings and wording estimates differ systematically.
        let comparable = previous.count >= 10 && readByModel(current) == readByModel(previous)
        let activities = activityShares(current, previous: comparable ? previous : nil)
        let withFriction = current.filter { $0.analysis.friction != nil }
        let frictionRate = Double(withFriction.count) / Double(current.count)

        let frictions = frictionGroups(withFriction, project: project)
        let projects = projectBreakdowns(current, project: project, now: now)

        let recentFirst = current.sorted { $0.session.end > $1.session.end }
        let decisions = recentFirst
            .compactMap { item in item.analysis.decision.map { note(item, text: $0, field: "decision", project: project(for: item)?.title) } }
            .prefix(8)
        let questions = recentFirst
            .compactMap { item in item.analysis.openQuestion.map { note(item, text: $0, field: "question", project: project(for: item)?.title) } }
            .prefix(8)

        let days = Set(current.map { calendar.startOfDay(for: $0.session.end) }).count
        let report = ActivityReport(
            range: range,
            sessionCount: current.count,
            dayCount: days,
            modelAnalyzedCount: current.filter { !$0.analysis.isEstimate }.count,
            headline: [],
            activities: activities,
            frictionRate: frictionRate,
            frictions: Array(frictions),
            projects: Array(projects.prefix(8)),
            decisions: Array(decisions),
            openQuestions: Array(questions)
        )
        return ActivityReport(
            range: report.range,
            sessionCount: report.sessionCount,
            dayCount: report.dayCount,
            modelAnalyzedCount: report.modelAnalyzedCount,
            headline: headline(for: report),
            activities: report.activities,
            frictionRate: report.frictionRate,
            frictions: report.frictions,
            projects: report.projects,
            decisions: report.decisions,
            openQuestions: report.openQuestions
        )
    }

    private static func frictionGroups(
        _ items: [AnalyzedSession],
        project: (AnalyzedSession) -> ProjectCandidate?
    ) -> [FrictionGroup] {
        let grouped: [FrictionType: [AnalyzedSession]] = Dictionary(grouping: items) { $0.analysis.frictionType ?? .other }
        var groups: [FrictionGroup] = []
        for (type, members) in grouped {
            let recent = members.sorted { $0.session.end > $1.session.end }.prefix(3)
            let examples: [SessionNote] = recent.map { item in
                note(item, text: item.analysis.friction ?? "", field: "friction", project: project(item)?.title)
            }
            groups.append(FrictionGroup(type: type, sessions: members.count, examples: examples))
        }
        return groups.sorted { lhs, rhs in
            lhs.sessions == rhs.sessions ? lhs.type.rawValue < rhs.type.rawValue : lhs.sessions > rhs.sessions
        }
    }

    private static func projectBreakdowns(
        _ items: [AnalyzedSession],
        project: (AnalyzedSession) -> ProjectCandidate?,
        now: Date
    ) -> [ProjectBreakdown] {
        var byProject: [String: (candidate: ProjectCandidate, items: [AnalyzedSession])] = [:]
        for item in items {
            guard let candidate = project(item) else { continue }
            byProject[candidate.key, default: (candidate, [])].items.append(item)
        }
        var breakdowns: [ProjectBreakdown] = []
        for (candidate, members) in byProject.values where members.count >= 2 {
            let ordered = members.sorted { $0.session.end > $1.session.end }
            let frictionItems = members.filter { $0.analysis.friction != nil }
            let frictionCounts: [FrictionType: Int] = Dictionary(grouping: frictionItems) { $0.analysis.frictionType ?? .other }
                .mapValues(\.count)
            let topFriction = frictionCounts.max { lhs, rhs in
                lhs.value == rhs.value ? lhs.key.rawValue > rhs.key.rawValue : lhs.value < rhs.value
            }?.key
            breakdowns.append(ProjectBreakdown(
                id: candidate.key,
                title: candidate.title,
                sessions: members.count,
                lastActive: ordered.first?.session.end ?? now,
                activities: Array(activityShares(members, previous: nil).prefix(3)),
                frictionSessions: frictionItems.count,
                topFriction: topFriction,
                latestGoal: ordered.lazy.compactMap(\.analysis.goal).first
            ))
        }
        return breakdowns.sorted { lhs, rhs in
            lhs.sessions == rhs.sessions ? lhs.title < rhs.title : lhs.sessions > rhs.sessions
        }
    }

    /// True when most sessions were read by a model, false when most are
    /// estimates, nil when mixed.
    private static func readByModel(_ items: [AnalyzedSession]) -> Bool? {
        let share = Double(items.filter { !$0.analysis.isEstimate }.count) / Double(max(1, items.count))
        if share >= 0.8 { return true }
        if share <= 0.2 { return false }
        return nil
    }

    static func activityShares(_ items: [AnalyzedSession], previous: [AnalyzedSession]?) -> [ActivityShare] {
        guard !items.isEmpty else { return [] }
        let counts = Dictionary(grouping: items, by: \.analysis.activity).mapValues(\.count)
        let previousCounts = previous.map { Dictionary(grouping: $0, by: \.analysis.activity).mapValues(\.count) }
        let previousTotal = Double(previous?.count ?? 0)
        return counts
            .map { activity, count in
                ActivityShare(
                    activity: activity,
                    sessions: count,
                    share: Double(count) / Double(items.count),
                    previousShare: previousCounts.map { Double($0[activity] ?? 0) / max(1, previousTotal) }
                )
            }
            .sorted { $0.sessions == $1.sessions ? $0.activity.rawValue < $1.activity.rawValue : $0.sessions > $1.sessions }
    }

    /// A few plain sentences that say what the numbers mean.
    static func headline(for report: ActivityReport) -> [String] {
        var lines: [String] = []
        let period = report.range == .all ? "Overall" : "In the last \(report.range.title)"
        lines.append("\(period), you dictated through \(report.sessionCount) working session\(report.sessionCount == 1 ? "" : "s") on \(report.dayCount) day\(report.dayCount == 1 ? "" : "s").")

        let meaningful = report.activities.filter { $0.activity != .other }
        if let first = meaningful.first {
            if let second = meaningful.dropFirst().first, second.share >= 0.12 {
                lines.append("Most of it was \(first.activity.phrase) (\(percent(first.share))), then \(second.activity.phrase) (\(percent(second.share))).")
            } else {
                lines.append("Most of it was \(first.activity.phrase) (\(percent(first.share))).")
            }
        }

        if let shift = report.activities
            .compactMap({ share in share.change.map { (share, $0) } })
            .filter({ abs($0.1) >= 8 })
            .max(by: { abs($0.1) < abs($1.1) }) {
            let direction = shift.1 > 0 ? "up" : "down"
            lines.append("\(shift.0.activity.title) is \(direction) \(abs(shift.1)) points from the \(report.range.title) before.")
        }

        if let top = report.projects.first {
            if let next = report.projects.dropFirst().first {
                lines.append("\(top.title) took the most attention (\(top.sessions) sessions), then \(next.title) (\(next.sessions)).")
            } else {
                lines.append("\(top.title) took the most attention (\(top.sessions) sessions).")
            }
        }

        if report.frictionRate >= 0.05, let friction = report.frictions.first {
            lines.append("Something got in the way in \(percent(report.frictionRate)) of sessions, most often \(friction.type.title.lowercased()).")
        }
        return lines
    }

    private static func note(_ item: AnalyzedSession, text: String, field: String, project: String?) -> SessionNote {
        SessionNote(
            id: "\(item.session.key)-\(field)",
            text: text,
            date: item.session.end,
            appName: item.session.appName,
            project: project,
            isEstimate: item.analysis.isEstimate
        )
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
