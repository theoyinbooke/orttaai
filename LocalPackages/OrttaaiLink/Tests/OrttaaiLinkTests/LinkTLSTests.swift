// LinkTLSTests.swift
// OrttaaiLinkTests
//
// The service over real HTTPS, reached the way a linked device reaches it:
// trusting only the public key whose fingerprint it learnt while linking.

import Crypto
import Foundation
import Security
import Testing
@testable import OrttaaiLink
import OrttaaiSyncCore

/// Accepts exactly one server key, by its fingerprint.
final class PinningDelegate: NSObject, URLSessionDelegate, Sendable {
    let fingerprint: String

    init(fingerprint: String) {
        self.fingerprint = fingerprint
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let key = SecTrustCopyKey(trust),
              let bytes = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            return (.cancelAuthenticationChallenge, nil)
        }
        let seen = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return seen == fingerprint ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }
}

@Suite("Orttaai Link over HTTPS", .serialized)
struct LinkTLSTests {
    @Test func aDeviceLinksAndSyncsTrustingOnlyThePinnedKey() async throws {
        let host = MemoryHost()
        let server = LinkServer(macDeviceID: Sample.mac, name: "Mac Studio", appVersion: "1.20.0", identity: try .ephemeral(),
                                devices: LinkedDeviceStore(directory: nil), host: host)
        try await server.start(preferredPort: 48_731)
        defer { Task { await server.stop() } }
        let port = try #require(await server.port)
        let base = URL(string: "https://127.0.0.1:\(port)")!

        let pinned = URLSession(configuration: .ephemeral, delegate: PinningDelegate(fingerprint: server.identity.fingerprint), delegateQueue: nil)
        let session = await server.desk.open()
        var pair = URLRequest(url: base.appending(path: "link/v1/pair"))
        pair.httpMethod = "POST"
        pair.httpBody = try LinkWire.encode(PairRequest(code: session.code, device: LinkDeviceInfo(deviceID: Sample.linux, kind: .linux, name: "ThinkPad", app: "Orttaai")))
        let (pairData, pairResponse) = try await pinned.data(for: pair)
        #expect((pairResponse as? HTTPURLResponse)?.statusCode == 200)
        let token = try JSONDecoder().decode(PairResponse.self, from: pairData).token

        var push = URLRequest(url: base.appending(path: "sync/v1/push"))
        push.httpMethod = "POST"
        push.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let mine = try Sample.dictation("tls-1", origin: Sample.linux, kind: .linux)
        push.httpBody = try LinkWire.encode(PushRequest(records: [LinkRecord(mine)]))
        let (pushData, _) = try await pinned.data(for: push)
        #expect(try JSONDecoder().decode(PushResponse.self, from: pushData).accepted.map(\.recordName) == ["dictation.tls-1"])

        // Any other key is refused before a byte of the request is sent.
        let impostor = URLSession(configuration: .ephemeral, delegate: PinningDelegate(fingerprint: String(repeating: "0", count: 64)), delegateQueue: nil)
        await #expect(throws: URLError.self) { _ = try await impostor.data(from: base.appending(path: "link/v1/status")) }
    }
}
