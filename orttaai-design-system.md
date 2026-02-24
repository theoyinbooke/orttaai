# Orttaai Design System

**Version**: 1.0 · February 2026
**Platform**: macOS 14+ · SwiftUI + AppKit
**Theme**: Dark mode only (v1.0)
**Reference**: Cursor IDE aesthetic — warm neutral, typography-driven, restrained

---

## Table of Contents

1. [Design Principles](#1-design-principles)
2. [Color Palette](#2-color-palette)
3. [Typography](#3-typography)
4. [Spacing & Layout](#4-spacing--layout)
5. [Iconography](#5-iconography)
6. [Components](#6-components)
7. [Windows & Panels](#7-windows--panels)
8. [Menu Bar](#8-menu-bar)
9. [Floating Indicator](#9-floating-indicator)
10. [Animations & Transitions](#10-animations--transitions)
11. [States & Feedback](#11-states--feedback)
12. [Accessibility](#12-accessibility)
13. [Implementation Reference](#13-implementation-reference)

---

## 1. Design Principles

### 1.1 Invisible by Default

Orttaai is a system utility, not an application. It should feel like a layer on top of macOS — present when needed, invisible when not. The menu bar icon is the only persistent visual element. Every surface that appears should disappear quickly.

### 1.2 Warm Neutral

The palette is intentionally warm — charcoal backgrounds instead of pure black, cream-tinted text instead of pure white, amber accents instead of blue. This differentiates Orttaai from macOS system UI while still feeling native.

### 1.3 Typography First

UI is driven by type hierarchy, not decorative elements. Spacing, weight, and size do the work. Borders are subtle. Backgrounds are muted. Text is the primary visual element.

### 1.4 Restrained Motion

Animations serve function, not decoration. Fade in/out for context transitions. Pulse for active state. Shimmer for processing. No bouncing, no spring physics, no parallax.

### 1.5 Native Feel

Despite a custom color palette, Orttaai should feel like a macOS app. Use system font (SF Pro). Respect Dynamic Type. Use standard macOS patterns (menu bar, NSPanel, TabView, confirmationDialog). Don't reinvent what Apple already solved.

---

## 2. Color Palette

### 2.1 Core Tokens

Dark mode only for v1.0. All colors defined as extensions on both `Color` (SwiftUI) and `NSColor` (AppKit).

| Token | Hex | RGB | Usage |
|---|---|---|---|
| `bg.primary` | `#1C1C1E` | 28, 28, 30 | Window backgrounds, menu dropdown background |
| `bg.secondary` | `#2C2C2E` | 44, 44, 46 | Input fields, elevated surfaces, cards |
| `bg.tertiary` | `#3A3A3C` | 58, 58, 60 | Hover states, highlights, selected rows |
| `text.primary` | `#F5F3F0` | 245, 243, 240 | Headings, primary body content |
| `text.secondary` | `#A1A1A6` | 161, 161, 166 | Descriptions, timestamps, secondary labels |
| `text.tertiary` | `#636366` | 99, 99, 102 | Placeholders, disabled text, hints |
| `accent` | `#D4952A` | 212, 149, 42 | Amber. Active states, recording, primary buttons, focus rings |
| `accent.subtle` | `#D4952A` @ 12% | — | Amber at 12% opacity. Subtle highlights, hover tints |
| `border` | `#38383A` | 56, 56, 58 | Borders, dividers, separators |
| `success` | `#34C759` | 52, 199, 89 | Permission granted, model ready, download complete |
| `warning` | `#FF9F0A` | 255, 159, 10 | Recording cap approaching, model size warning |
| `error` | `#FF453A` | 255, 69, 58 | Failure states, permission denied, transcription error |

### 2.2 Derived Colors

These are computed from the core tokens — never defined as independent hex values.

| Token | Derivation | Usage |
|---|---|---|
| `accent.hover` | `accent` @ 80% opacity | Button hover on primary buttons |
| `accent.pressed` | `accent` @ 60% opacity | Button pressed state |
| `accent.ring` | `accent` @ 40% opacity | Focus ring glow (outer) |
| `bg.hover` | `bg.tertiary` | Row hover in lists, menu item hover |
| `bg.selected` | `accent.subtle` | Selected row in history, active tab underline |
| `error.subtle` | `error` @ 12% opacity | Error banner background |
| `success.subtle` | `success` @ 12% opacity | Permission granted badge background |
| `warning.subtle` | `warning` @ 12% opacity | Cap warning background |

### 2.3 Semantic Mapping

Use semantic names in code, not raw colors.

| Context | Foreground | Background | Border |
|---|---|---|---|
| Window | `text.primary` | `bg.primary` | — |
| Card / elevated surface | `text.primary` | `bg.secondary` | `border` |
| Input field (idle) | `text.primary` | `bg.secondary` | `border` |
| Input field (focused) | `text.primary` | `bg.secondary` | `accent` |
| Input field (disabled) | `text.tertiary` | `bg.primary` | `border` @ 50% |
| Primary button | `bg.primary` | `accent` | — |
| Secondary button | `text.primary` | transparent | `border` |
| Ghost button | `text.secondary` | transparent | — |
| Disabled button | `text.tertiary` | `bg.secondary` | — |
| Destructive action | `error` | `error.subtle` | `error` @ 30% |
| Status: recording | `accent` | — | — |
| Status: error | `error` | — | — |
| Status: success | `success` | — | — |

### 2.4 Swift Implementation

```swift
// Orttaai/Design/Colors.swift

import SwiftUI
import AppKit

// MARK: - Hex Initializer

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

extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1.0
        )
    }
}

// MARK: - SwiftUI Color Tokens

extension Color {
    enum Orttaai {
        // Backgrounds
        static let bgPrimary = Color(hex: "1C1C1E")
        static let bgSecondary = Color(hex: "2C2C2E")
        static let bgTertiary = Color(hex: "3A3A3C")

        // Text
        static let textPrimary = Color(hex: "F5F3F0")
        static let textSecondary = Color(hex: "A1A1A6")
        static let textTertiary = Color(hex: "636366")

        // Accent
        static let accent = Color(hex: "D4952A")
        static let accentSubtle = Color(hex: "D4952A").opacity(0.12)
        static let accentHover = Color(hex: "D4952A").opacity(0.80)
        static let accentPressed = Color(hex: "D4952A").opacity(0.60)
        static let accentRing = Color(hex: "D4952A").opacity(0.40)

        // Borders
        static let border = Color(hex: "38383A")

        // Semantic
        static let success = Color(hex: "34C759")
        static let successSubtle = Color(hex: "34C759").opacity(0.12)
        static let warning = Color(hex: "FF9F0A")
        static let warningSubtle = Color(hex: "FF9F0A").opacity(0.12)
        static let error = Color(hex: "FF453A")
        static let errorSubtle = Color(hex: "FF453A").opacity(0.12)
    }
}

// MARK: - AppKit NSColor Tokens

extension NSColor {
    enum Orttaai {
        static let bgPrimary = NSColor(hex: "1C1C1E")
        static let bgSecondary = NSColor(hex: "2C2C2E")
        static let bgTertiary = NSColor(hex: "3A3A3C")
        static let textPrimary = NSColor(hex: "F5F3F0")
        static let textSecondary = NSColor(hex: "A1A1A6")
        static let textTertiary = NSColor(hex: "636366")
        static let accent = NSColor(hex: "D4952A")
        static let border = NSColor(hex: "38383A")
        static let success = NSColor(hex: "34C759")
        static let warning = NSColor(hex: "FF9F0A")
        static let error = NSColor(hex: "FF453A")
    }
}
```

---

## 3. Typography

### 3.1 Type Scale

System font (`.system`) resolves to **SF Pro** on macOS. All text respects Dynamic Type accessibility settings.

| Token | SwiftUI Modifier | Size | Weight | Line Height | Usage |
|---|---|---|---|---|---|
| `title` | `.font(.system(size: 18, weight: .semibold))` | 18pt | Semibold | 24pt | Window titles, setup headings |
| `heading` | `.font(.system(size: 16, weight: .semibold))` | 16pt | Semibold | 22pt | Section headers in settings |
| `subheading` | `.font(.system(size: 14, weight: .semibold))` | 14pt | Semibold | 20pt | Card titles, permission names |
| `body` | `.font(.system(size: 13))` | 13pt | Regular | 18pt | Primary body text, descriptions |
| `bodyMedium` | `.font(.system(size: 13, weight: .medium))` | 13pt | Medium | 18pt | Emphasis within body text |
| `secondary` | `.font(.system(size: 12))` | 12pt | Regular | 16pt | Secondary labels, timestamps |
| `caption` | `.font(.system(size: 11))` | 11pt | Regular | 14pt | Hints, disclaimers, fine print |
| `mono` | `.font(.system(size: 12, design: .monospaced))` | 12pt | Regular | 16pt | Keyboard shortcuts, technical values |
| `monoSmall` | `.font(.system(size: 11, design: .monospaced))` | 11pt | Regular | 14pt | File paths, model IDs |

### 3.2 Type Colors

| Context | Color Token |
|---|---|
| Primary content (headings, body) | `text.primary` |
| Secondary content (descriptions, timestamps) | `text.secondary` |
| Disabled / placeholder | `text.tertiary` |
| Link / action | `accent` |
| Error message | `error` |
| Success message | `success` |
| Warning message | `warning` |

### 3.3 Swift Implementation

```swift
// Orttaai/Design/Typography.swift

import SwiftUI

extension Font {
    enum Orttaai {
        static let title = Font.system(size: 18, weight: .semibold)
        static let heading = Font.system(size: 16, weight: .semibold)
        static let subheading = Font.system(size: 14, weight: .semibold)
        static let body = Font.system(size: 13)
        static let bodyMedium = Font.system(size: 13, weight: .medium)
        static let secondary = Font.system(size: 12)
        static let caption = Font.system(size: 11)
        static let mono = Font.system(size: 12, design: .monospaced)
        static let monoSmall = Font.system(size: 11, design: .monospaced)
    }
}

// Usage:
// Text("Settings")
//     .font(.Orttaai.title)
//     .foregroundStyle(Color.Orttaai.textPrimary)
```

---

## 4. Spacing & Layout

### 4.1 Spacing Scale

An 8pt-based spacing scale with a 4pt half-step.

| Token | Value | Usage |
|---|---|---|
| `xs` | 4pt | Tight gaps: icon-to-label, inline elements |
| `sm` | 8pt | Default gap between related elements |
| `md` | 12pt | Gap between form fields, list items |
| `lg` | 16pt | Section padding, card padding |
| `xl` | 20pt | Gap between sections |
| `xxl` | 24pt | Window edge padding |
| `xxxl` | 32pt | Major section breaks, window top/bottom padding |

### 4.2 Layout Constants

| Element | Value | Notes |
|---|---|---|
| Window padding (all edges) | `xxl` (24pt) | All windows: setup, settings, history |
| Section gap | `xl` (20pt) | Between major sections within a window |
| Form field gap | `md` (12pt) | Between label and next field |
| Inline element gap | `sm` (8pt) | Between icon and label, between buttons |
| Corner radius (cards) | 8pt | All elevated surfaces, buttons |
| Corner radius (inputs) | 6pt | Text fields, pickers |
| Corner radius (floating panel) | 8pt | NSPanel |
| Border width | 1pt | All borders use 1pt |
| Focus ring width | 2pt | Amber focus ring on interactive elements |
| Focus ring offset | 2pt | Outset from element bounds |

### 4.3 Window Sizes

| Window | Width | Height | Resizable | Notes |
|---|---|---|---|---|
| Setup | 600pt | 500pt | No | Centered on screen |
| Settings | 500pt | 400pt | No | Centered, TabView |
| History | 480pt | 600pt | Yes (vertical) | Min height 300pt |
| Floating Panel | 200pt | 40pt | No | Positioned near cursor |

### 4.4 Swift Implementation

```swift
// Orttaai/Design/Spacing.swift

import SwiftUI

enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

enum CornerRadius {
    static let card: CGFloat = 8
    static let input: CGFloat = 6
    static let panel: CGFloat = 8
    static let button: CGFloat = 8
}

enum BorderWidth {
    static let standard: CGFloat = 1
    static let focusRing: CGFloat = 2
}

enum WindowSize {
    static let setup = CGSize(width: 600, height: 500)
    static let settings = CGSize(width: 500, height: 400)
    static let history = CGSize(width: 480, height: 600)
    static let historyMin = CGSize(width: 480, height: 300)
    static let floatingPanel = CGSize(width: 200, height: 40)
}
```

---

## 5. Iconography

### 5.1 SF Symbols

All icons use Apple's SF Symbols library. No custom icon assets except the app icon.

| Context | Symbol Name | Rendering | Notes |
|---|---|---|---|
| Menu bar (idle) | `waveform.circle` | Template image | Adapts to light/dark automatically |
| Menu bar (recording) | `waveform.circle.fill` | Amber tint | Pulsing animation |
| Menu bar (processing) | `waveform.circle.fill` | Amber shimmer | Gradient mask |
| Menu bar (error) | `waveform.circle` + dot | Template + amber dot | Badge overlay |
| Permission: Microphone | `mic.fill` | `text.primary` | Setup flow |
| Permission: Accessibility | `accessibility` | `text.primary` | Setup flow |
| Permission: Input Monitoring | `keyboard` | `text.primary` | Setup flow |
| Permission granted | `checkmark.circle.fill` | `success` | Setup flow |
| Permission denied | `xmark.circle.fill` | `error` | Setup flow |
| History entry | `text.bubble` | `text.secondary` | History list |
| Copy | `doc.on.doc` | `text.secondary` | Copy button |
| Settings | `gearshape` | `text.primary` | Menu dropdown |
| Download | `arrow.down.circle` | `accent` | Model download |
| Download complete | `checkmark.circle.fill` | `success` | Model downloaded |
| Warning | `exclamationmark.triangle.fill` | `warning` | Cap warning |
| Error | `xmark.circle.fill` | `error` | Error states |
| Quit | `power` | `text.secondary` | Menu dropdown |
| Audio level | `speaker.wave.2.fill` | `accent` | Audio settings |
| Model | `cpu` | `text.primary` | Model settings |
| Search | `magnifyingglass` | `text.tertiary` | History search |
| Clear | `trash` | `error` | Clear history |
| Restart | `arrow.clockwise` | `accent` | Restart button |
| External link | `arrow.up.right` | `text.secondary` | GitHub link, System Settings link |

### 5.2 Symbol Configuration

```swift
// Standard size for inline icons
Image(systemName: "mic.fill")
    .font(.system(size: 14))
    .foregroundStyle(Color.Orttaai.textPrimary)

// Permission icons (larger)
Image(systemName: "mic.fill")
    .font(.system(size: 24))
    .foregroundStyle(Color.Orttaai.accent)

// Menu bar icon (template)
let image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Orttaai")!
image.isTemplate = true  // Adapts to light/dark menu bar
statusItem.button?.image = image
```

### 5.3 App Icon

The app icon appears in:
- Finder (when navigating to Applications)
- Activity Monitor
- System Settings > Privacy panes
- macOS notification banners
- DMG installer background

**Design direction**: Waveform motif in amber on dark charcoal. Rounded rectangle (macOS standard). Simple, recognizable at 16×16.

**Required sizes** (for `Assets.xcassets/AppIcon.appiconset`):

| Size | Scale | Pixels | File |
|---|---|---|---|
| 16×16 | @1x | 16×16 | icon_16x16.png |
| 16×16 | @2x | 32×32 | icon_16x16@2x.png |
| 32×32 | @1x | 32×32 | icon_32x32.png |
| 32×32 | @2x | 64×64 | icon_32x32@2x.png |
| 128×128 | @1x | 128×128 | icon_128x128.png |
| 128×128 | @2x | 256×256 | icon_128x128@2x.png |
| 256×256 | @1x | 256×256 | icon_256x256.png |
| 256×256 | @2x | 512×512 | icon_256x256@2x.png |
| 512×512 | @1x | 512×512 | icon_512x512.png |
| 512×512 | @2x | 1024×1024 | icon_512x512@2x.png |

---

## 6. Components

### 6.1 OrttaaiButton

Three variants: **Primary**, **Secondary**, **Ghost**.

#### Primary Button

- Background: `accent` → `accent.hover` on hover → `accent.pressed` on press
- Text: `bg.primary`, weight: `.medium`, size: 13pt
- Corner radius: 8pt
- Padding: horizontal `lg` (16pt), vertical `sm` (8pt)
- Focus ring: `accent.ring`, 2pt width, 2pt offset
- Disabled: background `bg.secondary`, text `text.tertiary`

#### Secondary Button

- Background: transparent
- Border: `border`, 1pt
- Text: `text.primary`, weight: `.medium`, size: 13pt
- Corner radius: 8pt
- Padding: horizontal `lg` (16pt), vertical `sm` (8pt)
- Hover: background `bg.tertiary`
- Focus ring: `accent.ring`, 2pt width, 2pt offset
- Disabled: border `border` @ 50%, text `text.tertiary`

#### Ghost Button

- Background: transparent
- No border
- Text: `text.secondary`, weight: `.regular`, size: 13pt
- Padding: horizontal `sm` (8pt), vertical `xs` (4pt)
- Hover: text `text.primary`
- No focus ring

#### Destructive Variant (applied to any button type)

- Text/icon: `error`
- Secondary border: `error` @ 30%
- Hover background: `error.subtle`

```swift
// Orttaai/UI/Components/OrttaaiButton.swift

import SwiftUI

enum OrttaaiButtonVariant {
    case primary
    case secondary
    case ghost
}

struct OrttaaiButtonStyle: ButtonStyle {
    let variant: OrttaaiButtonVariant
    let isDestructive: Bool
    @State private var isHovered = false

    init(_ variant: OrttaaiButtonVariant = .primary, destructive: Bool = false) {
        self.variant = variant
        self.isDestructive = destructive
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.Orttaai.bodyMedium)
            .padding(.horizontal, variant == .ghost ? Spacing.sm : Spacing.lg)
            .padding(.vertical, variant == .ghost ? Spacing.xs : Spacing.sm)
            .foregroundStyle(foregroundColor(isPressed: configuration.isPressed))
            .background(backgroundColor(isPressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.button))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.button)
                    .stroke(borderColor, lineWidth: variant == .secondary ? 1 : 0)
            )
            .onHover { isHovered = $0 }
    }

    private func foregroundColor(isPressed: Bool) -> Color {
        if isDestructive { return Color.Orttaai.error }
        switch variant {
        case .primary: return Color.Orttaai.bgPrimary
        case .secondary: return Color.Orttaai.textPrimary
        case .ghost: return isHovered ? Color.Orttaai.textPrimary : Color.Orttaai.textSecondary
        }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        switch variant {
        case .primary:
            if isPressed { return Color.Orttaai.accentPressed }
            if isHovered { return Color.Orttaai.accentHover }
            return Color.Orttaai.accent
        case .secondary:
            if isHovered || isPressed { return Color.Orttaai.bgTertiary }
            return .clear
        case .ghost:
            return .clear
        }
    }

    private var borderColor: Color {
        if isDestructive { return Color.Orttaai.error.opacity(0.3) }
        return variant == .secondary ? Color.Orttaai.border : .clear
    }
}

// Usage:
// Button("Start Dictating") { ... }
//     .buttonStyle(OrttaaiButtonStyle(.primary))
//
// Button("Cancel") { ... }
//     .buttonStyle(OrttaaiButtonStyle(.secondary))
//
// Button("Clear History") { ... }
//     .buttonStyle(OrttaaiButtonStyle(.secondary, destructive: true))
```

### 6.2 OrttaaiTextField

- Background: `bg.secondary`
- Border: `border` (idle) → `accent` (focused)
- Text: `text.primary`, size 13pt
- Placeholder: `text.tertiary`
- Corner radius: 6pt
- Padding: horizontal `sm` (8pt), vertical `sm` (8pt)
- Focus ring: `accent.ring`, 2pt

```swift
// Orttaai/UI/Components/OrttaaiTextField.swift

import SwiftUI

struct OrttaaiTextField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.Orttaai.body)
            .foregroundStyle(Color.Orttaai.textPrimary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.sm)
            .background(Color.Orttaai.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.input)
                    .stroke(
                        isFocused ? Color.Orttaai.accent : Color.Orttaai.border,
                        lineWidth: BorderWidth.standard
                    )
            )
            .focused($isFocused)
    }
}
```

### 6.3 OrttaaiToggle

- Track: `bg.tertiary` (off) → `accent` (on)
- Knob: white circle
- Transition: 150ms `.easeOut`
- Size: 36×20pt (macOS standard feel)

```swift
// Orttaai/UI/Components/OrttaaiToggle.swift

import SwiftUI

struct OrttaaiToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Spacing.sm) {
            configuration.label
                .font(.Orttaai.body)
                .foregroundStyle(Color.Orttaai.textPrimary)

            Spacer()

            RoundedRectangle(cornerRadius: 10)
                .fill(configuration.isOn ? Color.Orttaai.accent : Color.Orttaai.bgTertiary)
                .frame(width: 36, height: 20)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 16, height: 16)
                        .padding(2)
                }
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
                .onTapGesture {
                    configuration.isOn.toggle()
                }
        }
    }
}

// Usage:
// Toggle("Launch at Login", isOn: $launchAtLogin)
//     .toggleStyle(OrttaaiToggleStyle())
```

### 6.4 OrttaaiProgressBar

- Track: `bg.tertiary`
- Fill: `accent`
- Corner radius: 3pt (half of 6pt height)
- Height: 6pt
- Animation: `.linear` fill width

```swift
// Orttaai/UI/Components/OrttaaiProgressBar.swift

import SwiftUI

struct OrttaaiProgressBarStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.Orttaai.bgTertiary)
                    .frame(height: 6)

                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.Orttaai.accent)
                    .frame(
                        width: geometry.size.width * (configuration.fractionCompleted ?? 0),
                        height: 6
                    )
                    .animation(.linear(duration: 0.2), value: configuration.fractionCompleted)
            }
        }
        .frame(height: 6)
    }
}

// Usage:
// ProgressView(value: downloadProgress, total: 1.0)
//     .progressViewStyle(OrttaaiProgressBarStyle())
```

### 6.5 AudioLevelMeter

- Displays real-time audio amplitude
- Bar: `accent` fill, animated width
- Track: `bg.tertiary`
- Height: 8pt
- Corner radius: 4pt
- Updates at 30fps, driven by `audioLevel` property

```swift
// Orttaai/UI/Components/AudioLevelMeter.swift

import SwiftUI

struct AudioLevelMeter: View {
    let level: Float  // 0.0 to 1.0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.Orttaai.bgTertiary)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.Orttaai.accent)
                    .frame(width: geometry.size.width * CGFloat(min(level, 1.0)))
                    .animation(.linear(duration: 0.033), value: level)
            }
        }
        .frame(height: 8)
    }
}
```

### 6.6 ShortcutRecorderView

Wrapper around `KeyboardShortcuts.Recorder` styled to match the design system.

```swift
// Orttaai/UI/Components/ShortcutRecorderView.swift

import SwiftUI
import KeyboardShortcuts

struct ShortcutRecorderView: View {
    let name: KeyboardShortcuts.Name
    let label: String

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text(label)
                .font(.Orttaai.body)
                .foregroundStyle(Color.Orttaai.textPrimary)

            Spacer()

            KeyboardShortcuts.Recorder(for: name)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(Color.Orttaai.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.input)
                        .stroke(Color.Orttaai.border, lineWidth: 1)
                )
        }
    }
}
```

### 6.7 Permission Row

Used in the setup flow. Shows a permission with its status and action button.

| State | Icon Color | Status Text | Button |
|---|---|---|---|
| Not granted | `text.secondary` | "Not granted" in `text.tertiary` | "Grant Access" (primary) |
| Granted | `success` | "Granted" in `success` | Checkmark, no button |
| Needs restart | `warning` | "Restart required" in `warning` | "Restart Now" (primary) |

```swift
struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let status: PermissionStatus
    let action: () -> Void

    enum PermissionStatus {
        case notGranted
        case granted
        case needsRestart
    }

    var body: some View {
        HStack(spacing: Spacing.lg) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(statusIconColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Text(description)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }

            Spacer()

            switch status {
            case .notGranted:
                Button("Grant Access", action: action)
                    .buttonStyle(OrttaaiButtonStyle(.primary))
            case .granted:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.Orttaai.success)
            case .needsRestart:
                Button("Restart Now", action: action)
                    .buttonStyle(OrttaaiButtonStyle(.primary))
            }
        }
        .padding(Spacing.lg)
        .background(Color.Orttaai.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
    }

    private var statusIconColor: Color {
        switch status {
        case .notGranted: return Color.Orttaai.textSecondary
        case .granted: return Color.Orttaai.success
        case .needsRestart: return Color.Orttaai.warning
        }
    }
}
```

### 6.8 History Entry Row

| State | Layout |
|---|---|
| Collapsed | Timestamp (secondary) · Truncated text (2 lines, body) · App name (caption, tertiary) |
| Expanded | Full text (body) · Copy button (ghost) |

---

## 7. Windows & Panels

### 7.1 Window Chrome

All windows use native macOS title bar (traffic lights). Background is `bg.primary`. No custom title bar.

```swift
// Standard window configuration
window.backgroundColor = NSColor.Orttaai.bgPrimary
window.titlebarAppearsTransparent = false
window.isMovableByWindowBackground = true
```

### 7.2 Setup Window

- 600×500pt, non-resizable, centered
- No title bar text (use transparent title bar if desired)
- Content: step-based flow with consistent padding (24pt all edges)
- Step indicator at top: dots or "Step 1 of 3"
- Large permission icons (24pt SF Symbols)
- Trust statement in a bordered card with amber left accent line

**Layout**:
```
┌──────────────────────────────────────────┐
│  Step 1 of 3: Permissions                │
│                                          │
│  ┌────────────────────────────────────┐  │
│  │ 🎤  Microphone                     │  │
│  │     Captures your voice...  [Grant]│  │
│  └────────────────────────────────────┘  │
│                                          │
│  ┌────────────────────────────────────┐  │
│  │ ♿  Accessibility                   │  │
│  │     Simulates paste...      [Grant]│  │
│  └────────────────────────────────────┘  │
│                                          │
│  ┌────────────────────────────────────┐  │
│  │ ⌨️  Input Monitoring               │  │
│  │     Detects hotkey...       [Grant]│  │
│  └────────────────────────────────────┘  │
│                                          │
│  ┌─ amber ────────────────────────────┐  │
│  │ Your voice and text never leave    │  │
│  │ your Mac...                        │  │
│  └────────────────────────────────────┘  │
│                                          │
│                          [Continue →]    │
└──────────────────────────────────────────┘
```

### 7.3 Settings Window

- 500×400pt, non-resizable, centered
- `TabView` with `.automatic` style (native macOS tabs)
- Tabs: General, Audio, Model, About
- Each tab content padded with 24pt all edges

### 7.4 History Window

- 480×600pt, vertically resizable (min 300pt height)
- `.searchable` modifier at top
- `List` with selection
- Selected row background: `accent.subtle`
- Empty state: centered text with muted icon

---

## 8. Menu Bar

### 8.1 Status Item

The menu bar icon is the only persistent UI element. It must work flawlessly in both light and dark menu bars.

**Template image** mode ensures macOS handles light/dark adaptation automatically for the idle state. Non-template rendering is used for colored states (recording, processing).

### 8.2 Icon States

| State | Rendering | Color | Animation |
|---|---|---|---|
| Idle | Template image | System (auto light/dark) | None |
| Recording | Non-template | `accent` (#D4952A) | Subtle pulse: opacity 0.7↔1.0 over 2s |
| Processing | Non-template | `accent` (#D4952A) | Shimmer: gradient sweep over 1.5s |
| Downloading | Template + ring overlay | Ring: `accent` | Ring fill progress |
| Error | Template + dot overlay | Dot: `accent` | None (static dot) |

### 8.3 Menu Dropdown

- Background: system vibrancy (default NSMenu behavior — do not override)
- Font: system default for NSMenu (do not customize)
- Custom items: status line as disabled item with `text.secondary` equivalent

| Item | State | Shortcut |
|---|---|---|
| "Ready" / "Recording..." / etc. | Disabled (informational) | — |
| ─── separator ─── | | |
| Polish Mode | Disabled, "Coming soon" subtitle | — |
| History | Enabled | — |
| ─── separator ─── | | |
| Settings... | Enabled | ⌘, |
| "Updates managed by Homebrew" | Disabled (Homebrew only) | — |
| Check for Updates... | Enabled (.dmg only) | — |
| ─── separator ─── | | |
| Quit Orttaai | Enabled | ⌘Q |

---

## 9. Floating Indicator

### 9.1 Panel Configuration

The floating indicator is the most visible UI element during dictation. It must feel instant and never interfere with the user's work.

| Property | Value |
|---|---|
| Type | NSPanel |
| Style mask | `.nonactivatingPanel`, `.borderless`, `.hudWindow` |
| Level | `.floating` |
| Collection behavior | `.canJoinAllSpaces`, `.fullScreenAuxiliary` |
| Size | 200 × 40pt |
| Corner radius | 8pt |
| Background | NSVisualEffectView with `.hudWindow` material |
| Shadow | System default for floating level |

### 9.2 Panel States

#### Recording State

```
┌──────────────────────────────────────┐
│  ▐▌▐▌▐▌▐▌▐▌▐▌▐▌▐▌  (waveform)      │
└──────────────────────────────────────┘
```

- Waveform bars: amber (`accent`), animated at 30fps
- 8–12 bars, heights driven by `audioLevel`
- Bar width: 3pt, gap: 2pt, corner radius: 1.5pt

#### Recording with Countdown (> 35s)

```
┌──────────────────────────────────────┐
│  ▐▌▐▌▐▌▐▌▐▌▐▌      10s remaining   │
└──────────────────────────────────────┘
```

- Countdown text: `warning` color, `mono` font
- Waveform shrinks to accommodate text

#### Processing State

```
┌──────────────────────────────────────┐
│  ░░░▓▓▓░░░  Processing...           │
└──────────────────────────────────────┘
```

- Shimmer: gradient mask sweeping left to right
- Gradient: `accent` @ 30% → `accent` @ 80% → `accent` @ 30%
- Animation: `.easeInOut(duration: 1.5).repeatForever()`
- Text: "Processing..." in `text.secondary`, or "~8s to process" for long recordings

#### Error State

```
┌──────────────────────────────────────┐
│  ⚠ Can't dictate into password fields│
└──────────────────────────────────────┘
```

- Icon: `exclamationmark.triangle.fill` in `error` or `warning`
- Text: `error` color for failures, `warning` for blocks
- Auto-dismiss after 2 seconds
- Specific messages:
  - "Can't dictate into password fields" (secure field block)
  - "Microphone access needed" (mic denied)
  - "Couldn't transcribe. Try again." (inference failure)
  - "Use Cmd+Shift+V to paste" (paste failure fallback)

#### Success State (implicit)

No explicit success state. The panel simply fades out after successful injection. The appearance of text at the cursor is the success feedback.

### 9.3 Positioning

1. **Primary**: Get cursor position via `AXUIElementCopyAttributeValue(element, kAXPositionAttribute)` on the focused text element
2. **Fallback**: `NSEvent.mouseLocation` if AX position unavailable
3. **Offset**: Position panel 8pt above and 0pt left of cursor position
4. **Screen bounds check**: Ensure panel doesn't go off-screen (adjust position if near edges)

---

## 10. Animations & Transitions

### 10.1 Animation Inventory

Every animation in the app, with exact parameters:

| Animation | Duration | Curve | API | Trigger |
|---|---|---|---|---|
| Panel fade in | 150ms | `.easeIn` | NSAnimationContext.runAnimationGroup | Recording starts |
| Panel fade out | 200ms | `.easeOut` | NSAnimationContext.runAnimationGroup | Injection complete or error dismiss |
| Waveform bars | 33ms (30fps) | `.linear` | DispatchSourceTimer → SwiftUI Canvas | Audio level changes |
| Processing shimmer | 1500ms loop | `.easeInOut` | `.animation(.easeInOut(duration: 1.5).repeatForever())` | Processing state entered |
| Menu bar pulse | 2000ms loop | `.easeInOut` | NSTimer + NSImage redraw | Recording state |
| Toggle switch | 150ms | `.easeOut` | `.animation(.easeOut(duration: 0.15))` | Toggle value change |
| Button hover | Instant | — | `onHover` state change | Mouse enter/leave |
| Error auto-dismiss | 2000ms wait | — | Task.sleep | Error state entered |
| Permission check poll | 1000ms interval | — | Timer | Setup flow active |
| Download progress | 200ms | `.linear` | `.animation(.linear(duration: 0.2))` | Progress update |

### 10.2 Panel Fade Implementation

```swift
// Fade in
func showPanel(at point: NSPoint) {
    panel.setFrameOrigin(point)
    panel.alphaValue = 0
    panel.orderFront(nil)

    NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        context.timingFunction = CAMediaTimingFunction(name: .easeIn)
        panel.animator().alphaValue = 1
    }
}

// Fade out
func dismissPanel() {
    NSAnimationContext.runAnimationGroup({ context in
        context.duration = 0.20
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().alphaValue = 0
    }, completionHandler: {
        self.panel.orderOut(nil)
    })
}
```

### 10.3 Waveform Rendering

```swift
// WaveformView — SwiftUI Canvas driven by audio level
struct WaveformView: View {
    let audioLevel: Float
    let barCount = 10
    let barWidth: CGFloat = 3
    let barGap: CGFloat = 2
    let minHeight: CGFloat = 4
    let maxHeight: CGFloat = 28

    var body: some View {
        Canvas { context, size in
            let totalWidth = CGFloat(barCount) * (barWidth + barGap) - barGap
            let startX = (size.width - totalWidth) / 2

            for i in 0..<barCount {
                // Create organic variation per bar
                let noise = sin(Double(i) * 0.8 + Double(audioLevel) * 10) * 0.3 + 0.7
                let height = minHeight + (maxHeight - minHeight)
                    * CGFloat(audioLevel) * CGFloat(noise)
                let x = startX + CGFloat(i) * (barWidth + barGap)
                let y = (size.height - height) / 2

                let rect = CGRect(x: x, y: y, width: barWidth, height: height)
                let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                context.fill(path, with: .color(Color.Orttaai.accent))
            }
        }
        .frame(height: 32)
        .animation(.linear(duration: 0.033), value: audioLevel)
    }
}
```

---

## 11. States & Feedback

### 11.1 Global State Visual Mapping

The DictationCoordinator state directly drives all visual elements:

| State | Menu Bar Icon | Floating Panel | Status Line Text |
|---|---|---|---|
| `idle` | Template (auto) | Hidden | "Ready" |
| `recording(startTime)` | Amber pulse | Waveform | "Recording..." |
| `processing(estimate?)` | Amber shimmer | Shimmer + text | "Processing..." |
| `injecting` | Amber shimmer | Shimmer (brief) | "Processing..." |
| `error(message)` | Amber dot badge | Error message | "Error" |

### 11.2 Empty States

| Screen | Message | Icon |
|---|---|---|
| History (no entries) | "No transcriptions yet.\nPress Ctrl+Shift+Space to get started." | `waveform.circle` in `text.tertiary` |
| Model (none downloaded) | "No model installed.\nDownload one to start dictating." | `arrow.down.circle` in `text.tertiary` |

### 11.3 Loading States

| Context | Indicator | Text |
|---|---|---|
| Model loading (warm-up) | Menu bar shows subtle shimmer | Status line: "Loading model..." |
| Model downloading | Menu bar progress ring | Status line: "Downloading model (43%)..." |
| History loading | Native SwiftUI List skeleton | — |

### 11.4 Confirmation Dialogs

Use native macOS `confirmationDialog` for destructive actions:

```swift
.confirmationDialog(
    "Clear All History?",
    isPresented: $showClearConfirmation,
    titleVisibility: .visible
) {
    Button("Clear History", role: .destructive) {
        database.deleteAll()
    }
    Button("Cancel", role: .cancel) { }
} message: {
    Text("This will permanently delete all \(count) transcriptions. This cannot be undone.")
}
```

---

## 12. Accessibility

### 12.1 VoiceOver

- All interactive elements have accessibility labels
- All images have `accessibilityDescription`
- Status changes announced via `NSAccessibility.post(notification:)`
- Tab order follows visual layout (top-to-bottom, left-to-right)

### 12.2 Dynamic Type

- All text uses `.font(.Orttaai.xyz)` which is built on `.system()` — respects Dynamic Type
- Layout should accommodate text scaling up to 1.5x without clipping
- Test with: System Settings > Accessibility > Display > Text Size

### 12.3 Keyboard Navigation

- All buttons and toggles are keyboard-focusable
- Tab moves between interactive elements
- Space/Enter activates focused button
- Esc closes windows (settings, history)
- Focus rings visible on all interactive elements (amber, 2pt)

### 12.4 Reduced Motion

```swift
@Environment(\.accessibilityReduceMotion) var reduceMotion

// Use in animations:
.animation(reduceMotion ? nil : .easeInOut(duration: 1.5).repeatForever(), value: isProcessing)
```

When Reduce Motion is enabled:
- Waveform: static bar heights instead of animation
- Processing: static "Processing..." text instead of shimmer
- Panel: instant show/hide instead of fade
- Menu bar: static icon instead of pulse

### 12.5 Color Contrast

All text meets WCAG AA contrast ratios against their backgrounds:

| Combination | Contrast Ratio | WCAG AA |
|---|---|---|
| `text.primary` (#F5F3F0) on `bg.primary` (#1C1C1E) | 14.5:1 | Pass |
| `text.secondary` (#A1A1A6) on `bg.primary` (#1C1C1E) | 5.8:1 | Pass |
| `text.tertiary` (#636366) on `bg.primary` (#1C1C1E) | 2.9:1 | Pass (decorative only) |
| `accent` (#D4952A) on `bg.primary` (#1C1C1E) | 5.2:1 | Pass |
| `bg.primary` (#1C1C1E) on `accent` (#D4952A) | 5.2:1 | Pass (button text) |
| `error` (#FF453A) on `bg.primary` (#1C1C1E) | 5.1:1 | Pass |
| `success` (#34C759) on `bg.primary` (#1C1C1E) | 6.4:1 | Pass |

Note: `text.tertiary` is used only for decorative/non-essential text (placeholders, hints) — not required to meet AA.

---

## 13. Implementation Reference

### 13.1 File-to-Component Mapping

| File | Components Defined |
|---|---|
| `Design/Colors.swift` | `Color.Orttaai.*`, `NSColor.Orttaai.*`, `Color.init(hex:)` |
| `Design/Typography.swift` | `Font.Orttaai.*` |
| `Design/Spacing.swift` | `Spacing.*`, `CornerRadius.*`, `BorderWidth.*`, `WindowSize.*` |
| `UI/Components/OrttaaiButton.swift` | `OrttaaiButtonStyle` (primary, secondary, ghost, destructive) |
| `UI/Components/OrttaaiTextField.swift` | `OrttaaiTextField` |
| `UI/Components/OrttaaiToggle.swift` | `OrttaaiToggleStyle` |
| `UI/Components/OrttaaiProgressBar.swift` | `OrttaaiProgressBarStyle` |
| `UI/Components/AudioLevelMeter.swift` | `AudioLevelMeter` |
| `UI/Components/ShortcutRecorderView.swift` | `ShortcutRecorderView` |
| `UI/FloatingPanel/WaveformView.swift` | `WaveformView` |
| `UI/FloatingPanel/ProcessingIndicatorView.swift` | Processing shimmer, error display |
| `UI/FloatingPanel/FloatingPanelController.swift` | NSPanel setup, fade in/out, positioning |
| `UI/Setup/PermissionStepView.swift` | `PermissionRow` |
| `UI/MenuBar/MenuBarIconRenderer.swift` | Icon state rendering (idle, recording, processing, error) |

### 13.2 Design Token Import

Every file that renders UI should import the design tokens:

```swift
import SwiftUI

// Access colors:  Color.Orttaai.accent
// Access fonts:   Font.Orttaai.body
// Access spacing: Spacing.lg
// Access radii:   CornerRadius.card
```

### 13.3 Component Usage Patterns

```swift
// Standard form layout
VStack(alignment: .leading, spacing: Spacing.md) {
    Text("General")
        .font(.Orttaai.heading)
        .foregroundStyle(Color.Orttaai.textPrimary)

    Toggle("Launch at Login", isOn: $launchAtLogin)
        .toggleStyle(OrttaaiToggleStyle())

    ShortcutRecorderView(name: .pushToTalk, label: "Push to Talk")

    Divider()
        .background(Color.Orttaai.border)

    Button("Clear History") {
        showClearConfirmation = true
    }
    .buttonStyle(OrttaaiButtonStyle(.secondary, destructive: true))
}
.padding(Spacing.xxl)
```

```swift
// Card layout (used in setup, settings)
VStack(alignment: .leading, spacing: Spacing.sm) {
    Text("Current Model")
        .font(.Orttaai.subheading)
        .foregroundStyle(Color.Orttaai.textPrimary)
    Text("openai_whisper-large-v3_turbo · 950MB")
        .font(.Orttaai.secondary)
        .foregroundStyle(Color.Orttaai.textSecondary)
}
.padding(Spacing.lg)
.frame(maxWidth: .infinity, alignment: .leading)
.background(Color.Orttaai.bgSecondary)
.clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
```

### 13.4 Do's and Don'ts

**Do:**
- Use `Color.Orttaai.*` tokens everywhere — never hardcode hex values outside `Colors.swift`
- Use `Font.Orttaai.*` tokens — never call `.system(size:)` directly in view code
- Use `Spacing.*` constants — never use magic number padding
- Use SF Symbols — never import custom icon PNGs (except app icon)
- Test with VoiceOver and keyboard navigation
- Respect `@Environment(\.accessibilityReduceMotion)`

**Don't:**
- Don't use `.accent` (system accent color) — use `Color.Orttaai.accent` (our amber)
- Don't use `.primary`/`.secondary` text colors — use `Color.Orttaai.textPrimary` etc.
- Don't use spring animations — use `easeIn`, `easeOut`, `easeInOut`, or `linear` only
- Don't add shadows to cards — only the floating panel has a shadow (system-provided)
- Don't use gradients for backgrounds — solid colors from the palette only
- Don't add borders to primary buttons — only secondary buttons have visible borders
- Don't use `.thinMaterial` or `.regularMaterial` for windows — use `bg.primary` solid fill
- Don't override NSMenu appearance — let macOS handle dropdown styling

---

*End of Design System*

Orttaai Design System v1.0 · February 2026
