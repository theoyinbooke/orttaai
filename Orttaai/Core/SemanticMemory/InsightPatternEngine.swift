// InsightPatternEngine.swift
// Orttaai

import Foundation

/// Deterministic pattern mining over the semantic memory corpus. Every finding
/// it emits is computed — never guessed — and carries evidence chunk IDs and a
/// confidence derived from sample size. Language models downstream may rephrase
/// these findings; they never originate them.
enum InsightPatternEngine {

    struct ActivitySample: Sendable {
        let createdAt: Date
        let wordCount: Int
        let recordingMs: Int
        let appName: String?
    }

    struct Input: Sendable {
        let activity: [ActivitySample]
        let graph: SemanticMemoryGraph
        /// sourceCreatedAt per chunkID for temporal analysis of concepts.
        let chunkDates: [Int64: Date]
        let signals: [SemanticSignalWithContext]
        let now: Date
        var calendar: Calendar = .current
    }

    static func computedKinds() -> [InsightFindingKind] {
        [.lifeArea, .rhythm, .emergingTheme, .fadingTheme, .resurfacingTheme,
         .openCommitment, .openQuestion, .anomaly]
    }

    static func computeFindings(_ input: Input) -> [InsightFindingDraft] {
        var findings: [InsightFindingDraft] = []
        findings.append(contentsOf: rhythmFindings(input))
        findings.append(contentsOf: lifeAreaFindings(input))
        findings.append(contentsOf: trajectoryFindings(input))
        findings.append(contentsOf: commitmentFindings(input))
        findings.append(contentsOf: questionFindings(input))
        findings.append(contentsOf: anomalyFindings(input))
        return findings
    }

    // MARK: - Rhythms

    private static func rhythmFindings(_ input: Input) -> [InsightFindingDraft] {
        let samples = input.activity
        guard samples.count >= 12 else { return [] }

        var countByHour: [Int: Int] = [:]
        var wpmByHour: [Int: [Double]] = [:]
        for sample in samples {
            let hour = input.calendar.component(.hour, from: sample.createdAt)
            countByHour[hour, default: 0] += 1
            if sample.recordingMs > 2_000, sample.wordCount > 4 {
                let wpm = Double(sample.wordCount) / (Double(sample.recordingMs) / 60_000)
                wpmByHour[hour, default: []].append(wpm)
            }
        }

        var findings: [InsightFindingDraft] = []

        // Peak activity window: best contiguous 3-hour block (wrapping).
        let total = samples.count
        var bestStart = 0
        var bestCount = -1
        for start in 0..<24 {
            let count = (0..<3).reduce(0) { $0 + (countByHour[(start + $1) % 24] ?? 0) }
            if count > bestCount {
                bestCount = count
                bestStart = start
            }
        }
        let share = Double(bestCount) / Double(total)
        if share >= 0.3 {
            let endHour = (bestStart + 3) % 24
            findings.append(InsightFindingDraft(
                kind: .rhythm,
                subjectKey: "peak-hours",
                title: "Your voice peaks \(hourLabel(bestStart))–\(hourLabel(endHour))",
                detail: "\(Int((share * 100).rounded()))% of your \(total) dictations happen between \(hourLabel(bestStart)) and \(hourLabel(endHour)). That window is when you think out loud the most.",
                magnitude: share,
                confidence: confidenceFromSamples(total),
                windowStart: samples.map(\.createdAt).min(),
                windowEnd: samples.map(\.createdAt).max(),
                evidenceChunkIDs: []
            ))
        }

        // Fluency peak: hour bucket with ≥5 samples whose median WPM beats the
        // overall median by ≥15%.
        let allWPM = wpmByHour.values.flatMap { $0 }
        if allWPM.count >= 10, let overallMedian = median(allWPM) {
            let qualified = wpmByHour
                .filter { $0.value.count >= 5 }
                .compactMap { hour, values -> (hour: Int, median: Double)? in
                    guard let m = median(values) else { return nil }
                    return (hour, m)
                }
            if let best = qualified.max(by: { $0.median < $1.median }),
               best.median >= overallMedian * 1.15 {
                let lift = Int(((best.median / overallMedian - 1) * 100).rounded())
                findings.append(InsightFindingDraft(
                    kind: .rhythm,
                    subjectKey: "fluency-peak",
                    title: "You speak \(lift)% faster around \(hourLabel(best.hour))",
                    detail: "Median dictation speed around \(hourLabel(best.hour)) is \(Int(best.median.rounded())) WPM vs your overall \(Int(overallMedian.rounded())) WPM — a fluency peak worth protecting for hard thinking.",
                    magnitude: best.median / overallMedian,
                    confidence: confidenceFromSamples(allWPM.count),
                    windowStart: nil,
                    windowEnd: nil,
                    evidenceChunkIDs: []
                ))
            }
        }

        return findings
    }

    // MARK: - Life areas (community detection)

    private static func lifeAreaFindings(_ input: Input) -> [InsightFindingDraft] {
        let graph = input.graph
        guard graph.nodes.count >= 12 else { return [] }

        // Label propagation over the whole graph (chunks included so concepts
        // connect through shared evidence), deterministic iteration order.
        var labels: [String: String] = [:]
        var adjacency: [String: [(neighbor: String, weight: Double)]] = [:]
        for node in graph.nodes {
            labels[node.nodeID] = node.nodeID
        }
        for edge in graph.edges {
            adjacency[edge.sourceNodeID, default: []].append((edge.targetNodeID, edge.weight))
            adjacency[edge.targetNodeID, default: []].append((edge.sourceNodeID, edge.weight))
        }

        let orderedNodeIDs = graph.nodes.map(\.nodeID).sorted()
        for _ in 0..<6 {
            var changed = false
            for nodeID in orderedNodeIDs {
                guard let neighbors = adjacency[nodeID], !neighbors.isEmpty else { continue }
                var weightByLabel: [String: Double] = [:]
                for (neighbor, weight) in neighbors {
                    if let label = labels[neighbor] {
                        weightByLabel[label, default: 0] += weight
                    }
                }
                // Deterministic tie-break by label name.
                if let winner = weightByLabel.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key,
                   winner != labels[nodeID] {
                    labels[nodeID] = winner
                    changed = true
                }
            }
            if !changed { break }
        }

        let nodesByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.nodeID, $0) })
        var communities: [String: [SemanticGraphNode]] = [:]
        for (nodeID, label) in labels {
            guard let node = nodesByID[nodeID] else { continue }
            communities[label, default: []].append(node)
        }

        let totalChunks = max(1, graph.nodes.filter { $0.kind == "chunk" }.count)
        let ranked = communities.values
            .map { members -> (members: [SemanticGraphNode], chunkCount: Int) in
                (members, members.filter { $0.kind == "chunk" }.count)
            }
            .filter { $0.chunkCount >= 3 && $0.members.contains { $0.kind != "chunk" } }
            .sorted { $0.chunkCount > $1.chunkCount }
            .prefix(4)

        return ranked.compactMap { community in
            let concepts = community.members
                .filter { $0.kind == "topic" || $0.kind == "entity" }
                .sorted { $0.weight > $1.weight }
            let apps = community.members.filter { $0.kind == "app" }.sorted { $0.weight > $1.weight }
            guard let anchor = concepts.first ?? apps.first else { return nil }

            let conceptNames = concepts.prefix(3).map(\.title)
            let appNames = apps.prefix(2).map(\.title)
            let share = Double(community.chunkCount) / Double(totalChunks)
            let chunkIDs = community.members
                .filter { $0.kind == "chunk" }
                .compactMap { Int64($0.nodeID.replacingOccurrences(of: "chunk:", with: "")) }
                .sorted()

            var detailParts: [String] = []
            if !conceptNames.isEmpty {
                detailParts.append("Centers on \(conceptNames.joined(separator: ", "))")
            }
            if !appNames.isEmpty {
                detailParts.append("lives in \(appNames.joined(separator: " and "))")
            }
            detailParts.append("\(Int((share * 100).rounded()))% of your indexed dictation")

            return InsightFindingDraft(
                kind: .lifeArea,
                subjectKey: "area:\(anchor.nodeID)",
                title: conceptNames.first.map { "Life area: \($0)" } ?? "Life area: \(anchor.title)",
                detail: detailParts.joined(separator: " · ") + ".",
                magnitude: share,
                confidence: confidenceFromSamples(community.chunkCount),
                windowStart: nil,
                windowEnd: nil,
                evidenceChunkIDs: Array(chunkIDs.prefix(8))
            )
        }
    }

    // MARK: - Trajectories

    private static func trajectoryFindings(_ input: Input) -> [InsightFindingDraft] {
        // Concept → dated mentions, via topic/entity edges to chunks.
        let nodesByID = Dictionary(uniqueKeysWithValues: input.graph.nodes.map { ($0.nodeID, $0) })
        var mentionsByConcept: [String: [(chunkID: Int64, date: Date)]] = [:]

        for edge in input.graph.edges where edge.kind == "mentions" || edge.kind == "entity" {
            let (conceptID, chunkNodeID): (String, String)
            if edge.sourceNodeID.hasPrefix("chunk:") {
                (conceptID, chunkNodeID) = (edge.targetNodeID, edge.sourceNodeID)
            } else {
                (conceptID, chunkNodeID) = (edge.sourceNodeID, edge.targetNodeID)
            }
            guard let chunkID = Int64(chunkNodeID.replacingOccurrences(of: "chunk:", with: "")),
                  let date = input.chunkDates[chunkID] else { continue }
            mentionsByConcept[conceptID, default: []].append((chunkID, date))
        }

        let recentWindow: TimeInterval = 14 * 86_400
        let weekWindow: TimeInterval = 7 * 86_400
        var findings: [InsightFindingDraft] = []

        for (conceptID, mentions) in mentionsByConcept.sorted(by: { $0.key < $1.key }) {
            guard mentions.count >= 3, let concept = nodesByID[conceptID] else { continue }
            let dates = mentions.map(\.date).sorted()
            let recent = mentions.filter { input.now.timeIntervalSince($0.date) <= recentWindow }
            let older = mentions.filter {
                let age = input.now.timeIntervalSince($0.date)
                return age > recentWindow && age <= recentWindow * 2
            }
            let evidence = Array(mentions.sorted { $0.date > $1.date }.map(\.chunkID).prefix(6))

            if recent.count >= 3, recent.count >= older.count * 2, older.count <= 1 {
                findings.append(InsightFindingDraft(
                    kind: .emergingTheme,
                    subjectKey: conceptID,
                    title: "\(concept.title) is taking off",
                    detail: "\(recent.count) mentions in the last two weeks vs \(older.count) before — a new thread is forming.",
                    magnitude: Double(recent.count),
                    confidence: confidenceFromSamples(recent.count),
                    windowStart: dates.first,
                    windowEnd: dates.last,
                    evidenceChunkIDs: evidence
                ))
            } else if older.count >= 3, recent.isEmpty {
                findings.append(InsightFindingDraft(
                    kind: .fadingTheme,
                    subjectKey: conceptID,
                    title: "\(concept.title) went quiet",
                    detail: "Active with \(older.count) mentions, then nothing in two weeks. Finished — or abandoned?",
                    magnitude: Double(older.count),
                    confidence: confidenceFromSamples(older.count),
                    windowStart: dates.first,
                    windowEnd: dates.last,
                    evidenceChunkIDs: evidence
                ))
            } else if dates.count >= 3 {
                // Resurfacing: mentioned, silent ≥7 days, back within last week.
                let lastGap = zip(dates.dropFirst(), dates).map { $0.timeIntervalSince($1) }.max() ?? 0
                let lastMention = dates.last ?? input.now
                if lastGap >= weekWindow, input.now.timeIntervalSince(lastMention) <= weekWindow {
                    findings.append(InsightFindingDraft(
                        kind: .resurfacingTheme,
                        subjectKey: conceptID,
                        title: "\(concept.title) is back",
                        detail: "It went silent for \(Int(lastGap / 86_400)) days and resurfaced this week — recurring loops like this are usually unfinished business.",
                        magnitude: lastGap / 86_400,
                        confidence: confidenceFromSamples(dates.count),
                        windowStart: dates.first,
                        windowEnd: dates.last,
                        evidenceChunkIDs: evidence
                    ))
                }
            }
        }

        return findings
            .sorted { $0.magnitude > $1.magnitude }
            .prefix(6)
            .map { $0 }
    }

    // MARK: - Commitments & questions

    private static func commitmentFindings(_ input: Input) -> [InsightFindingDraft] {
        let commitments = input.signals
            .filter { $0.signal.family == SemanticSignalFamily.commitment.rawValue }
            .filter { input.now.timeIntervalSince($0.sourceCreatedAt) <= 30 * 86_400 }
            .sorted { $0.sourceCreatedAt > $1.sourceCreatedAt }

        var seen: Set<String> = []
        var findings: [InsightFindingDraft] = []

        for commitment in commitments {
            let dedupKey = commitment.signal.value.lowercased().prefix(60).description
            guard !seen.contains(dedupKey) else { continue }
            seen.insert(dedupKey)

            // Resolution heuristic: a later chunk that mentions the same
            // most-salient concept and carries a completion cue closes the
            // loop. Matching only the top concept keeps incidental words
            // ("tonight", "team") from blocking resolution.
            let topConcept = distinctiveWords(in: commitment.signal.value).first
            let resolved = input.signals.contains { later in
                guard later.sourceCreatedAt > commitment.sourceCreatedAt,
                      let topConcept else { return false }
                let laterText = later.chunkText.lowercased()
                return completionCues.contains(where: laterText.contains)
                    && laterText.contains(topConcept)
            }
            guard !resolved else { continue }

            let ageDays = max(0, Int(input.now.timeIntervalSince(commitment.sourceCreatedAt) / 86_400))
            findings.append(InsightFindingDraft(
                kind: .openCommitment,
                subjectKey: "commitment:\(commitment.signal.chunkID):\(dedupKey.hashValue & 0xFFFF)",
                title: ageDays == 0 ? "Said today" : "Said \(ageDays) day\(ageDays == 1 ? "" : "s") ago",
                detail: "“\(commitment.signal.value)”" + (commitment.targetAppName.map { " — in \($0)" } ?? ""),
                magnitude: Double(ageDays),
                confidence: commitment.signal.confidence,
                windowStart: commitment.sourceCreatedAt,
                windowEnd: commitment.sourceCreatedAt,
                evidenceChunkIDs: [commitment.signal.chunkID]
            ))
            if findings.count >= 6 { break }
        }
        return findings
    }

    private static func questionFindings(_ input: Input) -> [InsightFindingDraft] {
        let questions = input.signals
            .filter { $0.signal.family == SemanticSignalFamily.question.rawValue }
            .filter { $0.signal.confidence >= 0.9 }
            .filter { input.now.timeIntervalSince($0.sourceCreatedAt) <= 14 * 86_400 }
            .sorted { $0.sourceCreatedAt > $1.sourceCreatedAt }

        var seen: Set<String> = []
        var findings: [InsightFindingDraft] = []
        for question in questions {
            let dedupKey = question.signal.value.lowercased().prefix(60).description
            guard !seen.contains(dedupKey) else { continue }
            seen.insert(dedupKey)
            findings.append(InsightFindingDraft(
                kind: .openQuestion,
                subjectKey: "question:\(question.signal.chunkID):\(dedupKey.hashValue & 0xFFFF)",
                title: "Still open?",
                detail: "“\(question.signal.value)”" + (question.targetAppName.map { " — asked in \($0)" } ?? ""),
                magnitude: input.now.timeIntervalSince(question.sourceCreatedAt) / 86_400,
                confidence: question.signal.confidence,
                windowStart: question.sourceCreatedAt,
                windowEnd: question.sourceCreatedAt,
                evidenceChunkIDs: [question.signal.chunkID]
            ))
            if findings.count >= 4 { break }
        }
        return findings
    }

    // MARK: - Anomalies

    private static func anomalyFindings(_ input: Input) -> [InsightFindingDraft] {
        let calendar = input.calendar
        let today = calendar.startOfDay(for: input.now)
        var dailyCounts: [Date: Int] = [:]
        for sample in input.activity {
            dailyCounts[calendar.startOfDay(for: sample.createdAt), default: 0] += 1
        }

        let baselineDays = (1...28).compactMap { offset -> Int? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return dailyCounts[day]
        }
        guard baselineDays.count >= 7 else { return [] }

        let todayCount = dailyCounts[today] ?? 0
        let mean = Double(baselineDays.reduce(0, +)) / Double(baselineDays.count)
        let variance = baselineDays.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(baselineDays.count)
        let std = sqrt(variance)
        guard std > 0.5, mean >= 1 else { return [] }

        let z = (Double(todayCount) - mean) / std
        guard abs(z) >= 2, todayCount >= 3 || z < 0 else { return [] }

        let direction = z > 0 ? "far above" : "well below"
        return [InsightFindingDraft(
            kind: .anomaly,
            subjectKey: "volume:today",
            title: z > 0 ? "Unusually vocal today" : "Unusually quiet today",
            detail: "\(todayCount) dictations today vs your ~\(Int(mean.rounded()))/day norm — \(direction) baseline.",
            magnitude: abs(z),
            confidence: confidenceFromSamples(baselineDays.count),
            windowStart: today,
            windowEnd: input.now,
            evidenceChunkIDs: []
        )]
    }

    // MARK: - Helpers

    private static func hourLabel(_ hour: Int) -> String {
        let normalized = ((hour % 24) + 24) % 24
        switch normalized {
        case 0: return "12am"
        case 12: return "12pm"
        case 1...11: return "\(normalized)am"
        default: return "\(normalized - 12)pm"
        }
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Confidence grows with evidence and saturates — never certainty from a
    /// handful of samples.
    private static func confidenceFromSamples(_ count: Int) -> Double {
        min(0.95, 0.35 + 0.06 * Double(count))
    }

    private static func distinctiveWords(in sentence: String) -> [String] {
        SemanticTextAnalyzer.topicConcepts(in: sentence, limit: 2).map(\.key)
    }

    private static let completionCues = [
        "done", "finished", "completed", "fixed", "shipped", "resolved",
        "works now", "working now", "it worked", "that worked", "solved"
    ]
}
