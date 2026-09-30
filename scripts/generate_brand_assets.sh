#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p .build/brand-export
xcrun swiftc Orttaai/Design/SignalCursorGlyph.swift scripts/generate_brand_assets.swift -o .build/brand-export/export
.build/brand-export/export
iconutil -c icns branding/orttaai/Orttaai.iconset -o branding/orttaai/Orttaai.icns
