// CodexIntegrationTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

/// End-to-end tests against the real installed Codex CLI. These skip (never
/// fail) when Codex is missing or not signed in with ChatGPT, so CI without
/// the binary stays green; on a signed-in dev machine they exercise the full
/// spawn → handshake → inference pipeline the app uses in production.
final class CodexIntegrationTests: XCTestCase {

    private func requireSignedInConnection() async throws -> CodexAppServerConnection {
        guard let info = CodexBinaryLocator.discover() else {
            throw XCTSkip("Codex CLI is not installed on this machine.")
        }
        guard CodexBinaryLocator.isVersionSupported(info.version) else {
            throw XCTSkip("Codex CLI \(info.version) is older than \(CodexBinaryLocator.minimumVersion).")
        }
        let connection = CodexAppServerConnection()
        let account = try await connection.request(method: "account/read", params: ["refreshToken": false])
        guard let accountObject = account["account"] as? [String: Any],
              (accountObject["type"] as? String) == "chatgpt" else {
            await connection.shutdown()
            throw XCTSkip("Codex is not signed in with a ChatGPT account.")
        }
        return connection
    }

    func testRealServerHealthAndModels() async throws {
        let connection = try await requireSignedInConnection()
        defer { Task { await connection.shutdown() } }

        let client = CodexClient(connection: connection)
        let health = await client.checkHealth(baseURLString: "", timeoutMs: 15_000)
        XCTAssertTrue(health.isReachable, health.message)
        XCTAssertFalse(health.installedModels.isEmpty, "Expected at least one cloud model")

        let details = try await client.fetchModelDetails()
        XCTAssertTrue(details.contains { $0.isDefault }, "Expected a default model in model/list")
    }

    func testRealServerStructuredGenerate() async throws {
        let connection = try await requireSignedInConnection()
        defer { Task { await connection.shutdown() } }

        let client = CodexClient(connection: connection)
        let models = try await client.fetchModelNames(baseURLString: "", timeoutMs: 15_000)
        let model = models.first { $0.contains("mini") } ?? models.first
        let schema = #"{"type":"object","properties":{"word_count":{"type":"integer"}},"required":["word_count"],"additionalProperties":false}"#

        let response = try await client.generate(
            baseURLString: "",
            model: try XCTUnwrap(model),
            prompt: "Count the words in this sentence and reply as JSON: \"The quick brown fox\"",
            timeoutMs: 120_000,
            think: nil,
            format: nil,
            formatJSONSchema: schema,
            temperature: 0,
            numPredict: 100,
            numContext: nil,
            keepAlive: "5m"
        )

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
            "Expected schema-valid JSON, got: \(response)"
        )
        XCTAssertNotNil(object["word_count"] as? NSNumber)
    }
}
