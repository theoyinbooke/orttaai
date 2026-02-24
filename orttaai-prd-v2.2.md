# ORTTAAI

**Product Requirements Document**

Native macOS Voice Keyboard · Swift + SwiftUI + WhisperKit

Version 2.2 · February 2026
**Status: Ready for Development**

---

## Contents

1. [Problem Statement](#1-problem-statement)
2. [Target User Profile](#2-target-user-profile)
3. [Product Vision](#3-product-vision)
4. [Core User Flows](#4-core-user-flows)
5. [MVP Feature Specification](#5-mvp-feature-specification)
6. [Technical Architecture](#6-technical-architecture)
7. [Native APIs Deep Dive](#7-native-apis-deep-dive)
8. [Design System](#8-design-system)
9. [Interaction Design](#9-interaction-design)
10. [Error Handling](#10-error-handling)
11. [Performance Requirements](#11-performance-requirements)
12. [Security & Privacy](#12-security--privacy)
13. [Distribution & Updates](#13-distribution--updates)
14. [Project Structure](#14-project-structure)
15. [Development Phases](#15-development-phases)
16. [Testing Strategy](#16-testing-strategy)
17. [Post-MVP Roadmap](#17-post-mvp-roadmap)
18. [Anti-Goals](#18-anti-goals)
19. [Success Metrics](#19-success-metrics)
20. [Competitive Landscape](#20-competitive-landscape)
21. [Decision Log](#21-decision-log)
22. [Changelog (v2.0 → v2.1)](#22-changelog-v20--v21)
23. [Changelog (v2.1 → v2.2)](#23-changelog-v21--v22)

---

## 1. Problem Statement

Voice dictation on macOS is broken. Apple's built-in dictation requires a constant internet connection, provides inconsistent accuracy, and offers no text cleanup. The market leader, Wispr Flow, sends all voice data to cloud servers (OpenAI, Meta), charges $144/year, consumes 800MB of RAM at idle, and drew significant user backlash over privacy practices.

There is no high-quality, local-first voice keyboard for macOS that respects user privacy, runs entirely on-device, and delivers accuracy comparable to cloud solutions. Orttaai fills this gap.

> **CORE THESIS**
>
> Apple Silicon Macs now have enough on-device compute (Neural Engine + GPU) to run state-of-the-art speech recognition locally at near-cloud quality. By building natively in Swift with WhisperKit as a direct dependency, Orttaai achieves the performance ceiling of the hardware — no Electron overhead, no sidecar process, no IPC boundaries.

---

## 2. Target User Profile

### 2.1 Primary User

**Developers and knowledge workers** on macOS (Apple Silicon) who type extensively throughout the day. They value privacy, prefer lightweight tools, and are comfortable installing software via Homebrew.

| Attribute | Detail |
|---|---|
| Platform | macOS 14+ (Sonoma and later), Apple Silicon (M1/M2/M3/M4) |
| RAM | Minimum 8GB, recommended 16GB+ |
| Technical level | Intermediate to advanced. Comfortable with terminal, Homebrew, system permissions. |
| Current solution | Apple Dictation (frustrating, slow), manual typing (slow), or Wispr Flow (privacy/cost concerns) |
| Willingness to pay | Prefers free/open-source. Values transparency over polish. |
| Usage pattern | Short bursts (3–15 seconds) throughout the day, not long-form dictation sessions. |

### 2.2 Secondary User

Content creators, writers, and accessibility-focused users who need voice input but refuse to send their words through cloud servers.

### 2.3 macOS Version Requirement

macOS 14 (Sonoma) is the minimum deployment target. This is a hard requirement imposed by WhisperKit's Core ML dependencies and the @Observable macro used throughout the app. This is not our choice to make — WhisperKit itself requires macOS 14. Sonoma adoption among Apple Silicon users exceeds 85% as of early 2026, so the impact on our target audience is minimal.

---

## 3. Product Vision

### 3.1 One-Line Description

Orttaai is a native macOS voice keyboard that converts speech to text entirely on-device using Apple Silicon's Neural Engine, with zero cloud dependency.

### 3.2 Design Philosophy

Orttaai is a **system utility**, not an application. Like Spotlight or Alfred, it is invisible 95% of the time. Because it is built natively in Swift, this is literal — no browser engine, no JavaScript runtime. Just a ~10MB binary that sits in the menu bar and responds instantly.

> **DESIGN METAPHOR**
>
> Orttaai is a layer on top of macOS, not a window inside it. The aesthetic is warm neutral — charcoal tones, amber accents, restrained and typography-driven. Primary design reference: Cursor IDE.

### 3.3 Monetization

Free and open source. No accounts, no subscriptions, no telemetry, no ads. Revenue is indirect through the creator's YouTube channel and consulting practice.

### 3.4 Naming & Brand

**Orttaai** — derived from "utter" (to speak) + "AI." Domain: orttaai.com (confirmed available).

---

## 4. Core User Flows

### 4.1 Flow 1: First Launch & Setup

Goal: User completes setup (permissions granted, download initiated) in under 3 minutes. First dictation within 60 seconds of model download completing.

1. User installs via Homebrew: `brew install --cask orttaai`.
2. App launches. No splash screen. Directly shows the setup flow in a single native window.
3. **Step 1: Permissions.** App explains in plain language why Microphone, Accessibility, and Input Monitoring are needed. Each permission has a one-sentence explanation and a button that opens the relevant System Settings pane. Trust statement: "Your voice and text never leave your Mac. Orttaai connects to the internet only to download speech models and check for app updates — never to process your audio or text."
4. **Step 2: Model Download.** App auto-detects hardware and recommends the optimal model. Download begins automatically with progress bar. User can use other apps during download.
5. **Step 3: Ready.** "Orttaai is ready. Press [hotkey] anywhere to start dictating." Setup window closes. App remains in menu bar.
6. User presses hotkey in any app. Floating indicator appears. User speaks. Text appears at cursor.

> **PERMISSION DETECTION**
>
> Microphone: `AVCaptureDevice.authorizationStatus(for: .audio)`. Accessibility: `AXIsProcessTrusted()`. Input Monitoring: no direct API exists. Detection method: attempt `CGEvent.tapCreate()` — returns nil if not granted. After the user grants Input Monitoring in System Settings, macOS may require an app restart for the permission to take effect. If the tap still returns nil after the permission appears granted, show a "Restart Orttaai" button. This is a known macOS behavior, not a bug.

### 4.2 Flow 2: Standard Dictation (Primary Flow)

Goal: User speaks naturally and text appears at their cursor in any application.

7. User is typing in any application (Slack, VS Code, Chrome, Notes, etc.).
8. User presses and holds the global hotkey (default: Ctrl+Shift+Space).
9. Floating NSPanel fades in near the cursor position (150ms). Shows live audio waveform. Menu bar icon shifts to amber.
10. User speaks naturally. Waveform responds to audio amplitude in real-time.
11. User releases the hotkey.
12. Waveform freezes, transitions to processing shimmer. `WhisperKit.transcribe()` called on background actor. Before injection, the focused element's AX role is checked — if it is a secure text field (password input), injection is skipped and the indicator shows "Can't dictate into password fields."
13. Text is injected at cursor via clipboard paste with save/restore (NSPasteboard).
14. Floating indicator fades out (200ms). Menu bar icon returns to idle.
15. Transcription is logged in the local database.

> **TIMING BUDGET**
>
> 3-second utterance: ~1.0s processing. 10-second utterance: ~2.4s processing. 30-second utterance: ~8-10s processing. 45-second utterance (max): ~12-15s processing. Benchmarked on M4 Mac Mini 16GB with large-v3 turbo model.

### 4.3 Flow 3: Reviewing History

16. User clicks menu bar icon and selects "History."
17. Compact NSWindow (480×600pt) opens with SwiftUI List of recent transcriptions.
18. Each entry: timestamp, truncated text, target app name. Click to expand, copy button.
19. Close window. Focus returns to previous application.

### 4.4 Flow 4: Changing Settings

20. Menu bar icon > "Settings" or Cmd+,
21. Settings NSWindow with SwiftUI TabView: General, Audio, Model, About.
22. Changes save immediately via @AppStorage. No save button.

### 4.5 Flow 5: Model Management

23. Settings > Model tab. Current model with size and performance info.
24. Browse available models with tradeoff descriptions.
25. Background downloads via URLSession. Progress in settings.
26. Model switch: WhisperKit reloads on next dictation.

---

## 5. MVP Feature Specification

### 5.1 System-Wide Voice Keyboard

**Requirements**

- Global hotkey via `CGEvent.tapCreate()` with `.cghidEventTap` placement. Default: Ctrl+Shift+Space. User-configurable.
- Push-to-talk: hold hotkey to record, release to process and inject.
- Audio capture at 16kHz mono via AVAudioEngine with input node tap.
- Processing via WhisperKit as a direct Swift package dependency. No sidecar, no HTTP. Call `WhisperKit.transcribe(audioArray:)` on a background actor.
- Model: `openai_whisper-large-v3_turbo`. ~950MB download, ~1s for 3s audio on Apple Silicon.
- Text injection via NSPasteboard paste with save/restore. Sequence: check for secure text field → save pasteboard → set transcript → simulate Cmd+V via CGEvent → restore pasteboard after 250ms.
- Fallback: "Paste last transcript" hotkey (default: Cmd+Shift+V).
- Recording cap: 45 seconds. Countdown at 35s. Auto-stop at 45s.
- Processing time estimate shown when recording exceeds 20 seconds.

**Acceptance Criteria**

- Text appears correctly in: Safari, Chrome, Firefox, Arc, VS Code, Cursor, Xcode, Terminal.app, iTerm2, Slack (native), Discord, Messages, Mail, Notes, TextEdit, Pages, Notion, Linear, Obsidian, Figma (comment fields), Bear, Craft, Google Docs (in Chrome), Gmail (in Chrome), ChatGPT input (in Chrome).
- Hotkey works when any application has focus, including full-screen apps.
- Clipboard contents (text, images, file references) preserved after injection.
- Hotkey does not fire when Settings/History window has focus.
- Dictation is blocked in password/secure text fields with a clear user-facing message.
- Text injection validated across 25+ apps in Phase 2, Week 3.

### 5.2 Floating Recording Indicator

A minimal NSPanel that appears near the cursor during recording and processing. Native AppKit — no hacks, no bridges.

**Implementation**

- **NSPanel** with styleMask [.nonactivatingPanel, .borderless, .hudWindow]. Level: .floating. collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary]. Never steals focus, works across all Spaces and full-screen apps.
- **Hosting**: NSHostingView containing a SwiftUI WaveformView. SwiftUI animations for waveform, native window behavior from AppKit.
- **Positioning**: Cursor position via `AXUIElementCopyAttributeValue` with `kAXPositionAttribute`. Fall back to `NSEvent.mouseLocation` if AX unavailable.
- **Waveform**: Driven by `AudioCaptureService.audioLevel` (@Published, throttled to 30fps). Rendered as a SwiftUI Path or Canvas view.
- **Processing shimmer**: `.animation(.easeInOut(duration: 1.5).repeatForever())` on a gradient mask.
- **Size**: 200×40pt. Corner radius 8pt. Background: NSVisualEffectView with .hudWindow material.
- **Fade in**: 150ms via NSAnimationContext. **Fade out**: 200ms.
- **Error display**: Amber/red tinted text, auto-dismisses after 2 seconds.
- **Countdown**: Seconds remaining when recording exceeds 35s.
- **Processing estimate**: "~8s to process" when recording exceeds 20s.

### 5.3 Hardware-Aware Auto-Setup

| Hardware | Recommended Model | Download Size | Expected Latency (5s) |
|---|---|---|---|
| M1/M2, 8GB RAM | large-v3_turbo (quantized if available) | ~500MB | ~2.0s |
| M1/M2, 16GB RAM | large-v3_turbo | ~950MB | ~1.5s |
| M3/M4, 16GB+ RAM | large-v3_turbo | ~950MB | ~1.0s |
| Intel Mac (unsupported) | N/A — incompatibility message | — | — |

> **IMPORTANT**
>
> Intel Macs are explicitly unsupported. WhisperKit requires Core ML and the Neural Engine. Show: "Orttaai requires an Apple Silicon Mac (M1 or later)." No degraded experience.

### 5.4 Model Download with Progress

- Download via URLSession with background configuration. Native resume-after-interrupt.
- Progress via URLSessionDownloadDelegate. UI: percentage, current/total size, speed (MB/s), ETA.
- Menu bar icon shows progress ring during download.
- SHA256 verification via CommonCrypto CC_SHA256 after download.
- Models stored in `~/Library/Application Support/Orttaai/Models/`.
- macOS notification (UNUserNotificationCenter) on background download completion.
- If Hugging Face unreachable: "Model download failed. Check your internet connection." with Retry button. Exponential backoff: 2s, 4s, 8s, then manual retry only.
- WhisperKit's built-in download API (`WhisperKit.download(variant:)`) may be used if it provides progress callbacks. Otherwise, implement direct URL download from the argmaxinc/whisperkit-coreml Hugging Face repository.

### 5.5 Transcript History

- Stores the last 500 transcriptions in SQLite via GRDB.swift. Table name: **transcription** (singular, matches GRDB convention of mapping to the Transcription struct).
- Each entry: id, text, targetAppName, targetAppBundleID, recordingDurationMs, processingDurationMs, modelId, audioDevice.
- SwiftUI List with lazy loading (native). No virtual scrolling library.
- Each row: relative timestamp (RelativeDateTimeFormatter), truncated text (2 lines), target app name.
- Click to expand. Full text with "Copy" button.
- Search: `.searchable` modifier, GRDB query with LIKE filter.
- Clear history: button in Settings with confirmationDialog.
- Auto-prune on insert: `DELETE FROM transcription WHERE id NOT IN (SELECT id FROM transcription ORDER BY createdAt DESC LIMIT 500)`. Runs in a GRDB write transaction. The createdAt index ensures this is fast.
- Silent logging for recordings < 0.5s (skippedTooShort flag in a separate log, not in the transcription table).

### 5.6 Polish Mode (Coming Soon — Architecture Built in v1.0)

Routes raw transcript through a local LLM for cleanup. **Visible but disabled in v1.0.**

**v1.0 Implementation**

- Toggle in menu bar dropdown: disabled, tooltip "Available in a future update."
- Settings shows Polish Mode with "Coming soon" label.
- Full architecture built: TextProcessor protocol, PassthroughProcessor active, pipeline slot reserved.

**Architecture Contract (Swift Protocol)**

```swift
protocol TextProcessor {
    func process(_ input: TextProcessorInput) async throws -> TextProcessorOutput
    func isAvailable() async -> Bool
}

struct TextProcessorInput {
    let rawTranscript: String
    let targetApp: String?
    let mode: ProcessingMode  // .raw, .clean, .formal, .casual
}

struct TextProcessorOutput {
    let text: String
    let changes: [String]?
}

// v1.0: PassthroughProcessor (returns raw transcript unchanged)
// v1.1: OllamaProcessor (HTTP to localhost:11434)
```

**State Model**

```swift
@Observable
final class PolishModeState {
    var enabled = false
    var available = false
    var provider: PolishProvider = .none  // .none, .ollama
    var model = ""
    var modes: [ProcessingMode] = [.clean, .formal, .casual]
}
```

### 5.7 Keyboard Shortcut Configuration

- Default: Ctrl+Shift+Space. User-configurable via KeyboardShortcuts package (sindresorhus/KeyboardShortcuts).
- Native shortcut recorder. Validates against reserved shortcuts (Cmd+C/V/Q). Warning on conflict.
- Secondary: "Paste last transcript" (default: Cmd+Shift+V). Also configurable.
- Persisted via UserDefaults (KeyboardShortcuts handles this).

### 5.8 Menu Bar Presence

NSStatusItem. `LSUIElement = true` (no Dock icon, no main menu bar).

**Status Item States**

| State | Icon Appearance | Behavior |
|---|---|---|
| Idle | Monochrome SF Symbol (waveform.circle), template image | Adapts to light/dark menu bar |
| Recording | Amber-tinted SF Symbol, subtle pulse via NSTimer | Active during hotkey hold |
| Processing | Amber shimmer on icon | During inference |
| Downloading | Progress ring around icon (Core Graphics) | During model download |
| Error | Small amber dot badge | Model load failure, inference error, permission issue |

**Menu Bar Dropdown (NSMenu)**

- **Status line**: "Ready" / "Recording..." / "Processing..." / "Downloading model (43%)..."
- **Polish Mode toggle**: Disabled in v1.0 with "Coming soon" subtitle.
- **History**: Opens History window.
- **Settings...**: Cmd+,
- **Check for Updates...**: Triggers Sparkle update check. **Disabled and hidden for Homebrew installs** — shows "Updates managed by Homebrew" as a non-clickable label instead.
- **Quit Orttaai**: Cmd+Q. Graceful shutdown: stop audio engine, save state, release WhisperKit model from memory.

### 5.9 Accessibility Permissions Onboarding

| Permission | Why It's Needed | What Orttaai Does NOT Do |
|---|---|---|
| Microphone | Captures your voice for on-device transcription. | Never records when hotkey is not held. Never sends audio to any server. |
| Accessibility | Simulates Cmd+V to paste text, and reads cursor position for the floating indicator. | Never reads screen content beyond cursor position. Never monitors other apps. Never takes screenshots. |
| Input Monitoring | Detects the global hotkey press in any application. | Never logs keystrokes. Never records what you type. Only the configured hotkey combination is monitored. |

Each permission requested one at a time. Button opens System Settings via `NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)`. After granting, UI updates via periodic polling.

> **TRUST STATEMENT**
>
> Displayed prominently during setup: "Your voice and text never leave your Mac. Orttaai connects to the internet only to download speech models and check for app updates — never to process your audio or text. There are no accounts, no analytics, no cloud services. This is a promise, and the code is open source so you can verify it."

> **INPUT MONITORING NOTE**
>
> After the user grants Input Monitoring, macOS may require the app to be restarted for the CGEvent tap to work. The setup flow handles this: after the user grants the permission, attempt to create the tap. If it returns nil, show "Permission granted. Orttaai needs to restart to activate the hotkey." with a "Restart Now" button that calls `NSApp.terminate(nil)` after setting a relaunch flag (login item or LaunchAgent). The app relaunches and retries the tap.

### 5.10 Microphone Selector

- Located in Settings > Audio tab.
- SwiftUI Picker showing available input devices via AVCaptureDevice.DiscoverySession.
- Default: system default input device.
- **Device selection is per-engine, not system-wide.** When the user selects a specific mic, we set it on AVAudioEngine's input node's AudioUnit via `AudioUnitSetProperty` with `kAudioOutputUnitProperty_CurrentDevice`. This does NOT change the system default mic — other apps (Zoom, FaceTime) are unaffected. The device must be set BEFORE calling `engine.prepare()` and `engine.start()`.
- Live audio level meter driven by AVAudioEngine tap. SwiftUI ProgressView or custom bar.
- Device name and sample rate displayed.
- If selected device disconnects, fall back to system default. Post macOS notification: "Microphone disconnected. Switched to [default device]."

---

## 6. Technical Architecture

### 6.1 System Overview

Orttaai is a single-process native macOS application. WhisperKit runs in-process as a Swift package dependency. All native APIs are called directly.

```
Orttaai.app (Single Process)
├── AppDelegate (NSApplicationDelegate)
│   ├── NSStatusItem (menu bar icon + dropdown)
│   ├── HotkeyService (CGEvent tap, push-to-talk)
│   └── Window management (setup, settings, history)
│
├── DictationCoordinator (@Observable, central state machine)
│   ├── AudioCaptureService (AVAudioEngine, 16kHz mono)
│   ├── TranscriptionService (WhisperKit in-process, actor)
│   ├── TextProcessor (protocol: Passthrough → Ollama)
│   └── TextInjectionService (NSPasteboard + CGEvent)
│
├── FloatingPanelController (NSPanel + NSHostingView)
│   └── WaveformView (SwiftUI, throttled 30fps)
│
├── ModelManager (download, verify, switch, warm-up)
├── DatabaseManager (GRDB.swift, SQLite)
├── HardwareDetector (sysctl, IOKit, ProcessInfo)
└── Sparkle (auto-update, disabled for Homebrew installs)
```

### 6.2 Technology Stack

| Layer | Technology | Justification |
|---|---|---|
| Language | Swift 5.9+ | Native macOS. Direct access to all Apple frameworks. |
| UI | SwiftUI + AppKit hybrid | SwiftUI for views. AppKit for NSStatusItem, NSPanel, NSMenu. |
| STT | WhisperKit (Swift Package) | In-process Core ML Whisper inference. Fastest on Apple Silicon. |
| Audio | AVAudioEngine | Low-latency capture, installTap, per-engine device selection. |
| Hotkey | CGEvent.tapCreate() | System-level event tap. Push-to-talk. |
| Text Injection | NSPasteboard + CGEvent | Clipboard paste with save/restore. Never steals focus. |
| Floating Panel | NSPanel (AppKit) | Non-activating, floating. Never steals focus. |
| Database | GRDB.swift | Type-safe SQLite. Observable for live UI updates. |
| Settings | @AppStorage / UserDefaults | Native persistence. |
| Icons | SF Symbols | Apple's built-in icon library. 5000+ symbols. |
| Auto-Update | Sparkle 2.x | Industry standard for non-App Store apps. |
| Shortcut UI | KeyboardShortcuts (sindresorhus) | Native recorder. Conflict detection. |
| Packages | Swift Package Manager | Built into Xcode. No CocoaPods/Carthage. |
| Build | Xcode 15+ | Native build, signing, notarization. |
| Min Deploy | macOS 14 (Sonoma) | Required by WhisperKit and @Observable. |

**SPM Dependencies**

| Package | Repository | Purpose |
|---|---|---|
| WhisperKit | argmaxinc/WhisperKit | Core ML Whisper inference |
| GRDB.swift | groue/GRDB.swift | SQLite wrapper |
| Sparkle | sparkle-project/Sparkle | Auto-update |
| KeyboardShortcuts | sindresorhus/KeyboardShortcuts | Shortcut recorder |

**Explicitly NOT Used**

- No Electron, web views, or JavaScript. No CocoaPods/Carthage. No Realm, Core Data, or SwiftData. No third-party UI libraries. No RxSwift or Combine for state (using @Observable).

### 6.3 WhisperKit Integration

```swift
import WhisperKit

actor TranscriptionService {
    private var whisperKit: WhisperKit?

    func loadModel(named modelName: String) async throws {
        let config = WhisperKitConfig(
            model: modelName,
            computeOptions: .init(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            )
        )
        whisperKit = try await WhisperKit(config)
    }

    func transcribe(audioSamples: [Float]) async throws -> String {
        guard let wk = whisperKit else {
            throw OrttaaiError.modelNotLoaded
        }
        let result = try await wk.transcribe(audioArray: audioSamples)
        return result.first?.text
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func unloadModel() {
        whisperKit = nil  // Release model memory
    }
}
```

- Model warm-up: after loading, transcribe 1 second of silence to prime the Core ML pipeline.
- Model switching: call `unloadModel()`, then `loadModel(named:)` with new model.
- Models stored in `~/Library/Application Support/Orttaai/Models/`.

### 6.4 Audio Capture Pipeline

Audio samples are accumulated on a private serial DispatchQueue (not @MainActor) to avoid creating hundreds of Tasks during long recordings. The audioLevel property for the waveform is updated on @MainActor at a throttled rate of 30fps.

```swift
@Observable
final class AudioCaptureService {
    private let engine = AVAudioEngine()
    private let sampleQueue = DispatchQueue(label: "com.orttaai.samples")
    private var _samples: [Float] = []
    private var levelTimer: DispatchSourceTimer?
    private let _currentLevel = OSAllocatedUnfairLock(initialState: Float(0))

    // Published to SwiftUI at 30fps (not per audio buffer)
    private(set) var audioLevel: Float = 0

    func startCapture(deviceID: AudioDeviceID? = nil) throws {
        // Set device on the engine's input AudioUnit (per-engine, NOT system-wide)
        if let deviceID {
            let inputNode = engine.inputNode
            let audioUnit = inputNode.audioUnit!
            var id = deviceID
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        let inputNode = engine.inputNode
        // Install tap at 16kHz mono — AVAudioEngine handles conversion from native format
        let tapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        inputNode.installTap(onBus: 0, bufferSize: 1024,
                             format: tapFormat) { [weak self] buffer, _ in
            guard let self,
                  let data = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            let chunk = Array(UnsafeBufferPointer(start: data, count: count))

            // Accumulate on private queue (no MainActor hop per buffer)
            self.sampleQueue.async {
                self._samples.append(contentsOf: chunk)
            }

            // Update peak level for waveform (read by 30fps timer)
            let peak = chunk.map { abs($0) }.max() ?? 0
            self._currentLevel.withLock { $0 = peak }
        }

        // Throttle audioLevel updates to 30fps on MainActor
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.audioLevel = self._currentLevel.withLock { $0 }
        }
        timer.resume()
        levelTimer = timer

        engine.prepare()
        try engine.start()
    }

    func stopCapture() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        levelTimer?.cancel()
        levelTimer = nil

        // Synchronously grab samples from private queue
        var captured: [Float] = []
        sampleQueue.sync { captured = self._samples; self._samples = [] }
        audioLevel = 0
        _currentLevel.withLock { $0 = 0 }
        return captured
    }
}
```

> **THREAD SAFETY**
>
> The `sampleQueue.sync` in `stopCapture()` is safe because recording and stop are sequential operations enforced by the DictationCoordinator state machine. The private queue is never contended between the audio tap (async writes) and stopCapture (sync read) — stopCapture is only called after the tap is removed, so no new writes are in flight.
>
> The `_currentLevel` property uses `OSAllocatedUnfairLock` to protect the Float value shared between the audio tap callback thread and the main-thread timer. This eliminates Thread Sanitizer warnings without measurable overhead (unfair locks are ~25ns on Apple Silicon).

### 6.5 Text Injection Pipeline

**Secure Text Field Detection**

Before any clipboard manipulation, check if the focused element is a password field. This prevents dictating into password inputs and avoids reading sensitive clipboard content.

```swift
private func isFocusedElementSecure() -> Bool {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
    let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
    var focusedElement: AnyObject?
    let result = AXUIElementCopyAttributeValue(
        appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
    guard result == .success, let element = focusedElement else {
        return false  // Fail OPEN: if we can't determine, allow injection
    }
    var role: AnyObject?
    AXUIElementCopyAttributeValue(
        element as! AXUIElement, kAXRoleAttribute as CFString, &role)
    return (role as? String) == kAXSecureTextFieldRole
}
```

If `isFocusedElementSecure()` returns true, the entire injection pipeline is skipped — no clipboard save, no clipboard modify, no paste simulation. The floating indicator shows "Can't dictate into password fields" for 2 seconds, and the transcript is **not** stored in `lastTranscript` (to prevent leaking sensitive dictation via the manual paste shortcut).

> **FAIL-OPEN DESIGN**
>
> If the AX query fails (app doesn't support AX, permission revoked, element not queryable), we return false and proceed with injection. This is the correct behavior: we can't let an AX failure block the core feature. The secure field check is an additional safety layer, not a gate.

> **SECURITY NOTE — FAIL-OPEN SCOPE**
>
> The fail-open design means that in rare cases where AX is unavailable but the focused field is actually a secure field, injection will proceed. This is an accepted tradeoff: AX unavailability is uncommon (it requires the Accessibility permission to be revoked after setup, or the app to use a non-standard text input that doesn't expose AX roles). The alternative — fail-closed — would break dictation in any app where AX doesn't work, which is a worse outcome for the 99% case.

**Clipboard Save/Restore Implementation**

```swift
final class ClipboardManager {
    struct SavedItem {
        let types: [NSPasteboard.PasteboardType]
        let dataByType: [NSPasteboard.PasteboardType: Data]
    }

    func save() -> [SavedItem] {
        let pb = NSPasteboard.general
        guard let items = pb.pasteboardItems else { return [] }
        return items.compactMap { item in
            let types = item.types
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in types {
                // Skip promised file types (cannot round-trip)
                if type.rawValue.contains("promise") { continue }
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
                // Note: lazy data providers will return nil here.
                // This is an accepted limitation — we save what's available.
            }
            guard !dataByType.isEmpty else { return nil }
            return SavedItem(types: types, dataByType: dataByType)
        }
    }

    func restore(_ savedItems: [SavedItem]) {
        guard !savedItems.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let newItems: [NSPasteboardItem] = savedItems.map { saved in
            let item = NSPasteboardItem()
            for (type, data) in saved.dataByType {
                item.setData(data, forType: type)
            }
            return item
        }
        pb.writeObjects(newItems)
    }
}
```

**Known Limitations of Clipboard Save/Restore**

- **Lazy data providers**: Some pasteboard items use NSPasteboardItemDataProvider for on-demand data generation. The save operation captures only data available at save time. Lazy providers will return nil and their data is lost. This matches Wispr Flow's behavior.
- **File promises (NSFilePromiseReceiver)**: Skipped during save. If the user has a file promise on the clipboard (rare, typically from drag-and-drop), it will be lost. Silent loss is acceptable for this edge case.
- **Finder file copies**: When a user copies files in Finder, the pasteboard contains `NSPasteboard.PasteboardType.fileURL` items. These ARE preserved by our save/restore because they are concrete URLs, not promises.

**Complete Injection Flow**

```swift
final class TextInjectionService {
    private let clipboard = ClipboardManager()
    private(set) var lastTranscript: String?

    func inject(text: String) async -> InjectionResult {
        // 1. Check for secure text field
        if isFocusedElementSecure() {
            // Do NOT store transcript — prevents leaking sensitive dictation
            return .blockedSecureField
        }

        // 2. Store for manual paste fallback (only after secure field check passes)
        lastTranscript = text

        // 3. Save current pasteboard
        let saved = clipboard.save()

        // 4. Set transcript on pasteboard
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // 5. Simulate Cmd+V
        simulatePaste()

        // 6. Restore after delay
        try? await Task.sleep(for: .milliseconds(250))
        clipboard.restore(saved)

        return .success
    }

    private func simulatePaste() {
        let src = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 0x09
        let down = CGEvent(keyboardEventSource: src,
                    virtualKey: vKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: src,
                    virtualKey: vKeyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        // Brief pause for Electron-based apps that process key events slowly
        usleep(10_000)  // 10ms
        up?.post(tap: .cghidEventTap)
    }
}

enum InjectionResult {
    case success
    case blockedSecureField
}
```

> **PASTE TIMING**
>
> The 250ms clipboard restore delay is a tuned constant (`kClipboardRestoreDelay`). Most apps process Cmd+V within 50ms, but slower Electron-based apps (Discord, Slack web views) may need up to 200ms. The 250ms value provides safety margin. If beta testing reveals apps that need more, this constant is the single place to adjust. The 10ms pause between key-down and key-up in `simulatePaste()` prevents event coalescing in apps with slow event loops.

### 6.6 Global Hotkey Service

```swift
final class HotkeyService {
    private var eventTap: CFMachPort?
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    /// Returns true if tap created successfully, false if permission denied.
    @discardableResult
    func start(keyCode: CGKeyCode, modifiers: CGEventFlags) -> Bool {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                    | (1 << CGEventType.keyUp.rawValue)
                    | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false  // Input Monitoring not granted
        }

        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }
}
```

The `start()` method returns a Bool indicating whether the tap was created. This serves as the Input Monitoring permission check — no separate API exists. If it returns false during setup, the UI guides the user to System Settings and shows a "Restart Orttaai" button after they grant the permission.

### 6.7 DictationCoordinator (Central State Machine)

```swift
@Observable
final class DictationCoordinator {
    enum State: Equatable {
        case idle
        case recording(startTime: Date)
        case processing(estimatedDuration: TimeInterval?)
        case injecting
        case error(message: String)
    }

    private(set) var state: State = .idle
    private let audioService: AudioCaptureService
    private let transcriptionService: TranscriptionService
    private let textProcessor: TextProcessor
    private let injectionService: TextInjectionService
    private let database: DatabaseManager
    private let maxDuration: TimeInterval = 45
    private var capTimer: Task<Void, Never>?

    func startRecording() {
        guard state == .idle else {
            Logger.dictation.debug("startRecording called in state \(state), ignoring")
            return
        }
        do {
            try audioService.startCapture()
            state = .recording(startTime: Date())
            startCapTimer()
        } catch {
            state = .error(message: "Microphone access needed")
            autoDismissError()
        }
    }

    func stopRecording() {
        guard case .recording(let start) = state else { return }
        capTimer?.cancel()
        let samples = audioService.stopCapture()
        let duration = Date().timeIntervalSince(start)

        guard duration >= 0.5 else {
            state = .idle
            database.logSkippedRecording(duration: duration)
            return
        }

        let estimate = estimateProcessingTime(duration)
        state = .processing(estimatedDuration: duration > 20 ? estimate : nil)

        Task {
            do {
                let appName = NSWorkspace.shared.frontmostApplication
                    ?.localizedName ?? "Unknown App"
                let processingStart = CFAbsoluteTimeGetCurrent()
                let transcript = try await transcriptionService
                    .transcribe(audioSamples: samples)
                let processingMs = Int(
                    (CFAbsoluteTimeGetCurrent() - processingStart) * 1000
                )
                let processed = try await textProcessor.process(
                    .init(rawTranscript: transcript,
                          targetApp: appName, mode: .raw))

                state = .injecting
                let result = await injectionService.inject(text: processed.text)

                switch result {
                case .success:
                    database.saveTranscription(
                        text: processed.text, appName: appName,
                        recordingMs: Int(duration * 1000),
                        processingMs: processingMs)
                case .blockedSecureField:
                    state = .error(message: "Can\u{2019}t dictate into password fields")
                    autoDismissError()
                    return
                }
                state = .idle
            } catch {
                state = .error(message: "Couldn\u{2019}t transcribe. Try again.")
                autoDismissError()
            }
        }
    }
}
```

### 6.8 Database Schema (GRDB.swift)

```swift
struct Transcription: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "transcription"  // singular, GRDB convention
    var id: Int64?
    var createdAt: Date
    var text: String
    var targetAppName: String?
    var targetAppBundleID: String?
    var recordingDurationMs: Int
    var processingDurationMs: Int
    var modelId: String
    var audioDevice: String?
}

// Migration
migrator.registerMigration("v1") { db in
    try db.create(table: "transcription") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("createdAt", .datetime).notNull()
            .defaults(sql: "CURRENT_TIMESTAMP")
        t.column("text", .text).notNull()
        t.column("targetAppName", .text)
        t.column("targetAppBundleID", .text)
        t.column("recordingDurationMs", .integer).notNull()
        t.column("processingDurationMs", .integer).notNull()
        t.column("modelId", .text).notNull()
        t.column("audioDevice", .text)
    }
    try db.create(index: "idx_transcription_createdAt",
                  on: "transcription", columns: ["createdAt"])
}
```

Auto-prune query (runs in write transaction on each insert):

```sql
DELETE FROM transcription
WHERE id NOT IN (
    SELECT id FROM transcription ORDER BY createdAt DESC LIMIT 500
)
```

Database file: `~/Library/Application Support/Orttaai/orttaai.db`. GRDB's `DatabaseRegionObservation` enables live-updating the history UI when new transcriptions are added.

---

## 7. Native APIs Deep Dive

Every native macOS API Orttaai uses, with exact framework, class/function, and purpose.

| API | Framework | Purpose |
|---|---|---|
| NSStatusItem / NSStatusBar | AppKit | Menu bar icon and dropdown |
| NSMenu / NSMenuItem | AppKit | Menu bar dropdown content |
| NSPanel | AppKit | Floating indicator (non-activating, borderless, HUD) |
| NSHostingView | SwiftUI | Embed SwiftUI views in NSPanel |
| NSVisualEffectView | AppKit | Native blur material for floating panel |
| NSWindow | AppKit | Settings and History windows |
| NSWorkspace | AppKit | Frontmost app, open System Settings URLs |
| NSPasteboard | AppKit | Clipboard read/write for text injection |
| NSAnimationContext | AppKit | Panel fade in/out |
| CGEvent.tapCreate() | CoreGraphics | Global hotkey capture + Input Monitoring detection |
| CGEvent(keyboardEventSource:) | CoreGraphics | Simulate Cmd+V paste |
| AVAudioEngine | AVFoundation | Audio capture with installTap() |
| AVCaptureDevice | AVFoundation | Microphone enumeration and authorization |
| AudioUnitSetProperty | AudioToolbox | Per-engine input device selection |
| WhisperKit | WhisperKit (SPM) | Core ML Whisper inference |
| URLSession (background) | Foundation | Model download with resume |
| UNUserNotificationCenter | UserNotifications | Download complete notification |
| ProcessInfo.physicalMemory | Foundation | RAM detection |
| sysctlbyname() | Darwin/POSIX | CPU brand, chip architecture |
| IOKit (IOServiceMatching) | IOKit | GPU core count |
| AXIsProcessTrusted() | ApplicationServices | Accessibility permission check |
| AXUIElementCopyAttributeValue | ApplicationServices | Cursor position + secure field detection |
| CC_SHA256 | CommonCrypto | Model file integrity |
| RelativeDateTimeFormatter | Foundation | Timestamps in history |
| Color(hex:) extension | Custom (Extensions.swift) | Hex string to SwiftUI Color. Not built into SwiftUI; must be implemented. |
| OSAllocatedUnfairLock | os | Thread-safe audio level sharing between callback and timer |

---

## 8. Design System

### 8.1 Color Palette

Dark mode only for v1.0. Colors defined as extensions on both Color (SwiftUI) and NSColor (AppKit).

| Token | Hex | Usage |
|---|---|---|
| bg.primary | #1C1C1E | Window backgrounds, menu dropdown |
| bg.secondary | #2C2C2E | Input fields, elevated surfaces |
| bg.tertiary | #3A3A3C | Hover states, highlights |
| text.primary | #F5F3F0 | Headings, primary content |
| text.secondary | #A1A1A6 | Descriptions, timestamps |
| text.tertiary | #636366 | Placeholders, disabled text |
| accent | #D4952A | Amber. Active states, recording indicator |
| accent.subtle | #D4952A20 | Amber at 12% opacity |
| border | #38383A | Borders, dividers |
| success | #34C759 | Permission granted, model ready |
| warning | #FF9F0A | Recording cap, model size warning |
| error | #FF453A | Failure, permission denied |

**Swift Implementation**

```swift
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

extension Color {
    enum Orttaai {
        static let bgPrimary = Color(hex: "1C1C1E")
        static let bgSecondary = Color(hex: "2C2C2E")
        static let bgTertiary = Color(hex: "3A3A3C")
        static let textPrimary = Color(hex: "F5F3F0")
        static let textSecondary = Color(hex: "A1A1A6")
        static let textTertiary = Color(hex: "636366")
        static let accent = Color(hex: "D4952A")
        static let accentSubtle = Color(hex: "D4952A").opacity(0.12)
        static let border = Color(hex: "38383A")
        static let success = Color(hex: "34C759")
        static let warning = Color(hex: "FF9F0A")
        static let error = Color(hex: "FF453A")
    }
}
```

### 8.2 Typography

System font (.system) resolves to SF Pro on macOS. Respects accessibility settings.

| Element | SwiftUI Modifier | Weight |
|---|---|---|
| Window Title | .font(.system(size: 18, weight: .semibold)) | Semibold |
| Section Header | .font(.system(size: 14, weight: .semibold)) | Semibold |
| Body | .font(.system(size: 13)) | Regular |
| Secondary | .font(.system(size: 12)) | Regular |
| Caption | .font(.system(size: 11)) | Regular |
| Monospace | .font(.system(size: 12, design: .monospaced)) | Regular |

### 8.3 Spacing & Components

```swift
enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}
```

- **OrttaaiButton**: Primary (amber bg), Secondary (bordered), Ghost. Custom ButtonStyle, onHover, @FocusState focus ring.
- **OrttaaiTextField**: Styled TextField. Dark bg, subtle border, amber focus ring.
- **OrttaaiToggle**: Custom ToggleStyle. Amber active, gray inactive. 150ms animation.
- **OrttaaiProgressBar**: Custom ProgressViewStyle. Amber fill.
- **AudioLevelMeter**: GeometryReader + Rectangle with animated width driven by audioLevel.
- **ShortcutRecorderView**: Wrapper around KeyboardShortcuts.Recorder, styled to match.

---

## 9. Interaction Design

### 9.1 State Machine

```
IDLE ── hotkey keyDown ─► RECORDING(startTime)

RECORDING(startTime)
├─ hotkey keyUp ──────────────► PROCESSING(estimate?)
├─ 45s cap reached ───────────► PROCESSING(estimate?)
└─ error (no mic, permission) ─► ERROR(message)

PROCESSING(estimate?)
├─ transcript received ───────► INJECTING
└─ error (inference failure) ──► ERROR(message)

INJECTING
├─ success ───────────────────► IDLE
└─ blockedSecureField ────────► ERROR("Can't dictate into password fields")

ERROR(message) ── 2s auto-dismiss ─► IDLE
```

### 9.2 Animations

| Animation | Duration | API |
|---|---|---|
| Panel fade in | 150ms | NSAnimationContext.runAnimationGroup |
| Panel fade out | 200ms | NSAnimationContext.runAnimationGroup |
| Waveform | 33ms (30fps) | DispatchSourceTimer on main + SwiftUI Canvas |
| Processing shimmer | 1500ms loop | .animation(.easeInOut(duration: 1.5).repeatForever()) |
| Menu bar pulse | 2000ms loop | NSTimer + NSImage redraw |
| Toggle switch | 150ms | .animation(.easeOut(duration: 0.15)) |

### 9.3 Keyboard Shortcuts

| Shortcut | Action | Configurable |
|---|---|---|
| Ctrl+Shift+Space | Push-to-talk | Yes |
| Cmd+Shift+V | Paste last transcript | Yes |
| Cmd+, | Open Settings | No |
| Cmd+W | Close window | No |
| Cmd+Q | Quit | No |

---

## 10. Error Handling

| Error Condition | User Sees | Recovery |
|---|---|---|
| Microphone denied | Panel: "Microphone access needed" | Opens System Settings > Microphone |
| Accessibility denied | Setup: highlighted step + "Grant Access" | Opens System Settings > Accessibility |
| Input Monitoring denied | Setup: "Grant access, then restart Orttaai" | Opens System Settings + Restart button |
| Model not downloaded | Settings: "No model installed. Download now?" | Download button |
| Model load failure (corrupted) | Panel: "Engine error. Re-download model in Settings." | Settings > Model > Re-download |
| Inference failure | Panel: "Couldn't transcribe. Try again." (2s) | Next hotkey retries |
| Out of memory during inference | Panel: "Not enough memory. Close apps or use smaller model." | Settings > Model to switch |
| Insufficient disk space | Settings: "Need X GB free." | Show free space, suggest smaller model |
| Download failed (network) | Settings: "Download failed. Check internet." + Retry | Exponential backoff, then manual |
| Paste failed | Panel: "Use Cmd+Shift+V to paste" (3s) | Manual paste shortcut |
| Secure text field (password) | Panel: "Can't dictate into password fields" (2s) | Transcript NOT saved to lastTranscript |
| Recording too short (<0.5s) | No visible error | Logged silently for debugging |
| Intel Mac detected | Setup: "Requires Apple Silicon (M1+)." | Link to requirements |
| No audio input | Panel: "No microphone detected" | Check connections |
| Input Monitoring granted but tap fails | Setup: "Restart Orttaai to activate hotkey" | "Restart Now" button |

---

## 11. Performance Requirements

Performance targets use three tiers: **Target** (what we aim for), **Acceptable** (ships without blocking), and **Fail** (must fix before release).

| Metric | Target | Acceptable | Fail |
|---|---|---|---|
| Cold start (launch to menu bar ready) | < 1.5s | < 2.5s | > 4s |
| Model load (warm-up) | < 4s | < 6s | > 10s |
| Transcription (3s audio) | < 1.0s | < 1.5s | > 2.5s |
| Transcription (10s audio) | < 2.5s | < 3.5s | > 5s |
| Transcription (30s audio) | < 10s | < 14s | > 20s |
| Idle RAM (no model loaded) | < 12MB | < 25MB | > 40MB |
| RAM (model loaded, idle) | < 1.0GB | < 1.3GB | > 1.8GB |
| RAM (during inference) | < 1.5GB | < 1.8GB | > 2.5GB |
| Idle CPU (model loaded, no activity) | 0% | < 0.1% | > 0.5% |
| Waveform rendering | 60fps | 30fps | < 20fps |
| UI interaction (click to response) | < 30ms | < 60ms | > 100ms |
| App binary (excl. WhisperKit framework) | < 10MB | < 15MB | > 25MB |

> **NATIVE ADVANTAGE**
>
> Idle RAM drops from 80MB (Electron) to ~12MB (native Swift). CPU drops from <1% to 0% (no JS event loop). Cold start from 3s to ~1.5s (no Chromium). These are not aspirational — they're measured baselines for SwiftUI menu bar apps with similar complexity.

---

## 12. Security & Privacy

### 12.1 Data Flow

- **Audio**: Captured in memory via AVAudioEngine, passed to WhisperKit in-process, discarded after transcription. Never written to disk. Never transmitted.
- **Text**: Transcribed text stored in local SQLite. Never transmitted.
- **Network**: Model downloads from Hugging Face (HTTPS) and Sparkle update checks (HTTPS) only. No other network activity.
- **No analytics, telemetry, crash reporting, or usage tracking.**
- **No accounts, sign-in, or cloud sync.**
- **Secure fields**: Dictation is blocked in detected password/secure text fields. The app never reads the content of secure fields. When a secure field is detected, the transcript is not stored in `lastTranscript` either.

### 12.2 App Sandbox & Hardened Runtime

Orttaai runs **outside the App Sandbox**. Required because `CGEvent.tapCreate()` needs system-level event access, `AXUIElement` requires trust (`AXIsProcessTrusted`), and `NSPasteboard` system-wide access is restricted in sandboxed apps.

Since we distribute via Homebrew (not Mac App Store), sandboxing is not required. Hardened Runtime is enabled with these entitlements:

- **com.apple.security.device.audio-input**: Microphone access.
- **com.apple.security.automation.apple-events**: Apple Events (future Shortcuts integration).
- No JIT, no unsigned library loading, no protected file access.

### 12.3 Sparkle Security

- Sparkle 2.x uses EdDSA signing for update verification. Keys generated via Sparkle's `generate_keys` tool.
- Appcast served over HTTPS only (GitHub Pages or raw GitHub).
- Sparkle's built-in code signature verification is enabled — updates must match the app's code signing identity.
- Since the app is not sandboxed, these measures are critical to prevent supply chain attacks via malicious updates.

### 12.4 File System

- `~/Library/Application Support/Orttaai/` — app data root.
- `~/Library/Application Support/Orttaai/Models/` — downloaded models.
- `~/Library/Application Support/Orttaai/orttaai.db` — SQLite database.
- `UserDefaults` (`~/Library/Preferences/com.orttaai.app.plist`) — settings.

---

## 13. Distribution & Updates

### 13.1 Distribution

- **Primary**: Homebrew cask. `brew install --cask orttaai`.
- **Secondary**: Direct .dmg from orttaai.com.
- **Source**: GitHub. Build via swift build or Xcode.
- Code-signed (Developer ID Application) + notarized via notarytool.

### 13.2 Code Signing & Notarization

27. Apple Developer Program ($99/yr).
28. Developer ID Application certificate.
29. Xcode: `CODE_SIGN_IDENTITY` = "Developer ID Application", Hardened Runtime enabled.
30. Archive via Product > Archive. Export as Developer ID. Xcode handles notarization.
31. Staple: `xcrun stapler staple Orttaai.app`
32. Package into .dmg via `create-dmg` or `hdiutil`.

### 13.3 Auto-Update Policy

Sparkle and Homebrew are separate update channels. To prevent version drift:

- **Direct .dmg installs**: Sparkle is active. Checks on launch and every 6 hours. Shows native update dialog.
- **Homebrew installs**: Sparkle auto-check is **disabled**. Detected by checking for a `.homebrew-installed` marker file in the app bundle's `Resources/` directory. The Homebrew cask formula's `postflight` block writes this file during installation. Settings > About shows "Updates managed by Homebrew. Run `brew upgrade orttaai`." The "Check for Updates..." menu item is **replaced with a disabled "Updates managed by Homebrew" label** — no manual Sparkle check is possible for Homebrew installs.
- The Homebrew cask formula is updated on each GitHub Release. Homebrew users get updates via `brew upgrade`.
- This separation prevents the scenario where Sparkle updates to v1.2 but `brew upgrade` rolls back to v1.1.

> **HOMEBREW DETECTION**
>
> Previous versions checked the app bundle path for "/Homebrew/" or "/homebrew/", but Homebrew casks install to `/Applications/` — the bundle path does not contain the Homebrew prefix. The marker file approach is reliable: the cask formula writes `.homebrew-installed` to `Contents/Resources/` during `postflight`, and the app checks for its existence at launch with `Bundle.main.url(forResource: ".homebrew-installed", withExtension: nil) != nil`. This is a single line in the cask formula and a single `FileManager` check in the app.

**Homebrew Cask Formula (postflight block)**

```ruby
cask "orttaai" do
  # ... version, sha256, url, etc.

  postflight do
    marker = "#{appdir}/Orttaai.app/Contents/Resources/.homebrew-installed"
    File.write(marker, "installed via homebrew\n")
  end

  # ... other cask directives
end
```

**Swift Detection**

```swift
var isHomebrewInstall: Bool {
    Bundle.main.url(forResource: ".homebrew-installed", withExtension: nil) != nil
}
```

### 13.4 WhisperKit Version Management

- Pinned in Package.swift: `.upToNextMinor(from: "0.9.0")` (example).
- GitHub Action checks weekly for new WhisperKit releases, opens a PR to bump.
- Each Orttaai release documents the bundled WhisperKit version in release notes.

---

## 14. Project Structure

```
Orttaai/
  Orttaai/
    App/
      OrttaaiApp.swift          # @main, WindowGroup (hidden)
      AppDelegate.swift        # NSApplicationDelegate, menu bar
      AppState.swift           # @Observable root state
    Core/
      Audio/
        AudioCaptureService.swift    # AVAudioEngine, private sample queue
        AudioDeviceManager.swift     # CoreAudio device enumeration
      Transcription/
        TranscriptionService.swift   # WhisperKit actor wrapper
        TextProcessor.swift          # Protocol + PassthroughProcessor
      Injection/
        TextInjectionService.swift   # Secure field check + paste pipeline
        ClipboardManager.swift       # Full save/restore implementation
      Hotkey/
        HotkeyService.swift          # CGEvent tap, returns Bool for permission
      Hardware/
        HardwareDetector.swift
      Model/
        ModelManager.swift
        ModelDownloader.swift
      Coordination/
        DictationCoordinator.swift   # State machine, orchestrates all services
    UI/
      MenuBar/
        StatusBarController.swift
        StatusBarMenu.swift
        MenuBarIconRenderer.swift
      FloatingPanel/
        FloatingPanelController.swift
        WaveformView.swift
        ProcessingIndicatorView.swift
      Windows/
        WindowManager.swift
      Setup/
        SetupView.swift
        PermissionStepView.swift
        DownloadStepView.swift
        ReadyStepView.swift
      Settings/
        SettingsView.swift
        GeneralSettingsView.swift
        AudioSettingsView.swift
        ModelSettingsView.swift
        AboutView.swift
      History/
        HistoryView.swift
        HistoryEntryView.swift
      Components/
        OrttaaiButton.swift
        OrttaaiTextField.swift
        OrttaaiToggle.swift
        OrttaaiProgressBar.swift
        AudioLevelMeter.swift
    Data/
      DatabaseManager.swift
      TranscriptionRecord.swift      # "transcription" table (singular)
      AppSettings.swift
    Design/
      Colors.swift                   # Color(hex:) + Color.Orttaai
      Typography.swift
      Spacing.swift
    Utilities/
      Extensions.swift
      Errors.swift                   # OrttaaiError enum
      Logger.swift                   # os.Logger categories
    Resources/
      Assets.xcassets
      Info.plist                     # LSUIElement=true
      Orttaai.entitlements
  OrttaaiTests/
    Core/
      AudioCaptureServiceTests.swift
      TextInjectionServiceTests.swift
      ClipboardManagerTests.swift
      HardwareDetectorTests.swift
      DatabaseManagerTests.swift
    Coordination/
      DictationCoordinatorTests.swift
  Package.swift
  Makefile
  README.md
  LICENSE
  CONTRIBUTING.md
  TESTING.md                         # Manual test matrix results
```

---

## 15. Development Phases

### Phase 1: Foundation (Week 1–2)

- Xcode project + SPM dependencies (WhisperKit, GRDB, Sparkle, KeyboardShortcuts).
- Info.plist: LSUIElement=true, privacy descriptions.
- Design system: Colors.swift (with Color(hex:) initializer), Typography, Spacing, all components.
- AppDelegate with NSStatusItem, basic NSMenu.
- WindowManager for setup, settings, history NSWindows.
- FloatingPanelController: NSPanel + NSHostingView, fade animations, positioning.
- HotkeyService: CGEvent tap, returns Bool for permission detection.
- AudioCaptureService: AVAudioEngine with private sample queue, 30fps throttled audioLevel, per-engine device selection.
- **ClipboardManager: full save/restore implementation including type iteration, file promise skipping, and round-trip testing.** This is foundational and must be validated in Phase 1.
- HardwareDetector: chip, RAM, GPU, disk.
- DatabaseManager: GRDB setup, migration (singular table name: transcription), CRUD, auto-prune.

### Phase 2: Core Pipeline (Week 3–4)

- TranscriptionService: WhisperKit init, model load, transcribe(), warm-up.
- ModelManager: Hugging Face download, progress, SHA256 verification, switching.
- TextInjectionService: secure field detection, clipboard save/paste/restore, CGEvent Cmd+V.
- DictationCoordinator: full state machine (idle → recording → processing → injecting → idle).
- WaveformView: SwiftUI Canvas driven by audioLevel.
- End-to-end: hotkey → speak → text appears in target app.
- **Text injection validation across 25+ apps in Week 3.** Highest-risk item — validate before UI investment.
- Processing time estimation. Countdown at 35s. Auto-stop at 45s.

### Phase 3: Features & UI (Week 5–6)

- Setup flow: permissions (with Input Monitoring restart handling), model download, ready.
- Settings: General, Audio (per-engine mic selector + level meter), Model, About.
- History: SwiftUI List, search, expand, copy, clear.
- Menu bar dropdown: status, Polish Mode (disabled), History, Settings, Updates, Quit.
- Sparkle integration with Homebrew detection (marker file approach, disable Sparkle and hide update menu item for Homebrew installs).
- Secure text field blocking in injection pipeline.
- Model warm-up on launch. Download notification.

### Phase 4: Polish & Ship (Week 7–9)

- All error states per error handling matrix.
- Performance profiling against three-tier targets. Optimize to Target tier.
- Code signing + notarization (budget extra time for first-time setup).
- DMG creation. Homebrew cask formula (with postflight marker file).
- App icon + menu bar icon states.
- README, LICENSE (MIT), CONTRIBUTING.md, TESTING.md.
- Manual test matrix execution: 25+ apps.
- Unit tests for all core services.
- Beta testing with 5–10 users. Iterate.
- GitHub repo + CI (GitHub Actions: build + test on push).

> **TIMELINE NOTE**
>
> Phase 4 is extended to 3 weeks (from 2 in v2.0). Code signing, notarization, DMG packaging, and Homebrew cask submission are time-consuming for first-time setup. Budget the extra week to avoid shipping under pressure.

---

## 16. Testing Strategy

### 16.1 Unit Tests (XCTest)

- **HardwareDetector**: Mock sysctl/IOKit, verify model recommendations per hardware tier.
- **DatabaseManager**: In-memory GRDB. Test insert, query, search, prune (500 cap), skipped recording log.
- **DictationCoordinator**: Mock all services. Test all state transitions, error paths, cap timer, <0.5s skip, secure field block.
- **TextProcessor**: PassthroughProcessor returns input unchanged. Protocol contract for OllamaProcessor.
- **ClipboardManager**: Test save/restore round-trip with text, images, file URLs. Test promise skipping. Test empty pasteboard.
- **ModelManager**: SHA256 verification. Download resume.
- **AppSettings**: @AppStorage read/write for all keys.

### 16.2 Manual Test Matrix (Text Injection)

Execute in Phase 2, Week 3. Each app tested with: short (3s), medium (10s), punctuation, and clipboard restore.

| Category | Apps |
|---|---|
| Browsers | Safari, Chrome, Firefox, Arc |
| Code Editors | VS Code, Cursor, Xcode, iTerm2, Terminal.app |
| Communication | Slack (native), Discord, Messages, Mail |
| Productivity | Notes, TextEdit, Pages, Notion, Linear, Obsidian, Bear, Craft |
| Web Apps (Chrome) | Google Docs, Gmail, Twitter/X, ChatGPT input, Figma comments |
| Edge Cases | Password fields (should block), Spotlight (should work), full-screen apps |

Results recorded in TESTING.md. Target: < 5% failure rate. Each test notes: pass/fail, delay/glitch, clipboard restore success.

### 16.3 QA Checklist (Per Release)

- Setup completes, permissions granted, model downloads, first dictation works.
- Cold start < 2.5s (Acceptable tier). Menu bar icon visible, hotkey responsive.
- Waveform responds. Countdown at 35s. Auto-stop at 45s.
- Processing estimate shown for recordings > 20s.
- History: entries appear, search works, copy works, clear works.
- Settings: all controls functional, changes persist after restart.
- Secure text field: dictation blocked with correct message. Transcript NOT stored in lastTranscript.
- Each error state triggered and verified.
- Sparkle update check works. Homebrew detection disables auto-check and hides menu item.
- Quit: clean shutdown, no orphan resources.

---

## 17. Post-MVP Roadmap

### v1.1: Polish Mode
- Ollama integration (detect, HTTP to localhost:11434). OllamaProcessor. Per-app tone.

### v1.2: Power User
- Personal dictionary. Voice commands. Multi-language. Audio file transcription.

### v2.0: Extended
- Long-form dictation (chunked > 45s). Meeting recording. Shortcuts.app integration. Desktop widget.

> **CROSS-PLATFORM**
>
> No Linux/Windows port planned. Native macOS is the product identity. If demand arises, a separate project (whisper.cpp + Tauri/GTK) would be appropriate.

---

## 18. Anti-Goals

- **No cloud processing.** Audio never leaves the device. No "cloud mode," no API keys.
- **No user accounts.** No sign-in, no profiles, no sync.
- **No telemetry.** No analytics, no crash reporting. Feedback via GitHub Issues.
- **No streaming transcription.** Batch after user stops. More accurate.
- **No always-listening.** Mic only active when hotkey held.
- **No text editing.** Inject and get out of the way.
- **No browser extension.** System-wide Accessibility works in browsers.
- **No Intel Mac.** WhisperKit requires Core ML + Neural Engine.
- **No iOS.** Desktop-only for keyboard workflows.
- **No Mac App Store.** Sandbox conflicts with CGEvent tap and Accessibility API.
- **No Electron or web views.** Native Swift/SwiftUI only.
- **No dictation into detected password fields.** Security commitment. When the focused element's AX role can be determined, secure text fields are always blocked. When AX is unavailable (permission revoked, non-standard input), injection proceeds — the secure field check is a safety layer, not a gate. See Section 6.5 for the fail-open rationale.

---

## 19. Success Metrics

| Metric | Target | Measurement |
|---|---|---|
| Setup complete (permissions + download started) in < 3 min | 95% of test users | Manual testing, 10 beta users |
| First dictation within 60s of model download completing | 95% of test users | Manual testing, 10 beta users |
| Transcription accuracy (English) | > 95% word accuracy | Standardized test sentences |
| GitHub stars (first month) | > 500 | GitHub |
| Homebrew installs (first month) | > 200 | Homebrew analytics |
| Text injection failures | < 5% of apps tested | GitHub Issues tagged injection-failure |
| Idle RAM (no model) | < 25MB (Acceptable tier) | Activity Monitor |
| Cold start | < 2.5s (Acceptable tier) | Measurement |

---

## 20. Competitive Landscape

| Product | Price | Architecture | Weakness |
|---|---|---|---|
| Wispr Flow | $144/yr | Cloud, Electron-based | Privacy backlash, 800MB RAM |
| Superwhisper | $96/yr | Local (whisper.cpp), native | Slower, paid, closed source |
| macOS Dictation | Free | Cloud (Apple) | Requires internet, poor accuracy |
| VoiceInk | One-time | Local (whisper.cpp), native | Less polished, smaller community |
| **Orttaai** | **Free OSS** | **Native Swift, WhisperKit, zero cloud** | **Fastest local, ~12MB idle, open source** |

---

## 21. Decision Log

| Decision | Choice | Rationale |
|---|---|---|
| App name | Orttaai | "Utter" + "AI." Domain available. |
| Platform | macOS only, Apple Silicon | Neural Engine, native performance. |
| Architecture | Native Swift (no Electron) | ~12MB vs 80MB idle. 0% CPU. Direct API access. |
| UI | SwiftUI + AppKit hybrid | SwiftUI views, AppKit for system integration. |
| STT | WhisperKit (in-process) | No sidecar. Direct Core ML. |
| Model | large-v3_turbo | ~1s for 3s audio. No LLM cleanup needed. |
| Monetization | Free, MIT license | YouTube + consulting revenue. |
| Distribution | Homebrew cask + .dmg | No App Store (sandbox conflicts). |
| Updates (Homebrew) | Sparkle disabled, brew upgrade | Prevents version drift. |
| Updates (.dmg) | Sparkle 2.x with EdDSA | Industry standard, secure. |
| Text injection | NSPasteboard paste + save/restore | Wispr's battle-tested approach. |
| Secure fields | Block injection, show message, don't store transcript | Security: never paste into password fields, never retain sensitive dictation. |
| Floating panel | NSPanel (native) | Non-activating. No focus stealing. |
| Audio device | Per-engine AudioUnit property | No system-wide mic change. |
| Audio buffer | Private DispatchQueue, 30fps throttle | No Task-per-buffer overhead. |
| Audio level thread safety | OSAllocatedUnfairLock | TSan-clean, ~25ns overhead. |
| Audio tap format | 16kHz mono AVAudioFormat | AVAudioEngine handles conversion; no manual resampling. |
| Clipboard restore delay | 250ms | Safety margin for slow Electron apps. Tunable constant. |
| Paste key timing | 10ms between key-down/key-up | Prevents event coalescing in slow event loops. |
| Polish Mode | Visible but disabled in v1.0 | Architecture ready for v1.1. |
| Recording cap | 45 seconds | Covers 95%+ use cases. |
| Min macOS | 14 (Sonoma) | WhisperKit hard requirement. |
| Cross-platform | Not planned | Separate project if demand arises. |
| Testing | XCTest + manual 25-app matrix | Automated for services, manual for injection. |
| Timeline | 9 weeks (extended Phase 4) | Extra week for signing/notarization. |
| Homebrew detection | Marker file in Resources/ | Bundle path check is unreliable; cask postflight writes marker. |
| Homebrew update UX | Hide Sparkle menu item entirely | Prevents accidental version drift from manual checks. |
| lastTranscript on secure field | Not stored | Prevents leaking sensitive dictation via manual paste. |

---

## 22. Changelog (v2.0 → v2.1)

All changes from v2.0, with rationale. 16 fixes applied, 2 discovered during audit.

| # | Fix | Section(s) Affected | Rationale |
|---|---|---|---|
| 1 | Trust statement reworded | 4.1, 5.9 | Old: "never connects to internet." New: "audio/text never leave device; internet only for downloads + updates." Prevents HN backlash. |
| 2 | Audio device: per-engine, not system-wide | 5.10, 6.4 | AudioUnitSetProperty on engine AudioUnit instead of AudioObjectSetPropertyData on system default. Prevents changing Zoom's mic. |
| 3 | Table name standardized to singular | 5.5, 6.8, 14 | "transcription" everywhere. Matches GRDB convention. Fixes runtime crash. |
| 4 | Sidecar references removed | 5.8, 10 | Replaced "sidecar crash" with native error conditions: model load failure, inference error. |
| 5 | Secure text field detection | 4.2, 5.1, 6.5, 9.1, 10, 12, 18 | AX role check before injection. Blocks password fields. Fail-open design. |
| 6 | Audio buffer on private queue | 6.4 | DispatchQueue for samples, 30fps throttle for audioLevel. Eliminates ~700 Task allocations at 45s. |
| 7 | savePasteboard() fully implemented | 6.5 | Complete ClipboardManager with type iteration, promise skipping, and known limitations documented. Moved to Phase 1. |
| 8 | Success metric split | 4.1, 19 | "Under 3 min" → setup in 3 min + first dictation in 60s after download. Realistic on slow networks. |
| 9 | Performance three-tier bands | 11, 19, 21 | Target / Acceptable / Fail. Prevents false failures from SwiftUI baseline overhead. |
| 10 | macOS 14 documented as WhisperKit requirement | 2.3 | Not our choice. WhisperKit requires macOS 14. |
| 11 | Input Monitoring detection via CGEvent tap | 4.1, 5.9, 6.6 | CGEvent.tapCreate() returns nil if denied. Only reliable detection method. |
| 12 | Homebrew + Sparkle interaction policy | 13.3 | Disable Sparkle for Homebrew installs. Prevents version rollback on brew upgrade. |
| 13 | Color(hex:) initializer provided | 7, 8.1 | Not built into SwiftUI. Full implementation in Colors.swift. |
| 14 | frontmostAppName() nil fallback | 6.7 | ?? "Unknown App" via nil coalescing. |
| 15 | Model-loaded-idle RAM tier added | 11 | Discovered during fix 9 audit. New row: < 1.0GB target, < 1.3GB acceptable. |
| 16 | App restart after Input Monitoring grant | 4.1, 5.9, 10 | Discovered during fix 11 audit. macOS may require restart. "Restart Now" button in setup. |

---

## 23. Changelog (v2.1 → v2.2)

All changes from v2.1, with rationale. 8 fixes applied based on combined technical review and external audit.

| # | Fix | Section(s) Affected | Rationale |
|---|---|---|---|
| 17 | Homebrew detection changed to marker file | 13.3, 21 | Homebrew casks install to `/Applications/` — bundle path does not contain "/Homebrew/". Cask `postflight` now writes `.homebrew-installed` marker to `Contents/Resources/`. Reliable single-file check. |
| 18 | Anti-Goals secure field wording clarified | 18 | Old: "Secure text fields are always blocked." New: explicitly scoped to "detected" secure fields with fail-open rationale cross-referenced. Eliminates contradiction with Section 6.5 fail-open design. |
| 19 | `lastTranscript` not stored on secure field block | 6.5, 6.7, 10, 21 | Old: `lastTranscript = text` was set unconditionally before secure field check. Dictating sensitive content near a password field would retain it for manual paste. Now set only after secure field check passes. |
| 20 | Sparkle menu item hidden for Homebrew installs | 5.8, 13.3, 16.3 | Old: manual "Check for Updates..." still available for Homebrew users, enabling accidental version drift. Now replaced with disabled "Updates managed by Homebrew" label. No manual Sparkle trigger possible. |
| 21 | Audio level uses OSAllocatedUnfairLock | 6.4, 7, 21 | `_currentLevel` was written on audio callback thread and read on main thread. While ARM64 natural alignment prevents corruption, Thread Sanitizer flags it. `OSAllocatedUnfairLock` makes it TSan-clean with ~25ns overhead. |
| 22 | Audio tap format set to 16kHz mono | 6.4, 21 | Code installed tap at `nativeFormat` but WhisperKit expects 16kHz mono. Now passes explicit 16kHz mono `AVAudioFormat` to `installTap` — AVAudioEngine handles the conversion internally. Eliminates need for manual resampling. |
| 23 | `processingMs` measurement implemented | 6.7 | Was a `/* measured */` placeholder comment. Now uses `CFAbsoluteTimeGetCurrent()` before/after `transcriptionService.transcribe()` to capture actual processing duration. |
| 24 | Clipboard restore delay increased to 250ms | 5.1, 6.5, 21 | Old: 200ms. Slow Electron-based apps (Discord, Slack web) can need up to 200ms for paste processing. 250ms provides safety margin. Named as a tunable constant. 10ms pause added between key-down/key-up in `simulatePaste()` to prevent event coalescing. |

---

*End of Document*

Orttaai PRD v2.2 · Native macOS · February 2026 · Ready for Development
