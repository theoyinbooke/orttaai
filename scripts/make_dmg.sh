#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Lay out an app in a drag-to-install DMG: the app and an Applications link
over a background, with large icons and no toolbar.

Usage:
  scripts/make_dmg.sh --app <path> --output <path.dmg> [options]

Options:
  --app <path>              The .app to put in the DMG.
  --output <path>           Where to write the compressed DMG.
  --volume-name <name>      Volume name (default: the app's name).
  --background <png>        Window background, 760x440 points (1520x880 at 2x).
  --volume-icon <icns>      Icon for the mounted volume.
  --work-dir <path>         Folder for the staging copy and read-write image
                            (default: next to --output).
  --layout <path>           A saved window layout (.DS_Store) to start from
                            (default: scripts/dmg-layout.DS_Store).
  --save-layout <path>      Save this build's window layout there, for --layout.
  -h, --help                Show this help.

Finder can only save a window layout while the window is open. Starting
from a saved layout means that window opens already styled on the build
machine, not in Finder's small default view. The shipped window opens in
the background's own colour while Finder decodes the picture, so it never
flashes white before the design appears.
EOF
}

APP_PATH=""
OUTPUT_PATH=""
VOLUME_NAME=""
BACKGROUND_PATH=""
VOLUME_ICON_PATH=""
WORK_DIR=""
LAYOUT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/dmg-layout.DS_Store"
SAVE_LAYOUT_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP_PATH="${2:-}"; shift 2 ;;
    --output) OUTPUT_PATH="${2:-}"; shift 2 ;;
    --volume-name) VOLUME_NAME="${2:-}"; shift 2 ;;
    --background) BACKGROUND_PATH="${2:-}"; shift 2 ;;
    --volume-icon) VOLUME_ICON_PATH="${2:-}"; shift 2 ;;
    --work-dir) WORK_DIR="${2:-}"; shift 2 ;;
    --layout) LAYOUT_PATH="${2:-}"; shift 2 ;;
    --save-layout) SAVE_LAYOUT_PATH="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$APP_PATH" || -z "$OUTPUT_PATH" ]]; then
  usage >&2
  exit 1
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found: $APP_PATH" >&2
  exit 1
fi

APP_BUNDLE_NAME="$(basename "$APP_PATH")"
VOLUME_NAME="${VOLUME_NAME:-${APP_BUNDLE_NAME%.app}}"
WORK_DIR="${WORK_DIR:-$(dirname "$OUTPUT_PATH")}"
STAGING_PATH="$WORK_DIR/dmg-root"
RW_PATH="$WORK_DIR/$(basename "${OUTPUT_PATH%.dmg}")-rw.dmg"
BACKGROUND_IN_DMG=".background/background.png"

# Finder addresses the disk by name; a second volume of the same name (an
# older installer still mounted) would get the layout instead.
if [[ -e "/Volumes/$VOLUME_NAME" ]]; then
  echo "A volume named \"$VOLUME_NAME\" is already mounted. Eject it, then run again." >&2
  exit 1
fi

echo "==> Staging DMG contents"
mkdir -p "$WORK_DIR"
rm -rf "$STAGING_PATH"
mkdir -p "$STAGING_PATH"
ditto "$APP_PATH" "$STAGING_PATH/$APP_BUNDLE_NAME"
ln -sfn /Applications "$STAGING_PATH/Applications"
if [[ -n "$BACKGROUND_PATH" ]]; then
  mkdir -p "$STAGING_PATH/.background"
  ditto "$BACKGROUND_PATH" "$STAGING_PATH/$BACKGROUND_IN_DMG"
fi
if [[ -n "$LAYOUT_PATH" && -f "$LAYOUT_PATH" && -z "$SAVE_LAYOUT_PATH" ]]; then
  cp "$LAYOUT_PATH" "$STAGING_PATH/.DS_Store"
fi

rm -f "$RW_PATH" "$OUTPUT_PATH"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_PATH" \
  -ov \
  -format UDRW \
  "$RW_PATH"
rm -rf "$STAGING_PATH"

ATTACHED_DEVICE=""
MOUNT_PATH=""
cleanup_mount() {
  if [[ -n "$ATTACHED_DEVICE" ]]; then
    hdiutil detach "$ATTACHED_DEVICE" -quiet >/dev/null 2>&1 || hdiutil detach "$ATTACHED_DEVICE" -force -quiet >/dev/null 2>&1 || true
    ATTACHED_DEVICE=""
  fi
}
trap cleanup_mount EXIT

ATTACH_OUTPUT="$(hdiutil attach "$RW_PATH" -readwrite -noverify -noautoopen)"
ATTACHED_DEVICE="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/\/Volumes\// {print $1; exit}')"
MOUNT_PATH="$(printf '%s\n' "$ATTACH_OUTPUT" | awk -F '\t' '/\/Volumes\// {print $NF; exit}')"

if [[ -z "$ATTACHED_DEVICE" || -z "$MOUNT_PATH" ]]; then
  echo "Failed to mount temporary DMG for layout customization." >&2
  exit 1
fi
if [[ "$MOUNT_PATH" != "/Volumes/$VOLUME_NAME" ]]; then
  echo "The DMG mounted at $MOUNT_PATH, not /Volumes/$VOLUME_NAME; Finder can't lay it out." >&2
  exit 1
fi

echo "==> Applying DMG window layout"
# Finder shows the window before it has decoded the background picture,
# painting the view's background colour meanwhile. Make that the picture's
# own average colour, so the window opens in the design's colour, not white.
BG_COLOR_LINE=""
if [[ -f "$MOUNT_PATH/$BACKGROUND_IN_DMG" ]]; then
  BG_BMP="$WORK_DIR/background-sample.bmp"
  sips -s format bmp "$MOUNT_PATH/$BACKGROUND_IN_DMG" --out "$BG_BMP" >/dev/null
  BG_COLOR="$(python3 -I - "$BG_BMP" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
offset = struct.unpack("<I", data[10:14])[0]
width, height = struct.unpack("<ii", data[18:26])
step = struct.unpack("<H", data[28:30])[0] // 8
row = (width * step + 3) // 4 * 4
total = [0, 0, 0]
count = 0
for y in range(0, abs(height), 4):
    for x in range(0, width, 4):
        i = offset + y * row + x * step
        total[0] += data[i + 2]; total[1] += data[i + 1]; total[2] += data[i]
        count += 1
# Finder takes 16-bit channels.
print(", ".join(str(round(c / count) * 257) for c in total))
PY
)"
  rm -f "$BG_BMP"
  BG_COLOR_LINE="set background color of viewOptions to {$BG_COLOR}"
fi

# Finder writes .DS_Store when it gets round to it. Wait until it holds the
# given records, then until it stops changing, so the image is never
# detached with half a layout.
wait_for_layout() {
  local store="$MOUNT_PATH/.DS_Store" last="" current
  for _ in $(seq 1 40); do
    if [[ -f "$store" ]] && python3 -I - "$store" "$@" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
ok = all(code.encode() in data for code in sys.argv[2:]) and data.count(b"Iloc") >= 2
sys.exit(0 if ok else 1)
PY
    then
      current="$(shasum "$store" | awk '{print $1}')"
      [[ "$current" == "$last" ]] && return 0
      last="$current"
    fi
    sleep 0.5
  done
  echo "Finder didn't save the DMG window layout. Check that Terminal may control Finder (Privacy & Security › Automation), then run again." >&2
  exit 1
}

# The window, its icons and its colour. With a saved layout on the disk the
# window already opens like this; the settings are applied again in case
# the saved layout is out of date.
osascript <<EOF
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, 860, 540}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 152
    set text size of viewOptions to 14
    $BG_COLOR_LINE
    set position of item "$APP_BUNDLE_NAME" of container window to {190, 220}
    set position of item "Applications" of container window to {570, 220}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
wait_for_layout bwsp icvp

# Saved before the picture is added: the picture is linked to this disk,
# while the rest suits any build.
if [[ -n "$SAVE_LAYOUT_PATH" ]]; then
  cp "$MOUNT_PATH/.DS_Store" "$SAVE_LAYOUT_PATH"
  echo "Saved the window layout to $SAVE_LAYOUT_PATH"
fi

if [[ -f "$MOUNT_PATH/$BACKGROUND_IN_DMG" ]]; then
  osascript <<EOF
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set background picture of the icon view options of container window to file ".background:background.png"
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
  wait_for_layout bwsp icvp pBBk
fi

if [[ -n "$VOLUME_ICON_PATH" && -f "$VOLUME_ICON_PATH" ]]; then
  ditto "$VOLUME_ICON_PATH" "$MOUNT_PATH/.VolumeIcon.icns"
  chflags hidden "$MOUNT_PATH/.VolumeIcon.icns" >/dev/null 2>&1 || true

  SETFILE_BIN=""
  if command -v SetFile >/dev/null 2>&1; then
    SETFILE_BIN="$(command -v SetFile)"
  else
    SETFILE_BIN="$(xcrun --find SetFile 2>/dev/null || true)"
  fi

  if [[ -n "$SETFILE_BIN" ]]; then
    "$SETFILE_BIN" -a C "$MOUNT_PATH" >/dev/null 2>&1 || true
  else
    echo "Warning: SetFile tool not found; DMG may show generic volume icon."
  fi
fi

if [[ -d "$MOUNT_PATH/.background" ]]; then
  chflags hidden "$MOUNT_PATH/.background" >/dev/null 2>&1 || true
fi
# Volume bookkeeping that shouldn't ship.
rm -rf "$MOUNT_PATH/.fseventsd" "$MOUNT_PATH/.Trashes"

sync
cleanup_mount
trap - EXIT

hdiutil convert "$RW_PATH" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT_PATH"
rm -f "$RW_PATH"
