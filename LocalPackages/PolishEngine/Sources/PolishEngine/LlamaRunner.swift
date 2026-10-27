// LlamaRunner.swift
// PolishEngine
//
// Adapted from the Oyinbooke chat kit's ChatLlama/LlamaRunner.swift, which
// runs S1-mini in Orttakey on the iPhone. The Mac has no rule against GPU
// work from an app in the background, so here the model can run on Metal.

import Foundation
import llama
import os

/// One GGUF model in llama.cpp, on the GPU (Metal) or the CPU.
///
/// Not thread-safe: one generation at a time, from one thread. `S1MiniPolisher` serializes them.
public nonisolated final class LlamaRunner: @unchecked Sendable {
    public nonisolated struct Sampling: Sendable, Equatable {
        public var temperature: Double
        public var topP: Double
        public var topK: Int
        public var repetitionPenalty: Double

        public init(temperature: Double = 0, topP: Double = 1, topK: Int = 0, repetitionPenalty: Double = 1) {
            self.temperature = temperature
            self.topP = topP
            self.topK = topK
            self.repetitionPenalty = repetitionPenalty
        }

        /// The same text for the same prompt: what clean-up and formatting want.
        public static let greedy = Sampling()
    }

    public nonisolated struct Output: Sendable {
        public let text: String
        public let promptTokens: Int
        public let generatedTokens: Int
        public let prefillSeconds: TimeInterval
        public let generateSeconds: TimeInterval
        public let timeToFirstToken: TimeInterval
        /// Cut off at `maxTokens` instead of ending on its own.
        public let hitLimit: Bool
        public let cancelled: Bool
    }

    public nonisolated enum Failure: LocalizedError {
        case loadFailed(String)
        case contextFailed
        case tokenizeFailed
        case promptTooLong(tokens: Int, context: Int)
        case decodeFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .loadFailed(let path): "Couldn't load the model at \(path)."
            case .contextFailed: "Couldn't set up the model's memory."
            case .tokenizeFailed: "Couldn't read the prompt."
            case .promptTooLong(let tokens, let context): "The prompt has \(tokens) tokens; the model holds \(context)."
            case .decodeFailed(let code): "The model stopped with error \(code)."
            }
        }
    }

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let threads: Int32
    private let useGPU: Bool
    /// Tokens the context kept loaded holds: prompt and answer together.
    public let contextLength: Int
    /// A prompt and answer that need more than `contextLength` get a context
    /// of their own for that generation, up to this many tokens.
    public let maxContextLength: Int
    /// Seconds from the call to a ready context.
    public let loadSeconds: TimeInterval
    /// The weights' size on disk (memory-mapped, so mostly not counted against the app).
    public let modelBytes: UInt64

    private static let backend: Void = {
        llama_log_set({ level, text, _ in
            guard level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue, let text else { return }
            Logger(subsystem: "com.orttaai.Orttaai", category: "llama").notice("\(String(cString: text), privacy: .public)")
        }, nil)
        llama_backend_init()
    }()

    /// What llama.cpp was built with (CPU features), for diagnostics.
    public static var systemInfo: String {
        _ = backend
        return String(cString: llama_print_system_info())
    }

    /// CPU threads for the parts the GPU doesn't take.
    public static var defaultThreads: Int32 {
        Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
    }

    /// - Parameters:
    ///   - contextLength: the context kept loaded, whose memory is held as long as the model is.
    ///     For S1-mini that's 224 MB at 2,048 tokens, room for a 580-word dictation and its
    ///     answer; 4,096 held 448 MB for the one dictation in a few hundred that's longer.
    ///   - useGPU: every layer on Metal (the default on a Mac), or the CPU only.
    public init(
        path: String,
        contextLength: Int = 2_048,
        maxContextLength: Int = 4_096,
        threads: Int32 = LlamaRunner.defaultThreads,
        useGPU: Bool = true
    ) throws {
        _ = Self.backend
        let started = Date()

        // The CPU device alone when the GPU isn't wanted, so nothing goes to Metal.
        let devices = UnsafeMutablePointer<ggml_backend_dev_t?>.allocate(capacity: 2)
        defer { devices.deallocate() }
        devices[0] = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU)
        devices[1] = nil

        var modelParams = llama_model_default_params()
        if useGPU {
            modelParams.n_gpu_layers = 999
        } else {
            modelParams.devices = devices
            modelParams.n_gpu_layers = 0
        }
        guard let model = llama_model_load_from_file(path, modelParams) else {
            throw Failure.loadFailed(path)
        }

        guard let context = Self.makeContext(model, length: contextLength, threads: threads, useGPU: useGPU) else {
            llama_model_free(model)
            throw Failure.contextFailed
        }

        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
        self.threads = threads
        self.useGPU = useGPU
        self.contextLength = contextLength
        self.maxContextLength = max(contextLength, maxContextLength)
        self.modelBytes = llama_model_size(model)
        self.loadSeconds = Date().timeIntervalSince(started)
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    private static func makeContext(_ model: OpaquePointer, length: Int, threads: Int32, useGPU: Bool) -> OpaquePointer? {
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(length)
        contextParams.n_batch = 512
        contextParams.n_ubatch = 512
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        contextParams.offload_kqv = useGPU
        contextParams.op_offload = useGPU
        contextParams.no_perf = true
        return llama_init_from_model(model, contextParams)
    }

    /// `prompt` is already in the model's chat format: special tokens in it are parsed, and the
    /// model's own BOS is added when it wants one. `onText` receives each new piece of text
    /// (whole UTF-8 characters only) and returns false to stop.
    public func generate(
        prompt: String,
        maxTokens: Int,
        sampling: Sampling = .greedy,
        onText: (String) -> Bool = { _ in true }
    ) throws -> Output {
        let started = Date()
        var tokens = tokenize(prompt)
        guard !tokens.isEmpty else { throw Failure.tokenizeFailed }

        // Most prompts and their answers fit the kept context; a longer one
        // gets a context of its own, freed when it's done.
        var context = self.context
        var length = contextLength
        if tokens.count + maxTokens > contextLength, maxContextLength > contextLength {
            length = min(maxContextLength, tokens.count + maxTokens)
            guard let larger = Self.makeContext(model, length: length, threads: threads, useGPU: useGPU) else {
                throw Failure.contextFailed
            }
            context = larger
        }
        defer { if context != self.context { llama_free(context) } }
        llama_memory_clear(llama_get_memory(context), true)
        let sampler = makeSampler(sampling)
        defer { llama_sampler_free(sampler) }

        let room = max(0, length - tokens.count)
        guard room > 0 else { throw Failure.promptTooLong(tokens: tokens.count, context: length) }
        let limit = min(maxTokens, room)

        var offset = 0
        while offset < tokens.count {
            let count = min(512, tokens.count - offset)
            let status = tokens.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress! + offset, Int32(count)))
            }
            guard status == 0 else { throw Failure.decodeFailed(status) }
            offset += count
        }
        let prefillSeconds = Date().timeIntervalSince(started)

        let decodeStarted = Date()
        var bytes: [UInt8] = []
        var emitted = 0
        var generated = 0
        var hitLimit = true
        var cancelled = false
        var firstToken: TimeInterval?
        while generated < limit {
            var token = llama_sampler_sample(sampler, context, -1)
            if firstToken == nil { firstToken = Date().timeIntervalSince(started) }
            if llama_vocab_is_eog(vocab, token) {
                hitLimit = false
                break
            }
            bytes += piece(token)
            generated += 1
            // Hand over only complete characters; a multi-byte one can span tokens.
            let ready = Self.completePrefixLength(bytes)
            if ready > emitted {
                let text = String(decoding: bytes[emitted..<ready], as: UTF8.self)
                emitted = ready
                if !onText(text) {
                    cancelled = true
                    hitLimit = false
                    break
                }
            }
            let status = llama_decode(context, llama_batch_get_one(&token, 1))
            guard status == 0 else { throw Failure.decodeFailed(status) }
        }
        if !cancelled, emitted < bytes.count {
            _ = onText(String(decoding: bytes[emitted...], as: UTF8.self))
        }

        return Output(
            text: String(decoding: bytes, as: UTF8.self),
            promptTokens: tokens.count,
            generatedTokens: generated,
            prefillSeconds: prefillSeconds,
            generateSeconds: Date().timeIntervalSince(decodeStarted),
            timeToFirstToken: firstToken ?? prefillSeconds,
            hitLimit: hitLimit,
            cancelled: cancelled
        )
    }

    /// Token count for `text` as the model reads it.
    public func tokenCount(_ text: String) -> Int {
        tokenize(text).count
    }

    private func tokenize(_ text: String) -> [llama_token] {
        let length = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(length) + 8)
        let count = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), true, true)
        guard count >= 0 else { return [] }
        return Array(tokens.prefix(Int(count)))
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(Int(max(count, 0))).map { UInt8(bitPattern: $0) }
    }

    private func makeSampler(_ sampling: Sampling) -> UnsafeMutablePointer<llama_sampler> {
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        if sampling.repetitionPenalty > 1 {
            llama_sampler_chain_add(chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, Float(sampling.repetitionPenalty), 0, 0))
        }
        if sampling.temperature <= 0.01 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
            return chain
        }
        if sampling.topK > 0 { llama_sampler_chain_add(chain, llama_sampler_init_top_k(Int32(sampling.topK))) }
        if sampling.topP < 1 { llama_sampler_chain_add(chain, llama_sampler_init_top_p(Float(sampling.topP), 1)) }
        llama_sampler_chain_add(chain, llama_sampler_init_temp(Float(sampling.temperature)))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
        return chain
    }

    /// Bytes up to the last complete UTF-8 character.
    static func completePrefixLength(_ bytes: [UInt8]) -> Int {
        var index = bytes.count
        var continuation = 0
        while index > 0, continuation < 4 {
            let byte = bytes[index - 1]
            if byte & 0b1100_0000 == 0b1000_0000 {
                continuation += 1
                index -= 1
                continue
            }
            let width = byte < 0x80 ? 1 : byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return continuation + 1 >= width ? bytes.count : index - 1
        }
        return bytes.count
    }
}
