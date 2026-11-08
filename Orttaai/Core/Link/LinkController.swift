// LinkController.swift
// Orttaai
//
// Orttaai Link on this Mac: runs the HTTPS service linked devices sync with
// (Orttaai for Windows and Linux, Orttakey for Android), advertises it on the
// home network, opens linking sessions, and keeps what Settings › Devices
// shows. It runs once a device is linked, or while the Link window is open.
// The contract is docs/orttaai-link-protocol.md.

import Foundation
import Observation
import OrttaaiLink
import OrttaaiSyncCore
import os

@MainActor
@Observable
final class LinkController {
    static let shared = LinkController()

    enum State: Equatable {
        case off
        case starting
        case running(port: Int)
        case failed(String)
    }

    private(set) var state: State = .off
    private(set) var devices: [LinkedDevice] = []
    /// Each linked device's own dictations, counted here.
    private(set) var totals: [String: DeviceTotals] = [:]
    private(set) var session: LinkingSession?
    private(set) var linkingURL: URL?
    /// The name devices reach this Mac by over Tailscale, when it has one.
    private(set) var tailscaleName: String?
    private(set) var addresses: [String] = []
    let computerName = LinkMacNames.computerName

    var isRunning: Bool { if case .running = state { true } else { false } }

    @ObservationIgnored private var server: LinkServer?
    @ObservationIgnored private var host: MacLinkHost?
    @ObservationIgnored private let bonjour = LinkBonjourAdvertiser()
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var totalsTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.orttaai.link", category: "controller")

    static var supportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Orttaai/Link", directoryHint: .isDirectory)
    }

    private var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private init() {}

    // MARK: Running

    /// At launch: serve when a device is linked.
    func startIfNeeded() async {
        guard !isTesting else { return }
        let store = LinkedDeviceStore(directory: Self.supportDirectory)
        guard await !store.devices.isEmpty else { return }
        await start()
    }

    func start() async {
        guard server == nil, state != .starting else { return }
        state = .starting
        do {
            let database = try DatabaseManager()
            let device = ArchiveSyncController.deviceInfo()
            let host = MacLinkHost(dbQueue: database.dbQueue, device: device)
            let devices = LinkedDeviceStore(directory: Self.supportDirectory)
            let server = LinkServer(
                macDeviceID: device.deviceID, name: computerName,
                appVersion: device.appVersion ?? "unknown",
                identity: try LinkIdentity.loadOrCreate(in: Self.supportDirectory),
                devices: devices, host: host
            )
            try await server.start()
            self.server = server
            self.host = host
            await devices.onChange { list in Task { @MainActor in self.devicesChanged(list) } }
            ArchiveSyncController.shared.onArchiveChanged = { [weak self] in self?.archiveChanged() }
            state = .running(port: await server.port ?? LinkProtocol.defaultPort)
            await refreshNetwork()
            startTimer()
        } catch {
            logger.error("Orttaai Link couldn't start: \(error.localizedDescription, privacy: .public)")
            state = .failed("Orttaai couldn't open its Link port: \(error.localizedDescription)")
        }
    }

    func stop() async {
        timer?.cancel()
        timer = nil
        await server?.stop()
        server = nil
        host = nil
        bonjour.stop()
        session = nil
        linkingURL = nil
        state = .off
    }

    // MARK: Linking

    /// Opens a 5-minute linking session: a code to type on a PC, a QR code
    /// for a phone.
    func openLinking() async {
        await start()
        guard let server else { return }
        let opened = await server.desk.open()
        session = opened
        await refreshNetwork()
        linkingURL = await server.linkingURL(for: opened, hosts: linkHosts)
    }

    func closeLinking() async {
        await server?.desk.close()
        session = nil
        linkingURL = nil
        await advertise()
        if devices.isEmpty { await stop() }
    }

    func remove(_ device: LinkedDevice) async {
        await server?.devices.remove(device.id)
    }

    func rename(_ device: LinkedDevice, to name: String) async {
        await server?.devices.rename(device.id, to: name)
    }

    // MARK: Changes

    private func devicesChanged(_ list: [LinkedDevice]) {
        let newlyLinked = list.count > devices.count
        devices = list.sorted { $0.linkedAt < $1.linkedAt }
        // A device just linked with the code: the session is used up.
        if newlyLinked, session != nil {
            session = nil
            linkingURL = nil
        }
        refreshTotals()
    }

    private func archiveChanged() {
        Task { await server?.notifyChanged() }
        refreshTotals()
    }

    private func refreshTotals() {
        totalsTask?.cancel()
        totalsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, let host = self.host else { return }
            let ids = self.devices.map(\.id)
            let totals = await Task.detached { (try? host.deviceTotals(ids)) ?? [:] }.value
            self.totals = totals
        }
    }

    #if DEBUG
    /// Sample state for rendering the Devices page in tests.
    func showPreview(devices: [LinkedDevice], totals: [String: DeviceTotals], tailscaleName: String?, session: LinkingSession? = nil, url: URL? = nil) {
        self.session = session
        self.linkingURL = url
        self.devices = devices
        self.totals = totals
        self.tailscaleName = tailscaleName
        state = .running(port: LinkProtocol.defaultPort)
    }
    #endif

    // MARK: Network

    /// Addresses a device tries at home: LAN addresses, then the .local name.
    private var linkHosts: [String] {
        addresses + [LinkMacNames.localHostName].compactMap { $0 }
    }

    private func startTimer() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await self?.tick()
            }
        }
    }

    /// Every 15 seconds: addresses, Tailscale, the linking timer, Bonjour.
    private func tick() async {
        if let session, session.expires < .now { await closeLinking() }
        await refreshNetwork()
    }

    private func refreshNetwork() async {
        addresses = LinkMacNames.lanAddresses
        let name = await LinkTailscaleApp.dnsName()
        if name != tailscaleName {
            tailscaleName = name
            await server?.setTailscaleName(name)
        }
        await advertise()
    }

    private func advertise() async {
        guard let server, let port = await server.port else {
            bonjour.stop()
            return
        }
        let record = await server.bonjourRecord(host: LinkMacNames.localHostName ?? "", addresses: addresses, linking: session != nil)
        bonjour.advertise(name: computerName, port: port, record: record)
    }
}
