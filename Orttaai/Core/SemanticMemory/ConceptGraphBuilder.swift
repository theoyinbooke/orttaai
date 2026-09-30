// ConceptGraphBuilder.swift
// Orttaai

import Foundation

/// The concepts found in one dictation, with the context the graph needs.
nonisolated struct DictationConcepts: Sendable {
    let dictationID: Int64
    let date: Date
    let appName: String?
    let concepts: [ExtractedConcept]
}

nonisolated enum ConceptTimeRange: String, CaseIterable, Identifiable, Sendable {
    case week
    case month
    case quarter
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return "7 days"
        case .month: return "30 days"
        case .quarter: return "90 days"
        case .all: return "All time"
        }
    }

    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .all: return nil
        }
    }
}

nonisolated enum ConceptTrend: String, Sendable {
    case new
    case rising
    case steady
    case fading

    var label: String? {
        switch self {
        case .new: return "New"
        case .rising: return "Rising"
        case .fading: return "Quiet lately"
        case .steady: return nil
        }
    }
}

nonisolated struct ConceptAppShare: Hashable, Sendable {
    let appName: String
    let count: Int
    let share: Double
}

nonisolated struct ConceptNode: Identifiable, Hashable, Sendable {
    let id: String
    let kind: ConceptKind
    let title: String
    /// Dictations mentioning it inside the selected range.
    let mentionCount: Int
    /// Distinct days it came up inside the selected range.
    let dayCount: Int
    let firstSeen: Date
    let lastSeen: Date
    /// Mentions in the last 7 days, and in the 4 weeks before that (all-time data).
    let recentCount: Int
    let previousCount: Int
    let trend: ConceptTrend
    let apps: [ConceptAppShare]
    /// Most recent first, capped; the evidence behind the concept.
    let dictationIDs: [Int64]
    let themeID: String?
    let salience: Double
}

nonisolated struct ConceptEdge: Identifiable, Hashable, Sendable {
    let sourceID: String
    let targetID: String
    /// Working sessions (same app, dictations within 30 minutes) that
    /// mention both.
    let sharedSessions: Int
    /// Association strength in 0...1 (Ochiai coefficient): high when the two
    /// mostly appear together, not merely when both are frequent.
    let strength: Double

    var id: String { "\(sourceID)|\(targetID)" }
}

nonisolated struct ConceptTheme: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let conceptIDs: [String]
    let mentionCount: Int
    let lastSeen: Date
}

nonisolated enum ConceptHighlightKind: String, Sendable {
    case rising
    case new
    case pair
    case person
    case fading
    case focus
}

nonisolated struct ConceptHighlight: Identifiable, Hashable, Sendable {
    let kind: ConceptHighlightKind
    let title: String
    let detail: String
    let conceptIDs: [String]

    var id: String { "\(kind.rawValue):\(conceptIDs.joined(separator: ","))" }
}

nonisolated struct ConceptGraph: Sendable {
    let range: ConceptTimeRange
    let dictationCount: Int
    let nodes: [ConceptNode]
    let edges: [ConceptEdge]
    let themes: [ConceptTheme]
    let highlights: [ConceptHighlight]
    /// Variant key → the key it was merged into ("mitumo" → "meetumo").
    var aliases: [String: String] = [:]
    let generatedAt: Date

    static func empty(range: ConceptTimeRange) -> ConceptGraph {
        ConceptGraph(range: range, dictationCount: 0, nodes: [], edges: [], themes: [], highlights: [], generatedAt: Date())
    }

    func node(id: String) -> ConceptNode? {
        nodes.first { $0.id == id }
    }

    /// Neighbors with their shared-dictation counts, strongest first.
    func related(to id: String) -> [(node: ConceptNode, edge: ConceptEdge)] {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        return edges
            .compactMap { edge -> (ConceptNode, ConceptEdge)? in
                let other = edge.sourceID == id ? edge.targetID : (edge.targetID == id ? edge.sourceID : nil)
                guard let other, let node = byID[other] else { return nil }
                return (node, edge)
            }
            .sorted {
                if $0.1.sharedSessions == $1.1.sharedSessions { return $0.1.strength > $1.1.strength }
                return $0.1.sharedSessions > $1.1.sharedSessions
            }
    }
}

/// Turns per-dictation concepts into a readable concept graph: which things
/// matter, how they connect, how they group into themes, and what changed.
/// Pure and deterministic, so it is cheap to rerun for every time range.
nonisolated enum ConceptGraphBuilder {
    struct Options {
        var maxNodes = 80
        /// Dictations in the same app this close together are one session.
        var sessionGap: TimeInterval = 30 * 60
        var maxEdgesPerNode = 6
        var minEdgeMentions = 2
        var minEdgeStrength = 0.1
        var pairConceptsPerDictation = 14
        var evidencePerConcept = 40
    }

    static func build(
        dictations: [DictationConcepts],
        range: ConceptTimeRange,
        now: Date = Date(),
        preferredKeys: Set<String> = [],
        options: Options = Options(),
        calendar: Calendar = .current
    ) -> ConceptGraph {
        let rangeStart = range.days.map { now.addingTimeInterval(-Double($0) * 86_400) }
        let inRange = dictations.filter { rangeStart == nil || $0.date >= rangeStart! }
        guard !inRange.isEmpty else { return .empty(range: range) }

        let aliasMap = aliasMap(for: dictations, preferredKeys: preferredKeys)
        let recentStart = now.addingTimeInterval(-7 * 86_400)
        let previousStart = now.addingTimeInterval(-35 * 86_400)

        // Aggregate every concept across the range; trends use all-time data.
        struct Accumulator {
            var kindVotes: [ConceptKind: Int] = [:]
            var titleVotes: [String: Int] = [:]
            var dictationIDs: [(Int64, Date)] = []
            var days = Set<Date>()
            var apps: [String: Int] = [:]
            var firstSeen = Date.distantFuture
            var lastSeen = Date.distantPast
            var recent = 0
            var previous = 0
            var allTimeFirstSeen = Date.distantFuture
        }
        var accumulators: [String: Accumulator] = [:]
        var conceptKeysBySession: [Int: Set<String>] = [:]
        let sessionByDictation = sessions(for: inRange, gap: options.sessionGap)

        for dictation in dictations {
            let isInRange = rangeStart == nil || dictation.date >= rangeStart!
            var seenInDictation = Set<String>()
            for concept in dictation.concepts {
                let key = aliasMap[concept.key] ?? concept.key
                guard seenInDictation.insert(key).inserted else { continue }
                var accumulator = accumulators[key] ?? Accumulator()
                accumulator.allTimeFirstSeen = min(accumulator.allTimeFirstSeen, dictation.date)
                if dictation.date >= recentStart {
                    accumulator.recent += 1
                } else if dictation.date >= previousStart {
                    accumulator.previous += 1
                }
                if isInRange {
                    accumulator.kindVotes[concept.kind, default: 0] += 1
                    // A merged variant's spelling ("Chargpt") never names the
                    // concept; the canonical key's own mentions do, and a
                    // dictionary spelling beats everything.
                    let weight = preferredKeys.contains(concept.key) ? 1_000 : (concept.key == key ? 10 : 1)
                    accumulator.titleVotes[concept.title, default: 0] += weight
                    accumulator.dictationIDs.append((dictation.dictationID, dictation.date))
                    accumulator.days.insert(calendar.startOfDay(for: dictation.date))
                    if let app = normalizedApp(dictation.appName) {
                        accumulator.apps[app, default: 0] += 1
                    }
                    accumulator.firstSeen = min(accumulator.firstSeen, dictation.date)
                    accumulator.lastSeen = max(accumulator.lastSeen, dictation.date)
                }
                accumulators[key] = accumulator
            }
            if isInRange, let session = sessionByDictation[dictation.dictationID] {
                conceptKeysBySession[session, default: []].formUnion(seenInDictation)
            }
        }

        let documentCount = inRange.count
        let minMentions = documentCount < 12 ? 1 : 2
        let genericShare = documentCount >= 40 ? 0.3 : 1.01

        struct Candidate {
            let key: String
            let kind: ConceptKind
            let title: String
            let accumulator: Accumulator
            let salience: Double
        }

        var candidates: [Candidate] = []
        for (key, accumulator) in accumulators {
            let mentions = accumulator.dictationIDs.count
            guard mentions >= minMentions else { continue }
            let kind = resolvedKind(accumulator.kindVotes, isSingleWord: !key.contains(" "))
            // A topic in a third of all dictations is vocabulary, not a concept.
            if kind == .topic, Double(mentions) / Double(documentCount) > genericShare { continue }
            // A lone capitalized word must recur before it counts as a name.
            if kind == .product, mentions < 2, documentCount >= 12 { continue }
            let idf = log(Double(documentCount + 1) / Double(mentions + 1)) + 1
            let recentShare = Double(accumulator.recent) / Double(max(1, mentions))
            let spread = min(1.0, Double(accumulator.days.count) / 5.0)
            // Multi-word topics ("design system") are specific; single-word
            // ones are usually vocabulary, so they rank below them.
            let specificity = kind == .topic && !key.contains(" ") ? 0.55 : 1.0
            let salience = Double(mentions) * idf * kind.rankBoost * specificity * (1 + 0.5 * recentShare) * (0.75 + 0.25 * spread)
            let title = accumulator.titleVotes.max {
                if $0.value == $1.value { return $0.key > $1.key }
                return $0.value < $1.value
            }?.key ?? key
            candidates.append(Candidate(key: key, kind: kind, title: title, accumulator: accumulator, salience: salience))
        }

        candidates.sort {
            if $0.salience == $1.salience { return $0.key < $1.key }
            return $0.salience > $1.salience
        }
        let selected = Array(candidates.prefix(options.maxNodes))
        let selectedKeys = Set(selected.map(\.key))
        let salienceByKey = Dictionary(uniqueKeysWithValues: selected.map { ($0.key, $0.salience) })

        // Co-occurrence between selected concepts, per working session: what
        // you talk about while doing one piece of work belongs together.
        var pairCounts: [String: Int] = [:]
        var sessionCounts: [String: Int] = [:]
        for keys in conceptKeysBySession.values {
            for key in keys where selectedKeys.contains(key) {
                sessionCounts[key, default: 0] += 1
            }
            let present = keys
                .filter { selectedKeys.contains($0) }
                .sorted { (salienceByKey[$0] ?? 0) > (salienceByKey[$1] ?? 0) }
                .prefix(options.pairConceptsPerDictation)
            let ordered = Array(present).sorted()
            guard ordered.count >= 2 else { continue }
            for i in 0..<(ordered.count - 1) {
                for j in (i + 1)..<ordered.count {
                    pairCounts["\(ordered[i])\u{1F}\(ordered[j])", default: 0] += 1
                }
            }
        }

        var candidateEdges: [ConceptEdge] = []
        for (pairKey, count) in pairCounts where count >= options.minEdgeMentions {
            let parts = pairKey.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, !overlaps(parts[0], parts[1]),
                  let lhs = sessionCounts[parts[0]], let rhs = sessionCounts[parts[1]] else { continue }
            let strength = Double(count) / sqrt(Double(lhs * rhs))
            guard strength >= options.minEdgeStrength else { continue }
            candidateEdges.append(ConceptEdge(sourceID: parts[0], targetID: parts[1], sharedSessions: count, strength: min(1, strength)))
        }

        // Keep each concept's strongest links so hubs don't swallow the map.
        func edgeScore(_ edge: ConceptEdge) -> Double { edge.strength * log2(1 + Double(edge.sharedSessions)) }
        var edgesByNode: [String: [ConceptEdge]] = [:]
        for edge in candidateEdges {
            edgesByNode[edge.sourceID, default: []].append(edge)
            edgesByNode[edge.targetID, default: []].append(edge)
        }
        var keptEdgeIDs = Set<String>()
        for (_, edges) in edgesByNode {
            for edge in edges.sorted(by: { edgeScore($0) > edgeScore($1) }).prefix(options.maxEdgesPerNode) {
                keptEdgeIDs.insert(edge.id)
            }
        }
        let edges = candidateEdges
            .filter { keptEdgeIDs.contains($0.id) }
            .sorted {
                if edgeScore($0) == edgeScore($1) { return $0.id < $1.id }
                return edgeScore($0) > edgeScore($1)
            }

        let themeByKey = detectThemes(keys: selected.map(\.key), salience: salienceByKey, edges: edges)
        let titleByKey = Dictionary(uniqueKeysWithValues: selected.map { ($0.key, $0.title) })

        let nodes: [ConceptNode] = selected.map { candidate in
            let accumulator = candidate.accumulator
            let mentions = accumulator.dictationIDs.count
            let apps = accumulator.apps
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(4)
                .map { ConceptAppShare(appName: $0.key, count: $0.value, share: Double($0.value) / Double(max(1, mentions))) }
            let evidence = accumulator.dictationIDs
                .sorted { $0.1 > $1.1 }
                .prefix(options.evidencePerConcept)
                .map(\.0)
            return ConceptNode(
                id: candidate.key,
                kind: candidate.kind,
                title: candidate.title,
                mentionCount: mentions,
                dayCount: accumulator.days.count,
                firstSeen: accumulator.firstSeen,
                lastSeen: accumulator.lastSeen,
                recentCount: accumulator.recent,
                previousCount: accumulator.previous,
                trend: trend(recent: accumulator.recent, previous: accumulator.previous, firstSeen: accumulator.allTimeFirstSeen, recentStart: recentStart),
                apps: Array(apps),
                dictationIDs: Array(evidence),
                themeID: themeByKey[candidate.key].map { "theme:\($0)" },
                salience: candidate.salience
            )
        }

        let themes = makeThemes(nodes: nodes, themeByKey: themeByKey, titleByKey: titleByKey)
        let themedNodes = nodes.map { node -> ConceptNode in
            // Only real themes (3+ members) keep an assignment.
            guard let themeID = node.themeID, themes.contains(where: { $0.id == themeID }) else {
                return node.withTheme(nil)
            }
            return node
        }

        let graph = ConceptGraph(
            range: range,
            dictationCount: documentCount,
            nodes: themedNodes,
            edges: edges,
            themes: themes,
            highlights: [],
            generatedAt: now
        )
        return ConceptGraph(
            range: range,
            dictationCount: documentCount,
            nodes: themedNodes,
            edges: edges,
            themes: themes,
            highlights: highlights(for: graph, now: now, calendar: calendar),
            aliases: aliasMap,
            generatedAt: now
        )
    }

    // MARK: - Aliases

    /// Merges keys that name the same thing:
    /// - speech-recognition variants of a name ("mitumo", "metumo" → "meetumo"),
    ///   preferring the user's dictionary spelling, then the most common one;
    /// - spacing variants ("chat gpt" → "chatgpt");
    /// - a short name onto the one full name it abbreviates ("sam" →
    ///   "sam rivera") when that is unambiguous.
    static func aliasMap(for dictations: [DictationConcepts], preferredKeys: Set<String> = []) -> [String: String] {
        var namedKeys: [String: ConceptKind] = [:]
        var counts: [String: Int] = [:]
        for dictation in dictations {
            for concept in dictation.concepts {
                counts[concept.key, default: 0] += 1
                guard concept.kind != .topic else { continue }
                if let existing = namedKeys[concept.key], existing.precedence >= concept.kind.precedence { continue }
                namedKeys[concept.key] = concept.kind
            }
        }

        var map: [String: String] = [:]
        func rank(_ key: String) -> (Int, Int) { (preferredKeys.contains(key) ? 1 : 0, counts[key] ?? 0) }

        // Spelling and spacing variants, bucketed by first letter. Only named
        // keys can be canonical, but any key (a mis-heard name is often tagged
        // as a topic, like "cloud code") can merge into one.
        let buckets = Dictionary(grouping: counts.keys.filter { $0.count >= 5 && (counts[$0] ?? 0) >= 1 }) { $0.first! }
        for (_, keys) in buckets {
            let ordered = keys.sorted { rank($0) == rank($1) ? $0 < $1 : rank($0) > rank($1) }
            var canonicals: [String] = []
            for key in ordered {
                let squashed = key.replacingOccurrences(of: " ", with: "")
                if let target = canonicals.first(where: { canonical in
                    let other = canonical.replacingOccurrences(of: " ", with: "")
                    if other == squashed { return true }
                    let shorter = min(other.count, squashed.count)
                    guard abs(other.count - squashed.count) <= 2, shorter >= 5 else { return false }
                    let allowed = shorter >= 6 ? 2 : 1
                    return editDistance(other, squashed, limit: allowed) <= allowed
                }) {
                    map[key] = target
                } else if namedKeys[key] != nil {
                    canonicals.append(key)
                }
            }
        }

        // Short names onto their unique full name.
        var expansions: [String: Set<String>] = [:]
        for key in namedKeys.keys where map[key] == nil {
            let tokens = key.split(separator: " ").map(String.init)
            guard tokens.count >= 2 else { continue }
            for token in [tokens.first!, tokens.last!] where token.count >= 3 {
                expansions[token, default: []].insert(key)
            }
        }
        for (short, fulls) in expansions where fulls.count == 1 && map[short] == nil {
            guard let kind = namedKeys[short], kind == .person || kind == .product else { continue }
            map[short] = fulls.first!
        }
        return map
    }

    /// Levenshtein distance, giving up early once it exceeds `limit`.
    static func editDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        let a = Array(lhs.unicodeScalars), b = Array(rhs.unicodeScalars)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    // MARK: - Sessions

    /// Groups dictations into working sessions: consecutive dictations in the
    /// same app with no more than `gap` between them.
    static func sessions(for dictations: [DictationConcepts], gap: TimeInterval) -> [Int64: Int] {
        var result: [Int64: Int] = [:]
        var lastByApp: [String: (date: Date, session: Int)] = [:]
        var nextSession = 0
        for dictation in dictations.sorted(by: { $0.date < $1.date }) {
            let app = dictation.appName ?? ""
            if let last = lastByApp[app], dictation.date.timeIntervalSince(last.date) <= gap {
                result[dictation.dictationID] = last.session
                lastByApp[app] = (dictation.date, last.session)
            } else {
                result[dictation.dictationID] = nextSession
                lastByApp[app] = (dictation.date, nextSession)
                nextSession += 1
            }
        }
        return result
    }

    // MARK: - Themes

    /// Groups concepts into themes by modularity (the Louvain method):
    /// concepts land together when they link to each other more than their
    /// overall connectedness predicts, so one busy hub cannot swallow the
    /// map. Deterministic: nodes are visited in salience order.
    static func detectThemes(keys: [String], salience: [String: Double], edges: [ConceptEdge]) -> [String: String] {
        let ordered = keys.sorted {
            let lhs = salience[$0] ?? 0, rhs = salience[$1] ?? 0
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }
        let index = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset) })
        var adjacency = Array(repeating: [Int: Double](), count: ordered.count)
        for edge in edges {
            guard let a = index[edge.sourceID], let b = index[edge.targetID], a != b else { continue }
            let weight = edge.strength * log2(1 + Double(edge.sharedSessions))
            adjacency[a][b, default: 0] += weight
            adjacency[b][a, default: 0] += weight
        }

        // membership[node] = community, refined level by level.
        var membership = Array(0..<ordered.count)
        var levelAdjacency = adjacency
        var levelMembers = (0..<ordered.count).map { [$0] }
        for _ in 0..<4 {
            let assignment = louvainLocalMoving(levelAdjacency)
            let communities = Array(Set(assignment)).sorted()
            guard communities.count < levelAdjacency.count else { break }
            let remap = Dictionary(uniqueKeysWithValues: communities.enumerated().map { ($0.element, $0.offset) })
            var nextMembers = Array(repeating: [Int](), count: communities.count)
            for (superNode, community) in assignment.enumerated() {
                let target = remap[community]!
                nextMembers[target].append(contentsOf: levelMembers[superNode])
            }
            var nextAdjacency = Array(repeating: [Int: Double](), count: communities.count)
            for (node, neighbors) in levelAdjacency.enumerated() {
                let from = remap[assignment[node]]!
                for (other, weight) in neighbors {
                    // Links inside a community become its self-loop, so the
                    // next level still counts them as internal.
                    let to = remap[assignment[other]]!
                    nextAdjacency[from][to, default: 0] += weight
                }
            }
            levelMembers = nextMembers
            levelAdjacency = nextAdjacency
        }
        for (community, members) in levelMembers.enumerated() {
            for member in members { membership[member] = community }
        }

        // Label each community by its most salient member.
        var leader: [Int: String] = [:]
        for key in ordered where leader[membership[index[key]!]] == nil {
            leader[membership[index[key]!]] = key
        }
        return Dictionary(uniqueKeysWithValues: ordered.map { ($0, leader[membership[index[$0]!]]!) })
    }

    /// One Louvain pass: move each node to the neighboring community with the
    /// largest modularity gain until nothing moves.
    private static func louvainLocalMoving(_ adjacency: [[Int: Double]], resolution: Double = 1.15) -> [Int] {
        let count = adjacency.count
        var community = Array(0..<count)
        let degree = adjacency.map { $0.values.reduce(0, +) }
        let totalWeight = degree.reduce(0, +) / 2
        guard totalWeight > 0 else { return community }
        var communityTotal = degree

        for _ in 0..<30 {
            var moved = false
            for node in 0..<count {
                let current = community[node]
                communityTotal[current] -= degree[node]
                var weightTo: [Int: Double] = [:]
                for (other, weight) in adjacency[node] where other != node {
                    weightTo[community[other], default: 0] += weight
                }
                var best = current
                var bestGain = (weightTo[current] ?? 0) - resolution * communityTotal[current] * degree[node] / (2 * totalWeight)
                for (candidate, weight) in weightTo.sorted(by: { $0.key < $1.key }) {
                    let gain = weight - resolution * communityTotal[candidate] * degree[node] / (2 * totalWeight)
                    if gain > bestGain + 1e-12 {
                        best = candidate
                        bestGain = gain
                    }
                }
                community[node] = best
                communityTotal[best] += degree[node]
                if best != current { moved = true }
            }
            if !moved { break }
        }
        return community
    }

    private static func makeThemes(
        nodes: [ConceptNode],
        themeByKey: [String: String],
        titleByKey: [String: String]
    ) -> [ConceptTheme] {
        let grouped = Dictionary(grouping: nodes) { themeByKey[$0.id] ?? $0.id }
        return grouped
            .compactMap { (label, members) -> ConceptTheme? in
                guard members.count >= 3 else { return nil }
                let ranked = members.sorted { $0.salience > $1.salience }
                let title = ranked.prefix(2).map(\.title).joined(separator: " · ")
                return ConceptTheme(
                    id: "theme:\(label)",
                    title: title,
                    conceptIDs: ranked.map(\.id),
                    mentionCount: members.reduce(0) { $0 + $1.mentionCount },
                    lastSeen: members.map(\.lastSeen).max() ?? .distantPast
                )
            }
            .sorted {
                if $0.mentionCount == $1.mentionCount { return $0.id < $1.id }
                return $0.mentionCount > $1.mentionCount
            }
    }

    // MARK: - Trend

    static func trend(recent: Int, previous: Int, firstSeen: Date, recentStart: Date) -> ConceptTrend {
        let weeklyBaseline = Double(previous) / 4.0
        if firstSeen >= recentStart && recent >= 2 { return .new }
        if recent >= 4 && Double(recent) >= 2.5 * max(1, weeklyBaseline) { return .rising }
        if previous >= 6 && recent == 0 { return .fading }
        return .steady
    }

    // MARK: - Highlights

    /// The few findings worth reading first, in order of how surprising they
    /// usually are. Each names the concepts it is about so the UI can focus them.
    static func highlights(for graph: ConceptGraph, now: Date, calendar: Calendar) -> [ConceptHighlight] {
        var result: [ConceptHighlight] = []
        let nodes = graph.nodes

        if let rising = nodes
            .filter({ $0.trend == .rising })
            .max(by: { risingScore($0) < risingScore($1) }) {
            let weekly = Double(rising.previousCount) / 4
            let baseline = weekly < 1 ? "barely at all before" : "up from about \(Int(weekly.rounded())) a week"
            result.append(ConceptHighlight(
                kind: .rising,
                title: "\(rising.title) is heating up",
                detail: "\(rising.recentCount) mentions this week, \(baseline).",
                conceptIDs: [rising.id]
            ))
        }

        if let fresh = nodes
            .filter({ $0.trend == .new })
            .max(by: { $0.recentCount < $1.recentCount }) {
            result.append(ConceptHighlight(
                kind: .new,
                title: "New this week: \(fresh.title)",
                detail: "First came up \(relativeDay(fresh.firstSeen, now: now, calendar: calendar)), and \(fresh.recentCount) times since.",
                conceptIDs: [fresh.id]
            ))
        }

        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        if let pair = graph.edges
            .filter({ edge in
                edge.strength >= 0.25 && edge.sharedSessions >= 3 && !overlaps(edge.sourceID, edge.targetID)
                    && [edge.sourceID, edge.targetID].contains { isSpecific(byID[$0]) }
            })
            .max(by: { ($0.sharedSessions, $0.strength) < ($1.sharedSessions, $1.strength) }),
           let lhs = byID[pair.sourceID], let rhs = byID[pair.targetID] {
            result.append(ConceptHighlight(
                kind: .pair,
                title: "\(lhs.title) and \(rhs.title) go together",
                detail: "They come up in the same working session \(pair.sharedSessions) times.",
                conceptIDs: [lhs.id, rhs.id]
            ))
        }

        if let person = nodes
            .filter({ $0.kind == .person && $0.mentionCount >= 3 })
            .max(by: { $0.mentionCount < $1.mentionCount }) {
            result.append(ConceptHighlight(
                kind: .person,
                title: "\(person.title) comes up most",
                detail: "Mentioned in \(person.mentionCount) dictations across \(person.dayCount) day\(person.dayCount == 1 ? "" : "s").",
                conceptIDs: [person.id]
            ))
        }

        if let fading = nodes
            .filter({ $0.trend == .fading })
            .max(by: { $0.previousCount < $1.previousCount }) {
            result.append(ConceptHighlight(
                kind: .fading,
                title: "\(fading.title) has gone quiet",
                detail: "\(fading.previousCount) mentions in the weeks before, none in the last 7 days.",
                conceptIDs: [fading.id]
            ))
        }

        if let focused = nodes
            .filter({ $0.mentionCount >= 5 && ($0.apps.first?.share ?? 0) >= 0.75 && $0.kind != .topic })
            .max(by: { $0.mentionCount < $1.mentionCount }),
           let app = focused.apps.first {
            result.append(ConceptHighlight(
                kind: .focus,
                title: "\(focused.title) lives in \(app.appName)",
                detail: "\(Int((app.share * 100).rounded()))% of its mentions happen while dictating in \(app.appName).",
                conceptIDs: [focused.id]
            ))
        }

        return Array(result.prefix(4))
    }

    /// A named thing or a multi-word topic, rather than one generic word.
    static func isSpecific(_ node: ConceptNode?) -> Bool {
        guard let node else { return false }
        return node.kind != .topic || node.id.contains(" ")
    }

    /// "design" and "design system" co-occur by construction; that pairing
    /// is not a finding.
    static func overlaps(_ lhs: String, _ rhs: String) -> Bool {
        let left = Set(lhs.split(separator: " "))
        let right = Set(rhs.split(separator: " "))
        return !left.isDisjoint(with: right)
    }

    private static func risingScore(_ node: ConceptNode) -> Double {
        Double(node.recentCount + 1) / (Double(node.previousCount) / 4 + 1)
    }

    static func relativeDay(_ date: Date, now: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        default:
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return "on \(formatter.string(from: date))"
        }
    }

    // MARK: - Helpers

    private static func resolvedKind(_ votes: [ConceptKind: Int], isSingleWord: Bool) -> ConceptKind {
        let total = votes.values.reduce(0, +)
        let named = votes.filter { $0.key != .topic }
        // Named when enough mentions tag it as a name. ASR and NER are
        // inconsistent, so a multi-word name needs a third; a single word
        // needs most, or ordinary words capitalized once ("Icon") pass.
        let threshold = isSingleWord ? 0.5 : 1.0 / 3.0
        if let best = named.max(by: { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.precedence < rhs.key.precedence : lhs.value < rhs.value
        }), Double(named.values.reduce(0, +)) >= Double(total) * threshold {
            return best.key
        }
        return .topic
    }

    private static func normalizedApp(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }
}

nonisolated private extension ConceptNode {
    func withTheme(_ themeID: String?) -> ConceptNode {
        ConceptNode(
            id: id, kind: kind, title: title, mentionCount: mentionCount, dayCount: dayCount,
            firstSeen: firstSeen, lastSeen: lastSeen, recentCount: recentCount, previousCount: previousCount,
            trend: trend, apps: apps, dictationIDs: dictationIDs, themeID: themeID, salience: salience
        )
    }
}
