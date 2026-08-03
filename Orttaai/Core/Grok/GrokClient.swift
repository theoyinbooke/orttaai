// GrokClient.swift
// Orttaai

import Foundation

nonisolated struct ExternalCLIProcessResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

nonisolated enum ExternalCLICommandError: LocalizedError {
    case launchFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message): message
        case .timedOut: "The command timed out."
        }
    }
}

/// Runs a CLI off the cooperative executor and enforces a hard timeout. Both
/// Codex-style Node shims and native binaries receive the same Finder-safe
/// environment used by discovery.
nonisolated enum ExternalCLICommandRunner {
    static func run(
        executablePath: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 120,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> ExternalCLIProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fileManager = FileManager.default
                let captureDirectory = fileManager.temporaryDirectory
                    .appendingPathComponent("orttaai-cli-output-\(UUID().uuidString)", isDirectory: true)
                do { try fileManager.createDirectory(at: captureDirectory, withIntermediateDirectories: true) } catch {
                    continuation.resume(throwing: ExternalCLICommandError.launchFailed(error.localizedDescription))
                    return
                }
                defer { try? fileManager.removeItem(at: captureDirectory) }
                let stdoutURL = captureDirectory.appendingPathComponent("stdout")
                let stderrURL = captureDirectory.appendingPathComponent("stderr")
                fileManager.createFile(atPath: stdoutURL.path, contents: nil)
                fileManager.createFile(atPath: stderrURL.path, contents: nil)
                guard let stdout = try? FileHandle(forWritingTo: stdoutURL),
                      let stderr = try? FileHandle(forWritingTo: stderrURL) else {
                    continuation.resume(throwing: ExternalCLICommandError.launchFailed("Could not create CLI output files."))
                    return
                }
                defer {
                    try? stdout.close()
                    try? stderr.close()
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.currentDirectoryURL = currentDirectory
                process.environment = ExternalCLIEnvironment.prepared(
                    forExecutableAt: executablePath,
                    baseEnvironment: baseEnvironment
                )
                process.standardOutput = stdout
                process.standardError = stderr
                let finished = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in finished.signal() }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ExternalCLICommandError.launchFailed(error.localizedDescription))
                    return
                }

                let deadline = DispatchTime.now() + timeout
                guard finished.wait(timeout: deadline) == .success else {
                    process.terminate()
                    _ = finished.wait(timeout: .now() + 2)
                    continuation.resume(throwing: ExternalCLICommandError.timedOut)
                    return
                }

                try? stdout.synchronize()
                try? stderr.synchronize()
                let stdoutData = (try? Data(contentsOf: stdoutURL)) ?? Data()
                let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()
                continuation.resume(returning: ExternalCLIProcessResult(
                    status: process.terminationStatus,
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? ""
                ))
            }
        }
    }
}

nonisolated struct GrokBinaryInfo: Sendable {
    let path: String
    let version: String
}

nonisolated enum GrokBinaryLocator {
    static let overridePathKey = "grokBinaryPathOverride"

    static func discover() -> GrokBinaryInfo? {
        for path in candidatePaths() where FileManager.default.isExecutableFile(atPath: path) {
            if let version = readVersion(atPath: path) {
                return GrokBinaryInfo(path: path, version: version)
            }
        }
        return nil
    }

    static func candidatePaths(
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [String] {
        let home = homeDirectory as NSString
        return ExternalCLIEnvironment.candidateExecutablePaths(
            named: "grok",
            overridePath: UserDefaults.standard.string(forKey: overridePathKey),
            additionalPaths: [
                home.appendingPathComponent(".grok/bin/grok"),
                "/Applications/Grok.app/Contents/Resources/grok",
                home.appendingPathComponent("Applications/Grok.app/Contents/Resources/grok"),
            ],
            homeDirectory: homeDirectory,
            environment: environment,
            fileManager: fileManager
        )
    }

    static func parseVersionOutput(_ output: String) -> String? {
        let tokens = output.split(whereSeparator: { $0.isWhitespace })
        guard let index = tokens.firstIndex(where: { $0.lowercased() == "grok" }),
              tokens.indices.contains(tokens.index(after: index)) else { return nil }
        let version = String(tokens[tokens.index(after: index)])
        return version.first?.isNumber == true && version.contains(".") ? version : nil
    }

    static func readVersion(
        atPath path: String,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.environment = ExternalCLIEnvironment.prepared(
            forExecutableAt: path,
            baseEnvironment: baseEnvironment,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return parseVersionOutput(String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? "")
    }
}

nonisolated enum GrokClientError: LocalizedError {
    case binaryMissing
    case signedOut
    case consentRequired
    case commandFailed(String)
    case embeddingsUnsupported

    var errorDescription: String? {
        switch self {
        case .binaryMissing:
            "Grok CLI not found. Install Grok Build or choose the executable manually in Settings."
        case .signedOut:
            "Grok CLI is installed but not signed in. Run `grok login`, then re-check."
        case .consentRequired:
            "Allow cloud text in Settings before using Grok CLI."
        case .commandFailed(let message):
            "Grok CLI failed: \(message)"
        case .embeddingsUnsupported:
            "Grok CLI does not provide embeddings; Orttaai keeps embeddings on the selected local provider."
        }
    }
}

actor GrokClient: LocalLLMServing {
    nonisolated var providerKind: LocalLLMProviderKind { .grok }
    nonisolated static let defaultModel = "grok-4.5"

    typealias CommandRunner = @Sendable (
        _ executablePath: String,
        _ arguments: [String],
        _ currentDirectory: URL?,
        _ timeout: TimeInterval
    ) async throws -> ExternalCLIProcessResult

    private let binaryDiscovery: @Sendable () -> GrokBinaryInfo?
    private let commandRunner: CommandRunner

    init(
        binaryDiscovery: @escaping @Sendable () -> GrokBinaryInfo? = { GrokBinaryLocator.discover() },
        commandRunner: @escaping CommandRunner = { path, arguments, directory, timeout in
            try await ExternalCLICommandRunner.run(
                executablePath: path,
                arguments: arguments,
                currentDirectory: directory,
                timeout: timeout
            )
        }
    ) {
        self.binaryDiscovery = binaryDiscovery
        self.commandRunner = commandRunner
    }

    func checkHealth(baseURLString: String, timeoutMs: Int) async -> OllamaHealthStatus {
        guard let binary = binaryDiscovery() else {
            return OllamaHealthStatus(isReachable: false, installedModels: [], message: GrokClientError.binaryMissing.localizedDescription)
        }
        do {
            let result = try await commandRunner(binary.path, ["models"], nil, max(1, Double(timeoutMs) / 1_000))
            let output = result.stdout + "\n" + result.stderr
            let models = Self.parseModelList(output)
            if output.localizedCaseInsensitiveContains("not authenticated") {
                return OllamaHealthStatus(isReachable: false, installedModels: models, message: GrokClientError.signedOut.localizedDescription)
            }
            guard result.status == 0 else {
                return OllamaHealthStatus(
                    isReachable: false,
                    installedModels: models,
                    message: Self.failureMessage(result)
                )
            }
            return OllamaHealthStatus(
                isReachable: true,
                installedModels: models,
                message: "Grok CLI \(binary.version) is ready. \(models.count) model\(models.count == 1 ? "" : "s") available."
            )
        } catch {
            return OllamaHealthStatus(isReachable: false, installedModels: [], message: error.localizedDescription)
        }
    }

    func fetchModelNames(baseURLString: String, timeoutMs: Int) async throws -> [String] {
        guard let binary = binaryDiscovery() else { throw GrokClientError.binaryMissing }
        let result = try await commandRunner(binary.path, ["models"], nil, max(1, Double(timeoutMs) / 1_000))
        let output = result.stdout + "\n" + result.stderr
        if output.localizedCaseInsensitiveContains("not authenticated") { throw GrokClientError.signedOut }
        guard result.status == 0 else { throw GrokClientError.commandFailed(Self.failureMessage(result)) }
        let models = Self.parseModelList(output)
        return models.isEmpty ? [Self.defaultModel] : models
    }

    func generate(
        baseURLString: String,
        model: String,
        prompt: String,
        timeoutMs: Int?,
        think: Bool?,
        format: String?,
        formatJSONSchema: String?,
        temperature: Double,
        numPredict: Int,
        numContext: Int?,
        keepAlive: String
    ) async throws -> String {
        guard UserDefaults.standard.bool(forKey: "grokConsentAcknowledged") else {
            throw GrokClientError.consentRequired
        }
        guard let binary = binaryDiscovery() else { throw GrokClientError.binaryMissing }
        let fileManager = FileManager.default
        let invocationDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("orttaai-grok-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: invocationDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: invocationDirectory) }
        let promptURL = invocationDirectory.appendingPathComponent("prompt.txt")
        try prompt.write(to: promptURL, atomically: true, encoding: .utf8)

        let arguments = Self.inferenceArguments(
            promptFile: promptURL.path,
            workingDirectory: invocationDirectory.path,
            model: model,
            reasoningEffort: think == false ? "low" : nil,
            jsonSchema: formatJSONSchema
        )
        let result = try await commandRunner(
            binary.path,
            arguments,
            invocationDirectory,
            max(1, Double(timeoutMs ?? 300_000) / 1_000)
        )
        guard result.status == 0 else {
            let combined = result.stdout + "\n" + result.stderr
            if combined.localizedCaseInsensitiveContains("not authenticated") { throw GrokClientError.signedOut }
            throw GrokClientError.commandFailed(Self.failureMessage(result))
        }
        let response = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard response.isEmpty == false else { throw GrokClientError.commandFailed("No response was returned.") }
        return response
    }

    func chat(
        baseURLString: String,
        model: String,
        messages: [OllamaChatMessage],
        timeoutMs: Int?,
        think: Bool?,
        temperature: Double,
        numPredict: Int,
        numContext: Int?,
        keepAlive: String
    ) async throws -> String {
        try await generate(
            baseURLString: baseURLString,
            model: model,
            prompt: CodexClient.flattenedPrompt(messages: messages),
            timeoutMs: timeoutMs,
            think: think,
            format: nil,
            formatJSONSchema: nil,
            temperature: temperature,
            numPredict: numPredict,
            numContext: numContext,
            keepAlive: keepAlive
        )
    }

    func embed(
        baseURLString: String,
        model: String,
        inputs: [String],
        timeoutMs: Int?,
        keepAlive: String,
        truncate: Bool
    ) async throws -> [[Float]] {
        throw GrokClientError.embeddingsUnsupported
    }

    func warmModel(baseURLString: String, model: String, timeoutMs: Int, keepAlive: String) async throws -> Int { 0 }

    nonisolated static func inferenceArguments(
        promptFile: String,
        workingDirectory: String,
        model: String,
        reasoningEffort: String?,
        jsonSchema: String?
    ) -> [String] {
        var arguments = [
            "--prompt-file", promptFile,
            "--cwd", workingDirectory,
            "--model", model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultModel : model,
            "--output-format", "plain",
            "--max-turns", "1",
            "--no-plan",
            "--no-subagents",
            "--no-memory",
            "--disable-web-search",
            "--permission-mode", "plan",
            "--tools", "",
            "--verbatim",
            "--system-prompt-override", "Return only the requested text or schema-constrained JSON. Do not use tools, inspect files, or modify the user's Mac.",
        ]
        if let reasoningEffort, reasoningEffort.isEmpty == false {
            arguments.append(contentsOf: ["--reasoning-effort", reasoningEffort])
        }
        if let jsonSchema, jsonSchema.isEmpty == false {
            arguments.append(contentsOf: ["--json-schema", jsonSchema])
        }
        return arguments
    }

    nonisolated static func parseModelList(_ output: String) -> [String] {
        var models: [String] = []
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("*") else { continue }
            let model = line.dropFirst()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " (default)", with: "")
            if model.isEmpty == false, models.contains(model) == false { models.append(model) }
        }
        return models
    }

    nonisolated private static func failureMessage(_ result: ExternalCLIProcessResult) -> String {
        let message = (result.stderr.isEmpty ? result.stdout : result.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Command exited with status \(result.status)." : message
    }
}
