# Contributing to Orttaai

Thank you for your interest in contributing to Orttaai!

## Development Setup

1. **Clone the repository**
   ```bash
   git clone https://github.com/theoyinbooke/orttaai.git
   cd orttaai
   ```

2. **Open in Xcode**
   ```bash
   open Orttaai.xcodeproj
   ```

3. **Build and run**
   - `Cmd+B` to build
   - `Cmd+R` to run
   - `Cmd+U` to run tests

4. **Grant permissions** when prompted (Microphone, Accessibility, Input Monitoring)

## Code Style

- **Swift**: Follow Swift API Design Guidelines
- **Naming**: Use descriptive names. Avoid abbreviations except well-known ones (URL, ID, etc.)
- **Design tokens**: Always use `Color.Orttaai.*`, `Font.Orttaai.*`, `Spacing.*` — never hardcode values
- **Logging**: Use the appropriate `Logger` category (`Logger.audio`, `Logger.ui`, etc.)
- **Error handling**: Use `OrttaaiError` cases. Provide `errorDescription` and `recoverySuggestion`.

## Architecture

```
Orttaai/
├── App/          — App entry point, AppDelegate, AppState
├── Core/         — Business logic services
│   ├── Audio/         — Audio capture, device management
│   ├── Transcription/ — WhisperKit integration, text processing
│   ├── Injection/     — Clipboard management, text injection
│   ├── Hotkey/        — CGEvent tap hotkey service
│   ├── Hardware/      — Hardware detection and tier classification
│   ├── Model/         — Model download and management
│   └── Coordination/  — DictationCoordinator state machine
├── UI/           — User interface
│   ├── MenuBar/       — Status bar icon and menu
│   ├── FloatingPanel/ — Waveform, processing indicator
│   ├── Windows/       — Window management
│   ├── Setup/         — First-run setup flow
│   ├── Settings/      — Settings tabs
│   ├── History/       — Transcription history
│   └── Components/    — Reusable UI components
├── Data/         — Data models and persistence
├── Design/       — Design tokens (colors, typography, spacing)
├── Utilities/    — Error types, logging, extensions
└── Resources/    — Assets, entitlements, appcast
```

## Pull Request Process

1. Fork the repository
2. Create a feature branch from `main`
3. Make your changes
4. Run tests (`Cmd+U`) and ensure they pass
5. Test manually with the 25+ app matrix if your changes affect text injection
6. Submit a pull request with:
   - Clear description of what changed and why
   - Screenshots for UI changes
   - Test results for behavior changes

## Issue Templates

When filing issues, include:
- macOS version
- Mac model (chip and RAM)
- Steps to reproduce
- Expected vs actual behavior
- Console logs (filter by `com.orttaai.app` in Console.app)

## Areas Where Help is Needed

- Testing on different Mac models (M1, M2, M3)
- Testing with more apps for the compatibility matrix
- Accessibility improvements
- Performance optimization
- Localization
