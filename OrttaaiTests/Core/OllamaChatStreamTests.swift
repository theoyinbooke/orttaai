// OllamaChatStreamTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class OllamaChatStreamTests: XCTestCase {
    private func client(status: Int = 200, body: String) -> OllamaClient {
        StubbedOllamaResponse.set(status: status, body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubbedOllamaResponse.self]
        return OllamaClient(session: URLSession(configuration: configuration))
    }

    private func stream(_ client: OllamaClient, deltas: TextLog, thoughts: TextLog) async throws -> String {
        try await client.chatStream(
            baseURLString: "http://127.0.0.1:11434",
            model: "qwen3:1.7b",
            messages: [OllamaChatMessage(role: .user, content: "Say hello")],
            timeoutMs: nil,
            think: true,
            temperature: 0.35,
            numPredict: 400,
            numContext: nil,
            keepAlive: "5m",
            onDelta: { deltas.append($0) },
            onThinking: { thoughts.append($0) }
        )
    }

    func testStreamsReplyAndReasoningAsTheyArrive() async throws {
        let body = [
            #"{"message":{"role":"assistant","content":"","thinking":"They want "},"done":false}"#,
            #"{"message":{"role":"assistant","content":"","thinking":"a greeting."},"done":false}"#,
            #"{"message":{"role":"assistant","content":"Hello"},"done":false}"#,
            #"{"message":{"role":"assistant","content":", world"},"done":false}"#,
            #"{"message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"#,
        ].joined(separator: "\n") + "\n"
        let deltas = TextLog(), thoughts = TextLog()

        let reply = try await stream(client(body: body), deltas: deltas, thoughts: thoughts)

        XCTAssertEqual(reply, "Hello, world")
        XCTAssertEqual(deltas.values, ["Hello", "Hello, world"], "each delta is the reply so far")
        XCTAssertEqual(thoughts.values, ["They want ", "They want a greeting."])
    }

    func testErrorLineFailsTheStream() async {
        let body = #"{"error":"model 'qwen3:1.7b' not found"}"# + "\n"
        do {
            _ = try await stream(client(body: body), deltas: TextLog(), thoughts: TextLog())
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue("\(error)".contains("not found"))
        }
    }

    func testHTTPErrorIsReported() async {
        do {
            _ = try await stream(client(status: 404, body: #"{"error":"no such model"}"#), deltas: TextLog(), thoughts: TextLog())
            XCTFail("expected an error")
        } catch OllamaClientError.httpError(let status, let message) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(message, "no such model")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testReplyWithOnlyReasoningIsAnError() async {
        let body = #"{"message":{"role":"assistant","content":"","thinking":"Hmm."},"done":true}"# + "\n"
        do {
            _ = try await stream(client(body: body), deltas: TextLog(), thoughts: TextLog())
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue("\(error)".contains("Thinking content was present"))
        }
    }
}

private final class TextLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ value: String) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

/// Answers every request with the configured status and body.
private final class StubbedOllamaResponse: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body = Data()

    static func set(status: Int, body: String) {
        self.status = status
        self.body = Data(body.utf8)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/x-ndjson"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
