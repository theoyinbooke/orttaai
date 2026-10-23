// TodaySnapshotCard.swift
// Orttaai

import SwiftUI

/// Today at a glance, laid out like the Performance card beside it: the words
/// dictated so far as the headline, a seven-day strip with one line about it,
/// and the supporting numbers in single-line rows at the bottom.
struct TodaySnapshotCard: View {
    let snapshot: DashboardTodaySnapshot
    /// The last seven days, oldest first, ending today.
    var week: [DashboardTrendPoint] = []
    /// Average words on the other active days of the last 30, if any.
    var usualWords: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Spacer()
                Text(Date(), format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    Text(snapshot.words.formatted())
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(snapshot.sessions == 0 ? Color.Orttaai.textTertiary : Color.Orttaai.textPrimary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(snapshot.words == 1 ? "word" : "words")
                        .font(.Orttaai.body)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                    Spacer()
                    if snapshot.sessions == 0 {
                        Text("Nothing dictated yet")
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                    }
                }
                weekStrip
                Text(weekLine)
                    .font(.Orttaai.caption)
                    .foregroundStyle(comparison?.isAhead == true ? Color.Orttaai.accent : Color.Orttaai.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            HStack(spacing: Spacing.sm) {
                stat(icon: "waveform", value: snapshot.sessions.formatted(), label: snapshot.sessions == 1 ? "session" : "sessions")
                stat(icon: "clock", value: activeTime, label: "active")
                stat(icon: "speedometer", value: snapshot.averageWPM > 0 ? snapshot.averageWPM.formatted() : "–", label: "WPM")
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, minHeight: 188, alignment: .leading)
        .dashboardCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Today: \(statusDescription) \(snapshot.words) words, \(snapshot.sessions) sessions, \(activeTime) active, average \(snapshot.averageWPM) words per minute. \(weekLine)."
        )
    }

    // MARK: - Week

    /// Seven segments the size of the Performance bar, brighter on busier
    /// days, with today outlined.
    private var weekStrip: some View {
        let days = paddedWeek
        let busiest = max(1, days.map(\.words).max() ?? 1)
        return HStack(spacing: 2) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                let isToday = index == days.count - 1
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(day.words > 0
                          ? Color.Orttaai.accent.opacity(0.3 + 0.7 * Double(day.words) / Double(busiest))
                          : Color.Orttaai.textTertiary.opacity(0.35))
                    .overlay {
                        if isToday {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(Color.Orttaai.textPrimary.opacity(0.7), lineWidth: 1)
                        }
                    }
                    .help(dayHelp(day, isToday: isToday))
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    /// Always seven days, so the strip keeps its shape before a week of history.
    private var paddedWeek: [DashboardTrendPoint] {
        let recent = Array(week.suffix(7))
        guard recent.count < 7 else { return recent }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let missing = (0..<(7 - recent.count)).compactMap { offset in
            calendar.date(byAdding: .day, value: offset - 6, to: today)
        }
        return missing.map { DashboardTrendPoint(dayStart: $0, words: 0, sessions: 0, averageWPM: 0) } + recent
    }

    private func dayHelp(_ day: DashboardTrendPoint, isToday: Bool) -> String {
        let name = isToday ? "Today" : day.dayStart.formatted(.dateTime.weekday(.wide))
        return day.words > 0 ? "\(name): \(day.words.formatted()) words" : "\(name): no dictation"
    }

    private var weekLine: String {
        if let comparison { return comparison.text }
        let days = paddedWeek
        let activeDays = days.filter { $0.sessions > 0 }.count
        let words = days.reduce(0) { $0 + $1.words }
        guard activeDays > 0 else { return "No dictation this week yet" }
        return "\(words.formatted()) \(words == 1 ? "word" : "words") this week · \(activeDays) active \(activeDays == 1 ? "day" : "days")"
    }

    private var comparison: (text: String, isAhead: Bool)? {
        guard snapshot.sessions > 0, let usualWords, usualWords > 0 else { return nil }
        let ratio = Double(snapshot.words) / Double(usualWords)
        if ratio >= 1.1 {
            return ("\(Int(((ratio - 1) * 100).rounded()))% above your usual day", true)
        }
        if ratio <= 0.9 {
            return ("\(usualWords.formatted()) words on a usual day", false)
        }
        return ("Right on your usual pace", false)
    }

    // MARK: - Stats

    /// One line, built like the engine row on the Performance card so the
    /// two cards' bottoms line up.
    private func stat(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.Orttaai.accent)
                .frame(width: 22, height: 22)
                .background(Color.Orttaai.accentSubtle, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(value)
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .monospacedDigit()
            Text(label)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
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

    /// Dictations shorter than a minute still count as time spent.
    private var activeTime: String {
        if snapshot.activeMinutes == 0 {
            return snapshot.sessions > 0 ? "<1 min" : "0 min"
        }
        return "\(snapshot.activeMinutes.formatted()) min"
    }

    private var statusDescription: String {
        snapshot.sessions == 0 ? "No dictations today yet." : "\(snapshot.sessions.formatted()) dictations today."
    }
}
