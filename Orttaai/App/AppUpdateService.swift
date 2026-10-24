import Combine
import Foundation
import os
import Sparkle

/// Where an update stands, as the button at the bottom of the sidebar shows it.
enum AppUpdatePhase: Equatable {
    case idle
    /// A check the person asked for is running.
    case checking
    /// A check the person asked for found nothing newer.
    case upToDate
    /// A newer version is out. One click downloads it and restarts.
    case available(version: String)
    /// `fraction` is nil until the size of the download is known.
    case downloading(version: String, fraction: Double?)
    /// Downloaded; Sparkle is unpacking and checking it.
    case preparing(version: String)
    /// Ready, and installed when Orttaai quits. One click restarts into it now.
    case ready(version: String)
    case installing(version: String)
    case failed

    var version: String? {
        switch self {
        case .available(let version), .downloading(let version, _), .preparing(let version),
             .ready(let version), .installing(let version):
            return version
        case .idle, .checking, .upToDate, .failed:
            return nil
        }
    }
}

/// Drives Sparkle with Orttaai's own update UI: the button at the bottom of
/// the sidebar instead of Sparkle's windows. Updates are checked every few
/// hours, and again when the window opens or the Mac wakes if the last check
/// is over an hour old. A found update shows as "Update available" (or
/// downloads straight away when automatic downloads are on, showing its
/// progress); one click downloads with a percentage, installs and relaunches.
/// A downloaded update the person hasn't clicked still installs on quit.
@MainActor
final class AppUpdateService: NSObject, ObservableObject, SPUUserDriver {
    static let shared = AppUpdateService()
    static let automaticDownloadsKey = "OrttaaiAutomaticallyDownloadUpdates"
    /// A check this old is redone when the window opens or the Mac wakes.
    static let staleCheckAge: TimeInterval = 60 * 60

    @Published private(set) var isSupported = false
    @Published private(set) var automaticallyDownloadsUpdates: Bool
    @Published private(set) var phase: AppUpdatePhase = .idle

    /// Starts a check the person asked for. Set by `start()`; tests replace it.
    var requestCheck: () -> Void = {}

    private let defaults: UserDefaults
    private var updater: SPUUpdater?
    /// The person clicked the update: whatever Sparkle offers next installs
    /// and relaunches.
    private var installRequested = false
    private var userInitiatedCheck = false
    private var foundVersion = ""
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0
    private var retryTermination: (() -> Void)?
    private var clearUpToDate: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.automaticDownloadsKey) == nil {
            // Carries over Sparkle's own setting from before this driver.
            let previous = defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool ?? true
            defaults.set(previous, forKey: Self.automaticDownloadsKey)
        }
        automaticallyDownloadsUpdates = defaults.bool(forKey: Self.automaticDownloadsKey)
        super.init()
    }

    func start() {
        guard updater == nil, !Bundle.main.isHomebrewInstall else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
        // Sparkle's silent download would bypass this driver, so the sidebar
        // couldn't show it. Downloads start here instead.
        updater.automaticallyDownloadsUpdates = false
        updater.automaticallyChecksForUpdates = true
        do {
            try updater.start()
        } catch {
            Logger.ui.error("Updater failed to start: \(error.localizedDescription)")
            return
        }
        self.updater = updater
        requestCheck = { [weak updater] in updater?.checkForUpdates() }
        isSupported = true
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.automaticDownloadsKey)
        automaticallyDownloadsUpdates = enabled
    }

    /// Check for Updates in the menu and in About.
    func checkForUpdates() {
        guard isSupported else { return }
        if phase.version != nil {
            performPrimaryAction()
        } else {
            requestCheck()
        }
    }

    /// A quiet check when the window opens or the Mac wakes, if the last
    /// one is over an hour old.
    func checkIfStale() {
        guard let updater, phase == .idle, updater.canCheckForUpdates, !updater.sessionInProgress else { return }
        if let last = updater.lastUpdateCheckDate, Date().timeIntervalSince(last) < Self.staleCheckAge { return }
        updater.checkForUpdatesInBackground()
    }

    /// The sidebar button.
    func performPrimaryAction() {
        switch phase {
        case .available(let version):
            installRequested = true
            phase = .downloading(version: version, fraction: nil)
            requestCheck()
        case .ready(let version):
            // Sparkle keeps the prepared update; a check brings it back to install.
            installRequested = true
            phase = .installing(version: version)
            requestCheck()
        case .installing:
            retryTermination?()
        case .failed:
            phase = .idle
            requestCheck()
        case .idle, .checking, .upToDate, .downloading, .preparing:
            break
        }
    }

    // MARK: - SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        userInitiatedCheck = true
        if !installRequested {
            setPhase(.checking)
        }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let version = appcastItem.displayVersionString
        foundVersion = version
        userInitiatedCheck = false
        let downloaded = state.stage != .notDownloaded
        if installRequested {
            setPhase(downloaded ? .installing(version: version) : .downloading(version: version, fraction: nil))
            reply(.install)
        } else if downloaded {
            // Prepared earlier: it installs on quit, or now with a click.
            setPhase(.ready(version: version))
            reply(.dismiss)
        } else if automaticallyDownloadsUpdates {
            setPhase(.downloading(version: version, fraction: nil))
            reply(.install)
        } else {
            setPhase(.available(version: version))
            reply(.dismiss)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        resetSession()
        setPhase(.upToDate)
        clearUpToDate = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.phase == .upToDate else { return }
            self.phase = .idle
        }
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        Logger.ui.error("Update failed: \(error.localizedDescription)")
        // A quiet check that fails (offline, say) stays quiet.
        let visible: Bool
        switch phase {
        case .checking, .downloading, .preparing, .installing: visible = true
        default: visible = userInitiatedCheck || installRequested
        }
        resetSession()
        setPhase(visible ? .failed : .idle)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedLength = 0
        receivedLength = 0
        setPhase(.downloading(version: foundVersion, fraction: nil))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        receivedLength = 0
        publishDownloadProgress()
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        publishDownloadProgress()
    }

    func showDownloadDidStartExtractingUpdate() {
        setPhase(.preparing(version: foundVersion))
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if installRequested {
            setPhase(.installing(version: foundVersion))
            reply(.install)
        } else {
            // Dismissing keeps the prepared update, which installs on quit.
            setPhase(.ready(version: foundVersion))
            reply(.dismiss)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        retryTermination = retryTerminatingApplication
        setPhase(.installing(version: foundVersion))
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        resetSession()
        setPhase(.idle)
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        installRequested = false
        userInitiatedCheck = false
        retryTermination = nil
        switch phase {
        case .available, .ready, .upToDate, .failed:
            // These outlast Sparkle's session until the person acts.
            break
        case .idle, .checking, .downloading, .preparing, .installing:
            phase = .idle
        }
    }

    // MARK: - Private

    private func setPhase(_ newPhase: AppUpdatePhase) {
        if newPhase != .upToDate {
            clearUpToDate?.cancel()
            clearUpToDate = nil
        }
        phase = newPhase
    }

    private func resetSession() {
        installRequested = false
        userInitiatedCheck = false
        retryTermination = nil
    }

    /// Publishes whole percents only, not every chunk.
    private func publishDownloadProgress() {
        guard expectedLength > 0 else { return }
        let fraction = (min(1, Double(receivedLength) / Double(expectedLength)) * 100).rounded(.down) / 100
        if case .downloading(_, let current) = phase, current == fraction { return }
        setPhase(.downloading(version: foundVersion, fraction: fraction))
    }

    #if DEBUG
    /// `-OrttaaiUpdatePreview YES` on a Debug build: walks the sidebar
    /// button through a pretend update, without Sparkle or a relaunch.
    func startPreview() {
        isSupported = true
        setPhase(.available(version: "9.9.0"))
        requestCheck = { [weak self] in
            guard let self else { return }
            Task {
                for step in 0...25 {
                    self.setPhase(.downloading(version: "9.9.0", fraction: Double(step) / 25))
                    try? await Task.sleep(for: .milliseconds(160))
                }
                self.setPhase(.preparing(version: "9.9.0"))
                try? await Task.sleep(for: .seconds(1))
                self.setPhase(.installing(version: "9.9.0"))
                try? await Task.sleep(for: .seconds(2))
                self.setPhase(.available(version: "9.9.0"))
            }
        }
    }
    #endif
}
