// LinkSystem.swift
// Orttaai
//
// The Mac's side of finding it on the network for Orttaai Link: its names and
// home-network addresses, the Tailscale app's name for it, and the Bonjour
// advertisement. From My Local AI Link's MacSystem.

import Foundation
import SystemConfiguration

enum LinkMacNames {
    /// "Mac Studio", as set in System Settings › General › Sharing.
    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "This Mac"
    }

    /// "Mac-Studio.local".
    static var localHostName: String? {
        (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" }
    }

    /// IPv4 addresses on the home network: Wi-Fi and Ethernet first, never
    /// loopback, link-local or Tailscale's 100.64/10.
    static var lanAddresses: [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (entry.ifa_flags & UInt32(IFF_UP)) != 0, (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let parts = text.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4, parts[0] != 169, !(parts[0] == 100 && (64...127).contains(parts[1])) else { continue }
            found.append((String(cString: entry.ifa_name), text))
        }
        return found.sorted { ($0.name.hasPrefix("en") ? 0 : 1, $0.name) < ($1.name.hasPrefix("en") ? 0 : 1, $1.name) }.map(\.address)
    }
}

/// The Tailscale app on this Mac, read through its command-line tool.
enum LinkTailscaleApp {
    static let cli = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

    /// This Mac's MagicDNS name ("mac-studio.tail1b0ba8.ts.net") while
    /// Tailscale runs.
    static func dnsName() async -> String? {
        guard FileManager.default.isExecutableFile(atPath: cli) else { return nil }
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = ["status", "--json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  object["BackendState"] as? String == "Running",
                  let me = object["Self"] as? [String: Any],
                  var name = me["DNSName"] as? String, !name.isEmpty else { return nil }
            if name.hasSuffix(".") { name.removeLast() }
            return name
        }.value
    }
}

/// Advertises Orttaai Link as `_orttaai._tcp`, so devices find the Mac with
/// no typing.
@MainActor
final class LinkBonjourAdvertiser: NSObject, NetServiceDelegate {
    private var service: NetService?
    private var published: (name: String, port: Int)?

    func advertise(name: String, port: Int, record: [String: String]) {
        if published?.name != name || published?.port != port {
            service?.stop()
            let service = NetService(domain: "local.", type: "_orttaai._tcp.", name: name, port: Int32(port))
            service.delegate = self
            service.publish()
            self.service = service
            published = (name, port)
        }
        service?.setTXTRecord(NetService.data(fromTXTRecord: record.mapValues { Data($0.utf8) }))
    }

    func stop() {
        service?.stop()
        service = nil
        published = nil
    }
}
