// LocalModelPolicyTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class LocalModelPolicyTests: XCTestCase {
    // MARK: - Endpoints

    func testLocalAndPrivateNetworkEndpointsAreAllowed() {
        for address in [
            "http://127.0.0.1:11434",
            "http://localhost:1234",
            "http://[::1]:1234",
            "http://192.168.1.20:1234",
            "http://10.0.0.5:11434",
            "http://172.20.3.4:1234",
            "http://100.101.102.103:1234",
            "http://mac-studio.local:1234",
            "http://mac-studio:11434",
            "http://[fd12:3456::1]:1234",
        ] {
            XCTAssertTrue(LocalModelPolicy.isAllowedEndpoint(URL(string: address)!), address)
        }
    }

    func testCloudAndPublicEndpointsAreRefused() {
        for address in [
            "https://api.openai.com",
            "https://ollama.com",
            "https://api.x.ai/v1",
            "https://openrouter.ai/api",
            "http://8.8.8.8:11434",
            "http://172.32.0.1:1234",
            "ftp://127.0.0.1:1234",
        ] {
            XCTAssertFalse(LocalModelPolicy.isAllowedEndpoint(URL(string: address)!), address)
        }
    }

    // MARK: - Ollama

    func testOllamaCloudModelNamesAreRecognised() {
        for name in ["gpt-oss:120b-cloud", "qwen3-coder:480b-cloud", "kimi-k2:cloud", "deepseek-v3.1:671b-cloud"] {
            XCTAssertTrue(LocalModelPolicy.isOllamaCloudModelName(name), name)
        }
        for name in ["gemma4:e2b", "qwen3:1.7b", "clef-flash:latest", "all-minilm"] {
            XCTAssertFalse(LocalModelPolicy.isOllamaCloudModelName(name), name)
        }
    }

    func testOllamaEntriesWithARemoteHostAreDropped() {
        let local: [String: Any] = ["name": "gemma4:e2b", "size": 7_476_595_162]
        let byName: [String: Any] = ["name": "gpt-oss:120b-cloud", "size": 384]
        let byRemote: [String: Any] = ["name": "glm-4.6:latest", "remote_host": "https://ollama.com:443", "remote_model": "glm-4.6"]
        XCTAssertTrue(LocalModelPolicy.isLocalOllamaEntry(local))
        XCTAssertFalse(LocalModelPolicy.isLocalOllamaEntry(byName))
        XCTAssertFalse(LocalModelPolicy.isLocalOllamaEntry(byRemote))
    }

    func testOllamaClientRefusesCloudModelsBeforeAnyRequest() async {
        do {
            _ = try await OllamaClient().chat(
                baseURLString: "http://127.0.0.1:9",
                model: "gpt-oss:120b-cloud",
                messages: [OllamaChatMessage(role: .user, content: "hi")],
                timeoutMs: 100,
                think: nil,
                temperature: 0,
                numPredict: 1,
                numContext: nil,
                keepAlive: "1m"
            )
            XCTFail("A cloud model must be refused")
        } catch {
            guard case OllamaClientError.notLocal = error else {
                return XCTFail("Expected notLocal, got \(error)")
            }
        }
    }

    func testClientsRefuseACloudEndpoint() async {
        let ollama = await OllamaClient().checkHealth(baseURLString: "https://api.openai.com", timeoutMs: 200)
        XCTAssertFalse(ollama.isReachable)
        XCTAssertTrue(ollama.message.contains("own hardware"), ollama.message)

        do {
            _ = try await LMStudioClient().fetchModelNames(baseURLString: "https://api.openai.com", timeoutMs: 200)
            XCTFail("A cloud endpoint must be refused")
        } catch {
            guard case OllamaClientError.notLocal = error else {
                return XCTFail("Expected notLocal, got \(error)")
            }
        }
    }

    // MARK: - LM Studio

    /// Shaped like LM Studio 0.4's /api/v1/models on the development Mac,
    /// plus a hosted entry with no files, as a Secure Cloud model would be.
    func testLMStudioNativeListKeepsOnlyModelsOnDisk() throws {
        let json = """
        {"models": [
          {"type": "llm", "key": "qwen3.5-2b", "size_bytes": 1750000000, "format": "gguf", "loaded_instances": []},
          {"type": "llm", "key": "google/gemma-3-4b", "size_bytes": 3030000000, "format": "mlx", "selected_variant": "google/gemma-3-4b@4bit"},
          {"type": "embedding", "key": "text-embedding-nomic-embed-text-v1.5", "size_bytes": 84106624, "format": "gguf"},
          {"type": "llm", "key": "zai-org/GLM-5.3", "display_name": "GLM-5.3"},
          {"type": "llm", "key": "deepseek-ai/DeepSeek-V4-Pro", "size_bytes": 0}
        ]}
        """
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let entries = try XCTUnwrap(object["models"] as? [[String: Any]])

        let models = LMStudioClient.localModels(fromNativeEntries: entries)

        XCTAssertEqual(models.map(\.key), ["qwen3.5-2b", "google/gemma-3-4b", "text-embedding-nomic-embed-text-v1.5"])
        XCTAssertEqual(models.map(\.type), ["llm", "llm", "embedding"])
    }
}
