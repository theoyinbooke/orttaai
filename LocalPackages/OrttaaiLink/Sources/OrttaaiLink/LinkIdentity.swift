// LinkIdentity.swift
// OrttaaiLink
//
// The key and certificate Orttaai Link serves HTTPS with, as in My Local AI
// Link. Made on first run and kept, so linked devices keep trusting it.
// Devices pin the public key (SHA-256 of its X9.63 bytes), not the
// certificate, so the certificate can be renewed without linking again.

import Crypto
import Foundation
import NIOSSL
import SwiftASN1
import X509

public struct LinkIdentity: Sendable {
    public let privateKey: P256.Signing.PrivateKey
    public let certificateDER: [UInt8]

    /// Lowercase hex SHA-256 of the public key's X9.63 representation.
    public var fingerprint: String { Self.fingerprint(of: privateKey.publicKey) }

    public static func fingerprint(of key: P256.Signing.PublicKey) -> String {
        SHA256.hash(data: key.x963Representation).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads the identity in `directory`, making it on first run and renewing
    /// the certificate (same key) when it has under 30 days left.
    public static func loadOrCreate(in directory: URL, now: Date = .now) throws -> LinkIdentity {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keyURL = directory.appending(path: "link-key.pem")
        let certificateURL = directory.appending(path: "link-certificate.der")

        let key: P256.Signing.PrivateKey
        if let pem = try? String(contentsOf: keyURL, encoding: .utf8) {
            key = try P256.Signing.PrivateKey(pemRepresentation: pem)
        } else {
            key = P256.Signing.PrivateKey()
            try Data(key.pemRepresentation.utf8).write(to: keyURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        }

        if let der = try? Data(contentsOf: certificateURL),
           let certificate = try? Certificate(derEncoded: Array(der)),
           certificate.publicKey == Certificate.PublicKey(key.publicKey),
           certificate.notValidAfter > now.addingTimeInterval(30 * 86_400) {
            return LinkIdentity(privateKey: key, certificateDER: Array(der))
        }
        let der = try makeCertificate(for: key, now: now)
        try Data(der).write(to: certificateURL, options: [.atomic])
        return LinkIdentity(privateKey: key, certificateDER: der)
    }

    /// An identity kept only in memory, for tests.
    public static func ephemeral(now: Date = .now) throws -> LinkIdentity {
        let key = P256.Signing.PrivateKey()
        return LinkIdentity(privateKey: key, certificateDER: try makeCertificate(for: key, now: now))
    }

    static func makeCertificate(for key: P256.Signing.PrivateKey, now: Date) throws -> [UInt8] {
        let signingKey = Certificate.PrivateKey(key)
        let name = try DistinguishedName { CommonName("Orttaai Link") }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: signingKey.publicKey,
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(397 * 86_400),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
            },
            issuerPrivateKey: signingKey
        )
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return serializer.serializedBytes
    }

    public func tlsConfiguration() throws -> TLSConfiguration {
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: certificateDER, format: .der))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(privateKey.pemRepresentation.utf8), format: .pem))
        )
        configuration.minimumTLSVersion = .tlsv12
        return configuration
    }
}
