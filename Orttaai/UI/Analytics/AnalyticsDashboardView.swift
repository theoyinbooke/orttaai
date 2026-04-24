// AnalyticsDashboardView.swift
// Orttaai

import SwiftUI
import Charts
import GRDB
import os

// MARK: - View Model

enum AnalyticsTimeRange: String, CaseIterable, Identifiable {
    case thirtyDays = "30 Days"
    case ninetyDays = "90 Days"
    case allTime = "All Time"

    var id: String { rawValue }

    var dayCount: Int? {
        switch self {
        case .thirtyDays: return 30
        case .ninetyDays: return 90
        case .allTime: return nil
        }
    }

    var shortLabel: String {
        switch self {
        case .thirtyDays: return "30d"
        case .ninetyDays: return "90d"
        case .allTime: return "All time"
        }
    }

    var trendTitle: String {
        switch self {
        case .thirtyDays: return "30-Day Trend"
        case .ninetyDays: return "90-Day Trend"
        case .allTime: return "All-Time Trend"
        }
    }

    var axisTickCount: Int {
        switch self {
        case .thirtyDays: return 8
        case .ninetyDays: return 10
        case .allTime: return 8
        }
    }
}

@MainActor
@Observable
final class AnalyticsDashboardViewModel {
    private let settings: AppSettings
    var selectedRange: AnalyticsTimeRange = .thirtyDays
    private(set) var payload: DashboardStatsPayload = .empty
    private(set) var trendPoints: [DashboardTrendPoint] = []
    private(set) var hourlyActivity: [HourlyActivityPoint] = []
    private(set) var durationBuckets: [DurationBucket] = []
    private(set) var wordsByApp: [AppWordCount] = []
    private(set) var totalSessions: Int = 0
    private(set) var totalWords: Int = 0
    private(set) var totalRecordingMinutes: Int = 0
    private(set) var activeDays: Int = 0
    private(set) var averageWPM: Int = 0
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    var errorMessage: String?

    private var observation: DatabaseCancellable?

    init(settings: AppSettings) {
        self.settings = settings
    }

    convenience init() {
        self.init(settings: AppSettings())
    }

    func load() {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
        }

        do {
            let db = try DatabaseManager()
            let service = DashboardStatsService(databaseManager: db)
            try refresh(using: db, service: service)

            observation = service.observeChanges { [weak self] in
                Task { @MainActor in
                    self?.refresh()
                }
            }
            hasLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load analytics."
            Logger.database.error("Analytics load error: \(error.localizedDescription)")
        }
    }

    func refresh() {
        do {
            let db = try DatabaseManager()
            let service = DashboardStatsService(databaseManager: db)
            try refresh(using: db, service: service)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to refresh analytics."
        }
    }

    func setSelectedRange(_ range: AnalyticsTimeRange) {
        guard selectedRange != range else { return }
        selectedRange = range
        if hasLoaded {
            refresh()
        }
    }

    private func refresh(
        using db: DatabaseManager,
        service: DashboardStatsService
    ) throws {
        payload = try service.load(currentModelId: currentModelID())
        let records = try fetchAnalyticsRecords(from: db)
        computeExtendedMetrics(from: records)
    }

    private func currentModelID() -> String? {
        let activeModelId = settings.activeModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        return activeModelId.isEmpty ? nil : activeModelId
    }

    private func fetchAnalyticsRecords(from db: DatabaseManager) throws -> [Transcription] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? Date()

        guard let dayCount = selectedRange.dayCount else {
            return try db.fetchRecent(limit: 500)
        }

        let start = calendar.date(
            byAdding: .day,
            value: -(dayCount - 1),
            to: todayStart
        ) ?? todayStart
        return try db.fetchTranscriptions(from: start, to: tomorrowStart)
    }

    private func computeExtendedMetrics(from records: [Transcription]) {
        totalSessions = records.count
        totalWords = records.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        let totalRecordingMs = records.reduce(0) { $0 + max(0, $1.recordingDurationMs) }
        totalRecordingMinutes = Int((Double(totalRecordingMs) / 60_000).rounded())
        averageWPM = calculateWPM(words: totalWords, recordingMs: totalRecordingMs)

        // Hourly activity
        let calendar = Calendar.current
        activeDays = Set(records.map { calendar.startOfDay(for: $0.createdAt) }).count
        trendPoints = makeTrendPoints(from: records, calendar: calendar)
        var countByHour = [Int: Int]()
        for record in records {
            let hour = calendar.component(.hour, from: record.createdAt)
            countByHour[hour, default: 0] += 1
        }
        hourlyActivity = (0..<24).map { hour in
            HourlyActivityPoint(hour: hour, count: countByHour[hour, default: 0])
        }

        // Duration buckets
        let bucketDefs: [(String, Int)] = [
            ("0-5s", 5_000),
            ("5-15s", 15_000),
            ("15-30s", 30_000),
            ("30s-1m", 60_000),
            ("1-2m", 120_000),
            ("2-5m", 300_000),
            ("5m+", Int.max),
        ]
        var counts = Array(repeating: 0, count: bucketDefs.count)
        for record in records {
            let ms = max(0, record.recordingDurationMs)
            var prevMax = 0
            for (index, def) in bucketDefs.enumerated() {
                if ms >= prevMax && (ms < def.1 || index == bucketDefs.count - 1) {
                    counts[index] += 1
                    break
                }
                prevMax = def.1
            }
        }
        durationBuckets = bucketDefs.enumerated().map { index, def in
            DurationBucket(label: def.0, count: counts[index], order: index)
        }

        // Words by app
        var appWords = [String: Int]()
        for record in records {
            let name = record.targetAppName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
            let appName = name.isEmpty ? "Unknown" : name
            appWords[appName, default: 0] += record.text.split(whereSeparator: \.isWhitespace).count
        }
        wordsByApp = appWords
            .map { AppWordCount(name: $0.key, words: $0.value) }
            .sorted { $0.words > $1.words }
            .prefix(6)
            .map { $0 }
    }

    private func makeTrendPoints(
        from records: [Transcription],
        calendar: Calendar
    ) -> [DashboardTrendPoint] {
        let todayStart = calendar.startOfDay(for: Date())
        let startDay: Date

        if let dayCount = selectedRange.dayCount {
            startDay = calendar.date(
                byAdding: .day,
                value: -(dayCount - 1),
                to: todayStart
            ) ?? todayStart
        } else if let oldestDate = records.map(\.createdAt).min() {
            startDay = calendar.startOfDay(for: oldestDate)
        } else {
            return []
        }

        let daySpan = max(
            0,
            calendar.dateComponents([.day], from: startDay, to: todayStart).day ?? 0
        )
        var aggregatesByDay: [Date: (words: Int, sessions: Int, recordingMs: Int)] = [:]

        for record in records {
            let day = calendar.startOfDay(for: record.createdAt)
            let wordCount = record.text.split(whereSeparator: \.isWhitespace).count
            var aggregate = aggregatesByDay[day, default: (0, 0, 0)]
            aggregate.words += wordCount
            aggregate.sessions += 1
            aggregate.recordingMs += max(0, record.recordingDurationMs)
            aggregatesByDay[day] = aggregate
        }

        return (0...daySpan).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay) else {
                return nil
            }
            let aggregate = aggregatesByDay[day, default: (0, 0, 0)]
            return DashboardTrendPoint(
                dayStart: day,
                words: aggregate.words,
                sessions: aggregate.sessions,
                averageWPM: calculateWPM(words: aggregate.words, recordingMs: aggregate.recordingMs)
            )
        }
    }

    private func calculateWPM(words: Int, recordingMs: Int) -> Int {
        guard words > 0, recordingMs > 0 else { return 0 }
        let minutes = Double(recordingMs) / 60_000
        guard minutes > 0 else { return 0 }
        return Int((Double(words) / minutes).rounded())
    }

    func cancelObservation() {
        observation?.cancel()
        observation = nil
    }
}

// MARK: - Data Models

struct HourlyActivityPoint: Identifiable {
    let hour: Int
    let count: Int
    var id: Int { hour }

    var hourLabel: String {
        if hour == 0 { return "12a" }
        if hour < 12 { return "\(hour)a" }
        if hour == 12 { return "12p" }
        return "\(hour - 12)p"
    }
}

struct DurationBucket: Identifiable {
    let label: String
    let count: Int
    let order: Int
    var id: String { label }
}

struct AppWordCount: Identifiable {
    let name: String
    let words: Int
    var id: String { name }
}

// MARK: - Dashboard View

struct AnalyticsDashboardView: View {
    @State private var viewModel = AnalyticsDashboardViewModel()

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < 1_000

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.Orttaai.secondary)
                            .foregroundStyle(Color.Orttaai.error)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.sm)
                            .background(Color.Orttaai.errorSubtle)
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
                    }

                    rangeControl

                    summaryCards(isCompact: isCompact)

                    trendChart

                    responsiveRow(isCompact: isCompact) {
                        sessionsPerDayChart
                    } right: {
                        hourlyActivityChart
                    }

                    responsiveRow(isCompact: isCompact) {
                        topAppsChart
                    } right: {
                        durationDistributionChart
                    }

                    performanceCard
                }
                .padding(.horizontal, Spacing.xxl)
                .padding(.bottom, Spacing.xxl)
            }
        }
        .onAppear {
            if !viewModel.hasLoaded {
                viewModel.load()
            }
        }
        .onDisappear {
            viewModel.cancelObservation()
        }
    }

    private var rangeSelection: Binding<AnalyticsTimeRange> {
        Binding(
            get: { viewModel.selectedRange },
            set: { viewModel.setSelectedRange($0) }
        )
    }

    private var rangeControl: some View {
        HStack(spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Trend Range")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Text("Activity charts and totals use the selected window.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }

            Spacer()

            HStack(spacing: Spacing.md) {
                Text("Trend Range")
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Picker("", selection: rangeSelection) {
                    ForEach(AnalyticsTimeRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Summary Cards

    private func summaryCards(isCompact: Bool) -> some View {
        let columns = isCompact
            ? [GridItem(.flexible()), GridItem(.flexible())]
            : [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

        return LazyVGrid(columns: columns, spacing: Spacing.md) {
            summaryMetric(
                title: "Total Words",
                value: viewModel.totalWords.formatted(),
                subtitle: "\(viewModel.selectedRange.shortLabel) total",
                icon: "character.cursor.ibeam",
                accentColor: Color.Orttaai.accent
            )
            summaryMetric(
                title: "Sessions",
                value: viewModel.totalSessions.formatted(),
                subtitle: "\(viewModel.payload.today.sessions) today",
                icon: "waveform",
                accentColor: Color(hex: "5E9CF5")
            )
            summaryMetric(
                title: "Active Time",
                value: formatMinutes(viewModel.totalRecordingMinutes),
                subtitle: "\(viewModel.payload.today.activeMinutes)m today",
                icon: "timer",
                accentColor: Color(hex: "34C759")
            )
            summaryMetric(
                title: "Avg WPM",
                value: viewModel.averageWPM.formatted(),
                subtitle: "\(viewModel.activeDays) active days",
                icon: "speedometer",
                accentColor: Color(hex: "FF9F0A")
            )
        }
    }

    private func summaryMetric(
        title: String,
        value: String,
        subtitle: String,
        icon: String,
        accentColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 28, height: 28)
                    .background(accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Text(title)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }

            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.Orttaai.textPrimary)

            Text(subtitle)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    // MARK: - Trend Chart (Words + WPM)

    private var trendChart: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text(viewModel.selectedRange.trendTitle)
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Spacer()

                HStack(spacing: Spacing.lg) {
                    legendDot(color: Color.Orttaai.accent.opacity(0.5), label: "Words")
                    legendDot(color: Color(hex: "5E9CF5"), label: "WPM")
                }
            }

            if viewModel.trendPoints.isEmpty || viewModel.trendPoints.allSatisfy({ $0.words == 0 && $0.sessions == 0 }) {
                emptyChartPlaceholder("No activity in this range yet.")
            } else {
                Chart(viewModel.trendPoints) { point in
                    BarMark(
                        x: .value("Day", point.dayStart, unit: .day),
                        y: .value("Words", point.words)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.Orttaai.accent.opacity(0.6), Color.Orttaai.accent.opacity(0.2)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .cornerRadius(4)

                    LineMark(
                        x: .value("Day", point.dayStart, unit: .day),
                        y: .value("WPM", point.averageWPM)
                    )
                    .foregroundStyle(Color(hex: "5E9CF5"))
                    .lineStyle(.init(lineWidth: 2.5))
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Day", point.dayStart, unit: .day),
                        y: .value("WPM", point.averageWPM)
                    )
                    .foregroundStyle(Color(hex: "5E9CF5"))
                    .symbolSize(30)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: viewModel.selectedRange.axisTickCount)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.Orttaai.border.opacity(0.3))
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .foregroundStyle(Color.Orttaai.textTertiary)
                            .font(.Orttaai.caption)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.Orttaai.border.opacity(0.3))
                        AxisValueLabel {
                            if let intValue = value.as(Int.self) {
                                Text(intValue.formatted())
                                    .font(.Orttaai.caption)
                                    .foregroundStyle(Color.Orttaai.textTertiary)
                            }
                        }
                    }
                }
                .frame(height: 220)
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    // MARK: - Sessions Per Day

    private var sessionsPerDayChart: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Sessions Per Day")
                .font(.Orttaai.subheading)
                .foregroundStyle(Color.Orttaai.textPrimary)

            if viewModel.trendPoints.isEmpty || viewModel.trendPoints.allSatisfy({ $0.sessions == 0 }) {
                emptyChartPlaceholder("No sessions recorded in this range.")
            } else {
                Chart(viewModel.trendPoints) { point in
                    BarMark(
                        x: .value("Day", point.dayStart, unit: .day),
                        y: .value("Sessions", point.sessions)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hex: "5E9CF5").opacity(0.8), Color(hex: "5E9CF5").opacity(0.3)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .cornerRadius(4)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: viewModel.selectedRange.axisTickCount)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .foregroundStyle(Color.Orttaai.textTertiary)
                            .font(.Orttaai.caption)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.Orttaai.border.opacity(0.3))
                        AxisValueLabel {
                            if let intValue = value.as(Int.self) {
                                Text("\(intValue)")
                                    .font(.Orttaai.caption)
                                    .foregroundStyle(Color.Orttaai.textTertiary)
                            }
                        }
                    }
                }
                .frame(height: 180)
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    // MARK: - Hourly Activity

    private var hourlyActivityChart: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Activity by Hour")
                .font(.Orttaai.subheading)
                .foregroundStyle(Color.Orttaai.textPrimary)

            if viewModel.hourlyActivity.allSatisfy({ $0.count == 0 }) {
                emptyChartPlaceholder("Not enough data yet.")
            } else {
                let maxCount = viewModel.hourlyActivity.map(\.count).max() ?? 1

                Chart(viewModel.hourlyActivity) { point in
                    BarMark(
                        x: .value("Hour", point.hourLabel),
                        y: .value("Sessions", point.count)
                    )
                    .foregroundStyle(
                        barGradient(
                            for: point.count,
                            max: maxCount,
                            baseColor: Color(hex: "34C759")
                        )
                    )
                    .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                        AxisValueLabel()
                            .foregroundStyle(Color.Orttaai.textTertiary)
                            .font(.Orttaai.caption)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.Orttaai.border.opacity(0.3))
                        AxisValueLabel {
                            if let intValue = value.as(Int.self) {
                                Text("\(intValue)")
                                    .font(.Orttaai.caption)
                                    .foregroundStyle(Color.Orttaai.textTertiary)
                            }
                        }
                    }
                }
                .frame(height: 180)
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    // MARK: - Top Apps (Words)

    private var topAppsChart: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Words by App")
                .font(.Orttaai.subheading)
                .foregroundStyle(Color.Orttaai.textPrimary)

            if viewModel.wordsByApp.isEmpty {
                emptyChartPlaceholder("No app data yet.")
            } else {
                let appColors: [Color] = [
                    Color.Orttaai.accent,
                    Color(hex: "5E9CF5"),
                    Color(hex: "34C759"),
                    Color(hex: "FF9F0A"),
                    Color(hex: "FF453A"),
                    Color(hex: "BF5AF2"),
                ]

                Chart(Array(viewModel.wordsByApp.enumerated()), id: \.element.id) { index, app in
                    BarMark(
                        x: .value("Words", app.words),
                        y: .value("App", app.name)
                    )
                    .foregroundStyle(appColors[index % appColors.count].opacity(0.8))
                    .cornerRadius(4)
                    .annotation(position: .trailing) {
                        Text(app.words.formatted())
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                            .foregroundStyle(Color.Orttaai.textSecondary)
                            .font(.Orttaai.secondary)
                    }
                }
                .chartXAxis {
                    AxisMarks(position: .bottom) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.Orttaai.border.opacity(0.3))
                    }
                }
                .frame(height: max(CGFloat(viewModel.wordsByApp.count) * 36, 120))
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    // MARK: - Duration Distribution

    private var durationDistributionChart: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Session Duration")
                .font(.Orttaai.subheading)
                .foregroundStyle(Color.Orttaai.textPrimary)

            if viewModel.durationBuckets.allSatisfy({ $0.count == 0 }) {
                emptyChartPlaceholder("No session data yet.")
            } else {
                Chart(viewModel.durationBuckets) { bucket in
                    BarMark(
                        x: .value("Duration", bucket.label),
                        y: .value("Count", bucket.count)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hex: "BF5AF2").opacity(0.7), Color(hex: "BF5AF2").opacity(0.25)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .cornerRadius(4)
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                            .foregroundStyle(Color.Orttaai.textTertiary)
                            .font(.Orttaai.caption)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.Orttaai.border.opacity(0.3))
                        AxisValueLabel {
                            if let intValue = value.as(Int.self) {
                                Text("\(intValue)")
                                    .font(.Orttaai.caption)
                                    .foregroundStyle(Color.Orttaai.textTertiary)
                            }
                        }
                    }
                }
                .frame(height: 180)
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    // MARK: - Performance Card

    private var performanceCard: some View {
        let health = viewModel.payload.performance
        let hasData = health.sampleCount > 0

        return VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text("Performance Breakdown")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Spacer()

                if hasData {
                    Text("\(health.sampleCount) samples")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textTertiary)

                    Text(health.currentModelId)
                        .font(.Orttaai.mono)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(performanceLevelLabel(health.level))
                        .font(.Orttaai.caption)
                        .foregroundStyle(performanceLevelColor(health.level))
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xs)
                        .background(performanceLevelColor(health.level).opacity(0.15))
                        .clipShape(Capsule())
                }
            }

            if !hasData {
                emptyChartPlaceholder("Not enough performance data yet.")
            } else {
                HStack(spacing: Spacing.lg) {
                    performanceMetricStack(
                        title: "Pipeline",
                        avgMs: health.averageProcessingMs,
                        p50Ms: health.processingP50Ms,
                        p95Ms: health.processingP95Ms,
                        color: Color.Orttaai.accent
                    )
                    performanceMetricStack(
                        title: "Transcription",
                        avgMs: health.averageTranscriptionMs,
                        p50Ms: health.transcriptionP50Ms,
                        p95Ms: health.transcriptionP95Ms,
                        color: Color(hex: "5E9CF5")
                    )
                    performanceMetricStack(
                        title: "Injection",
                        avgMs: health.averageInjectionMs,
                        p50Ms: health.injectionP50Ms,
                        p95Ms: health.injectionP95Ms,
                        color: Color(hex: "34C759")
                    )
                }
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    private func performanceMetricStack(
        title: String,
        avgMs: Int?,
        p50Ms: Int?,
        p95Ms: Int?,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                latencyRow("Avg", value: avgMs)
                latencyRow("P50", value: p50Ms)
                latencyRow("P95", value: p95Ms)
            }

            if let avgMs {
                GeometryReader { geo in
                    let barWidth = min(CGFloat(avgMs) / 3_000 * geo.size.width, geo.size.width)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.6), color.opacity(0.2)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(barWidth, 4), height: 6)
                }
                .frame(height: 6)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Orttaai.bgPrimary)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
    }

    private func latencyRow(_ label: String, value: Int?) -> some View {
        HStack {
            Text(label)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
                .frame(width: 28, alignment: .leading)
            Text(value.map { "\($0) ms" } ?? "—")
                .font(.Orttaai.mono)
                .foregroundStyle(Color.Orttaai.textSecondary)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func responsiveRow<Left: View, Right: View>(
        isCompact: Bool,
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right
    ) -> some View {
        if isCompact {
            VStack(spacing: Spacing.lg) {
                left()
                right()
            }
        } else {
            HStack(alignment: .top, spacing: Spacing.lg) {
                left().frame(maxWidth: .infinity)
                right().frame(maxWidth: .infinity)
            }
        }
    }

    private func emptyChartPlaceholder(_ message: String) -> some View {
        Text(message)
            .font(.Orttaai.secondary)
            .foregroundStyle(Color.Orttaai.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Spacing.xl)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textSecondary)
        }
    }

    private func barGradient(for value: Int, max: Int, baseColor: Color) -> LinearGradient {
        let intensity = max > 0 ? Double(value) / Double(max) : 0
        return LinearGradient(
            colors: [baseColor.opacity(0.3 + intensity * 0.5), baseColor.opacity(0.1 + intensity * 0.2)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func formatMinutes(_ minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let remaining = minutes % 60
        if remaining == 0 {
            return "\(hours)h"
        }
        return "\(hours)h \(remaining)m"
    }

    private func performanceLevelLabel(_ level: DashboardPerformanceLevel) -> String {
        switch level {
        case .noData: return "No Data"
        case .fast: return "Fast"
        case .normal: return "Normal"
        case .slow: return "Slow"
        }
    }

    private func performanceLevelColor(_ level: DashboardPerformanceLevel) -> Color {
        switch level {
        case .noData: return Color.Orttaai.textTertiary
        case .fast: return Color.Orttaai.success
        case .normal: return Color.Orttaai.warning
        case .slow: return Color.Orttaai.error
        }
    }
}
