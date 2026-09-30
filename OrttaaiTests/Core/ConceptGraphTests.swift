// ConceptGraphTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class ConceptExtractorTests: XCTestCase {
    func testFindsMidSentenceProperNamesAndSkipsSentenceStarts() {
        let names = ConceptExtractor.properNames(in: "Today we deployed Orttaai to Vercel. Then we checked the logs.")
        XCTAssertTrue(names.contains("Orttaai"))
        XCTAssertTrue(names.contains("Vercel"))
        XCTAssertFalse(names.contains("Today"))
        XCTAssertFalse(names.contains("Then"))
    }

    func testPhraseMakesItsWordsRedundant() {
        let concepts = ConceptExtractor.concepts(in: "The design system needs work. The design system tokens and the design system colors.")
        let keys = Set(concepts.map(\.key))
        XCTAssertTrue(keys.contains { $0.contains(" ") && $0.contains("design") }, "\(keys)")
        XCTAssertFalse(keys.contains("design"))
        XCTAssertFalse(keys.contains("system"))
    }

    func testGenericNounsAreNotConcepts() {
        let concepts = ConceptExtractor.concepts(in: "Move the button on the page and change the text on the card.")
        let keys = Set(concepts.map(\.key))
        for generic in ["button", "page", "text", "card"] {
            XCTAssertFalse(keys.contains(generic), "\(generic) should be vocabulary, not a concept")
        }
    }

    func testTrimsTaggerFragmentsFromNames() {
        XCTAssertEqual(ConceptExtractor.trimmedName("Twitter it"), "Twitter")
        XCTAssertEqual(ConceptExtractor.trimmedName("MCP can"), "MCP")
        XCTAssertEqual(ConceptExtractor.trimmedName("Groq g r o q"), "Groq")
        XCTAssertNil(ConceptExtractor.trimmedName("what"))
    }

    func testNormalizedKeyMergesCaseAndAppSuffix() {
        XCTAssertEqual(ConceptExtractor.normalizedKey("Meetumo app", kind: .product), "meetumo")
        XCTAssertEqual(ConceptExtractor.normalizedKey("Meetumo's", kind: .product), "meetumo")
        XCTAssertEqual(ConceptExtractor.normalizedKey("Mobile App", kind: .topic), "mobile app")
    }

    func testDictionaryTermsBecomeNamedConcepts() {
        let matcher = DictionaryTermMatcher(terms: ["groq"])
        let merged = matcher.merging(into: [], text: "We switched the endpoint to groq today.")
        XCTAssertEqual(merged.first?.key, "groq")
        XCTAssertEqual(merged.first?.title, "Groq")
        XCTAssertEqual(merged.first?.kind, .product)
        XCTAssertTrue(matcher.merging(into: [], text: "The groqish thing").isEmpty)
    }
}

final class ConceptGraphBuilderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func concept(_ key: String, _ kind: ConceptKind = .product, title: String? = nil) -> ExtractedConcept {
        ExtractedConcept(key: key, title: title ?? key.capitalized, kind: kind)
    }

    private func dictation(_ id: Int64, daysAgo: Double, minutes: Double = 0, app: String = "Code", _ concepts: [ExtractedConcept]) -> DictationConcepts {
        DictationConcepts(
            dictationID: id,
            date: now.addingTimeInterval(-daysAgo * 86_400 + minutes * 60),
            appName: app,
            concepts: concepts
        )
    }

    func testMergesSpellingVariantsIntoPreferredSpelling() {
        let dictations = [
            dictation(1, daysAgo: 1, [concept("meetumo")]),
            dictation(2, daysAgo: 2, [concept("mitumo")]),
            dictation(3, daysAgo: 3, [concept("metumo")]),
            dictation(4, daysAgo: 4, [concept("metumo")])
        ]
        let aliases = ConceptGraphBuilder.aliasMap(for: dictations, preferredKeys: ["meetumo"])
        XCTAssertEqual(aliases["mitumo"], "meetumo")
        XCTAssertEqual(aliases["metumo"], "meetumo")
        XCTAssertNil(aliases["meetumo"])
    }

    func testDoesNotMergeDifferentShortNames() {
        let dictations = [
            dictation(1, daysAgo: 1, [concept("claude", .person)]),
            dictation(2, daysAgo: 2, [concept("cloud", .topic)])
        ]
        XCTAssertNil(ConceptGraphBuilder.aliasMap(for: dictations)["cloud"])
    }

    func testMergedConceptUsesCanonicalTitle() {
        var dictations: [DictationConcepts] = []
        for id in 1...6 {
            dictations.append(dictation(Int64(id), daysAgo: Double(id), [concept("chargpt", title: "Chargpt")]))
        }
        dictations.append(dictation(7, daysAgo: 7, [concept("chatgpt", title: "ChatGPT")]))
        let graph = ConceptGraphBuilder.build(dictations: dictations, range: .all, now: now, preferredKeys: ["chatgpt"])
        let node = graph.node(id: "chatgpt")
        XCTAssertEqual(node?.title, "ChatGPT")
        XCTAssertEqual(node?.mentionCount, 7)
    }

    func testSessionsGroupSameAppDictationsCloseInTime() {
        let dictations = [
            dictation(1, daysAgo: 1, minutes: 0, app: "Code", []),
            dictation(2, daysAgo: 1, minutes: 10, app: "Code", []),
            dictation(3, daysAgo: 1, minutes: 12, app: "Mail", []),
            dictation(4, daysAgo: 1, minutes: 90, app: "Code", [])
        ]
        let sessions = ConceptGraphBuilder.sessions(for: dictations, gap: 30 * 60)
        XCTAssertEqual(sessions[1], sessions[2])
        XCTAssertNotEqual(sessions[1], sessions[3])
        XCTAssertNotEqual(sessions[1], sessions[4])
    }

    func testLinksConceptsThatShareSessionsAndSkipsOverlaps() {
        var dictations: [DictationConcepts] = []
        for day in 0..<4 {
            dictations.append(dictation(Int64(day * 10 + 1), daysAgo: Double(day), [concept("orttaai"), concept("design system", .topic)]))
            dictations.append(dictation(Int64(day * 10 + 2), daysAgo: Double(day), minutes: 5, [concept("vercel"), concept("design", .topic)]))
        }
        let graph = ConceptGraphBuilder.build(dictations: dictations, range: .all, now: now)
        let pairs = Set(graph.edges.map { Set([$0.sourceID, $0.targetID]) })
        XCTAssertTrue(pairs.contains(["orttaai", "vercel"]), "Concepts in the same working session are linked")
        XCTAssertFalse(pairs.contains(["design", "design system"]), "A phrase and its own word are not a finding")
    }

    func testThemesSeparateUnrelatedClusters() {
        var dictations: [DictationConcepts] = []
        var id: Int64 = 0
        for day in 0..<6 {
            id += 1
            dictations.append(dictation(id, daysAgo: Double(day), app: "Code", [concept("orttaai"), concept("whisper"), concept("xcode")]))
            id += 1
            dictations.append(dictation(id, daysAgo: Double(day), minutes: 240, app: "Mail", [concept("maria", .person), concept("garden", .topic), concept("lisbon", .place)]))
        }
        let graph = ConceptGraphBuilder.build(dictations: dictations, range: .all, now: now)
        let themeOf = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.themeID) })
        XCTAssertNotNil(themeOf["orttaai"] ?? nil)
        XCTAssertEqual(themeOf["orttaai"], themeOf["xcode"])
        XCTAssertEqual(themeOf["maria"], themeOf["lisbon"])
        XCTAssertNotEqual(themeOf["orttaai"], themeOf["maria"])
    }

    func testTrendClassification() {
        let recentStart = now.addingTimeInterval(-7 * 86_400)
        XCTAssertEqual(ConceptGraphBuilder.trend(recent: 3, previous: 0, firstSeen: now.addingTimeInterval(-86_400), recentStart: recentStart), .new)
        XCTAssertEqual(ConceptGraphBuilder.trend(recent: 8, previous: 4, firstSeen: .distantPast, recentStart: recentStart), .rising)
        XCTAssertEqual(ConceptGraphBuilder.trend(recent: 0, previous: 9, firstSeen: .distantPast, recentStart: recentStart), .fading)
        XCTAssertEqual(ConceptGraphBuilder.trend(recent: 2, previous: 8, firstSeen: .distantPast, recentStart: recentStart), .steady)
    }

    func testBuildIsDeterministic() {
        var dictations: [DictationConcepts] = []
        for id in 1...30 {
            dictations.append(dictation(Int64(id), daysAgo: Double(id % 9), minutes: Double(id), [
                concept(["orttaai", "vercel", "xcode", "meetumo"][id % 4]),
                concept(["maria", "sam"][id % 2], .person)
            ]))
        }
        let first = ConceptGraphBuilder.build(dictations: dictations, range: .all, now: now)
        let second = ConceptGraphBuilder.build(dictations: dictations, range: .all, now: now)
        XCTAssertEqual(first.nodes.map(\.id), second.nodes.map(\.id))
        XCTAssertEqual(first.edges.map(\.id), second.edges.map(\.id))
        XCTAssertEqual(first.themes.map(\.id), second.themes.map(\.id))
    }

    func testEditDistanceStopsEarly() {
        XCTAssertEqual(ConceptGraphBuilder.editDistance("meetumo", "metumo", limit: 2), 1)
        XCTAssertEqual(ConceptGraphBuilder.editDistance("chatgpt", "chargpt", limit: 2), 1)
        XCTAssertGreaterThan(ConceptGraphBuilder.editDistance("orttaai", "vercel", limit: 2), 2)
    }
}
