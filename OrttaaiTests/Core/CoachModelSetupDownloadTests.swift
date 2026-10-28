// CoachModelSetupDownloadTests.swift
// OrttaaiTests
//
// Coach's one-step setup against a stand-in Ollama on this Mac: it asks for
// each missing model, follows the download's progress, and then points
// every job at the right model.

import CoachCore
import Combine
import Network
import XCTest
@testable import Orttaai

@MainActor
final class CoachModelSetupDownloadTests: XCTestCase {
    private let keys = [
        "localLLMProvider", "localLLMEndpoint",
        CoachPreferences.partnerModelKey, CoachPreferences.coachModelKey, CoachPreferences.judgeModelKey,
        CoachPreferences.judgeGradesKey, CoachPreferences.modelSetupSeenKey,
    ]
    private var saved: [String: Any] = [:]
    private var server: FakeOllama!

    override func setUp() async throws {
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        server = try FakeOllama()
        try await server.start()
        UserDefaults.standard.set("ollama", forKey: "localLLMProvider")
        UserDefaults.standard.set("http://127.0.0.1:\(server.port)", forKey: "localLLMEndpoint")
    }

    override func tearDown() async throws {
        server.stop()
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    func testSetupDownloadsWhatsMissingAndPointsEachJobAtItsModel() async throws {
        let setup = CoachModelSetupCenter.shared
        // The judge has been checked already, so setup doesn't run the check.
        CoachPreferences.saveJudgeGrade(JudgeGrade(
            model: setup.judge, accuracy: 0.98, yesRecall: 1, noRecall: 0.96, answered: 52, total: 52,
            msPerAnswer: 190, version: CoachCalibration.version, gradedAt: Date()
        ))

        await setup.refresh()
        XCTAssertEqual(setup.missing.map(\.name), setup.models.map(\.name), "Nothing is installed yet")

        var fractions: [Double] = []
        let watching = setup.$step.sink { step in
            if case .downloading(_, let fraction?) = step { fractions.append(fraction) }
        }
        setup.includeVoice = false
        await setup.setUp()
        watching.cancel()

        XCTAssertEqual(setup.step, .done)
        XCTAssertEqual(server.pulled, setup.models.map(\.name), "Each missing model was asked for once, in order")
        XCTAssertTrue(fractions.contains { $0 > 0 && $0 < 1 }, "Progress came through: \(fractions)")
        XCTAssertTrue(setup.missing.isEmpty)
        XCTAssertEqual(UserDefaults.standard.string(forKey: CoachPreferences.partnerModelKey), CoachStarterModels.partner)
        XCTAssertNil(UserDefaults.standard.string(forKey: CoachPreferences.judgeModelKey), "Automatic")
        XCTAssertEqual(CoachModels.current().judgeModel, setup.judge)
        XCTAssertTrue(setup.isSetUp)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: CoachPreferences.modelSetupSeenKey))
    }

    func testAServerThatRefusesTheDownloadSaysSo() async throws {
        server.refusePulls = true
        let setup = CoachModelSetupCenter.shared
        setup.includeVoice = false
        await setup.setUp()
        guard case .failed(let message) = setup.step else { return XCTFail("Expected a failure, got \(setup.step)") }
        XCTAssertTrue(message.contains(setup.models[0].name), message)
        XCTAssertNil(UserDefaults.standard.string(forKey: CoachPreferences.partnerModelKey), "Nothing is changed")
    }
}

/// Just enough of Ollama's HTTP API: the installed models, and pulls that
/// stream progress and then install the model.
final class FakeOllama: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeOllama")
    private let lock = NSLock()
    private var installed: [String] = []
    private var pulls: [String] = []
    private var refusing = false

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var pulled: [String] { lock.withLock { pulls } }
    var refusePulls: Bool {
        get { lock.withLock { refusing } }
        set { lock.withLock { refusing = newValue } }
    }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; continuation.resume()
                case .failed(let error): resumed = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, _ in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.request(in: buffer) {
                self.respond(to: request, on: connection)
            } else if !done {
                self.read(connection, buffer: buffer)
            }
        }
    }

    private static func request(in data: Data) -> (method: String, path: String, body: Data)? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        let length = lines.compactMap { line -> Int? in
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2, pair[0].lowercased() == "content-length" else { return nil }
            return Int(pair[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return (String(parts[0]), String(parts[1]), Data(body.prefix(length)))
    }

    private func respond(to request: (method: String, path: String, body: Data), on connection: NWConnection) {
        switch (request.method, request.path) {
        case ("GET", "/api/tags"):
            let names = lock.withLock { installed }
            let models = names.map { ["name": $0, "model": $0, "size": 1_000] }
            send(json: ["models": models], on: connection)
        case ("POST", "/api/pull"):
            let model = ((try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any])?["model"] as? String ?? ""
            if refusePulls {
                send(status: 500, json: ["error": "pull model manifest: file does not exist"], on: connection)
                return
            }
            let lines: [[String: Any]] = [
                ["status": "pulling manifest"],
                ["status": "pulling 0123456789ab", "digest": "sha256:0123456789ab", "total": 1_000, "completed": 250],
                ["status": "pulling 0123456789ab", "digest": "sha256:0123456789ab", "total": 1_000, "completed": 750],
                ["status": "pulling 0123456789ab", "digest": "sha256:0123456789ab", "total": 1_000, "completed": 1_000],
                ["status": "verifying sha256 digest"],
                ["status": "success"],
            ]
            lock.withLock {
                pulls.append(model)
                installed.append(model)
            }
            let body = lines.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
                .map { String(decoding: $0, as: UTF8.self) }
                .joined(separator: "\n") + "\n"
            send(status: 200, contentType: "application/x-ndjson", body: Data(body.utf8), on: connection)
        default:
            send(status: 404, json: ["error": "not found"], on: connection)
        }
    }

    private func send(status: Int = 200, json: [String: Any], on connection: NWConnection) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        send(status: status, contentType: "application/json", body: body, on: connection)
    }

    private func send(status: Int, contentType: String, body: Data, on connection: NWConnection) {
        var response = Data("HTTP/1.1 \(status) OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
