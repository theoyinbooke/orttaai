# Automatic app updates

The automatic-download checkbox in Sparkle and the toggle in About use Sparkle's own persisted `automaticallyDownloadsUpdates` preference. The app observes that preference instead of keeping a second setting or overwriting it at launch. Enabling the About toggle also enables scheduled checks. Homebrew copies remain managed by Homebrew; Debug builds do not start the updater.

For an automatic download, `AppUpdateService` waits for Sparkle's `willInstallUpdateOnQuit` callback. At this point download, validation, extraction, and installer preparation have completed. It retains Sparkle's immediate installation handler and shows a compact **Update** button at the bottom of the sidebar, above Run Setup. Clicking it installs and relaunches; the existing install-on-quit behavior also remains available. No additional polling or download worker is introduced.

Sparkle can also restore a downloaded or installing update in its standard UI. These states show the footer reminder; its action brings Sparkle's update UI forward when no immediate handler is retained. Remind Me Later retains the reminder for a downloaded update. Skip, download cancellation, errors, and replacement downloads clear stale readiness. The app does not persist a ready flag independently of Sparkle's files.

The implementation uses Sparkle's [updater delegate](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html) and [gentle reminder APIs](https://sparkle-project.org/documentation/gentle-reminders/).

## Version comparison

The app displayed 1.10.0 but the Xcode project's internal build version was 1.2.21, causing Sparkle to offer the existing 1.10.0 release again. The application target now derives `CURRENT_PROJECT_VERSION` from `MARKETING_VERSION` in both configurations. The release script can still supply its explicit build version. The rebuilt preview reports 1.10.0 (1.10.0), and a live update check confirmed that it is up to date.

## Validation

- Release build completed; local preview signatures passed strict verification.
- Six updater tests passed: preference observation, delayed readiness, install handler invocation/retry, errors, cancellation/replacement, recovered stages, and dismiss/skip behavior.
- Native UI inspection confirmed the About toggle is enabled and on, the corrected version is displayed, and the footer remains clear when no update is ready.
- Startup logs confirmed speech-model loading and warm-up completed.

The prepared-update tests use Sparkle delegate fixtures and inert updater controllers. No newer release is currently available, so a real newer-version download/install was not exercised or published during this change. The local preview remains at `.build/accuracy-preview/Orttaai.app`; its iCloud sync still requires a provisioning profile containing the current signing certificate. The installed `/Applications/Orttaai.app` was not replaced.
