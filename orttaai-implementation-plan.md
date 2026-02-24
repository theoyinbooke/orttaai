# Orttaai — Implementation Plan

**Version**: Based on PRD v2.2 · February 2026
**Target Machine**: Mac Mini M4 · macOS 14+ · Xcode 15+ · Cursor editor
**Timeline**: 9 weeks (4 phases)

---

## Table of Contents

1. [Prerequisites & Environment Setup](#1-prerequisites--environment-setup)
2. [Phase 1: Foundation (Week 1–2)](#2-phase-1-foundation-week-12)
3. [Phase 2: Core Pipeline (Week 3–4)](#3-phase-2-core-pipeline-week-34)
4. [Phase 3: Features & UI (Week 5–6)](#4-phase-3-features--ui-week-56)
5. [Phase 4: Polish & Ship (Week 7–9)](#5-phase-4-polish--ship-week-79)
6. [Risk Register & Mitigations](#6-risk-register--mitigations)
7. [Daily Workflow](#7-daily-workflow)
8. [Definition of Done (Per Phase)](#8-definition-of-done-per-phase)

---

## 1. Prerequisites & Environment Setup

Complete these before writing any application code. Estimated time: 2–4 hours.

### 1.1 Developer Tools

- [ ] **Xcode 15+** installed and updated (you confirmed this)
- [ ] **Xcode Command Line Tools**: Run `xcode-select --install` if not already present
- [ ] **Cursor** installed for editing Swift files
- [ ] **Homebrew** installed: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
- [ ] **create-dmg** for packaging: `brew install create-dmg`
- [ ] **SwiftLint** (optional but recommended): `brew install swiftlint`

### 1.2 Apple Developer Account

- [ ] Apple Developer Program membership ($99/yr) — required for code signing and notarization
- [ ] Developer ID Application certificate created in Xcode > Settings > Accounts
- [ ] Verify certificate: `security find-identity -v -p codesigning` should list your Developer ID

### 1.3 GitHub Repository

- [ ] Create GitHub repository: `orttaai` (public, MIT license)
- [ ] Clone locally to your working directory
- [ ] Create `.gitignore` for Swift/Xcode:
  ```
  .DS_Store
  /.build
  /Packages
  xcuserdata/
  DerivedData/
  .swiftpm/xcode/package.xcworkspace/contents.xcworkspacedata
  *.xcodeproj/project.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist
  ```
- [ ] Create initial commit with `.gitignore`, `LICENSE` (MIT), and empty `README.md`

### 1.4 Xcode Project Creation

This is the most important setup step. Get this right and everything else builds on it.

- [ ] Open Xcode > File > New > Project
- [ ] Template: **macOS > App**
- [ ] Configuration:
  - Product Name: `Orttaai`
  - Team: Your Developer ID team
  - Organization Identifier: `com.orttaai`
  - Bundle Identifier: `com.orttaai.app`
  - Interface: **SwiftUI**
  - Language: **Swift**
  - Storage: **None**
  - **Uncheck** "Include Tests" (we'll add the test target manually with proper structure)
- [ ] Deployment Target: **macOS 14.0**
- [ ] After creation, close the default `ContentView.swift` — we'll restructure everything

### 1.5 Project Configuration in Xcode

- [ ] **Signing & Capabilities**:
  - Team: Your developer team
  - Signing Certificate: "Developer ID Application"
  - **Disable** App Sandbox (uncheck it or remove the entitlement)
  - Enable Hardened Runtime
- [ ] **Info.plist** — add these keys:
  - `LSUIElement` = `YES` (hides Dock icon)
  - `NSMicrophoneUsageDescription` = "Orttaai captures your voice for on-device transcription. Audio never leaves your Mac."
  - `NSAppleEventsUsageDescription` = "Orttaai uses Apple Events for future Shortcuts integration."
- [ ] **Entitlements file** (`Orttaai.entitlements`):
  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
      <key>com.apple.security.app-sandbox</key>
      <false/>
      <key>com.apple.security.hardened-runtime</key>
      <true/>
      <key>com.apple.security.device.audio-input</key>
      <true/>
      <key>com.apple.security.automation.apple-events</key>
      <true/>
  </dict>
  </plist>
  ```

### 1.6 Add SPM Dependencies

In Xcode: File > Add Package Dependencies. Add each one:

| Package | URL | Version Rule |
|---|---|---|
| WhisperKit | `https://github.com/argmaxinc/WhisperKit` | Up to Next Minor |
| GRDB.swift | `https://github.com/groue/GRDB.swift` | Up to Next Major |
| Sparkle | `https://github.com/sparkle-project/Sparkle` | Up to Next Major |
| KeyboardShortcuts | `https://github.com/sindresorhus/KeyboardShortcuts` | Up to Next Major |

- [ ] After adding, build the project (`Cmd+B`) to verify all packages resolve
- [ ] WhisperKit may take a few minutes to compile Core ML components — this is normal
- [ ] If WhisperKit fails to build, check that deployment target is macOS 14.0

### 1.7 Create Folder Structure

In Xcode's Project Navigator, create the following group structure. Every group should correspond to an actual folder on disk (right-click > New Group, not New Group without Folder).

```
Orttaai/
├── App/
├── Core/
│   ├── Audio/
│   ├── Transcription/
│   ├── Injection/
│   ├── Hotkey/
│   ├── Hardware/
│   ├── Model/
│   └── Coordination/
├── UI/
│   ├── MenuBar/
│   ├── FloatingPanel/
│   ├── Windows/
│   ├── Setup/
│   ├── Settings/
│   ├── History/
│   └── Components/
├── Data/
├── Design/
├── Utilities/
└── Resources/
```

- [ ] Verify folder structure on disk matches Xcode groups
- [ ] Move `Assets.xcassets` into `Resources/`
- [ ] Move `Info.plist` into `Resources/`
- [ ] Move `Orttaai.entitlements` into `Resources/`
- [ ] Update Xcode build settings if file paths changed (Info.plist File, Code Signing Entitlements)

### 1.8 Add Test Target

- [ ] File > New > Target > macOS > Unit Testing Bundle
- [ ] Product Name: `OrttaaiTests`
- [ ] Create subfolder structure:
  ```
  OrttaaiTests/
  ├── Core/
  └── Coordination/
  ```
- [ ] Build and run tests (`Cmd+U`) to verify the test target works with an empty test

### 1.9 Verification Checkpoint

Before proceeding, confirm:

- [ ] `Cmd+B` builds successfully with zero errors
- [ ] `Cmd+U` runs (empty) tests successfully
- [ ] All four SPM packages appear in Xcode's Package Dependencies
- [ ] Info.plist shows `LSUIElement = YES`
- [ ] Signing identity is Developer ID Application
- [ ] App Sandbox is OFF, Hardened Runtime is ON
- [ ] Git commit: "Project setup: Xcode project, SPM dependencies, folder structure"

---

## 2. Phase 1: Foundation (Week 1–2)

**Goal**: All foundational services built and tested in isolation. App launches as a menu bar icon with a basic dropdown. No dictation yet.

### Week 1, Day 1–2: Design System + Utilities

Build the design tokens and utility files first — everything else depends on them.

#### Task 1.1: Colors.swift
**File**: `Orttaai/Design/Colors.swift`

- [ ] Implement `Color.init(hex:)` extension
- [ ] Define `Color.Orttaai` enum with all 12 tokens from PRD Section 8.1
- [ ] Include both Color (SwiftUI) and NSColor (AppKit) variants
- [ ] Verification: Create a temporary SwiftUI preview showing all colors as swatches

#### Task 1.2: Typography.swift
**File**: `Orttaai/Design/Typography.swift`

- [ ] Define `Font` extensions or a `Typography` enum matching PRD Section 8.2
- [ ] Six styles: windowTitle, sectionHeader, body, secondary, caption, monospace

#### Task 1.3: Spacing.swift
**File**: `Orttaai/Design/Spacing.swift`

- [ ] Define `Spacing` enum with xs(4), sm(8), md(12), lg(16), xl(20), xxl(24), xxxl(32)

#### Task 1.4: Errors.swift
**File**: `Orttaai/Utilities/Errors.swift`

- [ ] Define `OrttaaiError` enum conforming to `LocalizedError`
- [ ] Cases: `modelNotLoaded`, `modelCorrupted`, `microphoneAccessDenied`, `transcriptionFailed(underlying: Error)`, `insufficientDiskSpace`, `downloadFailed`, `intelMacDetected`
- [ ] Each case provides `errorDescription` and `recoverySuggestion`

#### Task 1.5: Logger.swift
**File**: `Orttaai/Utilities/Logger.swift`

- [ ] Define `Logger` extensions with subsystem "com.orttaai.app"
- [ ] Categories: `audio`, `transcription`, `injection`, `hotkey`, `ui`, `database`, `model`, `dictation`
- [ ] Example: `static let audio = Logger(subsystem: "com.orttaai.app", category: "audio")`

#### Task 1.6: Extensions.swift
**File**: `Orttaai/Utilities/Extensions.swift`

- [ ] `NSWorkspace` extension: `frontmostAppName` → `String` (with ?? "Unknown App" fallback)
- [ ] `Bundle` extension: `isHomebrewInstall` → `Bool` (checks for `.homebrew-installed` resource)
- [ ] Any other small helpers needed as they arise

---

### Week 1, Day 2–3: Data Layer

#### Task 1.7: TranscriptionRecord.swift
**File**: `Orttaai/Data/TranscriptionRecord.swift`

- [ ] Define `Transcription` struct conforming to `Codable, FetchableRecord, PersistableRecord`
- [ ] Set `static let databaseTableName = "transcription"` (singular)
- [ ] Properties: id (Int64?), createdAt (Date), text (String), targetAppName (String?), targetAppBundleID (String?), recordingDurationMs (Int), processingDurationMs (Int), modelId (String), audioDevice (String?)

#### Task 1.8: DatabaseManager.swift
**File**: `Orttaai/Data/DatabaseManager.swift`

- [ ] Create `DatabaseManager` class
- [ ] Database file path: `~/Library/Application Support/Orttaai/orttaai.db`
- [ ] Ensure directory creation on init (`FileManager.default.createDirectory`)
- [ ] Register migration "v1": create `transcription` table with all columns per PRD Section 6.8
- [ ] Create index: `idx_transcription_createdAt` on `createdAt`
- [ ] Implement `saveTranscription(text:appName:recordingMs:processingMs:modelId:audioDevice:)`
- [ ] Implement auto-prune in write transaction (keep latest 500)
- [ ] Implement `fetchRecent(limit:offset:)` → `[Transcription]`
- [ ] Implement `search(query:)` → `[Transcription]` using LIKE
- [ ] Implement `deleteAll()` for history clear
- [ ] Implement `logSkippedRecording(duration:)` — logs to `os.Logger`, not the database
- [ ] Set up `DatabaseRegionObservation` for live UI updates

#### Task 1.9: DatabaseManagerTests.swift
**File**: `OrttaaiTests/Core/DatabaseManagerTests.swift`

- [ ] Test with in-memory GRDB database (`:memory:`)
- [ ] Test insert and fetch
- [ ] Test auto-prune: insert 510 records, verify only 500 remain
- [ ] Test search with LIKE filter
- [ ] Test deleteAll
- [ ] Test fetchRecent ordering (newest first)
- [ ] `Cmd+U` — all tests pass

#### Task 1.10: AppSettings.swift
**File**: `Orttaai/Data/AppSettings.swift`

- [ ] Define `AppSettings` with `@AppStorage` properties:
  - `selectedModelId: String` (default: "openai_whisper-large-v3_turbo")
  - `selectedAudioDeviceID: String?` (default: nil = system default)
  - `polishModeEnabled: Bool` (default: false)
  - `launchAtLogin: Bool` (default: false)
  - `hasCompletedSetup: Bool` (default: false)
  - `showProcessingEstimate: Bool` (default: true)

---

### Week 1, Day 3–4: Hardware Detection

#### Task 1.11: HardwareDetector.swift
**File**: `Orttaai/Core/Hardware/HardwareDetector.swift`

- [ ] Detect chip family via `sysctlbyname("machdep.cpu.brand_string")`
- [ ] Detect Apple Silicon vs Intel via `sysctlbyname("hw.optional.arm64")`
- [ ] Get RAM via `ProcessInfo.processInfo.physicalMemory`
- [ ] Get GPU core count via IOKit (`IOServiceMatching("AppleARMIODevice")`)
- [ ] Get available disk space via `URL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])`
- [ ] Define `HardwareTier` enum: `.m1_8gb`, `.m1_16gb`, `.m3_16gb`, `.intel_unsupported`
- [ ] Implement `recommendedModel(for tier:)` → returns model name per PRD Section 5.3 table
- [ ] Return struct `HardwareInfo` with chip, ram, gpu, disk, tier, recommendedModel

#### Task 1.12: HardwareDetectorTests.swift
**File**: `OrttaaiTests/Core/HardwareDetectorTests.swift`

- [ ] Test that on your M4 Mac Mini it returns a valid tier (not intel_unsupported)
- [ ] Test recommendedModel returns correct model for each tier
- [ ] Test RAM detection returns a reasonable value (> 0)

---

### Week 1, Day 4–5: Audio Capture Service

#### Task 1.13: AudioCaptureService.swift
**File**: `Orttaai/Core/Audio/AudioCaptureService.swift`

- [ ] Define `@Observable final class AudioCaptureService`
- [ ] Private properties:
  - `engine: AVAudioEngine`
  - `sampleQueue: DispatchQueue(label: "com.orttaai.samples")`
  - `_samples: [Float]`
  - `_currentLevel: OSAllocatedUnfairLock<Float>`
  - `levelTimer: DispatchSourceTimer?`
- [ ] Published property: `audioLevel: Float` (read on main thread)
- [ ] Implement `startCapture(deviceID: AudioDeviceID? = nil) throws`:
  - Set per-engine AudioUnit device if deviceID provided
  - Create 16kHz mono `AVAudioFormat`
  - Install tap with 16kHz format (AVAudioEngine handles conversion)
  - Tap callback: append samples to `_samples` on `sampleQueue.async`
  - Tap callback: update `_currentLevel` via `OSAllocatedUnfairLock.withLock`
  - Start 30fps DispatchSourceTimer on `.main` queue to update `audioLevel`
  - `engine.prepare()` then `engine.start()`
- [ ] Implement `stopCapture() -> [Float]`:
  - Remove tap, stop engine
  - Cancel and nil the level timer
  - `sampleQueue.sync` to grab and clear `_samples`
  - Reset `audioLevel` and `_currentLevel`
  - Return captured samples

#### Task 1.14: AudioDeviceManager.swift
**File**: `Orttaai/Core/Audio/AudioDeviceManager.swift`

- [ ] Enumerate available input devices via `AVCaptureDevice.DiscoverySession`
- [ ] Define `AudioInputDevice` struct: id (AudioDeviceID), name (String), isDefault (Bool)
- [ ] Implement `availableInputDevices() -> [AudioInputDevice]`
- [ ] Implement `defaultInputDevice() -> AudioInputDevice?`
- [ ] Listen for device connection/disconnection via CoreAudio property listener

#### Task 1.15: AudioCaptureServiceTests.swift
**File**: `OrttaaiTests/Core/AudioCaptureServiceTests.swift`

- [ ] Test that `startCapture()` doesn't throw (requires mic permission — may need to run as app)
- [ ] Test that `stopCapture()` returns non-empty samples after brief recording
- [ ] Test that `audioLevel` updates (> 0) when speaking
- [ ] Note: audio tests may require running as a full app target, not just unit tests. Document this in TESTING.md if so.

---

### Week 1, Day 5 → Week 2, Day 1: Clipboard & Injection Foundation

#### Task 1.16: ClipboardManager.swift
**File**: `Orttaai/Core/Injection/ClipboardManager.swift`

- [ ] Define `final class ClipboardManager`
- [ ] Define inner `struct SavedItem` with types array and dataByType dictionary
- [ ] Implement `save() -> [SavedItem]`:
  - Iterate `NSPasteboard.general.pasteboardItems`
  - For each item, iterate types
  - Skip types where `rawValue.contains("promise")`
  - Collect available data per type
  - Return array of SavedItems (compactMap out empties)
- [ ] Implement `restore(_ savedItems: [SavedItem])`:
  - Clear pasteboard
  - Recreate NSPasteboardItems from saved data
  - Write to pasteboard

#### Task 1.17: ClipboardManagerTests.swift
**File**: `OrttaaiTests/Core/ClipboardManagerTests.swift`

- [ ] Test round-trip with plain text: copy text → save → clear → restore → verify text matches
- [ ] Test round-trip with multiple types (text + RTF)
- [ ] Test save on empty pasteboard returns empty array
- [ ] Test restore with empty array doesn't crash
- [ ] Test that file URLs (Finder copies) are preserved
- [ ] `Cmd+U` — all tests pass

---

### Week 2, Day 1–2: Hotkey Service

#### Task 1.18: HotkeyService.swift
**File**: `Orttaai/Core/Hotkey/HotkeyService.swift`

- [ ] Define `final class HotkeyService`
- [ ] Properties: `eventTap: CFMachPort?`, `onKeyDown: (() -> Void)?`, `onKeyUp: (() -> Void)?`
- [ ] Implement `start(keyCode:modifiers:) -> Bool`:
  - Create CGEvent tap with `.cghidEventTap` placement
  - Listen for keyDown, keyUp, flagsChanged
  - Return false if tap creation fails (Input Monitoring not granted)
  - Add to run loop
- [ ] Implement C callback function that routes to `onKeyDown`/`onKeyUp`
- [ ] Implement `stop()`: disable tap, nil out reference
- [ ] Handle push-to-talk: keyDown starts recording, keyUp stops recording

---

### Week 2, Day 2–3: App Shell (Menu Bar + Window Management)

#### Task 1.19: AppDelegate.swift
**File**: `Orttaai/App/AppDelegate.swift`

- [ ] Define `class AppDelegate: NSObject, NSApplicationDelegate`
- [ ] Create `NSStatusItem` in `applicationDidFinishLaunching`
- [ ] Set status item image: SF Symbol `waveform.circle` as template image
- [ ] Wire up `StatusBarMenu` to status item
- [ ] Determine if setup is needed (`AppSettings.hasCompletedSetup`)
- [ ] If setup needed: show setup window. Otherwise: stay as menu bar icon.

#### Task 1.20: OrttaaiApp.swift
**File**: `Orttaai/App/OrttaaiApp.swift`

- [ ] Define `@main struct OrttaaiApp: App`
- [ ] Use `@NSApplicationDelegateAdaptor(AppDelegate.self)`
- [ ] Body: `WindowGroup { }` with `.defaultSize(width: 0, height: 0)` (hidden — all UI is menu bar driven)
- [ ] Alternatively, use `Settings { SettingsView() }` scene for native settings window

#### Task 1.21: AppState.swift
**File**: `Orttaai/App/AppState.swift`

- [ ] Define `@Observable final class AppState`
- [ ] Holds references to all services (will be populated in Phase 2):
  - `hardwareInfo: HardwareInfo`
  - `settings: AppSettings`
  - `isSetupComplete: Bool`
- [ ] Acts as the dependency container passed to views

#### Task 1.22: StatusBarController.swift
**File**: `Orttaai/UI/MenuBar/StatusBarController.swift`

- [ ] Manages the `NSStatusItem`
- [ ] Updates icon based on state (idle, recording, processing, downloading, error)
- [ ] Uses template image for idle (adapts to light/dark)
- [ ] Amber-tinted for recording/processing states

#### Task 1.23: StatusBarMenu.swift
**File**: `Orttaai/UI/MenuBar/StatusBarMenu.swift`

- [ ] Creates `NSMenu` with items:
  - Status line (disabled, shows current state)
  - Separator
  - Polish Mode toggle (disabled, "Coming soon")
  - History
  - Separator
  - Settings... (Cmd+,)
  - Check for Updates... / "Updates managed by Homebrew" (based on `isHomebrewInstall`)
  - Separator
  - Quit Orttaai (Cmd+Q)
- [ ] Wire menu item actions to appropriate handlers

#### Task 1.24: WindowManager.swift
**File**: `Orttaai/UI/Windows/WindowManager.swift`

- [ ] Manages creation and display of NSWindows for setup, settings, history
- [ ] Setup window: centered, 600×500pt, not resizable
- [ ] Settings window: centered, 500×400pt, uses TabView
- [ ] History window: 480×600pt, resizable
- [ ] Each window: bring to front, make key, prevent duplicates

---

### Week 2, Day 3–4: Floating Panel

#### Task 1.25: FloatingPanelController.swift
**File**: `Orttaai/UI/FloatingPanel/FloatingPanelController.swift`

- [ ] Create `NSPanel` with styleMask: `.nonactivatingPanel`, `.borderless`, `.hudWindow`
- [ ] Level: `.floating`
- [ ] CollectionBehavior: `.canJoinAllSpaces`, `.fullScreenAuxiliary`
- [ ] Size: 200×40pt, corner radius 8pt
- [ ] Background: `NSVisualEffectView` with `.hudWindow` material
- [ ] Host SwiftUI content via `NSHostingView`
- [ ] Implement `show(near point: NSPoint)`:
  - Position panel near cursor
  - Fade in via `NSAnimationContext` (150ms)
- [ ] Implement `dismiss()`:
  - Fade out (200ms)
  - Order out after animation
- [ ] Implement `updateContent(_ view: some View)` for swapping between waveform/processing/error
- [ ] Positioning logic: try AX cursor position first, fall back to `NSEvent.mouseLocation`

#### Task 1.26: WaveformView.swift
**File**: `Orttaai/UI/FloatingPanel/WaveformView.swift`

- [ ] SwiftUI view that takes `audioLevel: Float` as input
- [ ] Render as Canvas or Path — animated bars responding to level
- [ ] Use `Color.Orttaai.accent` for active bars
- [ ] Smooth animation via `.animation(.linear(duration: 0.033))` (30fps)

#### Task 1.27: ProcessingIndicatorView.swift
**File**: `Orttaai/UI/FloatingPanel/ProcessingIndicatorView.swift`

- [ ] Shimmer animation: gradient mask with `.easeInOut(duration: 1.5).repeatForever()`
- [ ] Optional processing estimate text: "~8s to process"
- [ ] Error state: amber/red tinted text, auto-dismisses after 2s

---

### Week 2, Day 4–5: UI Components

#### Task 1.28: OrttaaiButton.swift
**File**: `Orttaai/UI/Components/OrttaaiButton.swift`

- [ ] Custom `ButtonStyle` with three variants: primary (amber bg), secondary (bordered), ghost
- [ ] Hover state with `onHover`
- [ ] Focus ring via `@FocusState`
- [ ] Use design system colors and spacing

#### Task 1.29: OrttaaiTextField.swift
**File**: `Orttaai/UI/Components/OrttaaiTextField.swift`

- [ ] Styled `TextField` with dark bg (`Color.Orttaai.bgSecondary`)
- [ ] Subtle border (`Color.Orttaai.border`)
- [ ] Amber focus ring

#### Task 1.30: OrttaaiToggle.swift
**File**: `Orttaai/UI/Components/OrttaaiToggle.swift`

- [ ] Custom `ToggleStyle`: amber when active, gray when inactive
- [ ] 150ms animation on toggle

#### Task 1.31: OrttaaiProgressBar.swift
**File**: `Orttaai/UI/Components/OrttaaiProgressBar.swift`

- [ ] Custom `ProgressViewStyle` with amber fill
- [ ] Used for model download progress and audio level

#### Task 1.32: AudioLevelMeter.swift
**File**: `Orttaai/UI/Components/AudioLevelMeter.swift`

- [ ] `GeometryReader` + `Rectangle` with animated width
- [ ] Width driven by `audioLevel` float (0.0 to 1.0)
- [ ] Amber fill color

#### Task 1.33: ShortcutRecorderView.swift
**File**: `Orttaai/UI/Components/ShortcutRecorderView.swift`

- [ ] Wrapper around `KeyboardShortcuts.Recorder`
- [ ] Styled to match Orttaai design system

---

### Phase 1 Verification Checkpoint

- [ ] App launches and shows menu bar icon (waveform.circle)
- [ ] Clicking icon shows dropdown menu with all items
- [ ] Menu items are correctly enabled/disabled
- [ ] FloatingPanel can be shown/dismissed programmatically (test via a temporary menu action)
- [ ] WaveformView animates when given changing audioLevel values
- [ ] All unit tests pass (`Cmd+U`)
- [ ] DatabaseManager tests pass with in-memory DB
- [ ] ClipboardManager round-trip tests pass
- [ ] HardwareDetector correctly identifies your M4 Mac Mini
- [ ] Git commit: "Phase 1 complete: foundation services, menu bar, floating panel, design system"

---

## 3. Phase 2: Core Pipeline (Week 3–4)

**Goal**: End-to-end dictation works. Press hotkey → speak → text appears in target app. Validated across 25+ apps.

### Week 3, Day 1–2: Transcription Service

#### Task 2.1: TranscriptionService.swift
**File**: `Orttaai/Core/Transcription/TranscriptionService.swift`

- [ ] Define `actor TranscriptionService`
- [ ] Private `whisperKit: WhisperKit?`
- [ ] Implement `loadModel(named:) async throws`:
  - Create `WhisperKitConfig` with `.cpuAndNeuralEngine` for both encoder and decoder
  - Initialize WhisperKit with config
- [ ] Implement `transcribe(audioSamples: [Float]) async throws -> String`:
  - Guard whisperKit is loaded
  - Call `wk.transcribe(audioArray:)`
  - Return trimmed text from first result
- [ ] Implement `unloadModel()`: set whisperKit = nil
- [ ] Implement `warmUp() async`: transcribe 1 second of silence (16000 zeros) to prime Core ML

#### Task 2.2: TextProcessor.swift
**File**: `Orttaai/Core/Transcription/TextProcessor.swift`

- [ ] Define `protocol TextProcessor`
- [ ] Define `TextProcessorInput` struct: rawTranscript, targetApp, mode
- [ ] Define `ProcessingMode` enum: `.raw`, `.clean`, `.formal`, `.casual`
- [ ] Define `TextProcessorOutput` struct: text, changes
- [ ] Implement `PassthroughProcessor`: returns input unchanged
- [ ] `isAvailable()` always returns true for PassthroughProcessor

---

### Week 3, Day 2–3: Text Injection Service

#### Task 2.3: TextInjectionService.swift
**File**: `Orttaai/Core/Injection/TextInjectionService.swift`

- [ ] Define `final class TextInjectionService`
- [ ] Private `clipboard: ClipboardManager`
- [ ] Private(set) `lastTranscript: String?`
- [ ] Implement `isFocusedElementSecure() -> Bool`:
  - Get frontmost app via `NSWorkspace.shared.frontmostApplication`
  - Create `AXUIElementCreateApplication` with process identifier
  - Query `kAXFocusedUIElementAttribute` for focused element
  - If query fails: return `false` (fail-open)
  - Query `kAXRoleAttribute` on focused element
  - Return `true` if role == `kAXSecureTextFieldRole`
- [ ] Implement `inject(text:) async -> InjectionResult`:
  1. Check `isFocusedElementSecure()` — if true, return `.blockedSecureField` WITHOUT setting `lastTranscript`
  2. Set `lastTranscript = text` (only after secure field check passes)
  3. Save current pasteboard
  4. Set transcript on pasteboard
  5. Call `simulatePaste()`
  6. Sleep 250ms
  7. Restore pasteboard
  8. Return `.success`
- [ ] Implement `simulatePaste()`:
  - Create `CGEventSource` with `.hidSystemState`
  - Key code 0x09 (V key)
  - Create key-down event with `.maskCommand`
  - Create key-up event with `.maskCommand`
  - Post key-down to `.cghidEventTap`
  - `usleep(10_000)` — 10ms pause
  - Post key-up to `.cghidEventTap`
- [ ] Define `InjectionResult` enum: `.success`, `.blockedSecureField`

#### Task 2.4: TextInjectionServiceTests.swift
**File**: `OrttaaiTests/Core/TextInjectionServiceTests.swift`

- [ ] Test that `inject` returns `.blockedSecureField` when secure field is focused (mock AX)
- [ ] Test that `lastTranscript` is NOT set when blocked
- [ ] Test that `lastTranscript` IS set on successful injection
- [ ] Test clipboard save/restore round-trip through inject flow

---

### Week 3, Day 3–4: Model Management

#### Task 2.5: ModelDownloader.swift
**File**: `Orttaai/Core/Model/ModelDownloader.swift`

- [ ] Download models via `URLSession` with background configuration
- [ ] Implement `URLSessionDownloadDelegate` for progress
- [ ] Progress reporting: percentage, bytes downloaded, total bytes, speed, ETA
- [ ] Resume-after-interrupt via `downloadTask(withResumeData:)`
- [ ] SHA256 verification after download using `CC_SHA256`
- [ ] Store downloaded files in `~/Library/Application Support/Orttaai/Models/`
- [ ] Error handling: exponential backoff (2s, 4s, 8s), then manual retry
- [ ] Post `UNUserNotificationCenter` notification on background download completion

#### Task 2.6: ModelManager.swift
**File**: `Orttaai/Core/Model/ModelManager.swift`

- [ ] Define `@Observable final class ModelManager`
- [ ] Track state: `.notDownloaded`, `.downloading(progress)`, `.downloaded`, `.loaded`, `.error`
- [ ] Available models list with metadata (name, size, description, hardware tier)
- [ ] Implement `download(model:)` — delegates to ModelDownloader
- [ ] Implement `loadModel() async throws` — delegates to TranscriptionService
- [ ] Implement `switchModel(to:)` — unload current, download if needed, load new
- [ ] Implement `verifyModel(at path:)` — SHA256 check
- [ ] Implement `deleteModel(named:)` — removes from disk
- [ ] Directory check: create Models/ directory if it doesn't exist

---

### Week 3, Day 4–5: DictationCoordinator

#### Task 2.7: DictationCoordinator.swift
**File**: `Orttaai/Core/Coordination/DictationCoordinator.swift`

- [ ] Define `@Observable final class DictationCoordinator`
- [ ] State enum: `.idle`, `.recording(startTime: Date)`, `.processing(estimatedDuration: TimeInterval?)`, `.injecting`, `.error(message: String)`
- [ ] Hold references to: AudioCaptureService, TranscriptionService, TextProcessor, TextInjectionService, DatabaseManager
- [ ] `maxDuration: TimeInterval = 45`
- [ ] `capTimer: Task<Void, Never>?`
- [ ] Implement `startRecording()`:
  - Guard state == .idle
  - Try audioService.startCapture()
  - Set state = .recording(startTime: Date())
  - Start cap timer (Task.sleep for 45s, then call stopRecording)
- [ ] Implement `stopRecording()`:
  - Guard case .recording(let start)
  - Cancel cap timer
  - Get samples from audioService.stopCapture()
  - Calculate duration
  - Guard duration >= 0.5 (else: state = .idle, log skipped recording)
  - Set state = .processing
  - Launch Task:
    - Get frontmost app name
    - Measure processingMs with CFAbsoluteTimeGetCurrent
    - Transcribe samples
    - Process through TextProcessor
    - Set state = .injecting
    - Inject text
    - Handle result: .success → save to DB, .blockedSecureField → show error
    - Set state = .idle
    - On error: state = .error, auto-dismiss after 2s
- [ ] Implement `startCapTimer()`:
  - At 35s: trigger countdown display
  - At 45s: call stopRecording()
- [ ] Implement `estimateProcessingTime(_:) -> TimeInterval`
- [ ] Implement `autoDismissError()`: Task.sleep 2s, then state = .idle

#### Task 2.8: DictationCoordinatorTests.swift
**File**: `OrttaaiTests/Coordination/DictationCoordinatorTests.swift`

- [ ] Create mock services (MockAudioService, MockTranscriptionService, etc.)
- [ ] Test idle → recording transition on startRecording()
- [ ] Test recording → processing → injecting → idle on stopRecording()
- [ ] Test < 0.5s recording goes straight to idle
- [ ] Test secure field block → error state, then auto-dismiss to idle
- [ ] Test transcription failure → error state
- [ ] Test cap timer fires at 45s
- [ ] Test startRecording() in non-idle state is ignored

---

### Week 3, Day 5 → Week 4, Day 1: Wire Everything Together

#### Task 2.9: End-to-End Integration

- [ ] In `AppDelegate`, create all services and inject into `DictationCoordinator`
- [ ] Wire `HotkeyService.onKeyDown` → `coordinator.startRecording()`
- [ ] Wire `HotkeyService.onKeyUp` → `coordinator.stopRecording()`
- [ ] Wire coordinator state changes → floating panel show/hide
- [ ] Wire coordinator state changes → menu bar icon updates
- [ ] Wire coordinator state changes → waveform audioLevel
- [ ] Test end-to-end: press hotkey → speak → release → text appears at cursor

#### Task 2.10: First Manual Test

- [ ] Open TextEdit
- [ ] Press Ctrl+Shift+Space, say "Hello world", release
- [ ] Verify: floating panel appears, waveform responds, text "Hello world" appears in TextEdit
- [ ] Verify: clipboard is restored after injection
- [ ] Verify: transcription appears in database (check via Settings or a temporary debug view)

---

### Week 4, Day 1–3: Text Injection Validation (25+ Apps)

**This is the highest-risk validation in the entire project.** Do not skip or rush this.

#### Task 2.11: App Compatibility Testing

For each app, test:
- Short dictation (3s): "Hello world"
- Medium dictation (10s): A full sentence with punctuation
- Clipboard restore: Copy an image before dictating, verify image is restored after

Create `TESTING.md` and record results:

```markdown
| App | Short | Medium | Punctuation | Clipboard | Notes |
|-----|-------|--------|-------------|-----------|-------|
| Safari | | | | | |
| Chrome | | | | | |
...
```

**Test these apps** (from PRD Section 16.2):
- [ ] Safari
- [ ] Chrome
- [ ] Firefox
- [ ] Arc
- [ ] VS Code
- [ ] Cursor
- [ ] Xcode
- [ ] iTerm2
- [ ] Terminal.app
- [ ] Slack (native)
- [ ] Discord
- [ ] Messages
- [ ] Mail
- [ ] Notes
- [ ] TextEdit
- [ ] Pages
- [ ] Notion
- [ ] Linear
- [ ] Obsidian
- [ ] Bear
- [ ] Craft
- [ ] Google Docs (in Chrome)
- [ ] Gmail (in Chrome)
- [ ] ChatGPT input (in Chrome)
- [ ] Figma comments (in Chrome)
- [ ] Password field (should block)
- [ ] Spotlight (should work)
- [ ] Full-screen app

**If injection failure rate > 5%**: investigate and fix before proceeding to Phase 3.

Common issues to watch for:
- Text not appearing: increase clipboard restore delay (try 300ms, 400ms)
- Duplicate text: key-down/key-up spacing too close (increase `usleep`)
- Focus stolen: NSPanel configuration issue
- Clipboard not restored: promise type handling issue

---

### Week 4, Day 3–4: Countdown & Processing Estimate

#### Task 2.12: Recording Cap

- [ ] Implement countdown display in floating panel at 35s
- [ ] Auto-stop at 45s (cap timer fires, calls stopRecording)
- [ ] Show processing estimate when recording > 20s
- [ ] Estimate formula based on hardware tier and recording duration

---

### Week 4, Day 5: Integration Polish

#### Task 2.13: Edge Cases

- [ ] Test hotkey during model loading (should show "Model loading..." error)
- [ ] Test hotkey with no model downloaded (should show "No model installed")
- [ ] Test hotkey when microphone permission revoked (should show error with System Settings link)
- [ ] Test rapid hotkey press/release (< 0.5s) — should silently skip
- [ ] Test hotkey while Settings/History window has focus — should not fire
- [ ] Run all unit tests: `Cmd+U`

### Phase 2 Verification Checkpoint

- [ ] End-to-end dictation works: hotkey → speak → text appears
- [ ] Text injection passes across 25+ apps (< 5% failure rate)
- [ ] Clipboard is preserved after injection (text, images, file URLs)
- [ ] Secure text fields block injection with user-facing message
- [ ] `lastTranscript` is NOT set when secure field blocks
- [ ] Recording countdown shows at 35s, auto-stops at 45s
- [ ] Processing estimate shows for recordings > 20s
- [ ] < 0.5s recordings silently skipped
- [ ] All unit tests pass
- [ ] TESTING.md populated with manual test results
- [ ] Git commit: "Phase 2 complete: end-to-end dictation, 25+ app validation"

---

## 4. Phase 3: Features & UI (Week 5–6)

**Goal**: All user-facing features built. Setup flow, settings, history, Sparkle integration.

### Week 5, Day 1–2: Setup Flow

#### Task 3.1: SetupView.swift
**File**: `Orttaai/UI/Setup/SetupView.swift`

- [ ] Multi-step view: Permissions → Download → Ready
- [ ] Track current step as state
- [ ] Navigation via "Continue" / "Back" buttons
- [ ] Overall progress indicator (step 1 of 3, etc.)

#### Task 3.2: PermissionStepView.swift
**File**: `Orttaai/UI/Setup/PermissionStepView.swift`

- [ ] Three permission rows: Microphone, Accessibility, Input Monitoring
- [ ] Each row: icon, description, status (granted/not granted), "Grant Access" button
- [ ] Trust statement displayed prominently (from PRD Section 5.9)
- [ ] "Grant Access" opens the correct System Settings URL:
  - Microphone: `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`
  - Accessibility: `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`
  - Input Monitoring: `x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent`
- [ ] Poll for permission changes every 1s (use Timer)
- [ ] For Input Monitoring: attempt `CGEvent.tapCreate()` after granting
  - If tap succeeds: show green check
  - If tap returns nil: show "Restart Orttaai to activate hotkey" + "Restart Now" button
  - "Restart Now" calls `NSApp.terminate(nil)` after setting relaunch flag
- [ ] "Continue" button enabled only when all three permissions granted

#### Task 3.3: DownloadStepView.swift
**File**: `Orttaai/UI/Setup/DownloadStepView.swift`

- [ ] Show detected hardware (chip, RAM)
- [ ] Show recommended model with size
- [ ] Progress bar during download (percentage, speed, ETA)
- [ ] "Download" button to start
- [ ] Progress updates from ModelDownloader
- [ ] On completion: SHA256 verification, then auto-advance to Ready step
- [ ] On error: show retry button with error message

#### Task 3.4: ReadyStepView.swift
**File**: `Orttaai/UI/Setup/ReadyStepView.swift`

- [ ] "Orttaai is ready!" message
- [ ] Show configured hotkey: "Press [Ctrl+Shift+Space] anywhere to start dictating."
- [ ] "Start Using Orttaai" button → closes setup window, sets `hasCompletedSetup = true`

---

### Week 5, Day 2–4: Settings

#### Task 3.5: SettingsView.swift
**File**: `Orttaai/UI/Settings/SettingsView.swift`

- [ ] `TabView` with tabs: General, Audio, Model, About
- [ ] Use `Settings` scene in OrttaaiApp if using native settings window approach
- [ ] OR use WindowManager to show a custom NSWindow with TabView

#### Task 3.6: GeneralSettingsView.swift
**File**: `Orttaai/UI/Settings/GeneralSettingsView.swift`

- [ ] Launch at Login toggle (uses SMAppService or login item API)
- [ ] Hotkey configuration: `ShortcutRecorderView` for primary hotkey
- [ ] Paste-last-transcript hotkey configuration
- [ ] Show Processing Estimate toggle
- [ ] Clear History button with confirmationDialog

#### Task 3.7: AudioSettingsView.swift
**File**: `Orttaai/UI/Settings/AudioSettingsView.swift`

- [ ] Microphone selector: SwiftUI Picker with available input devices
- [ ] Default option: "System Default"
- [ ] Live audio level meter showing current input level
- [ ] Device name and sample rate display
- [ ] Per-engine device note: "Changing the microphone here only affects Orttaai. Other apps are not affected."

#### Task 3.8: ModelSettingsView.swift
**File**: `Orttaai/UI/Settings/ModelSettingsView.swift`

- [ ] Current model: name, size, expected performance
- [ ] Available models list with:
  - Name, download size, accuracy description
  - Hardware compatibility note
  - Download/Switch button
- [ ] Download progress inline
- [ ] Re-download button for corrupted models
- [ ] Disk space used by models

#### Task 3.9: AboutView.swift
**File**: `Orttaai/UI/Settings/AboutView.swift`

- [ ] App icon
- [ ] App name and version
- [ ] "Made by [your name]"
- [ ] GitHub link
- [ ] License: MIT
- [ ] For Homebrew installs: "Updates managed by Homebrew. Run `brew upgrade orttaai`."
- [ ] For direct installs: current version, last update check date
- [ ] Acknowledgments: WhisperKit, GRDB, Sparkle, KeyboardShortcuts

---

### Week 5, Day 4–5: History

#### Task 3.10: HistoryView.swift
**File**: `Orttaai/UI/History/HistoryView.swift`

- [ ] SwiftUI `List` with `.searchable` modifier
- [ ] GRDB `DatabaseRegionObservation` for live updates
- [ ] Each row: `HistoryEntryView`
- [ ] Lazy loading (native SwiftUI List handles this)
- [ ] Empty state: "No transcriptions yet. Press [hotkey] to get started."

#### Task 3.11: HistoryEntryView.swift
**File**: `Orttaai/UI/History/HistoryEntryView.swift`

- [ ] Collapsed: relative timestamp (RelativeDateTimeFormatter), truncated text (2 lines), target app name
- [ ] Expanded (on click): full text, "Copy" button
- [ ] Copy button copies full text to clipboard
- [ ] App name styled as secondary text

---

### Week 6, Day 1–2: Menu Bar Integration

#### Task 3.12: MenuBarIconRenderer.swift
**File**: `Orttaai/UI/MenuBar/MenuBarIconRenderer.swift`

- [ ] Render different icon states:
  - Idle: template SF Symbol (adapts to light/dark)
  - Recording: amber-tinted, subtle pulse via NSTimer (2s interval)
  - Processing: amber shimmer effect
  - Downloading: progress ring around icon (Core Graphics custom drawing)
  - Error: small amber dot badge
- [ ] Update icon based on DictationCoordinator state and ModelManager state

#### Task 3.13: Update StatusBarMenu
**File**: `Orttaai/UI/MenuBar/StatusBarMenu.swift`

- [ ] Dynamic status line: "Ready" / "Recording..." / "Processing..." / "Downloading model (43%)..."
- [ ] Polish Mode toggle: disabled with "Coming soon" subtitle
- [ ] History: opens HistoryView in WindowManager
- [ ] Settings: opens SettingsView (Cmd+,)
- [ ] Check for Updates / "Updates managed by Homebrew": based on `isHomebrewInstall`
- [ ] Quit: graceful shutdown sequence

---

### Week 6, Day 2–3: Sparkle Integration

#### Task 3.14: Sparkle Setup

- [ ] Generate EdDSA keys: `./bin/generate_keys` from Sparkle package
- [ ] Store public key in `Info.plist` as `SUPublicEDKey`
- [ ] Configure Sparkle's `SUUpdater`:
  - `SUFeedURL`: point to your GitHub Pages appcast URL
  - `SUAutomaticallyChecksForUpdates`: `true` for .dmg, `false` for Homebrew
- [ ] Implement Homebrew detection:
  - Check `Bundle.main.url(forResource: ".homebrew-installed", withExtension: nil)`
  - If detected: disable Sparkle auto-check, hide update menu item
  - If not detected: enable Sparkle, show "Check for Updates..." menu item

#### Task 3.15: Appcast Setup

- [ ] Create `appcast.xml` template (will be populated in Phase 4)
- [ ] Host on GitHub Pages or raw GitHub URL
- [ ] Sparkle's `generate_appcast` tool will generate entries from signed releases

---

### Week 6, Day 3–4: Secure Field Blocking Integration

#### Task 3.16: End-to-End Secure Field Testing

- [ ] Test dictation with password field focused in:
  - Safari (login form)
  - Chrome (login form)
  - macOS System Settings (password fields)
  - 1Password / Bitwarden (if available)
- [ ] Verify: floating panel shows "Can't dictate into password fields"
- [ ] Verify: `lastTranscript` is NOT set
- [ ] Verify: clipboard is NOT touched
- [ ] Verify: after 2s, error dismisses and state returns to idle

---

### Week 6, Day 4–5: Model Warm-Up & Polish

#### Task 3.17: Model Warm-Up on Launch

- [ ] After setup completion and model downloaded:
  - On app launch, load model and call `warmUp()` (transcribe 1s silence)
  - This primes Core ML pipeline — first real dictation will be fast
- [ ] Show subtle loading state in menu bar during warm-up
- [ ] Don't block the user — warm-up runs in background

#### Task 3.18: Download Notification

- [ ] Request notification permission during setup (optional, don't block on it)
- [ ] When background model download completes: post `UNUserNotificationCenter` notification
- [ ] Notification title: "Orttaai" / body: "Model downloaded. Ready to dictate."

### Phase 3 Verification Checkpoint

- [ ] Setup flow works end-to-end: permissions → download → ready
- [ ] Input Monitoring restart flow works (grant permission → restart → tap works)
- [ ] Settings: all tabs functional, changes persist after restart
- [ ] Audio: mic selector changes device without affecting system default
- [ ] Model: can download, switch, re-download
- [ ] History: entries appear live, search works, copy works, clear works
- [ ] Menu bar: all icon states render correctly
- [ ] Menu bar: all dropdown items work
- [ ] Sparkle: update check works for .dmg installs
- [ ] Sparkle: disabled and hidden for Homebrew installs
- [ ] Secure field blocking works in Safari, Chrome, System Settings
- [ ] Model warm-up runs on launch
- [ ] All unit tests pass
- [ ] Git commit: "Phase 3 complete: setup flow, settings, history, Sparkle, model management"

---

## 5. Phase 4: Polish & Ship (Week 7–9)

**Goal**: Production-ready. Code-signed, notarized, packaged, tested, documented.

### Week 7, Day 1–2: Error States

#### Task 4.1: Implement All Error States

Walk through the entire error handling matrix (PRD Section 10) and verify each state:

- [ ] Microphone denied → Panel shows message → opens System Settings
- [ ] Accessibility denied → Setup highlights step → opens System Settings
- [ ] Input Monitoring denied → Setup shows restart flow
- [ ] Model not downloaded → Settings shows download prompt
- [ ] Model corrupted → Panel shows error → Settings > Model > Re-download
- [ ] Inference failure → Panel shows "Couldn't transcribe" (2s) → auto-dismiss
- [ ] Out of memory → Panel shows message → Settings > Model
- [ ] Insufficient disk space → Settings shows required space
- [ ] Download failed → Settings shows retry with exponential backoff
- [ ] Paste failed → Panel shows "Use Cmd+Shift+V to paste" (3s)
- [ ] Secure text field → Panel shows "Can't dictate" (2s)
- [ ] Recording too short → Silent log
- [ ] Intel Mac → Setup shows incompatibility message
- [ ] No audio input → Panel shows "No microphone detected"
- [ ] Input Monitoring granted but tap fails → "Restart Now" button

---

### Week 7, Day 3–5: Performance Profiling

#### Task 4.2: Measure Against Three-Tier Targets

Use Instruments (Xcode > Product > Profile) and Activity Monitor:

| Metric | How to Measure | Target |
|---|---|---|
| Cold start | Measure time from launch to menu bar icon visible | < 1.5s |
| Model load | Measure `loadModel` + `warmUp` duration | < 4s |
| Transcription (3s) | Time from `transcribe()` call to result | < 1.0s |
| Transcription (10s) | Same | < 2.5s |
| Transcription (30s) | Same | < 10s |
| Idle RAM (no model) | Activity Monitor, no model loaded | < 12MB |
| RAM (model loaded) | Activity Monitor, model loaded, no activity | < 1.0GB |
| RAM (inference) | Activity Monitor peak during transcription | < 1.5GB |
| Idle CPU | Activity Monitor, model loaded, 30s of no activity | 0% |
| Waveform fps | Instruments > Core Animation | 60fps |
| UI interaction | Time from click to response | < 30ms |
| Binary size | `ls -lh Orttaai.app/Contents/MacOS/Orttaai` | < 10MB |

- [ ] Record all measurements in a table
- [ ] For any Fail-tier results: investigate and optimize
- [ ] For Acceptable-tier results: document and create GitHub issues for future optimization
- [ ] For Target-tier results: celebrate

#### Task 4.3: Optimization (if needed)

Common optimization targets:
- [ ] If cold start > 2.5s: defer non-critical initialization, lazy-load services
- [ ] If RAM too high: check for retain cycles, use weak references, verify model unload
- [ ] If transcription too slow: verify Neural Engine is being used (not CPU fallback)
- [ ] If waveform < 30fps: simplify Canvas drawing, reduce sample count

---

### Week 8, Day 1–3: Code Signing, Notarization, Packaging

#### Task 4.4: Code Signing

- [ ] Verify signing identity in Xcode build settings:
  - `CODE_SIGN_IDENTITY` = "Developer ID Application"
  - `DEVELOPMENT_TEAM` = Your team ID
  - `CODE_SIGN_STYLE` = "Manual" (recommended for distribution)
- [ ] Build Archive: Product > Archive
- [ ] Export: Distribute App > Developer ID > Upload (for notarization) or Export (for manual)

#### Task 4.5: Notarization

- [ ] If using Xcode automatic: Archive > Distribute App > Developer ID > Upload
  - Xcode submits to Apple's notarization service
  - Wait for approval (usually 5–15 minutes)
  - Xcode staples the ticket automatically
- [ ] If using manual:
  ```bash
  xcrun notarytool submit Orttaai.zip --apple-id YOUR_ID --team-id YOUR_TEAM --password APP_SPECIFIC_PASSWORD --wait
  xcrun stapler staple Orttaai.app
  ```
- [ ] Verify notarization: `spctl --assess --verbose=4 Orttaai.app`

#### Task 4.6: DMG Creation

- [ ] Using create-dmg:
  ```bash
  create-dmg \
    --volname "Orttaai" \
    --volicon "Orttaai/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "Orttaai.app" 150 190 \
    --app-drop-link 450 190 \
    --hide-extension "Orttaai.app" \
    "Orttaai-1.0.0.dmg" \
    "build/Release/Orttaai.app"
  ```
- [ ] Notarize the DMG itself:
  ```bash
  xcrun notarytool submit Orttaai-1.0.0.dmg --apple-id ... --wait
  xcrun stapler staple Orttaai-1.0.0.dmg
  ```
- [ ] Test: download DMG, open, drag to Applications, launch — should not show Gatekeeper warning

#### Task 4.7: Homebrew Cask Formula

- [ ] Create cask formula:
  ```ruby
  cask "orttaai" do
    version "1.0.0"
    sha256 "SHA256_OF_DMG"

    url "https://github.com/YOURUSER/orttaai/releases/download/v#{version}/Orttaai-#{version}.dmg"
    name "Orttaai"
    desc "Native macOS voice keyboard using WhisperKit"
    homepage "https://orttaai.com"

    livecheck do
      url :url
      strategy :github_latest
    end

    depends_on macos: ">= :sonoma"
    depends_on arch: :arm64

    app "Orttaai.app"

    postflight do
      marker = "#{appdir}/Orttaai.app/Contents/Resources/.homebrew-installed"
      File.write(marker, "installed via homebrew\n")
    end

    zap trash: [
      "~/Library/Application Support/Orttaai",
      "~/Library/Preferences/com.orttaai.app.plist",
    ]
  end
  ```
- [ ] Test locally: `brew install --cask ./orttaai.rb`
- [ ] Verify marker file exists: `ls Orttaai.app/Contents/Resources/.homebrew-installed`
- [ ] Submit PR to homebrew-cask repository (or host in your own tap initially)

---

### Week 8, Day 3–5: App Icon & Visual Polish

#### Task 4.8: App Icon

- [ ] Design app icon (or commission one) — waveform motif in amber/charcoal
- [ ] Create all required sizes for `Assets.xcassets/AppIcon.appiconset`:
  - 16x16, 32x32, 64x64, 128x128, 256x256, 512x512, 1024x1024
  - @1x and @2x variants
- [ ] Add `Contents.json` mapping

#### Task 4.9: Menu Bar Icon States

- [ ] Create/refine SF Symbol configurations for each state
- [ ] Test in both light and dark mode menu bars
- [ ] Test amber pulse animation timing
- [ ] Test progress ring rendering during download

#### Task 4.10: Visual QA Pass

- [ ] Walk through every screen in the app
- [ ] Check spacing, alignment, color consistency against design system
- [ ] Test in light and dark mode (dark mode only for v1.0, but verify light mode doesn't break)
- [ ] Test with different Dynamic Type sizes (accessibility)
- [ ] Screenshot each screen for documentation

---

### Week 9, Day 1–2: Documentation

#### Task 4.11: README.md

- [ ] Project description and screenshot/GIF
- [ ] Features list
- [ ] Installation: Homebrew and direct download
- [ ] Permissions explanation
- [ ] Model information
- [ ] Keyboard shortcuts
- [ ] Building from source instructions
- [ ] Contributing link
- [ ] License (MIT)

#### Task 4.12: CONTRIBUTING.md

- [ ] Development setup instructions
- [ ] Code style guidelines
- [ ] PR process
- [ ] Issue templates

#### Task 4.13: TESTING.md

- [ ] Manual test matrix results (populated during Phase 2)
- [ ] How to run unit tests
- [ ] How to run the manual test matrix
- [ ] Known issues and workarounds

#### Task 4.14: LICENSE

- [ ] MIT License with your name and year

---

### Week 9, Day 2–3: Final Testing

#### Task 4.15: Manual Test Matrix (Re-run)

- [ ] Re-run the full 25+ app test matrix from Phase 2
- [ ] Record results in TESTING.md
- [ ] Fix any regressions

#### Task 4.16: QA Checklist (Full Run)

Execute the entire QA checklist from PRD Section 16.3:

- [ ] Setup completes, permissions granted, model downloads, first dictation works
- [ ] Cold start < 2.5s (Acceptable tier). Menu bar icon visible, hotkey responsive.
- [ ] Waveform responds. Countdown at 35s. Auto-stop at 45s.
- [ ] Processing estimate shown for recordings > 20s.
- [ ] History: entries appear, search works, copy works, clear works.
- [ ] Settings: all controls functional, changes persist after restart.
- [ ] Secure text field: dictation blocked with correct message. Transcript NOT stored in lastTranscript.
- [ ] Each error state triggered and verified.
- [ ] Sparkle update check works for .dmg installs.
- [ ] Homebrew detection disables auto-check and hides menu item.
- [ ] Quit: clean shutdown, no orphan resources.

#### Task 4.17: Unit Tests Final Run

- [ ] `Cmd+U` — all tests pass
- [ ] Check test coverage (aim for > 70% on core services)
- [ ] Fix any flaky tests

---

### Week 9, Day 3–4: Beta Testing

#### Task 4.18: Beta Distribution

- [ ] Create GitHub Release (pre-release) with DMG attached
- [ ] Share with 5–10 beta testers
- [ ] Provide feedback form or GitHub Issues template
- [ ] Collect feedback on:
  - Setup experience (time, confusion points)
  - Dictation accuracy
  - Text injection reliability (which apps fail?)
  - Performance (sluggishness, RAM concerns)
  - Missing features

#### Task 4.19: Beta Feedback Fixes

- [ ] Triage beta feedback
- [ ] Fix critical issues (injection failures, crashes, permission problems)
- [ ] Document non-critical issues as GitHub Issues for v1.0.1

---

### Week 9, Day 5: Ship

#### Task 4.20: Final Release

- [ ] Create final Archive with release build configuration
- [ ] Notarize final build
- [ ] Create DMG from notarized app
- [ ] Notarize DMG
- [ ] Create GitHub Release (v1.0.0):
  - Tag: `v1.0.0`
  - Title: "Orttaai v1.0.0 — First Release"
  - Release notes: features, known issues, system requirements
  - Attach DMG
- [ ] Update Sparkle appcast.xml with new release entry
- [ ] Update Homebrew cask formula with new version and SHA256
- [ ] Submit Homebrew cask PR (or push to your tap)
- [ ] Verify: `brew install --cask orttaai` works
- [ ] Verify: direct DMG download, install, and launch works
- [ ] Git commit & tag: "v1.0.0: First release"

### Phase 4 Verification Checkpoint

- [ ] All error states work per error handling matrix
- [ ] Performance meets Acceptable tier or better for all metrics
- [ ] App is code-signed with Developer ID Application
- [ ] App is notarized and stapled
- [ ] DMG is notarized and stapled
- [ ] Homebrew cask installs successfully with marker file
- [ ] Sparkle update check works for .dmg installs
- [ ] Sparkle is disabled for Homebrew installs
- [ ] README, CONTRIBUTING, TESTING, LICENSE complete
- [ ] 25+ app test matrix passes (< 5% failure rate)
- [ ] Full QA checklist passes
- [ ] All unit tests pass
- [ ] Beta feedback addressed
- [ ] GitHub Release created with DMG
- [ ] Homebrew cask submitted

---

## 6. Risk Register & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| WhisperKit API changes | High | Medium | Pin to `.upToNextMinor`. Weekly GitHub Action to detect new releases. |
| Text injection fails in specific app | High | High | 25+ app matrix in Week 3. 250ms restore delay as tunable constant. |
| Notarization rejected | Medium | Low | Hardened Runtime enabled. No JIT, no unsigned libs. Test early in Week 8. |
| Model download slow/fails | Medium | Medium | Resume-after-interrupt. Exponential backoff. SHA256 verification. |
| CGEvent tap disabled by macOS update | High | Low | No mitigation — Apple controls this. Monitor macOS betas. |
| Sparkle supply chain attack | High | Very Low | EdDSA signing. Code signature verification. HTTPS-only appcast. |
| Clipboard restore fails (lazy providers) | Low | Medium | Documented as known limitation. Matches Wispr Flow behavior. |
| AX cursor position unavailable | Low | Medium | Fall back to `NSEvent.mouseLocation`. |
| Memory pressure during inference on 8GB | Medium | Medium | Recommend quantized model for 8GB. Show memory warning. |

---

## 7. Daily Workflow

Recommended daily routine for building Orttaai:

1. **Start**: Open Cursor and Xcode side-by-side
2. **Edit** in Cursor: write Swift code with AI assistance
3. **Build** in Xcode: `Cmd+B` to compile, check for errors
4. **Run** in Xcode: `Cmd+R` to launch the app
5. **Test** in Xcode: `Cmd+U` to run unit tests
6. **Debug** in Xcode: breakpoints, console, Instruments
7. **Commit** frequently: at least once per completed task
8. **End of day**: push to GitHub, note where you left off

**Git branch strategy** (simple):
- `main`: always releasable
- `develop`: daily work
- Feature branches for larger changes
- Merge to `main` at end of each phase

---

## 8. Definition of Done (Per Phase)

### Phase 1: Foundation
- All design tokens implemented and importable
- All utility files created
- DatabaseManager tested with in-memory DB (5+ tests passing)
- ClipboardManager save/restore round-trip tested (3+ tests passing)
- HardwareDetector correctly identifies M4
- AudioCaptureService captures audio and reports levels
- HotkeyService creates event tap and detects push-to-talk
- Menu bar icon visible with dropdown menu
- FloatingPanel shows/hides with fade animation
- WaveformView animates with test data
- All UI components styled per design system
- `Cmd+B` builds with zero warnings (or only SPM dependency warnings)
- `Cmd+U` passes all tests

### Phase 2: Core Pipeline
- Dictation works end-to-end: hotkey → speak → text at cursor
- 25+ apps tested with < 5% injection failure rate
- Clipboard preserved after every injection
- Secure field detection blocks password fields
- `lastTranscript` not set on secure field block
- Recording cap at 45s with countdown at 35s
- < 0.5s recordings silently skipped
- DictationCoordinator tests cover all state transitions (8+ tests)
- TESTING.md populated with real test results

### Phase 3: Features & UI
- Setup flow works from scratch (fresh install simulation)
- Input Monitoring restart flow works
- All Settings tabs functional with persistent storage
- History shows live updates, search, copy, clear
- Model download with progress, verification, switching
- Sparkle active for .dmg, disabled for Homebrew
- Menu bar icon reflects all states correctly
- Model warm-up runs on launch

### Phase 4: Polish & Ship
- All performance metrics at Acceptable tier or better
- Code-signed and notarized
- DMG created and notarized
- Homebrew cask installs successfully
- Full QA checklist passes
- All documentation complete
- Beta tested with 5+ users
- GitHub Release published
- Homebrew formula submitted

---

*End of Implementation Plan*

Orttaai Implementation Plan · Based on PRD v2.2 · February 2026
