// LinkTestServer
//
// The real Orttaai Link service with an archive kept in memory, advertised on
// Bonjour, for testing a linked device (Orttaai for Windows and Linux,
// Orttakey for Android) against it without touching Orttaai's own data.
//
//   swift run LinkTestServer [port]
//
// Prints one JSON line with what a device needs (port, fingerprint, code,
// invite link), then logs what devices send. Ctrl-C to stop.

import Foundation
import OrttaaiLink
import OrttaaiSyncCore

actor MemoryArchive: LinkHost {
    private(set) var records: [String: (envelope: SyncEnvelope, seq: Int64)] = [:]
    private var seq: Int64 = 0

    func put(_ envelope: SyncEnvelope) {
        seq += 1
        records[envelope.id.recordName] = (envelope, seq)
    }

    func existingRecordNames(_ names: [String]) -> Set<String> {
        Set(names.filter { records[$0] != nil })
    }

    func apply(_ envelopes: [SyncEnvelope], from device: LinkedDevice) -> LinkPushOutcome {
        var outcome = LinkPushOutcome()
        for envelope in envelopes {
            let local = records[envelope.id.recordName].map {
                LocalRecordState(revision: $0.envelope.revision, isDeleted: $0.envelope.isDeleted, generation: $0.envelope.generation)
            }
            switch ConflictPolicy.decide(local: local, remote: envelope) {
            case .acceptRemote:
                put(envelope)
                outcome.accepted[envelope.id] = envelope.revision
                var line = "PUSH \(envelope.id.recordName) from \(device.kind.rawValue)"
                if let payload = envelope.payload, let text = (try? PayloadCoder.decode(DictationPayload.self, from: payload))?.text {
                    line += " text=\(text)"
                }
                if envelope.isDeleted { line += " deleted" }
                print(line)
            case .keepLocal:
                if let mine = records[envelope.id.recordName]?.envelope { outcome.newer.append(mine) }
            case .alreadyCurrent:
                outcome.accepted[envelope.id] = envelope.revision
            }
        }
        fflush(stdout)
        return outcome
    }

    func changes(after cursor: Int64, limit: Int, for device: LinkedDevice) -> LinkChangePage {
        let after = records.values.filter { $0.seq > cursor }.sorted { $0.seq < $1.seq }
        let page = after.prefix(limit)
        return LinkChangePage(records: page.map(\.envelope), cursor: page.last?.seq ?? cursor, more: after.count > limit)
    }

    func iCloudStatus() -> ICloudStatus { ICloudStatus(state: .syncing, lastSentAt: Date()) }
}

let macID = "6f1d1c9e-1b7a-4c55-9c39-0d3c1e2a7b10"
let archive = MemoryArchive()
let now = SyncDate.rounded(Date())
let seedDictation = SyncEnvelope(
    id: .dictation(syncID: "mac-seed-1", zone: .dictations(originDeviceID: macID)),
    revision: Revision(counter: 1, modifiedAt: now, writerDeviceID: macID),
    payload: try PayloadCoder.encode(DictationPayload(createdAt: now, text: "Said on the Mac", targetAppName: "Claude Code", recordingMs: 2_400)),
    origin: DictationOrigin(deviceID: macID, kind: .mac),
    createdAt: now
)
let seedWord = DictionaryEntryPayload(source: "Orttaai", target: "Orttaai", createdAt: now)
await archive.put(seedDictation)
await archive.put(SyncEnvelope(
    id: .dictionaryEntry(normalizedSource: seedWord.normalizedSource),
    revision: Revision(counter: 2, modifiedAt: now, writerDeviceID: macID),
    payload: try PayloadCoder.encode(seedWord)
))

let port = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 48_990
let server = LinkServer(macDeviceID: macID, name: "Link Test Mac", appVersion: "test", identity: try .ephemeral(),
                        devices: LinkedDeviceStore(directory: nil), host: archive)
try await server.start(preferredPort: port)
let session = await server.desk.open()
let actualPort = await server.port ?? port
let invite = await server.linkingURL(for: session, hosts: ["127.0.0.1"])?.absoluteString ?? ""

let record = await server.bonjourRecord(host: "localhost", addresses: ["127.0.0.1"], linking: true)
// Bonjour needs a run loop: give it a thread of its own.
let bonjour = Thread {
    let service = NetService(domain: "local.", type: "_orttaai._tcp.", name: "Link Test Mac", port: Int32(actualPort))
    service.setTXTRecord(NetService.data(fromTXTRecord: record.mapValues { Data($0.utf8) }))
    service.schedule(in: .current, forMode: .default)
    service.publish()
    while true { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
}
bonjour.start()

let info: [String: Any] = ["port": actualPort, "fingerprint": server.identity.fingerprint, "code": session.code, "macDeviceID": macID, "invite": invite]
print(String(decoding: try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]), as: UTF8.self))
fflush(stdout)

while true {
    try await Task.sleep(for: .seconds(3600))
}
