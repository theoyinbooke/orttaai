// LocalModelPolicy.swift
// Orttaai

import Foundation

/// Keeps every AI request on the user's own hardware. Orttaai only talks to
/// Ollama and LM Studio (Bionic included), but both can also reach cloud
/// models: Ollama's "-cloud" models run on ollama.com, and LM Studio's
/// Secure Cloud serves hosted models. These rules decide what counts as
/// local; the clients refuse everything else.
enum LocalModelPolicy {
    /// Shown when a request or endpoint is refused.
    static let refusalMessage = "Orttaai only uses models on your own hardware. Cloud models aren't supported."

    // MARK: - Endpoints

    /// An endpoint is allowed when its host is this Mac or a private
    /// network: loopback, RFC 1918 and link-local addresses, CGNAT ranges
    /// (Tailscale), IPv6 unique-local and link-local, `.local` names, and
    /// single-label names like "mac-studio" that only resolve on a LAN.
    /// Any public host, including cloud APIs, is refused.
    static func isAllowedEndpoint(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }

        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        if let octets = ipv4Octets(host) {
            return isPrivateIPv4(octets)
        }
        if host.contains(":") {
            return isPrivateIPv6(host)
        }
        // A bare machine name resolves only on the local network.
        return !host.contains(".")
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }

    private static func isPrivateIPv4(_ o: [Int]) -> Bool {
        switch (o[0], o[1]) {
        case (127, _), (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (169, 254): return true
        case (100, 64...127): return true
        default: return false
        }
    }

    private static func isPrivateIPv6(_ host: String) -> Bool {
        let address = host.split(separator: "%").first.map(String.init) ?? host
        if address == "::1" { return true }
        let first = address.split(separator: ":", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        guard let value = UInt16(first, radix: 16) else { return false }
        // fc00::/7 unique-local, fe80::/10 link-local.
        return (value & 0xFE00) == 0xFC00 || (value & 0xFFC0) == 0xFE80
    }

    // MARK: - Ollama

    /// Ollama names its cloud models with a "cloud" tag ("gpt-oss:120b-cloud",
    /// "qwen3-coder:480b-cloud", "deepseek-v3.1:671b-cloud", "kimi-k2:cloud").
    static func isOllamaCloudModelName(_ name: String) -> Bool {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tag = lowered.split(separator: ":", maxSplits: 1).dropFirst().first else {
            return lowered.hasSuffix("-cloud")
        }
        return tag == "cloud" || tag.hasSuffix("-cloud")
    }

    /// An `/api/tags` entry is local when it isn't a cloud model by name and
    /// carries no remote host (Ollama proxies those to ollama.com).
    static func isLocalOllamaEntry(_ entry: [String: Any]) -> Bool {
        let name = (entry["name"] as? String) ?? (entry["model"] as? String) ?? ""
        guard !name.isEmpty, !isOllamaCloudModelName(name) else { return false }
        if let remote = entry["remote_host"] as? String, !remote.isEmpty { return false }
        if let remote = entry["remote_model"] as? String, !remote.isEmpty { return false }
        return true
    }

    // MARK: - LM Studio

    /// An `/api/v1/models` entry is local when LM Studio reports files on
    /// disk for it. Hosted (Secure Cloud) models have none.
    static func isLocalLMStudioEntry(_ entry: [String: Any]) -> Bool {
        guard let key = entry["key"] as? String, !key.isEmpty else { return false }
        let size = (entry["size_bytes"] as? NSNumber)?.int64Value ?? 0
        return size > 0
    }
}
