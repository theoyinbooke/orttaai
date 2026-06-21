// SemanticMemoryRecord.swift
// Orttaai

import Foundation
import GRDB

struct SemanticChunkDraft: Sendable {
    let transcriptionID: Int64
    let chunkIndex: Int
    let text: String
    let textHash: String
    let sourceCreatedAt: Date
    let targetAppName: String?
    let targetAppBundleID: String?
    let wordCount: Int
}

struct SemanticChunk: Codable, Identifiable, FetchableRecord, PersistableRecord, Sendable {
    var id: Int64?
    var transcriptionID: Int64
    var chunkIndex: Int
    var text: String
    var textHash: String
    var sourceCreatedAt: Date
    var targetAppName: String?
    var targetAppBundleID: String?
    var wordCount: Int
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "semantic_chunk"
}

struct SemanticEmbedding: Codable, Identifiable, FetchableRecord, PersistableRecord, Sendable {
    var id: Int64?
    var chunkID: Int64
    var modelID: String
    var providerName: String
    var dimension: Int
    var vectorData: Data
    var generatedAt: Date

    static let databaseTableName = "semantic_embedding"
}

struct SemanticEmbeddedChunk: Sendable, Identifiable {
    let chunkID: Int64
    let transcriptionID: Int64
    let chunkIndex: Int
    let text: String
    let textHash: String
    let sourceCreatedAt: Date
    let targetAppName: String?
    let targetAppBundleID: String?
    let wordCount: Int
    let modelID: String
    let providerName: String
    let dimension: Int
    let vectorData: Data

    var id: Int64 { chunkID }
}

struct SemanticGraphNode: Codable, Identifiable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    var nodeID: String
    var kind: String
    var title: String
    var subtitle: String?
    var weight: Double
    var lastSeenAt: Date?
    var updatedAt: Date

    static let databaseTableName = "semantic_graph_node"
    var id: String { nodeID }
}

struct SemanticGraphEdge: Codable, Identifiable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    var id: Int64?
    var sourceNodeID: String
    var targetNodeID: String
    var kind: String
    var weight: Double
    var evidence: String?
    var updatedAt: Date

    static let databaseTableName = "semantic_graph_edge"
}

struct SemanticMemoryGraph: Sendable {
    let nodes: [SemanticGraphNode]
    let edges: [SemanticGraphEdge]
}

struct SemanticMemoryStats: Sendable {
    let chunkCount: Int
    let embeddedChunkCount: Int
    let nodeCount: Int
    let edgeCount: Int
    let activeModelID: String
    let latestIndexedAt: Date?
}

struct SemanticInsightSnapshotRecord: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var generatedAt: Date
    var graphSignature: String
    var analyzerName: String
    var summaryModelName: String?
    var sourceNodeCount: Int
    var sourceEdgeCount: Int
    var sourceChunkCount: Int
    var reportJSON: String

    static let databaseTableName = "semantic_insight_snapshot"
}

struct SemanticInsightFreshness: Sendable, Equatable {
    let reportGraphSignature: String
    let currentGraphSignature: String
    let status: SemanticInsightFreshnessStatus

    var isStale: Bool { status == .stale }
}

enum SemanticInsightFreshnessStatus: String, Sendable, Codable {
    case fresh
    case stale
}

struct SemanticInsightReport: Sendable, Codable {
    let generatedAt: Date
    let graphSignature: String
    let analyzerName: String
    let usedFallback: Bool
    let summary: [String]
    let summaryModelName: String?
    let clusters: [SemanticInsightCluster]
    let comparisons: [SemanticInsightComparison]
    let coverageNotes: [String]
    let cards: [SemanticInsightCard]
    let sourceNodeCount: Int
    let sourceEdgeCount: Int
    let sourceChunkCount: Int
}

struct SemanticInsightCluster: Identifiable, Sendable, Codable, Hashable {
    let id: String
    let title: String
    let summary: String
    let relatedNodeIDs: [String]
    let evidence: [SemanticInsightEvidence]
}

struct SemanticInsightComparison: Identifiable, Sendable, Codable, Hashable {
    let id: String
    let title: String
    let detail: String
    let trend: String
    let evidence: [SemanticInsightEvidence]
}

struct SemanticInsightCard: Identifiable, Sendable, Codable, Hashable {
    let id: String
    let kind: String
    let title: String
    let body: String
    let confidence: Double
    let actionText: String
    let relatedNodeIDs: [String]
    let evidence: [SemanticInsightEvidence]
}

struct SemanticInsightEvidence: Identifiable, Sendable, Codable, Hashable {
    let id: String
    let title: String
    let excerpt: String
    let sourceAppName: String?
    let sourceCreatedAt: Date?
    let score: Double
}

extension SemanticChunk {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension SemanticEmbedding {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension SemanticGraphEdge {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension SemanticInsightSnapshotRecord {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
