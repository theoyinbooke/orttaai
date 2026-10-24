# App updates

Orttaai drives Sparkle with its own user driver (`AppUpdateService`, an `SPUUserDriver`) instead of Sparkle's windows. Everything about an update shows in one button at the bottom of the sidebar, above Run Setup (`AppUpdateSidebarButton`). Homebrew copies stay managed by Homebrew, and Debug builds don't start the updater.

## When it checks

- Every 3 hours (`SUScheduledCheckInterval` 10800 in Info.plist). A check fetches one small appcast file.
- Each time the home window opens or reopens (`WindowManager.showHomeWindow`), 15 seconds after launch, and 20 seconds after the Mac wakes, if the last check is over an hour old (`checkIfStale`).
- **Check for Updates** in the menu bar or About opens the window and checks; the button shows "Checking for updates…" and then the result.

Before this driver, Sparkle checked once a day and, with automatic downloads on, downloaded silently and installed only on quit. A menu bar app is rarely quit, so new versions went unnoticed.

## What the button shows

| Phase | Button | Click |
| --- | --- | --- |
| available | Update available · Version x | Downloads, installs and restarts |
| downloading | A ring filling with the download, "Downloading 42%" | – |
| preparing | Preparing update… | – |
| ready | Restart to update · Version x is ready | Installs and restarts |
| installing | Restarting… | Retries if quitting was stopped |
| checking / upToDate | Checking… / You're up to date (4 s) | – |
| failed | Update didn't finish · Click to try again | Checks again |

**Automatically download updates** (About, stored in `OrttaaiAutomaticallyDownloadUpdates`, carried over from Sparkle's `SUAutomaticallyUpdate`) starts the download as soon as an update is found, still with its progress, and stops at "Restart to update". Orttaai never restarts unless the person clicks; a prepared update also installs on quit.

## How it maps to Sparkle

Sparkle's silent download is turned off (`automaticallyDownloadsUpdates = false`) because it bypasses the user driver. The driver never holds Sparkle's reply: an update the person hasn't acted on is answered with **dismiss**, which keeps a downloaded or prepared update (and installs it on quit). The button's click sets `installRequested` and starts a check; Sparkle finds or resumes the same update and the driver answers **install** to it and to the relaunch prompt.

## Trying it

A Debug build started with `-OrttaaiUpdatePreview YES` walks the button through a pretend update (available, download to 100%, preparing, restarting) without Sparkle. `AppUpdateServiceTests` cover the driver's phases and replies.

## What's New

After an update relaunches, the home window shows the release's What's New card. See [whats-new.md](whats-new.md).
