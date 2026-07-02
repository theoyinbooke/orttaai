// LMStudioClientTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class LMStudioClientTests: XCTestCase {

    // MARK: - keepAlive → ttl

    func testTTLParsingFromKeepAliveStrings() {
        XCTAssertEqual(LMStudioClient.ttlSeconds(fromKeepAlive: "5m"), 300)
        XCTAssertEqual(LMStudioClient.ttlSeconds(fromKeepAlive: "10m"), 600)
        XCTAssertEqual(LMStudioClient.ttlSeconds(fromKeepAlive: "15m"), 900)
        XCTAssertEqual(LMStudioClient.ttlSeconds(fromKeepAlive: "90s"), 90)
        XCTAssertEqual(LMStudioClient.ttlSeconds(fromKeepAlive: "1h"), 3_600)
        XCTAssertEqual(LMStudioClient.ttlSeconds(fromKeepAlive: "300"), 300)
        XCTAssertNil(LMStudioClient.ttlSeconds(fromKeepAlive: ""))
        XCTAssertNil(LMStudioClient.ttlSeconds(fromKeepAlive: "forever"))
        XCTAssertNil(LMStudioClient.ttlSeconds(fromKeepAlive: "0m"))
    }

    // MARK: - response_format

    func testResponseFormatFromJSONSchema() throws {
        let schema = #"{"type":"object","properties":{"color":{"type":"string"}},"required":["color"]}"#

        let payload = try XCTUnwrap(
            LMStudioClient.responseFormatPayload(format: nil, formatJSONSchema: schema)
        )

        XCTAssertEqual(payload["type"] as? String, "json_schema")
        let wrapper = try XCTUnwrap(payload["json_schema"] as? [String: Any])
        XCTAssertEqual(wrapper["name"] as? String, "structured_response")
        XCTAssertEqual(wrapper["strict"] as? Bool, true)
        let schemaObject = try XCTUnwrap(wrapper["schema"] as? [String: Any])
        XCTAssertEqual(schemaObject["type"] as? String, "object")
    }

    func testResponseFormatFromPlainJSONMode() throws {
        let payload = try XCTUnwrap(
            LMStudioClient.responseFormatPayload(format: "json", formatJSONSchema: nil)
        )
        XCTAssertEqual(payload["type"] as? String, "json_object")
    }

    func testResponseFormatNilWhenUnspecified() throws {
        XCTAssertNil(try LMStudioClient.responseFormatPayload(format: nil, formatJSONSchema: nil))
        XCTAssertNil(try LMStudioClient.responseFormatPayload(format: "text", formatJSONSchema: nil))
    }

    func testResponseFormatSchemaTakesPrecedenceOverFormat() throws {
        let payload = try XCTUnwrap(
            LMStudioClient.responseFormatPayload(format: "json", formatJSONSchema: #"{"type":"object"}"#)
        )
        XCTAssertEqual(payload["type"] as? String, "json_schema")
    }

    // MARK: - Chat completion parsing

    func testMessageContentParsesOpenAIShape() {
        let json: [String: Any] = [
            "choices": [
                [
                    "message": ["role": "assistant", "content": "  Hello there  "],
                    "finish_reason": "stop",
                ]
            ]
        ]

        XCTAssertEqual(LMStudioClient.messageContent(fromChatCompletion: json), "Hello there")
        XCTAssertEqual(LMStudioClient.finishReason(fromChatCompletion: json), "stop")
    }

    func testMessageContentStripsInlineThinkTags() {
        let json: [String: Any] = [
            "choices": [
                ["message": ["content": "<think>internal reasoning</think>The answer is 4."]]
            ]
        ]

        XCTAssertEqual(LMStudioClient.messageContent(fromChatCompletion: json), "The answer is 4.")
    }

    func testMessageContentNilForEmptyOrMissing() {
        XCTAssertNil(LMStudioClient.messageContent(fromChatCompletion: [:]))
        XCTAssertNil(LMStudioClient.messageContent(fromChatCompletion: [
            "choices": [["message": ["content": "   "]]]
        ]))
    }

    // MARK: - Embeddings parsing

    func testEmbeddingsParseAndPreserveIndexOrder() {
        let json: [String: Any] = [
            "data": [
                ["index": 1, "embedding": [0.4, 0.5]],
                ["index": 0, "embedding": [0.1, 0.2]],
            ]
        ]

        let embeddings = LMStudioClient.embeddings(fromEmbeddingsResponse: json)

        XCTAssertEqual(embeddings.count, 2)
        XCTAssertEqual(embeddings[0], [Float(0.1), Float(0.2)])
        XCTAssertEqual(embeddings[1], [Float(0.4), Float(0.5)])
    }

    func testEmbeddingsEmptyForMalformedResponse() {
        XCTAssertTrue(LMStudioClient.embeddings(fromEmbeddingsResponse: [:]).isEmpty)
        XCTAssertTrue(LMStudioClient.embeddings(fromEmbeddingsResponse: ["data": [["embedding": "bad"]]]).isEmpty)
    }

    // MARK: - Provider kind plumbing

    func testProviderKindDefaults() {
        XCTAssertEqual(LocalLLMProviderKind.ollama.defaultEndpoint, "http://127.0.0.1:11434")
        XCTAssertEqual(LocalLLMProviderKind.lmStudio.defaultEndpoint, "http://127.0.0.1:1234")
        XCTAssertTrue(LocalLLMProviderKind.ollama.supportsModelInstall)
        XCTAssertFalse(LocalLLMProviderKind.lmStudio.supportsModelInstall)
        XCTAssertTrue(LocalLLMProviderKind.ollama.supportsThinkFlag)
        XCTAssertFalse(LocalLLMProviderKind.lmStudio.supportsThinkFlag)
    }

    func testFactoryReturnsMatchingClients() {
        XCTAssertEqual(LocalLLM.client(for: .ollama).providerKind, .ollama)
        XCTAssertEqual(LocalLLM.client(for: .lmStudio).providerKind, .lmStudio)
    }

    // MARK: - Live integration (skips unless the LM Studio server is running)

    func testLiveLMStudioRoundTrip() async throws {
        let endpoint = LocalLLMProviderKind.lmStudio.defaultEndpoint
        let client = LMStudioClient()
        let health = await client.checkHealth(baseURLString: endpoint, timeoutMs: 1_500)
        try XCTSkipUnless(health.isReachable, "LM Studio server is not running; skipping live round trip.")

        // Unknown model must fail loudly, never silently use a loaded model.
        do {
            _ = try await client.generate(
                baseURLString: endpoint,
                model: "definitely-not-a-real-model",
                prompt: "Say OK.",
                timeoutMs: 10_000,
                think: nil,
                format: nil,
                formatJSONSchema: nil,
                temperature: 0,
                numPredict: 8,
                numContext: nil,
                keepAlive: "5m"
            )
            XCTFail("Expected unknown-model request to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not available in LM Studio"), error.localizedDescription)
        }

        // Generation with a real chat model, if one is downloaded.
        let chatModel = health.installedModels.first { !Self.looksLikeEmbeddingModel($0) }
        if let chatModel {
            let response = try await client.generate(
                baseURLString: endpoint,
                model: chatModel,
                prompt: "Reply with the single word OK.",
                timeoutMs: 120_000,
                think: nil,
                format: nil,
                formatJSONSchema: nil,
                temperature: 0,
                numPredict: 12,
                numContext: nil,
                keepAlive: "5m"
            )
            XCTAssertFalse(response.isEmpty)
        }

        // Embeddings with a real embedding model, if one is downloaded.
        let embeddingModel = health.installedModels.first(where: Self.looksLikeEmbeddingModel)
        if let embeddingModel {
            let vectors = try await client.embed(
                baseURLString: endpoint,
                model: embeddingModel,
                inputs: ["hello world", "semantic memory"],
                timeoutMs: 60_000,
                keepAlive: "5m",
                truncate: true
            )
            XCTAssertEqual(vectors.count, 2)
            XCTAssertGreaterThan(vectors[0].count, 100)
        }
    }

    private static func looksLikeEmbeddingModel(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("embed") || lower.contains("minilm") || lower.contains("bge")
    }
}
