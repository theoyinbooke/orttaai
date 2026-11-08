// LinkWire.swift
// OrttaaiSync
//
// A record as Orttaai Link sends it between the Mac and a linked device
// (docs/orttaai-link-protocol.md §5). The payload travels as base64 of its
// JSON, and the Mac uploads the bytes it receives to iCloud unchanged.

import Foundation

public struct LinkRecord: Codable, Hashable, Sendable {
    public struct WireRevision: Codable, Hashable, Sendable {
        public var counter: Int64
        /// Milliseconds since 1970.
        public var modifiedAt: Int64
        public var writer: String
    }

    public struct WireOrigin: Codable, Hashable, Sendable {
        public var deviceID: String?
        public var kind: DeviceKind
    }

    public var zone: String
    public var recordName: String
    public var schemaVersion: Int
    public var revision: WireRevision
    public var generation: Int64
    public var isDeleted: Bool
    public var deletedAt: Int64?
    /// Base64 of the payload JSON.
    public var payload: String?
    public var origin: WireOrigin?
    public var createdAt: Int64?

    public init(_ envelope: SyncEnvelope) {
        zone = envelope.id.zone.zoneName
        recordName = envelope.id.recordName
        schemaVersion = envelope.schemaVersion
        revision = WireRevision(
            counter: envelope.revision.counter,
            modifiedAt: LinkWire.milliseconds(envelope.revision.modifiedAt),
            writer: envelope.revision.writerDeviceID
        )
        generation = envelope.generation
        isDeleted = envelope.isDeleted
        deletedAt = envelope.deletedAt.map(LinkWire.milliseconds)
        payload = envelope.payload?.base64EncodedString()
        origin = envelope.origin.map { WireOrigin(deviceID: $0.deviceID, kind: $0.kind) }
        createdAt = envelope.createdAt.map(LinkWire.milliseconds)
    }

    /// The envelope this record carries. Whether it may be applied is still
    /// `SyncEnvelope.problem`'s call.
    public func envelope() throws -> SyncEnvelope {
        guard let zone = SyncZone(zoneName: zone) else { throw LinkWireError.unknownZone(self.zone) }
        var data: Data?
        if let payload {
            guard let decoded = Data(base64Encoded: payload) else { throw LinkWireError.unreadablePayload(recordName) }
            data = decoded
        }
        return SyncEnvelope(
            id: SyncRecordID(zone: zone, recordName: recordName),
            schemaVersion: schemaVersion,
            revision: Revision(counter: revision.counter, modifiedAt: LinkWire.date(revision.modifiedAt), writerDeviceID: revision.writer),
            generation: generation,
            isDeleted: isDeleted,
            deletedAt: deletedAt.map(LinkWire.date),
            payload: data,
            origin: origin.map { DictationOrigin(deviceID: $0.deviceID, kind: $0.kind) },
            createdAt: createdAt.map(LinkWire.date)
        )
    }
}

public enum LinkWireError: Error, Hashable, Sendable, CustomStringConvertible {
    case unknownZone(String)
    case unreadablePayload(String)

    public var description: String {
        switch self {
        case .unknownZone(let zone): "unknown zone \(zone)"
        case .unreadablePayload(let name): "payload of \(name) isn't base64"
        }
    }
}

public enum LinkWire {
    /// Keys sorted so the same record always gives the same bytes.
    public static func encode<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}
