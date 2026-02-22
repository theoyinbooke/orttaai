# Uttrai Testing Guide

## Unit Tests

Run via Xcode: `Cmd+U` or `xcodebuild test -scheme Uttrai -destination 'platform=macOS'`

### Test Coverage

| Module | Tests | Status |
|--------|-------|--------|
| DatabaseManager | 6 | Pending Xcode build |
| HardwareDetector | 7 | Pending Xcode build |
| ClipboardManager | 5 | Pending Xcode build |
| AudioCaptureService | 3 | [NEEDS-RUNTIME-TEST] |
| TextInjectionService | 4 | Pending Xcode build |
| DictationCoordinator | 8 | Pending Xcode build |

## Manual Test Matrix

Test each app with:
- **Short** (3s): "Hello world"
- **Medium** (10s): A full sentence with punctuation
- **Clipboard**: Copy an image before dictating, verify image is restored after

| App | Short | Medium | Punctuation | Clipboard | Notes |
|-----|-------|--------|-------------|-----------|-------|
| **Browsers** | | | | | |
| Safari | | | | | |
| Chrome | | | | | |
| Firefox | | | | | |
| Arc | | | | | |
| **Code Editors** | | | | | |
| VS Code | | | | | |
| Cursor | | | | | |
| Xcode | | | | | |
| iTerm2 | | | | | |
| Terminal.app | | | | | |
| **Communication** | | | | | |
| Slack (native) | | | | | |
| Discord | | | | | |
| Messages | | | | | |
| Mail | | | | | |
| **Productivity** | | | | | |
| Notes | | | | | |
| TextEdit | | | | | |
| Pages | | | | | |
| Notion | | | | | |
| Linear | | | | | |
| Obsidian | | | | | |
| Bear | | | | | |
| Craft | | | | | |
| **Web Apps (in Chrome)** | | | | | |
| Google Docs | | | | | |
| Gmail | | | | | |
| ChatGPT | | | | | |
| Figma comments | | | | | |
| **Edge Cases** | | | | | |
| Password field (Safari) | N/A | N/A | N/A | N/A | Should block |
| Password field (Chrome) | N/A | N/A | N/A | N/A | Should block |
| Spotlight | | | | | |
| Full-screen app | | | | | |

### Secure Field Tests

| Scenario | Blocked? | lastTranscript set? | Clipboard touched? | Error shown? |
|----------|----------|--------------------|--------------------|-------------|
| Safari login form | | | | |
| Chrome login form | | | | |
| System Settings password | | | | |

## Known Issues

(None yet — to be populated during testing)

## How to Run Manual Tests

1. Build and run Uttrai from Xcode (`Cmd+R`)
2. Complete the setup flow (grant permissions, download model)
3. Open each target app from the matrix
4. Press `Ctrl+Shift+Space`, speak the test phrase, release
5. Verify text appears, clipboard is restored, and database entry is created
6. Mark results in the matrix above
