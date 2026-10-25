// CloudSyncSettingsView.swift
// Orttaai

import SwiftUI
import Combine

struct CloudSyncSettingsView: View {
    @StateObject private var viewModel = CloudSyncSettingsViewModel()

    var body: some View {
        SettingsCard("iCloud Sync", info: viewModel.summary) {
            Button {
                viewModel.syncButtonTapped()
            } label: {
                Label(viewModel.primaryButtonTitle, systemImage: viewModel.primaryButtonIcon)
            }
            .buttonStyle(OrttaaiButtonStyle(.primary, size: .small))
            .disabled(viewModel.isBusy)
        } content: {
            statusContent
        }
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
                .padding(.bottom, Spacing.xs)
        case .failed(let message):
            SettingsNotice(kind: .error, message: message)
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
        .padding(.bottom, Spacing.xs)
    }

    private func setupChoiceContent(_ preview: CloudSyncSetupPreview) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SettingsDivider()

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
        .padding(.bottom, Spacing.xs)
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
                    .foregroundStyle(isPrimary ? Color.Orttaai.accent : Color.Orttaai.textPrimary)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.sm) {
                        Text(title)
                            .font(.Orttaai.bodyMedium)
                            .foregroundStyle(Color.Orttaai.textPrimary)
                        if isPrimary {
                            Text("Recommended")
                                .font(.Orttaai.caption.weight(.medium))
                                .foregroundStyle(Color.Orttaai.accent)
                        }
                    }
                    Text(subtitle)
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(SyncChoiceButtonStyle(isRecommended: isPrimary))
        .disabled(viewModel.isBusy)
    }
}

/// A full-width choice card. Unlike the solid primary button, it keeps light
/// text on a dark surface so the explanation under the title stays readable;
/// the recommended choice is marked with an accent tint and border instead.
private struct SyncChoiceButtonStyle: ButtonStyle {
    let isRecommended: Bool

    func makeBody(configuration: Configuration) -> some View {
        ChoiceCard(configuration: configuration, isRecommended: isRecommended)
    }

    private struct ChoiceCard: View {
        let configuration: ButtonStyleConfiguration
        let isRecommended: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: CornerRadius.button)
            configuration.label
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.md)
                .background(shape.fill(backgroundColor))
                .overlay(shape.stroke(borderColor, lineWidth: BorderWidth.standard))
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovered = $0 }
        }

        private var backgroundColor: Color {
            let isActive = isEnabled && (isHovered || configuration.isPressed)
            if isRecommended {
                return isActive ? Color.Orttaai.accent.opacity(0.2) : Color.Orttaai.accentSubtle
            }
            return isActive ? Color.Orttaai.bgTertiary : .clear
        }

        private var borderColor: Color {
            isRecommended ? Color.Orttaai.accentRing : Color.Orttaai.border
        }
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
