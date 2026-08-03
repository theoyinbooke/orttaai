// GrokIntegrationTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class GrokIntegrationTests: XCTestCase {
    @MainActor
    func testRealGrokHealthAndModels() async throws {
        guard GrokBinaryLocator.discover() != nil else {
            throw XCTSkip("Grok CLI is not installed on this machine.")
        }
        let client = GrokClient()
        let health = await client.checkHealth(baseURLString: "", timeoutMs: 15_000)
        guard health.message.localizedCaseInsensitiveContains("not signed in") == false else {
            throw XCTSkip("Grok CLI is installed but not signed in.")
        }
        XCTAssertTrue(health.isReachable, health.message)
        let models = try await client.fetchModelNames(baseURLString: "", timeoutMs: 15_000)
        XCTAssertFalse(models.isEmpty)
    }

    @MainActor
    func testRealGrokHeadlessInference() async throws {
        guard GrokBinaryLocator.discover() != nil else {
            throw XCTSkip("Grok CLI is not installed on this machine.")
        }
        let key = "grokConsentAcknowledged"
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        let response = try await GrokClient().generate(
            baseURLString: "",
            model: GrokClient.defaultModel,
            prompt: "Reply with exactly ORTTAAI_GROK_OK and nothing else.",
            timeoutMs: 120_000,
            think: false,
            format: nil,
            formatJSONSchema: nil,
            temperature: 0,
            numPredict: 20,
            numContext: nil,
            keepAlive: ""
        )
        XCTAssertEqual(response, "ORTTAAI_GROK_OK")
    }
}
