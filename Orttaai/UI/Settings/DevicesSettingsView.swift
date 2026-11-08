// DevicesSettingsView.swift
// Orttaai
//
// Settings › Devices: the PCs and Android phones linked to this Mac through
// Orttaai Link, what each has synced, and linking a new one with a code or a
// QR code. Their dictations reach iCloud, and Orttakey on iPhone, through
// this Mac.

import CoreImage
import CoreImage.CIFilterBuiltins
import OrttaaiLink
import OrttaaiSyncCore
import SwiftUI

struct DevicesSettingsView: View {
    @State private var link = LinkController.shared
    @State private var sync = ArchiveSyncController.shared
    @State private var showsLinking = false
    @State private var renaming: LinkedDevice?
    @State private var removing: LinkedDevice?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SettingsCard(
                "Linked Devices",
                info: "Orttaai for Windows and Linux and Orttakey for Android sync through this Mac: at home on the same Wi-Fi, or away over Tailscale. Keep Orttaai running here; a device holds its changes until it reaches this Mac."
            ) {
                Button {
                    showsLinking = true
                    Task { await link.openLinking() }
                } label: {
                    Label("Link a Device", systemImage: "plus")
                }
                .buttonStyle(OrttaaiButtonStyle(.primary, size: .small))
            } content: {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    statusRow
                    if link.devices.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(link.devices.enumerated()), id: \.element.id) { index, device in
                            if index > 0 { SettingsDivider() }
                            DeviceRow(device: device, totals: link.totals[device.id]) {
                                renaming = device
                            } onRemove: {
                                removing = device
                            }
                        }
                    }
                    if !link.devices.isEmpty, !sync.isEnabled {
                        SettingsNotice(kind: .info, message: "iCloud Sync is off, so linked devices' dictations stay on this Mac. Turn it on in General to see them on your iPhone too.")
                    }
                }
                .padding(.bottom, Spacing.xs)
            }

            SettingsCard("How Linking Works") {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    step("1", "Install Orttaai on your Windows or Linux PC, or Orttakey on your Android phone.")
                    step("2", "Choose Link a Device here. A PC finds this Mac on your Wi-Fi and asks for the code; a phone scans the QR code.")
                    step("3", "That's it. Dictations, words and snippets sync both ways, and each dictation shows the device it was said on.")
                    SettingsFootnote("Away from home, devices reach this Mac over Tailscale when both are on your tailnet.")
                }
            }
        }
        .sheet(isPresented: $showsLinking, onDismiss: { Task { await link.closeLinking() } }) {
            LinkDeviceSheet(link: link) { showsLinking = false }
        }
        .sheet(item: $renaming) { device in
            RenameDeviceSheet(device: device) { name in
                Task { await link.rename(device, to: name) }
                renaming = nil
            } onCancel: { renaming = nil }
        }
        .confirmationDialog(
            "Remove \(removing?.name ?? "this device")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { device in
            Button("Remove", role: .destructive) { Task { await link.remove(device) } }
        } message: { _ in
            Text("It stops syncing with this Mac at once. Its dictations stay here and in iCloud. You can link it again any time.")
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch link.state {
        case .off:
            EmptyView()
        case .starting:
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Starting Orttaai Link")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }
        case .running:
            HStack(spacing: Spacing.sm) {
                StatusChip(title: "Ready on Wi-Fi", systemImage: "wifi", tint: Color.Orttaai.success)
                if link.tailscaleName != nil {
                    StatusChip(title: "Ready over Tailscale", systemImage: "network", tint: Color.Orttaai.success)
                }
            }
        case .failed(let message):
            SettingsNotice(kind: .error, message: message)
        }
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 20))
                .foregroundStyle(Color.Orttaai.textTertiary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("No devices linked yet")
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Text("Link your Windows or Linux PC or your Android phone, and its dictations join this Mac's: in History, Analytics and iCloud.")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Spacing.sm)
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(number)
                .font(.Orttaai.monoSmall)
                .foregroundStyle(Color.Orttaai.accent)
                .frame(width: 14, alignment: .leading)
            Text(text)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - A linked device

private struct DeviceRow: View {
    let device: LinkedDevice
    let totals: DeviceTotals?
    let onRename: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            Image(systemName: DeviceLabel.symbol(device.kind))
                .font(.system(size: 16))
                .foregroundStyle(Color.Orttaai.textSecondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text(device.name)
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                    Text(device.kind.displayName)
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                }
                Text(totalsText)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .monospacedDigit()
                Text(activityText)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
            }
            Spacer(minLength: Spacing.md)
            Menu {
                Button("Rename…", action: onRename)
                Divider()
                Button("Remove…", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Options for \(device.name)")
        }
        .padding(.vertical, Spacing.xs)
    }

    private var totalsText: String {
        guard let totals, totals.dictations > 0 else { return "No dictations yet" }
        let dictations = "\(totals.dictations.formatted()) dictation\(totals.dictations == 1 ? "" : "s")"
        let words = "\(totals.words.formatted()) word\(totals.words == 1 ? "" : "s")"
        return "\(dictations) · \(words) · \(Self.duration(ms: totals.recordingMs)) spoken"
    }

    private var activityText: String {
        var parts: [String] = []
        let app = [device.app, device.appVersion].compactMap { $0 }.joined(separator: " ")
        parts.append(app)
        if let seen = device.lastSeen {
            parts.append("synced \(seen.formatted(.relative(presentation: .named)))")
            parts.append(device.viaTailnet ? "through Tailscale" : "on home Wi-Fi")
        } else {
            parts.append("linked \(device.linkedAt.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: " · ")
    }

    static func duration(ms: Int) -> String {
        let minutes = ms / 60_000
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(max(ms / 1000, 0))s"
    }
}

// MARK: - Linking a device

struct LinkDeviceSheet: View {
    let link: LinkController
    let onDone: () -> Void
    /// Devices linked since this moment are the ones this window linked
    /// (linking again replaces a device, so counting wouldn't show it).
    @State private var since = Date()
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Link a Device")
                    .font(.Orttaai.title)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Text("Keep this window open while you link. The code works once, and a new one appears every 5 minutes.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }

            if newlyLinked == nil, case .failed(let message) = link.state {
                SettingsNotice(kind: .error, message: message)
            }

            if let linked = newlyLinked {
                linkedState(linked)
                    .frame(minHeight: 220)
            } else {
                HStack(alignment: .top, spacing: Spacing.lg) {
                    pcColumn
                    Divider()
                    phoneColumn
                }
                .frame(minHeight: 220)
            }

            HStack {
                if newlyLinked == nil, let session = link.session {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(remaining(until: session.expires, now: context.date))
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                            .monospacedDigit()
                    }
                }
                Spacer()
                Button(newlyLinked == nil ? "Cancel" : "Done", action: onDone)
                    .buttonStyle(OrttaaiButtonStyle(newlyLinked == nil ? .secondary : .primary, size: .small))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xxl)
        .frame(width: 600)
        .background(Color.Orttaai.bgPrimary)
        .onAppear {
            since = Date()
            link.isLinkWindowOpen = true
        }
        .onDisappear { link.isLinkWindowOpen = false }
        // A fresh code before the old one runs out, for as long as this is open.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard newlyLinked == nil else { continue }
                if let session = link.session, session.expires.timeIntervalSinceNow > 2 { continue }
                await link.openLinking()
            }
        }
    }

    private var newlyLinked: LinkedDevice? {
        link.devices.filter { $0.linkedAt >= since.addingTimeInterval(-1) }.max { $0.linkedAt < $1.linkedAt }
    }

    private func linkedState(_ device: LinkedDevice) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.Orttaai.success)
            VStack(spacing: Spacing.xs) {
                Text("\(device.name) is linked")
                    .font(.Orttaai.heading)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Text("\(device.kind.displayName) · \(device.app). It syncs with this Mac from now on, at home and away.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button("Link Another Device") {
                since = Date()
                Task { await link.openLinking() }
            }
            .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
        }
        .frame(maxWidth: .infinity)
    }

    private var pcColumn: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Label("Windows or Linux PC", systemImage: "pc")
                .font(.Orttaai.subheading)
                .foregroundStyle(Color.Orttaai.textPrimary)
            Text("In Orttaai on the PC, open Devices, choose \(link.computerName), and type:")
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(spacedCode)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .foregroundStyle(link.session == nil ? Color.Orttaai.textTertiary : Color.Orttaai.textPrimary)
                .textSelection(.enabled)
                .accessibilityLabel("Code \(link.session?.code.map(String.init).joined(separator: " ") ?? "not ready")")
            if link.linkingURL != nil {
                Button {
                    copyLink()
                } label: {
                    Label(copied ? "Copied" : "Copy Link for a PC Away from Home", systemImage: copied ? "checkmark" : "link")
                }
                .buttonStyle(OrttaaiButtonStyle(.ghost, size: .small))
                .help("Paste it into Orttaai on a PC that isn't on this Wi-Fi. It works over Tailscale.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var phoneColumn: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Label("Android phone", systemImage: "smartphone")
                .font(.Orttaai.subheading)
                .foregroundStyle(Color.Orttaai.textPrimary)
            Text("In Orttakey, open Settings › Sync, choose Link to a Mac, and scan:")
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if let url = link.linkingURL, let image = QRCode.image(for: url.absoluteString) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .accessibilityLabel("QR code to link a phone")
                } else {
                    ProgressView()
                }
            }
            .frame(width: 150, height: 150)
            .padding(Spacing.sm)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var spacedCode: String {
        guard let code = link.session?.code else { return "––– –––" }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    private func remaining(until expiry: Date, now: Date) -> String {
        let seconds = max(Int(expiry.timeIntervalSince(now)), 0)
        return "Code expires in \(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    private func copyLink() {
        guard let url = link.linkingURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        copied = true
    }
}

private struct RenameDeviceSheet: View {
    let device: LinkedDevice
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Rename Device")
                .font(.Orttaai.heading)
                .foregroundStyle(Color.Orttaai.textPrimary)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            Text("The name shows here and next to its dictations.")
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
                Button("Save") { onSave(name) }
                    .buttonStyle(OrttaaiButtonStyle(.primary, size: .small))
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 360)
        .background(Color.Orttaai.bgPrimary)
        .onAppear { name = device.name }
    }
}

enum QRCode {
    /// A crisp QR code for `text`, scaled up without smoothing.
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
