// GrokClientTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class GrokClientTests: XCTestCase {
    func testVersionParsing() {
        XCTAssertEqual(GrokBinaryLocator.parseVersionOutput("grok 0.2.114 (0c785038798)"), "0.2.114")
        XCTAssertNil(GrokBinaryLocator.parseVersionOutput("not grok"))
    }

    func testCandidatePathsCoverOfficialPackageManagerAndFinderLocations() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: home) }
        try fileManager.createDirectory(
            at: home.appendingPathComponent(".nvm/versions/node/v24.1.0/bin"),
            withIntermediateDirectories: true
        )

        let paths = GrokBinaryLocator.candidatePaths(
            homeDirectory: home.path,
            environment: ["PATH": "/finder/only"],
            fileManager: fileManager
        )

        XCTAssertTrue(paths.contains(home.appendingPathComponent(".grok/bin/grok").path))
        XCTAssertTrue(paths.contains(home.appendingPathComponent(".bun/bin/grok").path))
        XCTAssertTrue(paths.contains(home.appendingPathComponent(".nvm/versions/node/v24.1.0/bin/grok").path))
        XCTAssertTrue(paths.contains("/opt/homebrew/bin/grok"))
        XCTAssertTrue(paths.contains("/finder/only/grok"))
        XCTAssertEqual(paths.count, Set(paths).count)
    }

    func testModelListParsing() {
        let output = """
        Default model: grok-4.5

        Available models:
          * grok-4.5 (default)
          * grok-code-fast-1
        """
        XCTAssertEqual(GrokClient.parseModelList(output), ["grok-4.5", "grok-code-fast-1"])
    }

    func testInferenceArgumentsDisableAgenticCapabilities() {
        let arguments = GrokClient.inferenceArguments(
            promptFile: "/tmp/prompt.txt",
            workingDirectory: "/tmp/empty",
            model: "grok-4.5",
            reasoningEffort: "low",
            jsonSchema: #"{"type":"object"}"#
        )

        XCTAssertTrue(arguments.contains("--no-subagents"))
        XCTAssertTrue(arguments.contains("--no-memory"))
        XCTAssertTrue(arguments.contains("--disable-web-search"))
        XCTAssertTrue(arguments.contains("--permission-mode"))
        XCTAssertTrue(arguments.contains("plan"))
        XCTAssertTrue(arguments.contains("--tools"))
        XCTAssertTrue(arguments.contains("--json-schema"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--tools")! + 1], "")
    }

    func testHealthDistinguishesInstalledButSignedOut() async {
        let client = GrokClient(
            binaryDiscovery: { GrokBinaryInfo(path: "/fake/grok", version: "0.2.114") },
            commandRunner: { _, _, _, _ in
                ExternalCLIProcessResult(
                    status: 0,
                    stdout: "You are not authenticated.\nAvailable models:\n  * grok-4.5 (default)\n",
                    stderr: ""
                )
            }
        )

        let health = await client.checkHealth(baseURLString: "", timeoutMs: 1_000)
        XCTAssertFalse(health.isReachable)
        XCTAssertEqual(health.installedModels, ["grok-4.5"])
        XCTAssertTrue(health.message.contains("not signed in"))
    }
}
