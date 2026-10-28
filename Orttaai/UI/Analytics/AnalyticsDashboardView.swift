// AnalyticsDashboardView.swift
// Orttaai

import SwiftUI
import Charts
import GRDB
import os

// MARK: - View Model

nonisolated enum AnalyticsTimeRange: String, CaseIterable, Identifiable {
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
    /// The device group every card counts, apart from Performance (always
    /// this Mac's) and By Device.
    private(set) var deviceFilter: DictationDeviceFilter = .all
    /// All, plus each device group the archive has dictations from.
    private(set) var availableDeviceFilters: [DictationDeviceFilter] = [.all]
    /// Every device's words and dictations in the range.
    private(set) var deviceBreakdown: [DeviceBreakdownRow] = []
    private(set) var payload: DashboardStatsPayload = .empty
    private(set) var trendPoints: [DashboardTrendPoint] = []
    private(set) var hourlyActivity: [HourlyActivityPoint] = []
    private(set) var durationBuckets: [DurationBucket] = []
    private(set) var wordsByApp: [AppWordCount] = []
    private(set) var weekdayActivity: [WeekdayActivityPoint] = []
    /// Seconds spoken on each day of `trendPoints`, in the same order.
    private(set) var dailyActiveSeconds: [Int] = []
    private(set) var medianDurationMs: Int?
    private(set) var totalSessions: Int = 0
    private(set) var totalWords: Int = 0
    private(set) var totalRecordingMinutes: Int = 0
    private(set) var activeDays: Int = 0
    private(set) var averageWPM: Int = 0
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    var errorMessage: String?

    private var observation: DatabaseCancellable?
    private let makeDatabase: () throws -> DatabaseManager
    /// Opened by the first load and kept.
    private var database: DatabaseManager?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0

    init(settings: AppSettings, makeDatabase: @escaping () throws -> DatabaseManager = { try DatabaseManager() }) {
        self.settings = settings
        self.makeDatabase = makeDatabase
    }

    convenience init() {
        self.init(settings: AppSettings())
    }

    func load() {
        if database == nil {
            do {
                let db = try makeDatabase()
                database = db
                var isFirstCall = true
                observation = DashboardStatsService(databaseManager: db).observeChanges { [weak self] in
                    // The first call is the archive as it is now, which the
                    // load below reads anyway: refreshing for it too worked
                    // the whole dashboard out twice on every open.
                    guard !isFirstCall else {
                        isFirstCall = false
                        return
                    }
                    Task { @MainActor in
                        self?.refresh()
                    }
                }
            } catch {
                errorMessage = "Failed to load analytics."
                Logger.database.error("Analytics load error: \(error.localizedDescription)")
                return
            }
        }
        refresh()
    }

    /// Works the numbers out again away from the main thread, which reading
    /// every dictation and counting its words froze for 0.3 s on each open
    /// and click (0.6 s for All Time), and shows them in one update. One
    /// refresh runs at a time, one still waiting when a newer one starts is
    /// skipped, and an older refresh's numbers never replace a newer one's.
    func refresh(animated: Bool = false) {
        guard let database else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let range = selectedRange
        let filter = deviceFilter
        let modelID = currentModelID()
        let previous = refreshTask
        isLoading = true
        refreshTask = Task { [weak self] in
            await previous?.value
            guard let self, generation == self.refreshGeneration else { return }
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try AnalyticsDashboardSnapshot.load(
                        from: database,
                        range: range,
                        deviceFilter: filter,
                        currentModelId: modelID
                    )
                }
            }.value
            guard generation == self.refreshGeneration else { return }
            self.isLoading = false
            switch result {
            case .success(let snapshot):
                if animated {
                    // As the picker that asked for it does.
                    withAnimation(.easeOut(duration: 0.16)) { self.show(snapshot) }
                } else {
                    self.show(snapshot)
                }
                self.hasLoaded = true
                self.errorMessage = nil
            case .failure(let error):
                self.errorMessage = self.hasLoaded ? "Failed to refresh analytics." : "Failed to load analytics."
                Logger.database.error("Analytics load error: \(error.localizedDescription)")
            }
        }
    }

    /// Waits until the numbers asked for so far are shown, including any
    /// refresh started meanwhile (for tests).
    func waitForRefresh() async {
        while let task = refreshTask {
            await task.value
            if refreshTask == task { return }
        }
    }

    func setDeviceFilter(_ filter: DictationDeviceFilter) {
        guard deviceFilter != filter else { return }
        deviceFilter = filter
        refresh(animated: true)
    }

    func setSelectedRange(_ range: AnalyticsTimeRange) {
        guard selectedRange != range else { return }
        selectedRange = range
        refresh(animated: true)
    }

    private func show(_ snapshot: AnalyticsDashboardSnapshot) {
        availableDeviceFilters = snapshot.availableDeviceFilters
        deviceFilter = snapshot.deviceFilter
        deviceBreakdown = snapshot.deviceBreakdown
        payload = snapshot.payload
        trendPoints = snapshot.trendPoints
        dailyActiveSeconds = snapshot.dailyActiveSeconds
        hourlyActivity = snapshot.hourlyActivity
        weekdayActivity = snapshot.weekdayActivity
        durationBuckets = snapshot.durationBuckets
        wordsByApp = snapshot.wordsByApp
        medianDurationMs = snapshot.medianDurationMs
        totalSessions = snapshot.totalSessions
        totalWords = snapshot.totalWords
        totalRecordingMinutes = snapshot.totalRecordingMinutes
        activeDays = snapshot.activeDays
        averageWPM = snapshot.averageWPM
    }

    private func currentModelID() -> String? {
        settings.dictationModelIDForDisplay
    }

    func cancelObservation() {
        observation?.cancel()
        observation = nil
    }
}

/// Everything the dashboard shows for one range and device group, worked
/// out from the archive away from the main thread.
nonisolated struct AnalyticsDashboardSnapshot: Sendable {
    var availableDeviceFilters: [DictationDeviceFilter] = [.all]
    /// The group asked for, or All when the archive has none of its dictations.
    var deviceFilter: DictationDeviceFilter = .all
    var deviceBreakdown: [DeviceBreakdownRow] = []
    var payload: DashboardStatsPayload = .empty
    var trendPoints: [DashboardTrendPoint] = []
    var dailyActiveSeconds: [Int] = []
    var hourlyActivity: [HourlyActivityPoint] = []
    var weekdayActivity: [WeekdayActivityPoint] = []
    var durationBuckets: [DurationBucket] = []
    var wordsByApp: [AppWordCount] = []
    var medianDurationMs: Int?
    var totalSessions = 0
    var totalWords = 0
    var totalRecordingMinutes = 0
    var activeDays = 0
    var averageWPM = 0

    static func load(
        from db: DatabaseManager,
        range: AnalyticsTimeRange,
        deviceFilter requested: DictationDeviceFilter,
        currentModelId: String?
    ) throws -> AnalyticsDashboardSnapshot {
        var snapshot = AnalyticsDashboardSnapshot()
        let devices = try db.fetchDictationDevices()
        let present = Set(try db.fetchDictationDeviceSources().map { devices.filter(deviceID: $0.deviceID, kind: $0.kind) })
        snapshot.availableDeviceFilters = DictationDeviceFilter.allCases.filter { $0 == .all || present.contains($0) }
        let filter = snapshot.availableDeviceFilters.contains(requested) ? requested : .all
        snapshot.deviceFilter = filter

        snapshot.payload = try DashboardStatsService(databaseManager: db).load(currentModelId: currentModelId, deviceFilter: filter)
        let records = try fetchAnalyticsRecords(from: db, range: range)
        snapshot.deviceBreakdown = DashboardStatsService.deviceBreakdown(from: records, devices: devices)
        snapshot.computeExtendedMetrics(
            from: filter == .all ? records : records.filter { devices.filter(for: $0) == filter },
            range: range
        )
        return snapshot
    }

    private static func fetchAnalyticsRecords(from db: DatabaseManager, range: AnalyticsTimeRange) throws -> [Transcription] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? Date()

        guard let dayCount = range.dayCount else {
            return try db.fetchAllTranscriptions()
        }

        let start = calendar.date(
            byAdding: .day,
            value: -(dayCount - 1),
            to: todayStart
        ) ?? todayStart
        return try db.fetchTranscriptions(from: start, to: tomorrowStart)
    }

    private mutating func computeExtendedMetrics(from records: [Transcription], range: AnalyticsTimeRange) {
        totalSessions = records.count
        totalWords = records.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        let totalRecordingMs = records.reduce(0) { $0 + max(0, $1.recordingDurationMs) }
        totalRecordingMinutes = Int((Double(totalRecordingMs) / 60_000).rounded())
        averageWPM = calculateWPM(words: totalWords, recordingMs: totalRecordingMs)

        // Hourly activity
        let calendar = Calendar.current
        activeDays = Set(records.map { calendar.startOfDay(for: $0.createdAt) }).count
        trendPoints = makeTrendPoints(from: records, calendar: calendar, range: range)

        // The hour and weekday it was where each dictation was said, when
        // its time zone is known: 9 a.m. on a trip is still 9 a.m.
        var calendarsByZone: [String: Calendar] = [:]
        func localCalendar(for record: Transcription) -> Calendar {
            guard let identifier = record.timeZoneIdentifier, identifier != calendar.timeZone.identifier else { return calendar }
            if let cached = calendarsByZone[identifier] { return cached }
            var local = calendar
            if let zone = TimeZone(identifier: identifier) { local.timeZone = zone }
            calendarsByZone[identifier] = local
            return local
        }

        var countByHour = [Int: Int]()
        for record in records {
            let hour = localCalendar(for: record).component(.hour, from: record.createdAt)
            countByHour[hour, default: 0] += 1
        }
        hourlyActivity = (0..<24).map { hour in
            HourlyActivityPoint(hour: hour, count: countByHour[hour, default: 0])
        }

        // Weekdays, starting on the calendar's first day of the week
        var countByWeekday = [Int: Int]()
        for record in records {
            countByWeekday[localCalendar(for: record).component(.weekday, from: record.createdAt), default: 0] += 1
        }
        weekdayActivity = (0..<7).map { offset in
            let weekday = (calendar.firstWeekday - 1 + offset) % 7 + 1
            return WeekdayActivityPoint(
                weekday: weekday,
                shortName: calendar.shortWeekdaySymbols[weekday - 1],
                name: calendar.weekdaySymbols[weekday - 1],
                sessions: countByWeekday[weekday, default: 0]
            )
        }

        let durations = records.map { max(0, $0.recordingDurationMs) }.sorted()
        medianDurationMs = durations.isEmpty ? nil : durations[durations.count / 2]

        // Duration buckets
        let bucketDefs: [(String, String, Int)] = [
            ("<5s", "under 5 seconds", 5_000),
            ("5–15s", "5 to 15 seconds", 15_000),
            ("15–30s", "15 to 30 seconds", 30_000),
            ("30s–1m", "30 seconds to a minute", 60_000),
            ("1–2m", "1 to 2 minutes", 120_000),
            ("2–5m", "2 to 5 minutes", 300_000),
            ("5m+", "over 5 minutes", Int.max),
        ]
        var counts = Array(repeating: 0, count: bucketDefs.count)
        for record in records {
            let ms = max(0, record.recordingDurationMs)
            var prevMax = 0
            for (index, def) in bucketDefs.enumerated() {
                if ms >= prevMax && (ms < def.2 || index == bucketDefs.count - 1) {
                    counts[index] += 1
                    break
                }
                prevMax = def.2
            }
        }
        durationBuckets = bucketDefs.enumerated().map { index, def in
            DurationBucket(label: def.0, phrase: def.1, count: counts[index], order: index)
        }

        // Words by app
        var appWords = [String: Int]()
        for record in records {
            // Phone dictations have no app (iOS doesn't tell a keyboard):
            // they count as "Orttakey on iPhone".
            let appName = record.displayAppName ?? "Unknown"
            appWords[appName, default: 0] += record.text.split(whereSeparator: \.isWhitespace).count
        }
        wordsByApp = appWords
            .map { AppWordCount(name: $0.key, words: $0.value) }
            .sorted { $0.words > $1.words }
            .prefix(5)
            .map { $0 }
    }

    private mutating func makeTrendPoints(
        from records: [Transcription],
        calendar: Calendar,
        range: AnalyticsTimeRange
    ) -> [DashboardTrendPoint] {
        let todayStart = calendar.startOfDay(for: Date())
        let startDay: Date

        if let dayCount = range.dayCount {
            startDay = calendar.date(
                byAdding: .day,
                value: -(dayCount - 1),
                to: todayStart
            ) ?? todayStart
        } else if let oldestDate = records.map(\.createdAt).min() {
            startDay = calendar.startOfDay(for: oldestDate)
        } else {
            dailyActiveSeconds = []
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

        let days = (0...daySpan).compactMap { calendar.date(byAdding: .day, value: $0, to: startDay) }
        dailyActiveSeconds = days.map { aggregatesByDay[$0, default: (0, 0, 0)].recordingMs / 1_000 }
        return days.map { day in
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
}

// MARK: - Data Models

nonisolated struct HourlyActivityPoint: Identifiable {
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

nonisolated struct DurationBucket: Identifiable {
    let label: String
    /// How the bucket reads in a sentence ("5 to 15 seconds").
    let phrase: String
    let count: Int
    let order: Int
    var id: String { label }
}

nonisolated struct WeekdayActivityPoint: Identifiable {
    /// Calendar weekday, 1 = Sunday.
    let weekday: Int
    let shortName: String
    let name: String
    let sessions: Int
    var id: Int { weekday }
}

nonisolated struct AppWordCount: Identifiable {
    let name: String
    let words: Int
    var id: String { name }
}

// MARK: - Dashboard View

/// The Analytics dashboard: a row of totals, the trend, when and where you
/// dictate, and how fast it runs. The range is picked in the page header.
struct AnalyticsDashboardView: View {
    let range: AnalyticsTimeRange
    @State private var viewModel: AnalyticsDashboardViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @MainActor
    init(range: AnalyticsTimeRange, viewModel: AnalyticsDashboardViewModel? = nil) {
        self.range = range
        _viewModel = State(initialValue: viewModel ?? AnalyticsDashboardViewModel())
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(showsIndicators: false) {
                // Drawn once the numbers, worked out in the background, are
                // in: before them it read as an archive with nothing in it.
                if viewModel.hasLoaded || viewModel.errorMessage != nil {
                    AnalyticsDashboardContent(
                        range: range,
                        viewModel: viewModel,
                        isCompact: proxy.size.width < 760
                    )
                    .padding(.horizontal, WorkspaceLayout.contentHorizontalPadding)
                    .padding(.bottom, Spacing.lg)
                    .transition(reduceMotion ? .identity : .opacity)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: viewModel.hasLoaded)
        .onAppear {
            if !viewModel.hasLoaded {
                viewModel.selectedRange = range
                viewModel.load()
            }
        }
        .onChange(of: range) { _, newRange in
            viewModel.setSelectedRange(newRange)
        }
        .onDisappear {
            viewModel.cancelObservation()
        }
    }
}

/// The dashboard's cards, top to bottom.
struct AnalyticsDashboardContent: View {
    let range: AnalyticsTimeRange
    let viewModel: AnalyticsDashboardViewModel
    let isCompact: Bool
    @State private var hoveredWeekday: String?
    @State private var hoveredHour: String?

    private let chartHeight: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.error)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(Color.Orttaai.errorSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
            }

            if viewModel.availableDeviceFilters.count > 2 {
                deviceFilterBar
            }

            summaryCards

            TrendCardView(
                title: range.trendTitle,
                points: viewModel.trendPoints,
                showsLegend: !isCompact,
                axisTickCount: range.axisTickCount,
                emptyMessage: "No activity in this range yet."
            )

            if viewModel.deviceFilter == .all, viewModel.deviceBreakdown.count > 1 {
                deviceCard
            }

            pairedRow {
                weekdayCard
            } right: {
                hourCard
            }

            pairedRow {
                appsCard
            } right: {
                durationCard
            }

            performanceCard
        }
    }

    // MARK: - Devices

    /// Shown once dictations come from more than one kind of device.
    private var deviceFilterBar: some View {
        HStack(spacing: Spacing.sm) {
            Text("Showing")
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
            HeaderSegmentedPicker(
                options: viewModel.availableDeviceFilters,
                selection: Binding(get: { viewModel.deviceFilter }, set: { viewModel.setDeviceFilter($0) }),
                title: \.title,
                accessibilityTitle: "Device"
            )
            Spacer(minLength: 0)
        }
    }

    private var deviceCard: some View {
        let devices = viewModel.deviceBreakdown
        let total = max(1, devices.reduce(0) { $0 + $1.words })

        return analyticsCard(title: "By Device", detail: "\(devices.count) devices") {
            if let top = devices.first {
                headline(
                    "\(top.name) has the most words",
                    detail: "\(percent(top.words, of: total)) of your words in this range"
                )
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(devices) { device in
                    deviceRow(device, share: Double(device.words) / Double(total))
                }
            }
        }
    }

    private func deviceRow(_ device: DeviceBreakdownRow, share: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: DeviceLabel.symbol(kindName: device.kindName))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .frame(width: 16)
                Text(device.name)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .lineLimit(1)
                Text(device.dictations == 1 ? "1 dictation" : "\(device.dictations.formatted()) dictations")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: Spacing.sm)
                Text(device.words.formatted())
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .monospacedDigit()
                Text("\(Int((share * 100).rounded()))%")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.Orttaai.textTertiary.opacity(0.15))
                    Capsule()
                        .fill(Color.Orttaai.accent.opacity(device.isThisMac ? 1 : 0.55))
                        .frame(width: max(4, geometry.size.width * share))
                }
            }
            .frame(height: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(device.name), \(device.words) words in \(device.dictations) dictations, \(Int((share * 100).rounded())) percent")
    }

    // MARK: - Summary

    private var summaryCards: some View {
        let today = viewModel.payload.today
        return DashboardBalancedCardGrid(itemCount: 4, minimumColumnWidth: 200) {
            summaryMetric(
                title: "Words",
                value: viewModel.totalWords.formatted(),
                detail: wordsDetail,
                icon: "character.cursor.ibeam",
                series: viewModel.trendPoints.map(\.words)
            )
            summaryMetric(
                title: "Sessions",
                value: viewModel.totalSessions.formatted(),
                detail: "\(today.sessions.formatted()) today",
                icon: "waveform",
                series: viewModel.trendPoints.map(\.sessions)
            )
            summaryMetric(
                title: "Active Time",
                value: formatMinutes(viewModel.totalRecordingMinutes, hasSessions: viewModel.totalSessions > 0),
                detail: "\(formatMinutes(today.activeMinutes, hasSessions: today.sessions > 0)) today",
                icon: "timer",
                series: viewModel.dailyActiveSeconds
            )
            summaryMetric(
                title: "Avg WPM",
                value: viewModel.averageWPM > 0 ? viewModel.averageWPM.formatted() : "–",
                detail: viewModel.activeDays == 1 ? "over 1 active day" : "over \(viewModel.activeDays.formatted()) active days",
                icon: "speedometer",
                // Quiet days have no speed, so they'd only draw dips.
                series: viewModel.trendPoints.filter { $0.sessions > 0 }.map(\.averageWPM)
            )
        }
    }

    private var wordsDetail: String {
        guard viewModel.activeDays > 0 else { return "No dictation yet" }
        return "\((viewModel.totalWords / viewModel.activeDays).formatted()) per active day"
    }

    /// Icon and title, then the number with a sparkline of the range beside
    /// it: one compact card, four to a row.
    private func summaryMetric(
        title: String,
        value: String,
        detail: String,
        icon: String,
        series: [Int]
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.Orttaai.accent)
                    .frame(width: 22, height: 22)
                    .background(Color.Orttaai.accentSubtle, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .lineLimit(1)
            }

            HStack(alignment: .bottom, spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(value)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.Orttaai.textPrimary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .contentTransition(.numericText())
                    Text(detail)
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                        .lineLimit(1)
                }
                .layoutPriority(1)

                Spacer(minLength: Spacing.sm)

                AnalyticsSparkline(values: series)
                    .frame(width: 84, height: 30)
                    .padding(.bottom, 3)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value), \(detail)")
    }

    // MARK: - When

    private var weekdayCard: some View {
        let days = viewModel.weekdayActivity
        let total = days.reduce(0) { $0 + $1.sessions }
        let busiest = days.max { $0.sessions < $1.sessions }
        let focus = days.first { $0.shortName == hoveredWeekday } ?? busiest

        return analyticsCard(title: "Weekly Rhythm", detail: "Sessions by weekday") {
            if total == 0 {
                emptyChartPlaceholder("No sessions in this range yet.")
            } else {
                if let focus {
                    headline(
                        focus.id == busiest?.id && hoveredWeekday == nil ? "Busiest on \(focus.name)s" : focus.name,
                        detail: "\(sessionCount(focus.sessions)) · \(percent(focus.sessions, of: total)) of the range"
                    )
                }

                Chart(days) { day in
                    BarMark(
                        x: .value("Day", day.shortName),
                        y: .value("Sessions", day.sessions)
                    )
                    .foregroundStyle(day.id == focus?.id ? Color.Orttaai.accent : Color.Orttaai.accent.opacity(0.3))
                    .cornerRadius(4)
                    .annotation(position: .top, spacing: 3) {
                        if day.sessions > 0 {
                            Text(day.sessions.formatted())
                                .font(.Orttaai.caption)
                                .foregroundStyle(Color.Orttaai.textTertiary)
                        }
                    }
                }
                .chartXSelection(value: $hoveredWeekday)
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                    }
                }
                .frame(height: chartHeight)
                .accessibilityLabel("Sessions by weekday")
            }
        }
    }

    private var hourCard: some View {
        let hours = viewModel.hourlyActivity
        let total = hours.reduce(0) { $0 + $1.count }
        let peak = hours.max { $0.count < $1.count }
        let focus = hours.first { $0.hourLabel == hoveredHour } ?? peak

        return analyticsCard(title: "Time of Day", detail: "Sessions by hour") {
            if total == 0 {
                emptyChartPlaceholder("No sessions in this range yet.")
            } else {
                if let focus {
                    headline(
                        hoveredHour == nil ? "Most active around \(hourName(focus.hour))" : "\(hourName(focus.hour)) to \(hourName((focus.hour + 1) % 24))",
                        detail: "\(sessionCount(focus.count)) · \(percent(focus.count, of: total)) of the range"
                    )
                }

                Chart(hours) { point in
                    BarMark(
                        x: .value("Hour", point.hourLabel),
                        y: .value("Sessions", point.count)
                    )
                    .foregroundStyle(point.id == focus?.id ? Color.Orttaai.accent : Color.Orttaai.accent.opacity(point.count > 0 ? 0.3 : 0.12))
                    .cornerRadius(2)
                }
                .chartXSelection(value: $hoveredHour)
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks { value in
                        // Every sixth hour, so the labels breathe.
                        if let label = value.as(String.self), ["12a", "6a", "12p", "6p"].contains(label) {
                            AxisValueLabel()
                                .font(.Orttaai.caption)
                                .foregroundStyle(Color.Orttaai.textTertiary)
                        }
                    }
                }
                .frame(height: chartHeight)
                .accessibilityLabel("Sessions by hour of day")
            }
        }
    }

    // MARK: - What and how long

    private var appsCard: some View {
        let apps = viewModel.wordsByApp
        let total = max(1, viewModel.totalWords)

        return analyticsCard(title: "Words by App", detail: "Top \(max(1, apps.count))") {
            if apps.isEmpty {
                emptyChartPlaceholder("No app data yet.")
            } else {
                if let top = apps.first {
                    headline(
                        "\(top.name) gets the most",
                        detail: "\(percent(top.words, of: total)) of your words in this range"
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        appRow(app, share: Double(app.words) / Double(total), rank: index)
                    }
                }
            }
        }
    }

    private func appRow(_ app: AppWordCount, share: Double, rank: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Spacing.sm) {
                Text(app.name)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: Spacing.sm)
                Text(app.words.formatted())
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .monospacedDigit()
                Text("\(Int((share * 100).rounded()))%")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.Orttaai.textTertiary.opacity(0.15))
                    Capsule()
                        .fill(Color.Orttaai.accent.opacity(max(0.35, 1 - Double(rank) * 0.16)))
                        .frame(width: max(4, geometry.size.width * share))
                }
            }
            .frame(height: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(app.name), \(app.words) words, \(Int((share * 100).rounded())) percent")
    }

    private var durationCard: some View {
        let buckets = viewModel.durationBuckets
        let total = buckets.reduce(0) { $0 + $1.count }
        let common = buckets.max { $0.count < $1.count }

        return analyticsCard(title: "Session Length", detail: "How long you speak") {
            if total == 0 {
                emptyChartPlaceholder("No session data yet.")
            } else {
                if let common {
                    headline(
                        "Most last \(common.phrase)",
                        detail: viewModel.medianDurationMs.map { "Median \(formatDuration($0)) · \(sessionCount(total))" } ?? sessionCount(total)
                    )
                }

                Chart(buckets) { bucket in
                    BarMark(
                        x: .value("Length", bucket.label),
                        y: .value("Sessions", bucket.count)
                    )
                    .foregroundStyle(bucket.id == common?.id ? Color.Orttaai.accent : Color.Orttaai.accent.opacity(0.3))
                    .cornerRadius(4)
                    .annotation(position: .top, spacing: 3) {
                        if bucket.count > 0 {
                            Text(bucket.count.formatted())
                                .font(.Orttaai.caption)
                                .foregroundStyle(Color.Orttaai.textTertiary)
                        }
                    }
                }
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                    }
                }
                .frame(height: chartHeight)
                .accessibilityLabel("Sessions by length")
            }
        }
    }

    // MARK: - Performance

    private var performanceCard: some View {
        let health = viewModel.payload.performance
        let hasData = health.sampleCount > 0
        // One scale for all three, so their bars compare.
        let scale = max(1, [
            health.processingP95Ms, health.averageProcessingMs,
            health.transcriptionP95Ms, health.textProcessingP95Ms, health.injectionP95Ms,
        ].compactMap { $0 }.max() ?? 1)

        return VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text("Performance")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Spacer(minLength: Spacing.sm)

                if hasData {
                    // Always this Mac's speed: say so once other devices dictate too.
                    Text("\(viewModel.availableDeviceFilters.count > 2 ? "This Mac · " : "")\(health.sampleCount == 1 ? "Last dictation" : "Last \(health.sampleCount.formatted()) dictations") · \(ModelManager.formatDisplayName(health.currentModelId))")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(health.currentModelId)
                }

                Text(performanceLevelLabel(health.level))
                    .font(.Orttaai.caption)
                    .foregroundStyle(performanceLevelColor(health.level))
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 2)
                    .background(performanceLevelColor(health.level).opacity(0.15), in: Capsule())
            }

            if !hasData {
                emptyChartPlaceholder("Timings appear after your first dictation.")
            } else {
                HStack(spacing: Spacing.sm) {
                    latencyColumn(
                        "Total",
                        average: health.averageProcessingMs,
                        p50: health.processingP50Ms,
                        p95: health.processingP95Ms,
                        scale: scale,
                        color: Color.Orttaai.accent
                    )
                    latencyColumn(
                        "Transcribe",
                        average: health.averageTranscriptionMs,
                        p50: health.transcriptionP50Ms,
                        p95: health.transcriptionP95Ms,
                        scale: scale,
                        color: Color.Orttaai.accent.opacity(0.7)
                    )
                    latencyColumn(
                        "Rules & polish",
                        average: health.averageTextProcessingMs,
                        p50: health.textProcessingP50Ms,
                        p95: health.textProcessingP95Ms,
                        scale: scale,
                        color: Color.Orttaai.textTertiary.opacity(0.6)
                    )
                    latencyColumn(
                        "Insert",
                        average: health.averageInjectionMs,
                        p50: health.injectionP50Ms,
                        p95: health.injectionP95Ms,
                        scale: scale,
                        color: Color.Orttaai.accent.opacity(0.45)
                    )
                }
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    /// The average as the number and the solid bar; the slowest 5% (p95)
    /// as the faint bar behind it.
    private func latencyColumn(
        _ title: String,
        average: Int?,
        p50: Int?,
        p95: Int?,
        scale: Int,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(average.map { $0.formatted() } ?? "–")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .monospacedDigit()
                Text("ms avg")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.Orttaai.textTertiary.opacity(0.15))
                    if let p95 {
                        Capsule()
                            .fill(color.opacity(0.3))
                            .frame(width: geometry.size.width * min(1, CGFloat(p95) / CGFloat(scale)))
                    }
                    if let average {
                        Capsule()
                            .fill(color)
                            .frame(width: max(4, geometry.size.width * min(1, CGFloat(average) / CGFloat(scale))))
                    }
                }
            }
            .frame(height: 6)

            Text(percentileLine(p50: p50, p95: p95))
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Orttaai.bgPrimary.opacity(0.7), in: RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .help("\(title): the solid bar is the average, the faint one the slowest 5% (p95)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): average \(average.map { "\($0) milliseconds" } ?? "no data"). \(percentileLine(p50: p50, p95: p95)).")
    }

    private func percentileLine(p50: Int?, p95: Int?) -> String {
        let typical = p50.map { "typical \($0.formatted()) ms" } ?? "typical –"
        let slow = p95.map { "slowest \($0.formatted()) ms" } ?? "slowest –"
        return "\(typical) · \(slow)"
    }

    // MARK: - Building blocks

    /// Title and a quiet caption on one line, then the card's content; fills
    /// its row so paired cards match in height.
    private func analyticsCard<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text(title)
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Spacer(minLength: Spacing.sm)
                Text(detail)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .lineLimit(1)
            }
            content()
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dashboardCard()
    }

    /// The one thing the chart below says, in words.
    private func headline(_ text: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .lineLimit(1)
                .contentTransition(.opacity)
            Text(detail)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func pairedRow<Left: View, Right: View>(
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right
    ) -> some View {
        if isCompact {
            VStack(spacing: Spacing.md) {
                left()
                right()
            }
        } else {
            HStack(alignment: .top, spacing: Spacing.md) {
                left()
                right()
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func emptyChartPlaceholder(_ message: String) -> some View {
        Text(message)
            .font(.Orttaai.secondary)
            .foregroundStyle(Color.Orttaai.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Spacing.xl)
    }

    private func sessionCount(_ count: Int) -> String {
        count == 1 ? "1 session" : "\(count.formatted()) sessions"
    }

    private func percent(_ part: Int, of total: Int) -> String {
        guard total > 0 else { return "0%" }
        return "\(Int((Double(part) / Double(total) * 100).rounded()))%"
    }

    private func hourName(_ hour: Int) -> String {
        switch hour {
        case 0: return "12 am"
        case 12: return "12 pm"
        case 1..<12: return "\(hour) am"
        default: return "\(hour - 12) pm"
        }
    }

    private func formatDuration(_ ms: Int) -> String {
        let seconds = Int((Double(ms) / 1_000).rounded())
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder == 0 ? "\(minutes) min" : "\(minutes) min \(remainder) s"
    }

    /// Dictations shorter than a minute still count as time spent.
    private func formatMinutes(_ minutes: Int, hasSessions: Bool) -> String {
        if minutes == 0 {
            return hasSessions ? "<1m" : "0m"
        }
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

/// A small area line of a range's daily values, for the summary cards. Long
/// ranges are averaged into at most 45 points so the shape stays readable.
private struct AnalyticsSparkline: View {
    let values: [Int]

    private var points: [Double] {
        let limit = 45
        guard values.count > limit else { return values.map(Double.init) }
        let size = Double(values.count) / Double(limit)
        return (0..<limit).map { index in
            let chunk = values[Int(Double(index) * size)..<min(values.count, Int(Double(index + 1) * size))]
            return chunk.isEmpty ? 0 : Double(chunk.reduce(0, +)) / Double(chunk.count)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let values = points
            let peak = max(1, values.max() ?? 1)
            let inset: CGFloat = 1.5
            let height = geometry.size.height - inset * 2
            let line = values.enumerated().map { index, value in
                CGPoint(
                    x: values.count > 1 ? geometry.size.width * CGFloat(index) / CGFloat(values.count - 1) : geometry.size.width,
                    y: inset + height * (1 - CGFloat(value / peak))
                )
            }

            if line.count >= 2, values.contains(where: { $0 > 0 }) {
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: line[0].x, y: geometry.size.height))
                        line.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: line[line.count - 1].x, y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [Color.Orttaai.accent.opacity(0.28), Color.Orttaai.accent.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    Path { path in
                        path.addLines(line)
                    }
                    .stroke(Color.Orttaai.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            } else {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geometry.size.height - inset))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height - inset))
                }
                .stroke(Color.Orttaai.textTertiary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct DashboardBalancedCardGrid<Content: View>: View {
    let itemCount: Int
    let minimumColumnWidth: CGFloat
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(
        itemCount: Int,
        minimumColumnWidth: CGFloat,
        spacing: CGFloat = Spacing.md,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.itemCount = itemCount
        self.minimumColumnWidth = minimumColumnWidth
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        DashboardBalancedGridLayout(
            itemCount: itemCount,
            minimumColumnWidth: minimumColumnWidth,
            spacing: spacing
        ) {
            content()
        }
    }
}

private struct DashboardBalancedGridLayout: Layout {
    let itemCount: Int
    let minimumColumnWidth: CGFloat
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? requiredWidth(for: max(1, resolvedItemCount(subviews)))
        let columnCount = columnCount(for: width, subviews: subviews)
        let itemWidth = itemWidth(for: width, columns: columnCount)
        let rowHeights = rowHeights(for: subviews, columns: columnCount, itemWidth: itemWidth)
        let totalSpacing = spacing * CGFloat(max(0, rowHeights.count - 1))

        return CGSize(width: width, height: rowHeights.reduce(0, +) + totalSpacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columnCount = columnCount(for: bounds.width, subviews: subviews)
        let itemWidth = itemWidth(for: bounds.width, columns: columnCount)
        let rowHeights = rowHeights(for: subviews, columns: columnCount, itemWidth: itemWidth)
        var y = bounds.minY

        for row in 0..<rowHeights.count {
            let rowStart = row * columnCount
            let rowEnd = min(rowStart + columnCount, subviews.count)

            for index in rowStart..<rowEnd {
                let column = index - rowStart
                let x = bounds.minX + CGFloat(column) * (itemWidth + spacing)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: itemWidth, height: rowHeights[row])
                )
            }

            y += rowHeights[row] + spacing
        }
    }

    private func columnCount(for width: CGFloat, subviews: Subviews) -> Int {
        let count = max(1, resolvedItemCount(subviews))
        let options = (1...count).filter { count % $0 == 0 }.sorted(by: >)
        return options.first { requiredWidth(for: $0) <= width } ?? 1
    }

    private func resolvedItemCount(_ subviews: Subviews) -> Int {
        subviews.isEmpty ? itemCount : subviews.count
    }

    private func requiredWidth(for columns: Int) -> CGFloat {
        CGFloat(columns) * minimumColumnWidth + CGFloat(max(0, columns - 1)) * spacing
    }

    private func itemWidth(for width: CGFloat, columns: Int) -> CGFloat {
        let totalSpacing = spacing * CGFloat(max(0, columns - 1))
        return max(1, (width - totalSpacing) / CGFloat(max(1, columns)))
    }

    private func rowHeights(for subviews: Subviews, columns: Int, itemWidth: CGFloat) -> [CGFloat] {
        guard !subviews.isEmpty else { return [] }

        let rowCount = Int(ceil(Double(subviews.count) / Double(max(1, columns))))
        var heights = Array(repeating: CGFloat.zero, count: rowCount)

        for index in subviews.indices {
            let row = index / max(1, columns)
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: itemWidth, height: nil))
            heights[row] = max(heights[row], size.height)
        }

        return heights
    }
}
