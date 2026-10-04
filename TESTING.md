# Orttaai Testing Guide

## Unit Tests

Run via Xcode: `Cmd+U`  
Run via CLI (unit tests only):

```bash
xcodebuild test -scheme Orttaai -destination 'platform=macOS' -skip-testing:OrttaaiUITests
```

Drop `-skip-testing:OrttaaiUITests` to also run the UI test target (`OrttaaiUITests`, 1 sidebar navigation test), which launches the app.

### Test Coverage

`OrttaaiTests/` has 696 test methods in 52 test files (counted with `grep -c "func test"`; `ModelProbeTestSupport.swift` holds shared fakes only). The latest full run: 687 passed, 9 skipped, 0 failed.

| Area | Test files | Tests |
|------|-----------|-------|
| Dictation coordination (`DictationCoordinator`, hands-free auto-stop, hotkey tap/hold, finalize trace, secure-field discard) | 4 | 117 |
| Transcription and decoding (`TranscriptionService`, model loading, conditioning, decode accuracy, short audio, live transcript) | 6 | 104 |
| Text processing and personal memory (rule-based processor, disfluency cleanup, fuzzy dictionary, local LLM and Apple Intelligence polish) | 6 | 102 |
| Model management and hardware (`ModelManager`, variant resolver, directory/tokenizer/storage location, launch safety, quantized migration, quick start, `HardwareDetector`) | 9 | 90 |
| Text injection and voice editing (`TextInjectionService`, `ClipboardManager`, `KeyEventPoster`, selection capture, `EditCommandProcessor`) | 5 | 85 |
| Insights, analytics, and semantic memory (writing insights, dashboard stats, concept graph, insight patterns, semantic memory/signals/text analysis, work activity) | 8 | 84 |
| Data, settings, and app services (`DatabaseManager`, database bootstrap, `AppSettings`, `AppUpdateService`, bounded retry) | 5 | 52 |
| AI providers (Codex client, Grok client, LM Studio client, live Codex/Grok integration) | 5 | 51 |
| Audio capture (`AudioCaptureService`) | 1 | 7 |
| UI (floating panel shape) | 1 | 2 |
| Eval harnesses (ASR eval runner, text accuracy replay) | 2 | 2 |
| **Total** | **52** | **696** |

iCloud sync has no dedicated test file: its database snapshot, tombstone, and backup-retention paths are covered in `DatabaseManagerTests`, but `CloudSyncService` itself is untested.

### Skipped Tests

Some tests skip themselves unless their environment is available:

- **Live Codex/Grok integration** (`CodexIntegrationTests`, `GrokIntegrationTests`) — auto-skip when the CLI is missing, too old (Codex), or not signed in (Codex needs a ChatGPT account).
- **LM Studio live round trip** (`LMStudioClientTests`) — skips when no LM Studio server is reachable at the default endpoint.
- **Audio capture** (`AudioCaptureServiceTests`) — opt-in: set `RUN_AUDIO_TESTS=1` and grant microphone access. Set `ORTTAAI_AUDIO_DEVICE_ID` to test a specific microphone.
- **Eval harnesses** — set `ORTTAAI_ASR_EVAL=1` with `ORTTAAI_ASR_EVAL_MANIFEST` and `ORTTAAI_ASR_EVAL_OUT`, or `ORTTAAI_TEXT_REPLAY_INPUT` and `ORTTAAI_TEXT_REPLAY_OUT_DIR`.

## Manual Test Matrix

> Not yet filled in as of v1.11.0.

Test each app with:
- **Short** (3s): "Hello world"
- **Medium** (10s): A full sentence with punctuation
- **Hands-free 2+ min**: Tap the hotkey, dictate for more than 2 minutes, then tap to stop (or pause to let Stop After Silence end it)
- **Clipboard**: Copy an image before dictating, verify image is restored after

| App | Short | Medium | Hands-free 2+ min | Punctuation | Clipboard | Notes |
|-----|-------|--------|-------------------|-------------|-----------|-------|
| **Browsers** | | | | | | |
| Safari | | | | | | |
| Chrome | | | | | | |
| Firefox | | | | | | |
| Arc | | | | | | |
| **Code Editors** | | | | | | |
| VS Code | | | | | | |
| Cursor | | | | | | |
| Xcode | | | | | | |
| iTerm2 | | | | | | |
| Terminal.app | | | | | | |
| **Communication** | | | | | | |
| Slack (native) | | | | | | |
| Discord | | | | | | |
| Messages | | | | | | |
| Mail | | | | | | |
| **Productivity** | | | | | | |
| Notes | | | | | | |
| TextEdit | | | | | | |
| Pages | | | | | | |
| Notion | | | | | | |
| Linear | | | | | | |
| Obsidian | | | | | | |
| Bear | | | | | | |
| Craft | | | | | | |
| **Web Apps (in Chrome)** | | | | | | |
| Google Docs | | | | | | |
| Gmail | | | | | | |
| ChatGPT | | | | | | |
| Figma comments | | | | | | |
| **Edge Cases** | | | | | | |
| Password field (Safari) | N/A | N/A | N/A | N/A | N/A | Should block |
| Password field (Chrome) | N/A | N/A | N/A | N/A | N/A | Should block |
| Spotlight | | | | | | |
| Full-screen app | | | | | | |
| **Hands-Free** | | | | | | |
| Hands-free 2+ min, tap to stop | | | | | | |
| Hands-free 2+ min, Stop After Silence | | | | | | |
| Hands-free to Hands-Free Limit (countdown in final 20s) | | | | | | |
| Push-to-talk to Push-to-Talk Limit (countdown in final 20s) | | | | | | |

### Secure Field Tests

| Scenario | Blocked? | Saved to History? (should be no) | Clipboard touched? | Error shown? |
|----------|----------|--------------------|--------------------|-------------|
| Safari login form | | | | |
| Chrome login form | | | | |
| System Settings password | | | | |

## Known Issues

Use GitHub Issues for known issues and regressions:

- https://github.com/theoyinbooke/orttaai/issues

## How to Run Manual Tests

1. Build and run Orttaai from Xcode (`Cmd+R`)
2. Complete the setup flow (grant permissions, download model)
3. Open each target app from the matrix
4. Press `Ctrl+Shift+Space`, speak the test phrase, release
5. Verify text appears, clipboard is restored, and database entry is created
6. Mark results in the matrix above
