// CloudSyncSettingsView.swift
// Orttaai
//
// Settings › iCloud Sync: on or off, where sync stands, the devices sharing
// this archive (Macs, and Orttakey on iPhone and iPad), and any choice only
// the person can make.

import OrttaaiSyncCore
import SwiftUI

struct CloudSyncSettingsView: View {
    @State private var sync = ArchiveSyncController.shared
    @State private var isWorking = false

    var body: some View {
        SettingsCard(
            "iCloud Sync",
            info: "Dictations, your dictionary, snippets, insights, chats and settings sync through your private iCloud, encrypted. Orttakey on iPhone and iPad adds its dictations here."
        ) {
            HStack(spacing: Spacing.sm) {
                if sync.phase == .running {
                    Button {
                        run { await sync.syncNow(includingOlderMacs: true) }
                    } label: {
                        Label("Sync Now", systemImage: "arrow.clockwise.icloud")
                    }
                    .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
                    .disabled(isWorking)
                }
                Toggle("iCloud Sync", isOn: Binding(
                    get: { sync.isEnabled },
                    set: { on in run { on ? await sync.enable() : await sync.disable() } }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(isWorking || sync.phase == .starting)
            }
        } content: {
            VStack(alignment: .leading, spacing: Spacing.md) {
                statusRow
                notices
                if sync.phase == .needsAccountChoice { accountChoice }
                if sync.isEnabled, !sync.devices.isEmpty { devicesList }
            }
            .padding(.bottom, Spacing.xs)
        }
        .task { await sync.startIfEnabled() }
    }

    // MARK: Status

    @ViewBuilder
    private var statusRow: some View {
        switch sync.phase {
        case .off:
            EmptyView()
        case .starting:
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Connecting to iCloud")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }
        case .running:
            Label(runningText, systemImage: sync.pendingCount > 0 ? "arrow.triangle.2.circlepath.icloud" : "checkmark.icloud")
                .font(.Orttaai.caption)
                .foregroundStyle(sync.pendingCount > 0 ? Color.Orttaai.textSecondary : Color.Orttaai.success)
        case .needsAccountChoice:
            EmptyView()
        case .unavailable(let message):
            SettingsNotice(kind: .error, message: message)
        }
    }

    private var runningText: String {
        if sync.pendingCount > 0 {
            return "Sending \(sync.pendingCount) change\(sync.pendingCount == 1 ? "" : "s")"
        }
        if let date = sync.status.lastFetchedAt {
            return "Up to date · \(date.formatted(date: .omitted, time: .shortened))"
        }
        return "Up to date"
    }

    @ViewBuilder
    private var notices: some View {
        switch sync.status.suspension {
        case .libraryDeleted:
            noticeWithAction(
                "Your iCloud copy was deleted from another device. This Mac still has everything.",
                action: "Restore iCloud Copy"
            ) { await sync.restoreICloudCopy() }
        case .purged:
            noticeWithAction(
                "Orttaai's data was removed from iCloud in System Settings, so sync is off. This Mac still has everything.",
                action: "Upload This Mac's Archive"
            ) { await sync.restoreICloudCopy() }
        case .quotaExceeded:
            noticeWithAction(
                "Your iCloud storage is full. Changes are kept on this Mac and sent once there's space.",
                action: "Try Again"
            ) { await sync.resumeAfterStorageFreed() }
        case .signedOut:
            SettingsNotice(kind: .warning, message: "Signed out of iCloud. Sync resumes when you sign in again.")
        case .awaitingAccountCheck:
            SettingsNotice(kind: .warning, message: "Checking which iCloud account is signed in.")
        case .none, .accountChanged:
            EmptyView()
        }

        if !sync.status.missingZones.isEmpty {
            noticeWithAction(
                "Part of your iCloud copy is missing. This Mac still has everything.",
                action: "Restore iCloud Copy"
            ) { await sync.restoreICloudCopy() }
        }
        if let activity = sync.legacyActivity {
            SettingsNotice(
                kind: .warning,
                message: "\(activity.deviceName) is still on an older Orttaai (last seen \(activity.lastSeenAt.formatted(date: .abbreviated, time: .shortened))). Its dictations reach this archive, but it won't see new ones until it's updated."
            )
        }
        if sync.quarantinedCount > 0 {
            SettingsNotice(
                kind: .warning,
                message: "\(sync.quarantinedCount) item\(sync.quarantinedCount == 1 ? "" : "s") came from a newer version of Orttaai or Orttakey. Update Orttaai to read \(sync.quarantinedCount == 1 ? "it" : "them")."
            )
        }
        if let error = sync.lastError ?? sync.status.lastError, sync.phase == .running {
            SettingsNotice(kind: .error, message: error)
        }
    }

    private func noticeWithAction(_ message: String, action: String, perform: @escaping () async -> Void) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SettingsNotice(kind: .warning, message: message)
            Button(action) { run(perform) }
                .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
                .disabled(isWorking)
        }
    }

    // MARK: Account choice

    private var accountChoice: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SettingsDivider()
            Text("A different iCloud account is signed in than the one this Mac's archive syncs with.")
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.sm) {
                Button("Sync With This Account") { run { await sync.useCurrentAccount() } }
                    .buttonStyle(OrttaaiButtonStyle(.primary, size: .small))
                Button("Keep Separate") { run { await sync.keepArchiveSeparate() } }
                    .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
            }
            .disabled(isWorking)
            Text("Syncing with this account uploads everything on this Mac to it.")
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
        }
    }

    // MARK: Devices

    private var devicesList: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SettingsDivider()
            Text("Devices")
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
            ForEach(sync.devices, id: \.deviceID) { device in
                HStack(spacing: Spacing.md) {
                    Image(systemName: DeviceLabel.symbol(device.kind))
                        .font(.system(size: 14))
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .font(.Orttaai.body)
                            .foregroundStyle(Color.Orttaai.textPrimary)
                        Text(deviceDetail(device))
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                    }
                    Spacer()
                }
            }
        }
    }

    private func deviceDetail(_ device: DevicePayload) -> String {
        let count = "\(device.totals.dictations.formatted()) dictation\(device.totals.dictations == 1 ? "" : "s")"
        if device.deviceID == DeviceIdentity.currentID { return "This Mac · \(count)" }
        return "\(device.app) · \(count) · seen \(device.lastSeenAt.formatted(.relative(presentation: .named)))"
    }

    private func run(_ work: @escaping () async -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            await work()
            isWorking = false
        }
    }
}

/// How a device is named and drawn wherever dictations show their origin.
enum DeviceLabel {
    static func symbol(_ kind: DeviceKind) -> String {
        switch kind {
        case .mac: "laptopcomputer"
        case .iphone: "iphone"
        case .ipad: "ipad"
        case .unknown: "questionmark.square.dashed"
        }
    }

    static func symbol(kindName: String?) -> String {
        symbol(kindName.flatMap(DeviceKind.init(rawValue:)) ?? .unknown)
    }
}
