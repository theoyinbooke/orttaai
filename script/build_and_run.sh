#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Orttaai"
LOG_SUBSYSTEM="com.orttaai.app"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${ORTTAAI_DERIVED_DATA_PATH:-$ROOT_DIR/.build/codex/DerivedData}"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

stop_debug_app() {
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill "$pid"
  done < <(pgrep -f "$APP_BINARY" || true)
}

stop_debug_app

xcodebuild \
  -quiet \
  -project "$ROOT_DIR/Orttaai.xcodeproj" \
  -scheme Orttaai \
  -configuration Debug \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$LOG_SUBSYSTEM\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -f "$APP_BINARY" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
