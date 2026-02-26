# Orttaai

**Native macOS voice keyboard powered by WhisperKit.**

Giving you back your second hand. Press a hotkey, speak, and your words appear at the cursor — in any app. All processing happens on-device. Your voice never leaves your Mac.

## Features

- **Push-to-talk dictation** — Hold `Ctrl+Shift+Space`, speak, release. Text appears at your cursor.
- **100% on-device** — Uses WhisperKit for local speech recognition. No internet required. No data sent anywhere.
- **Works everywhere** — Text injection via clipboard simulation works across 25+ apps including Safari, Chrome, VS Code, Slack, Notes, and more.
- **Secure field detection** — Automatically blocks dictation into password fields. Your transcription is never stored when blocked.
- **Clipboard preservation** — Saves and restores your clipboard after each dictation. Copy an image, dictate, and your image is still on the clipboard.
- **Recording cap** — 45-second maximum with countdown at 35 seconds.
- **Menu bar app** — Lives in your menu bar with status icon showing current state.
- **History** — Searchable history of all transcriptions with live updates.
- **Personal Home dashboard** — Sleek at-a-glance view for 7-day activity, speed trends, top apps, and quick actions.
- **Model management** — Download and switch between Whisper models based on your hardware.
- **Auto-updates** — Sparkle integration for direct downloads; Homebrew-managed updates for cask installs.

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon (M1 or later)
- ~1GB disk space for the default model

## Installation

### Homebrew (Recommended)

```bash
brew install --cask orttaai
```

### Direct Download

Download the latest `.dmg` from [GitHub Releases](https://github.com/theoyinbooke/orttaai/releases).

## Permissions

Orttaai requires three macOS permissions:

1. **Microphone** — Captures your voice for transcription
2. **Accessibility** — Simulates paste to inject text at your cursor
3. **Input Monitoring** — Detects your push-to-talk hotkey

All processing happens locally. Your voice and text never leave your Mac.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Ctrl+Shift+Space` | Push-to-talk (hold to record, release to transcribe) |
| Configurable | Paste last transcription |

Shortcuts can be customized in Settings > General.

## Models

| Model | Size | RAM Required | Best For |
|-------|------|-------------|----------|
| Whisper Tiny | ~70MB | 8GB+ | Quick notes, commands |
| Whisper Tiny (English) | ~70MB | 8GB+ | Fast English dictation |
| Whisper Base | ~140MB | 8GB+ | Short dictation |
| Whisper Base (English) | ~140MB | 8GB+ | Short English dictation |
| Whisper Small | ~300MB | 8GB+ | General dictation |
| Whisper Small (English) | ~300MB | 8GB+ | General English dictation |
| Whisper Medium | ~770MB | 16GB+ | Longer dictation |
| Whisper Medium (English) | ~770MB | 16GB+ | Longer English dictation |
| Whisper Large V3 Turbo | ~950MB | 16GB+ | Maximum accuracy, optimized speed |
| Whisper Large V3 | ~1500MB | 16GB+ | Highest accuracy, slowest |

## Building from Source

```bash
git clone https://github.com/theoyinbooke/orttaai.git
cd orttaai
open Orttaai.xcodeproj
```

Requirements:
- Xcode 15+
- macOS 14+ SDK
- Apple Silicon Mac (for WhisperKit)

Build: `Cmd+B`
Run: `Cmd+R`
Test: `Cmd+U`

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, code style, and PR process.

## License

[MIT](LICENSE)

## Acknowledgments

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — On-device speech recognition
- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite database toolkit
- [Sparkle](https://github.com/sparkle-project/Sparkle) — Auto-update framework
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) — Shortcut recording
