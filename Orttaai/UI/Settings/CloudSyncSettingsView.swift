// CloudSyncSettingsView.swift
// Orttaai

import SwiftUI
import Combine

struct CloudSyncSettingsView: View {
    @StateObject private var viewModel = CloudSyncSettingsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .top, spacing: Spacing.md) {
                Image(systemName: "icloud")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.Orttaai.accent)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("iCloud Sync")
                        .font(.Orttaai.subheading)
                        .foregroundStyle(Color.Orttaai.textPrimary)

                    Text(viewModel.summary)
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }

                Spacer(minLength: Spacing.lg)

                Button {
                    viewModel.syncButtonTapped()
                } label: {
                    Label(viewModel.primaryButtonTitle, systemImage: viewModel.primaryButtonIcon)
                }
                .buttonStyle(OrttaaiButtonStyle(.primary))
                .disabled(viewModel.isBusy)
            }

            statusContent
        }
        .padding(Spacing.lg)
        .dashboardCard()
    }

    @ViewBuilder
    private var statusContent: some View {
        switch viewModel.status {
        case .idle:
            EmptyView()
        case .checking:
            syncProgressRow("Checking iCloud profile")
        case .syncing:
            syncProgressRow("Syncing profile")
        case .synced(let date):
            Label("Last synced \(date.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.icloud")
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.success)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.error)
        case .needsSetup(let preview):
            setupChoiceContent(preview)
        }
    }

    private func syncProgressRow(_ title: String) -> some View {
        HStack(spacing: Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textSecondary)
        }
    }

    private func setupChoiceContent(_ preview: CloudSyncSetupPreview) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Divider()
                .background(Color.Orttaai.border.opacity(0.75))

            HStack(alignment: .top, spacing: Spacing.lg) {
                statsColumn(title: "This Mac", stats: preview.localStats)
                statsColumn(title: "iCloud", stats: preview.iCloudStats)
            }

            VStack(alignment: .leading, spacing: Spacing.sm) {
                syncChoiceButton(
                    title: "Merge Both Devices",
                    subtitle: "Keep this Mac and iCloud data. Newer edits win if the same item changed twice.",
                    systemImage: "arrow.triangle.merge",
                    resolution: .merge,
                    isPrimary: true
                )

                syncChoiceButton(
                    title: "Use iCloud Profile",
                    subtitle: "Back up this Mac first, then replace local history, memory, chats, and settings from iCloud.",
                    systemImage: "icloud.and.arrow.down",
                    resolution: .useICloud,
                    isPrimary: false
                )
            }
        }
    }

    private func statsColumn(title: String, stats: CloudSyncStats) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)

            Text("\(stats.transcriptionCount) history")
            Text("\(stats.dictionaryCount + stats.snippetCount) memory")
            Text("\(stats.chatConversationCount) chats")
            Text("\(stats.syncedPreferenceCount) settings")
        }
        .font(.Orttaai.caption)
        .foregroundStyle(Color.Orttaai.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func syncChoiceButton(
        title: String,
        subtitle: String,
        systemImage: String,
        resolution: CloudSyncSetupResolution,
        isPrimary: Bool
    ) -> some View {
        Button {
            viewModel.chooseSetup(resolution)
        } label: {
            HStack(alignment: .top, spacing: Spacing.md) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(title)
                        .font(.Orttaai.bodyMedium)
                    Text(subtitle)
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(OrttaaiButtonStyle(isPrimary ? .primary : .secondary))
        .disabled(viewModel.isBusy)
    }
}

@MainActor
final class CloudSyncSettingsViewModel: ObservableObject {
    @Published var status: CloudSyncStatus = .idle

    private var service: CloudSyncService?

    init(service: CloudSyncService? = nil) {
        self.service = service
        if let lastSyncDate = Self.lastSyncDate {
            status = .synced(lastSyncDate)
        }
    }

    var isBusy: Bool {
        status == .checking || status == .syncing
    }

    var primaryButtonTitle: String {
        if UserDefaults.standard.bool(forKey: CloudSyncService.syncEnabledKey) {
            return "Sync Now"
        }
        return "Set Up Sync"
    }

    var primaryButtonIcon: String {
        UserDefaults.standard.bool(forKey: CloudSyncService.syncEnabledKey)
            ? "arrow.clockwise.icloud"
            : "icloud.and.arrow.up"
    }

    var summary: String {
        if UserDefaults.standard.bool(forKey: CloudSyncService.syncEnabledKey) {
            return "History, Personal Memory, chats, tone profile, insights, and settings sync through your private iCloud account."
        }
        return "Set up private iCloud sync to continue with the same Orttaai profile on another Mac."
    }

    func syncButtonTapped() {
        guard !isBusy else { return }
        Task {
            if UserDefaults.standard.bool(forKey: CloudSyncService.syncEnabledKey) {
                await runSync()
            } else {
                await prepareSetup()
            }
        }
    }

    func chooseSetup(_ resolution: CloudSyncSetupResolution) {
        guard !isBusy else { return }
        Task {
        status = .syncing
        do {
            _ = try await syncService().enableSync(resolution: resolution)
            status = .synced(Date())
        } catch {
            status = .failed(error.localizedDescription)
            }
        }
    }

    private func prepareSetup() async {
        status = .checking
        do {
            let preview = try await syncService().setupPreview()
            if preview.hasConflict {
                status = .needsSetup(preview)
            } else {
                _ = try await syncService().enableSync(resolution: .merge)
                status = .synced(Date())
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func runSync() async {
        status = .syncing
        do {
            try await syncService().syncNow()
            status = .synced(Date())
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func syncService() -> CloudSyncService {
        if let service {
            return service
        }
        let resolved = CloudSyncService.shared
        service = resolved
        return resolved
    }

    private static var lastSyncDate: Date? {
        let timestamp = UserDefaults.standard.double(forKey: CloudSyncService.lastCompletedAtKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }
}
