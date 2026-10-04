import Combine
import Foundation
import Sparkle

/// Owns Sparkle's preferences and the reminder for a prepared update.
/// Readiness is deliberately not persisted: Sparkle owns the downloaded files
/// and restores their state after relaunch.
@MainActor
final class AppUpdateService: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = AppUpdateService()

    @Published private(set) var isSupported = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var readyVersion: String?

    private var controller: SPUStandardUpdaterController?
    private var preferenceObservations: [NSKeyValueObservation] = []
    private var immediateInstallHandler: (() -> Void)?

    func start() {
        guard controller == nil, !Bundle.main.isHomebrewInstall else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        self.controller = controller
        observePreferences(of: controller.updater)
        controller.startUpdater()
        isSupported = true
    }

    // Sparkle's checkbox and our About toggle share the same persisted preference.
    // Sparkle requires these properties and their mutations on the main thread.
    func observePreferences(of updater: SPUUpdater) {
        preferenceObservations = [
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated {
                    self?.automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
                }
            },
        ]
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        if enabled {
            updater.automaticallyChecksForUpdates = true
        }
        updater.automaticallyDownloadsUpdates = enabled
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func installReadyUpdate() {
        guard readyVersion != nil else { return }
        if let immediateInstallHandler {
            // Keep the handler usable if the application cancels termination.
            immediateInstallHandler()
        } else {
            // Bring Sparkle's retained, manually downloaded update into focus.
            checkForUpdates()
        }
    }

    private func clearReadyUpdate() {
        readyVersion = nil
        immediateInstallHandler = nil
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        // Download, validation, extraction and installer preparation have all
        // completed. Sparkle still installs on quit; the button offers it now.
        readyVersion = item.displayVersionString
        self.immediateInstallHandler = immediateInstallHandler
        return true
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        if state.stage == .downloaded || state.stage == .installing {
            readyVersion = update.displayVersionString
        } else {
            clearReadyUpdate()
        }
    }

    func updater(
        _ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState
    ) {
        if choice == .skip {
            clearReadyUpdate()
        } else if choice == .dismiss, state.stage == .downloaded || state.stage == .installing {
            // "Remind Me Later" keeps the downloaded update in Sparkle.
            readyVersion = updateItem.displayVersionString
        }
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        clearReadyUpdate()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        clearReadyUpdate()
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        clearReadyUpdate()
    }
}
