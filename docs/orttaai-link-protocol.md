# Orttaai Link protocol (v1)

Orttaai Link lets devices that can't use Orttaai's iCloud sync take part in it through a Mac.
Orttaai on the Mac runs the Link service; Orttaai for Windows and Linux and Orttakey for Android
link to it. The Mac stores what they send in its own sync database and uploads it to iCloud like its
own changes, and sends back what they need from the archive. iPhones and iPads keep syncing through
iCloud directly.

This document is the contract the four codebases are built to:

| App | Repo | Role |
| --- | --- | --- |
| Orttaai for Mac | `orttaai` | Link host: the only side that talks to iCloud |
| Orttaai for Windows and Linux | `orttaai-desktop` | Linked device, platform `mac` |
| Orttakey for Android | `OrttaKeyAndroid` | Linked device, platform `mobile` |
| Orttakey for iPhone and iPad | `orttakey` | Not linked; reads linked devices' records from iCloud |

The sync rules themselves (record names, zones, revisions, conflicts, tombstones) are the ones in
`LocalPackages/OrttaaiSync` and `orttakey/.claude/handoff/plans/icloud-sync-agreed.md`. Link carries
the same records over a different wire; it adds no rule of its own about which version wins.

Modelled on My Local AI Link (`mylokai/docs/link-protocol.md`), which already works on Wi-Fi and
over Tailscale with iPhone and Android.

## 1. Device kinds and schema versions

`DeviceKind` gains `windows`, `linux` and `android`. Each linked device reads what its platform reads:

| Kind | Platform | Reads | May write |
| --- | --- | --- | --- |
| `windows`, `linux` | `mac` | every zone | its own dictations, any dictation's edit or deletion, dictionary words, snippets, learning suggestions, writing insights, chats, its own device record |
| `android` | `mobile` | `Library`, its own dictation zone | its own dictations, dictionary words, its own device record |

Never written by a linked device: `MacSummary`, `MacPreferences`, `ToneProfile` (they belong to a Mac),
and another device's `Device` record. `MacPreferences` and `ToneProfile` are not sent to linked
devices either: they are one Mac's settings.

Schema versions: a record that names a new kind (a dictation whose origin is one of them, or that
device's own `Device` record) is written as **schema 2**. Every other record stays schema 1. An app
from before schema 2 quarantines a schema-2 record as `unsupportedSchemaVersion` and reads it again
after updating, so nothing is dropped or misread. Apps from schema 2 on also read an unknown kind as
`unknown`. Writers never pick the version by hand: `SyncEnvelope.init` takes the lowest version that
carries the record.

## 2. Transport

- HTTPS on port **47821** (the next free port if taken), on every interface, so it works on Wi-Fi
  and on Tailscale.
- Self-signed P-256 certificate, made on first run and kept in Orttaai's Application Support.
  Devices trust it by its **SHA-256 fingerprint** (lowercase hex of the DER), learnt while linking.
  There's no CA and no hostname check: the fingerprint is the identity. A device refuses any other
  certificate, whatever address it reached.
- JSON bodies, UTF-8, `Content-Type: application/json`. Requests over 8 MB are refused with `413`.

## 3. Finding the Mac: Bonjour

Service type `_orttaai._tcp`, the instance name being the Mac's name. TXT record:

| key | value |
| --- | --- |
| `v` | `1` (this protocol) |
| `id` | the Mac's Orttaai device ID |
| `fp` | certificate fingerprint |
| `host` | `<LocalHostName>.local` |
| `ips` | LAN IPv4 addresses, comma-separated |
| `port` | the HTTPS port |
| `pair` | `1` while the Link window is open |

Desktop uses mDNS (`mdns-sd`); Android uses `NsdManager`.

## 4. Linking

Settings › Devices › Link a device opens a **linking session** for 5 minutes: a 32-byte secret
(base64url) for the QR code and a 6-digit code. Both are single use; the code allows 5 wrong tries
before the session closes. PCs type the code (they found the Mac by Bonjour, which gives the
fingerprint). Android scans the QR code.

QR code payload:

```
orttaai://link?v=1&id=<macDeviceID>&n=<name>&h=<host>,<host>&p=<port>&fp=<fingerprint>[&ts=<tailscale DNS name>]#<secret>
```

`h` lists the addresses to try at home (LAN IPs, then the `.local` name). `ts` is the Mac's Tailscale
name when it has one. The same string can be copied as text, so a PC away from home can link too.

`POST /link/v1/pair` (no key)

```json
{
  "secret": "…" | "code": "123456",
  "device": { "deviceID": "…", "kind": "linux", "name": "ThinkPad", "model": "…",
              "app": "Orttaai", "appVersion": "0.4.0", "osVersion": "Ubuntu 26.04" }
}
```

- `200` `{ "token": "…", "macDeviceID": "…", "name": "Mac Studio", "tailscaleName": "…" | null, "protocol": 1 }`
- `400` the kind isn't one that links (`mac`, `iphone`, `ipad`, `unknown`) · `401` wrong secret or code ·
  `410` no linking session open · `429` too many wrong codes

The token is 32 random bytes (base64url). The Mac stores only its SHA-256, with the device's ID,
kind and name. Linking the same `deviceID` again replaces its token. Removing a device on the Mac
revokes its token at once; its records stay in the archive.

## 5. Records on the wire

One record is a `SyncEnvelope` as JSON. `payload` is base64 of the payload JSON, the one
`PayloadCoder` writes on Apple devices: the same keys, dates as integer milliseconds since 1970, `Data`
fields as base64 strings, optional fields left out when they have no value. The Mac uploads the bytes
it receives unchanged.

Every app must write the same keys and values; the bytes needn't match. Swift writes `/` as `\/`
and Rust and Kotlin don't, and both are the same JSON. Readers accept a missing optional field and
`null` alike, and ignore keys they don't know (a newer app may add optional fields). All dates in the
envelope are integer milliseconds since 1970.

```json
{
  "zone": "Dictations-2f0c…",
  "recordName": "dictation.8d1e…",
  "schemaVersion": 2,
  "revision": { "counter": 41, "modifiedAt": 1790000000000, "writer": "2f0c…" },
  "generation": 0,
  "isDeleted": false,
  "deletedAt": null,
  "payload": "eyJjcmVhdGVkQXQiOjE3OTAwMDAwMDAwMDAs…",
  "origin": { "deviceID": "2f0c…", "kind": "linux" },
  "createdAt": 1790000000000
}
```

`origin` and `createdAt` are present on dictations only. A deleted dictation has no payload.

Sample files for every record kind a linked device sends or receives live in
`LocalPackages/OrttaaiSync/Tests/Fixtures/link/`. Each holds `record` (as sent), `payloadBytes` (the
payload JSON as Swift wrote it) and `payloadReadable` (the same, spelled out). The Swift tests check
that this version still writes them; the Rust and Kotlin tests keep a copy, read every file, and check
that decoding the payload and writing it again gives the same JSON values.

## 6. Syncing (`Authorization: Bearer <token>`)

### Send: `POST /sync/v1/push`

```json
{ "records": [ <envelope>, … ] }
```

Up to 500 records per request. The Mac checks each record (`SyncEnvelope.problem`, the write rules in
§1, origin matching the sender for new dictations), then applies the batch in one transaction with the
same conflict policy it uses for iCloud. Every accepted record is queued for iCloud at its own
revision, in its own zone (the Mac creates `Dictations-<deviceID>` the first time).

```json
{
  "accepted": [ { "recordName": "…", "revision": { … } } ],
  "newer":    [ <envelope> ],
  "rejected": [ { "recordName": "…", "problem": "payload of 1200000 bytes is over the limit" } ]
}
```

- `accepted`: the device retires the outbox entry for that revision (a newer local revision stays).
- `newer`: the Mac already had a newer version; the device applies it and retires its entry.
- `rejected`: kept visible on the device, in the outbox, the way iCloud's permanent failures are.

### Receive: `GET /sync/v1/changes?since=<cursor>&limit=500&wait=25`

Every record that changed on the Mac after `cursor` and that the device's platform reads, tombstones
included, in change order. `since` is empty the first time. With `wait`, the Mac holds the request up
to that many seconds when nothing has changed, so a change reaches the device within moments.

```json
{ "records": [ <envelope>, … ], "cursor": "1834", "more": false }
```

The device applies the records with the same conflict policy, moves its revision clock past every
revision it sees, then stores the cursor. Records it wrote itself come back too and are no-ops.
`cursor` is the Mac's change sequence (§7); a device must treat it as opaque.

### Status: `GET /link/v1/status`

```json
{ "name": "Mac Studio", "macDeviceID": "…", "version": "1.20.0", "protocol": 1,
  "iCloud": { "state": "syncing" | "paused" | "signedOut" | "off", "lastSentAt": 1790000000000 },
  "tailscaleName": "…" | null }
```

The device shows this on its Devices page ("Synced with Mac Studio · iCloud up to date").

### Errors

`401 {"error":{"code":"unlinked"}}`: the device was removed on the Mac; it shows "Link again" and
keeps its queue. `426 {"error":{"code":"updateMac"}}`: the device speaks a newer protocol or sends a
schema the Mac can't read; it keeps its queue and asks for an Orttaai update on the Mac. `503`:
iCloud sync is off or paused on the Mac; records are still accepted and stored, and go to iCloud when
it resumes.

## 7. What the Mac keeps

- `sync_record.changeSeq`: a number raised from one counter on every write to the row (local edit,
  iCloud fetch, Link push). The change feed reads rows with `changeSeq > cursor` in order.
- `link_device`: one row per linked device: ID, kind, name, token hash, linked at, last seen, last
  pushed, last pulled, address last used (LAN or Tailscale). The Devices page reads it with each
  device's `Device` record (its totals).
- Linked devices' records live in the same tables as everything else, so History, Analytics, Chat,
  Memory Graph and the iCloud summary for phones include them with no extra work.

## 8. What a linked device keeps

The same sync tables as the Mac (`sync_record`, `sync_outbox`, tombstones, a device ID, a revision
counter), plus the Mac's ID, fingerprint, addresses, Tailscale name, token and cursor. Every local
change commits its row and an outbox entry in one transaction. It publishes its own `Device` record
(name, kind, app, versions, totals of its own dictations) when totals change, at most every minute.

## 9. When it talks

- Push: 2 seconds after a change (batched), at launch, and when the Mac comes back.
- Pull: one long-poll held open while the app runs; after an error, back off 5 s, 15 s, 60 s, then
  every 5 minutes.
- Address order: the last address that worked, LAN addresses from Bonjour, the `.local` name, then
  the Tailscale name. A device never needs the Mac's IP typed in.
- When the Mac is off or asleep nothing is lost: the outbox waits and goes on the next connection.

## 10. Tailscale

- Mac: Orttaai joins the user's tailnet as its own node with TailscaleKit (userspace, no VPN), as
  My Local AI Link does, and forwards that node's port to the Link port. Its MagicDNS name goes in the
  QR code, the pair response and status.
- Android: Orttakey embeds the same userspace node (MyLocalAIAndroid's `tailnet` module).
- Windows and Linux: Orttaai uses the Tailscale app if it's installed and dials the Mac's MagicDNS
  name. A built-in node can follow later.
- The TLS between device and Mac is untouched; the tailnet only carries it.

## 11. Privacy

Nothing leaves the user's own devices and iCloud: no server of ours, no relay. Dictation text never
appears in logs. The payload is encrypted in transit by TLS pinned to the Mac, and in iCloud by the
existing encrypted field.
