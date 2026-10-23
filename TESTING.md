# Orttaai Testing Guide

## Unit Tests

Run via Xcode: `Cmd+U`  
Run via CLI:

```bash
xcodebuild test -scheme Orttaai -destination 'platform=macOS'
```

### Test Coverage

| Module | Tests | Status |
|--------|-------|--------|
| DatabaseManager | 6 | Covered |
| HardwareDetector | 7 | Covered |
| ClipboardManager | 5 | Covered |
| AudioCaptureService | 3 | Covered |
| TextInjectionService | 4 | Covered |
| DictationCoordinator | 8 | Covered |

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

### Local AI Providers

Orttaai's AI (chat, insights, Memory Graph, polish, tone of voice, semantic memory) runs only on Ollama or LM Studio, on your own hardware. `LocalOnlyAIGuardTests` fails the suite if a cloud provider, cloud AI host or spawned CLI returns; `LocalModelPolicyTests` covers the endpoint and model rules.

| Setup | Provider shown | Chat | Chat with memory | Insights | Activity reading | Graph insights | Polish | Tone of Voice |
|-------|----------------|------|------------------|----------|------------------|----------------|--------|---------------|
| Ollama only | Ollama | | | | | | | |
| LM Studio only (`lms server start`) | LM Studio | | | | | | | |
| Bionic open, Secure Cloud model pinned | LM Studio (Bionic), no cloud models listed | | | | | | | |
| Nothing running | "Start Ollama or LM Studio" | | | | | | | |
| Migration from a ChatGPT (Codex) install | Ollama, one-time notice | | | | | | | |
| Cloud endpoint typed in (`https://api.openai.com`) | Refused: "own hardware" | | | | | | | |

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
