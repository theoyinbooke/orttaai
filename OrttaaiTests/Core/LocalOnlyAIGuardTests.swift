// LocalOnlyAIGuardTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

/// Fails if cloud AI finds its way back into the app: a cloud provider, a
/// cloud AI host, or a spawned CLI. Orttaai's AI runs only on Ollama and LM
/// Studio on the user's own hardware.
final class LocalOnlyAIGuardTests: XCTestCase {
    /// Hosts of hosted AI APIs. None may appear in app source.
    private let cloudAIHosts = [
        "api.openai.com", "chatgpt.com", "api.anthropic.com", "generativelanguage.googleapis.com",
        "api.x.ai", "x.ai/cli", "openrouter.ai", "api.mistral.ai", "api.groq.com", "api.together",
        "api.deepseek.com", "api.moonshot", "ollama.com/api", "api.fireworks.ai", "api.cohere",
    ]

    /// Names of the removed cloud providers' code.
    private let removedSymbols = [
        "CodexClient", "CodexAppServerConnection", "CodexAccountService", "GrokClient",
        "case codex", "case grok", "codexModel", "grokModel",
    ]

    /// The migration names the removed providers' settings to delete them.
    private let removedSymbolAllowList = ["Core/Transcription/LocalAIMigration.swift"]

    /// The only file that may start a process: it opens System Settings.
    private let processAllowList = ["UI/Setup/PermissionStepView.swift"]

    func testOnlyLocalProvidersExist() {
        XCTAssertEqual(LocalLLMProviderKind.allCases.map(\.rawValue), ["ollama", "lmstudio"])
    }

    func testAppSourceHasNoCloudAI() throws {
        let sources = try appSourceFiles()
        XCTAssertGreaterThan(sources.count, 50, "Couldn't find the app's source files")

        var problems: [String] = []
        for (path, text) in sources {
            for host in cloudAIHosts where text.localizedCaseInsensitiveContains(host) {
                problems.append("\(path): cloud AI host \(host)")
            }
            for symbol in removedSymbols where text.contains(symbol) && !removedSymbolAllowList.contains(where: path.hasSuffix) {
                problems.append("\(path): removed cloud provider \(symbol)")
            }
            if text.contains("Process()"), !processAllowList.contains(where: path.hasSuffix) {
                problems.append("\(path): starts a process")
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    private func appSourceFiles() throws -> [(String, String)] {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Orttaai")
        guard let enumerator = FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        return try enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { url in
                (url.path.replacingOccurrences(of: appRoot.path + "/", with: ""), try String(contentsOf: url, encoding: .utf8))
            }
    }
}
