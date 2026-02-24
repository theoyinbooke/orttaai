#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build a signed + notarized DMG for Orttaai.

Usage:
  scripts/release_dmg.sh [options]

Options:
  --version <x.y.z>         Override MARKETING_VERSION from Xcode build settings.
  --project <path>          Xcode project path (default: Orttaai.xcodeproj).
  --scheme <name>           Xcode scheme (default: Orttaai).
  --configuration <name>    Build configuration (default: Release).
  --app-name <name>         App bundle name (default: Orttaai).
  --team-id <id>            Apple Team ID (default: from Xcode build settings).
  --notary-profile <name>   notarytool keychain profile (default: ORTTAAI_NOTARY).
  --output-dir <path>       Artifact directory root (default: dist).
  --skip-notarize           Build/sign/package only; skip notary submit + staple.
  -h, --help                Show this help.

Prerequisites:
  - Developer ID Application cert installed locally.
  - notarytool profile stored:
      xcrun notarytool store-credentials "ORTTAAI_NOTARY" \
        --apple-id "<apple-id>" --team-id "<team-id>" --password "<app-specific-password>"
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

PROJECT_PATH="Orttaai.xcodeproj"
SCHEME="Orttaai"
CONFIGURATION="Release"
APP_NAME="Orttaai"
NOTARY_PROFILE="ORTTAAI_NOTARY"
OUTPUT_DIR="dist"
VERSION_OVERRIDE=""
TEAM_ID_OVERRIDE=""
SKIP_NOTARIZE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION_OVERRIDE="${2:-}"
      shift 2
      ;;
    --project)
      PROJECT_PATH="${2:-}"
      shift 2
      ;;
    --scheme)
      SCHEME="${2:-}"
      shift 2
      ;;
    --configuration)
      CONFIGURATION="${2:-}"
      shift 2
      ;;
    --app-name)
      APP_NAME="${2:-}"
      shift 2
      ;;
    --team-id)
      TEAM_ID_OVERRIDE="${2:-}"
      shift 2
      ;;
    --notary-profile)
      NOTARY_PROFILE="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --skip-notarize)
      SKIP_NOTARIZE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_cmd xcodebuild
require_cmd xcrun
require_cmd hdiutil
require_cmd codesign
require_cmd spctl
require_cmd security
require_cmd shasum
require_cmd ditto

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "Project not found: $PROJECT_PATH" >&2
  exit 1
fi

BUILD_SETTINGS="$(xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -showBuildSettings)"
MARKETING_VERSION="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/MARKETING_VERSION =/{print $2; exit}')"
TEAM_ID_FROM_XCODE="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/DEVELOPMENT_TEAM =/{print $2; exit}')"

VERSION="${VERSION_OVERRIDE:-$MARKETING_VERSION}"
TEAM_ID="${TEAM_ID_OVERRIDE:-$TEAM_ID_FROM_XCODE}"

if [[ -z "${VERSION:-}" ]]; then
  echo "Unable to resolve app version. Pass --version." >&2
  exit 1
fi

if [[ -z "${TEAM_ID:-}" ]]; then
  echo "Unable to resolve Team ID. Pass --team-id." >&2
  exit 1
fi

DEVELOPER_ID_SHA="$(security find-identity -v -p codesigning | awk '/Developer ID Application/{print $2; exit}')"
if [[ -z "${DEVELOPER_ID_SHA:-}" ]]; then
  echo "Developer ID Application signing identity not found in keychain." >&2
  exit 1
fi

if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "Notary profile '$NOTARY_PROFILE' not found or invalid." >&2
    echo "Run: xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id ... --team-id ... --password ..." >&2
    exit 1
  fi
fi

ARTIFACT_ROOT="$OUTPUT_DIR/$VERSION"
ARCHIVE_PATH="$ARTIFACT_ROOT/${APP_NAME}.xcarchive"
EXPORT_PATH="$ARTIFACT_ROOT/export"
DMG_PATH="$ARTIFACT_ROOT/${APP_NAME}-${VERSION}.dmg"
APP_PATH="$EXPORT_PATH/${APP_NAME}.app"
ARCHIVED_APP_PATH="$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app"
ENTITLEMENTS_PATH="Orttaai/Orttaai.entitlements"
DMG_STAGING_PATH="$ARTIFACT_ROOT/dmg-root"
DMG_RW_PATH="$ARTIFACT_ROOT/${APP_NAME}-${VERSION}-rw.dmg"
DMG_BACKGROUND_SOURCE="$ARTIFACT_ROOT/dmg-background-source.png"
DMG_BACKGROUND_IN_DMG=".background/background.png"
DMG_VOLUME_ICON_SOURCE=""

rm -rf "$ARTIFACT_ROOT"
mkdir -p "$ARTIFACT_ROOT"

echo "==> Archiving app ($SCHEME, $CONFIGURATION)"
# Keep archive signing automatic to avoid forcing Developer ID onto SwiftPM dependency targets.
# Developer ID signing is applied after archive by re-signing the archived .app bundle.
xcodebuild archive \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  SKIP_INSTALL=NO

if [[ ! -d "$ARCHIVED_APP_PATH" ]]; then
  echo "Archive failed: app bundle not found at $ARCHIVED_APP_PATH" >&2
  exit 1
fi

echo "==> Copying app from archive"
mkdir -p "$EXPORT_PATH"
ditto "$ARCHIVED_APP_PATH" "$APP_PATH"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Copy failed: app bundle not found at $APP_PATH" >&2
  exit 1
fi

if [[ -f "Orttaai/Resources/dmg-volume-icon.icns" ]]; then
  DMG_VOLUME_ICON_SOURCE="Orttaai/Resources/dmg-volume-icon.icns"
elif [[ -f "$APP_PATH/Contents/Resources/AppIcon.icns" ]]; then
  DMG_VOLUME_ICON_SOURCE="$APP_PATH/Contents/Resources/AppIcon.icns"
fi

echo "==> Re-signing app with Developer ID"
if [[ -f "$ENTITLEMENTS_PATH" ]]; then
  codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID_SHA" "$APP_PATH"
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS_PATH" --sign "$DEVELOPER_ID_SHA" "$APP_PATH"
else
  echo "Warning: entitlements file not found at $ENTITLEMENTS_PATH, signing without explicit entitlements."
  codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID_SHA" "$APP_PATH"
fi

echo "==> Verifying app signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "==> Skipping Gatekeeper app assessment pre-notarization"

echo "==> Creating DMG"
rm -rf "$DMG_STAGING_PATH"
mkdir -p "$DMG_STAGING_PATH"
ditto "$APP_PATH" "$DMG_STAGING_PATH/${APP_NAME}.app"
ln -sfn /Applications "$DMG_STAGING_PATH/Applications"

# Optional polished Finder background.
if [[ -f "Orttaai/Resources/dmg-background.png" ]]; then
  mkdir -p "$DMG_STAGING_PATH/.background"
  ditto "Orttaai/Resources/dmg-background.png" "$DMG_STAGING_PATH/$DMG_BACKGROUND_IN_DMG"
elif [[ -f "orttaai.png" ]]; then
  mkdir -p "$DMG_STAGING_PATH/.background"
  if command -v sips >/dev/null 2>&1; then
    # Resize hero image to a Finder-window-friendly background.
    if ! sips -s format png -z 360 640 "orttaai.png" --out "$DMG_BACKGROUND_SOURCE" >/dev/null 2>&1; then
      ditto "orttaai.png" "$DMG_BACKGROUND_SOURCE"
    fi
  else
    ditto "orttaai.png" "$DMG_BACKGROUND_SOURCE"
  fi
  ditto "$DMG_BACKGROUND_SOURCE" "$DMG_STAGING_PATH/$DMG_BACKGROUND_IN_DMG"
fi

rm -f "$DMG_RW_PATH" "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING_PATH" \
  -ov \
  -format UDRW \
  "$DMG_RW_PATH"

ATTACHED_DEVICE=""
MOUNT_PATH=""
cleanup_mount() {
  if [[ -n "$ATTACHED_DEVICE" ]]; then
    hdiutil detach "$ATTACHED_DEVICE" -quiet >/dev/null 2>&1 || hdiutil detach "$ATTACHED_DEVICE" -force -quiet >/dev/null 2>&1 || true
    ATTACHED_DEVICE=""
  fi
}
trap cleanup_mount EXIT

ATTACH_OUTPUT="$(hdiutil attach "$DMG_RW_PATH" -readwrite -noverify -noautoopen)"
ATTACHED_DEVICE="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/\/Volumes\// {print $1; exit}')"
MOUNT_PATH="$(printf '%s\n' "$ATTACH_OUTPUT" | awk -F '\t' '/\/Volumes\// {print $NF; exit}')"

if [[ -z "$ATTACHED_DEVICE" || -z "$MOUNT_PATH" ]]; then
  echo "Failed to mount temporary DMG for layout customization." >&2
  exit 1
fi

if command -v osascript >/dev/null 2>&1; then
  echo "==> Applying polished DMG window layout"
  BG_SCRIPT_LINE=""
  if [[ -f "$MOUNT_PATH/$DMG_BACKGROUND_IN_DMG" ]]; then
    BG_SCRIPT_LINE='set background picture of viewOptions to file ".background:background.png"'
  fi

  if ! osascript <<EOF
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {120, 120, 840, 520}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 14
    $BG_SCRIPT_LINE
    set position of item "$APP_NAME.app" of container window to {180, 240}
    set position of item "Applications" of container window to {500, 240}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
EOF
  then
    echo "Warning: could not apply Finder window customization; continuing with standard DMG layout."
  fi
else
  echo "Warning: osascript not available; skipping polished DMG layout."
fi

if [[ -n "$DMG_VOLUME_ICON_SOURCE" && -f "$DMG_VOLUME_ICON_SOURCE" ]]; then
  ditto "$DMG_VOLUME_ICON_SOURCE" "$MOUNT_PATH/.VolumeIcon.icns"
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

sync
cleanup_mount
trap - EXIT

hdiutil convert "$DMG_RW_PATH" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
rm -f "$DMG_RW_PATH" "$DMG_BACKGROUND_SOURCE"

if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
  echo "==> Submitting DMG for notarization"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

  echo "==> Stapling DMG"
  xcrun stapler staple "$DMG_PATH"

  echo "==> Verifying DMG Gatekeeper assessment"
  SPCTL_OUTPUT=""
  if ! SPCTL_OUTPUT="$(spctl --assess --type open --verbose=4 "$DMG_PATH" 2>&1)"; then
    if printf '%s' "$SPCTL_OUTPUT" | grep -q "source=Insufficient Context"; then
      echo "Warning: Gatekeeper returned 'Insufficient Context' for this local artifact."
      echo "Notarization + stapling succeeded; continuing."
      printf '%s\n' "$SPCTL_OUTPUT"
    else
      printf '%s\n' "$SPCTL_OUTPUT" >&2
      echo "Gatekeeper assessment failed." >&2
      exit 1
    fi
  else
    printf '%s\n' "$SPCTL_OUTPUT"
  fi
else
  echo "==> Skipping notarization and stapling (--skip-notarize)"
  echo "==> Skipping Gatekeeper DMG assessment (--skip-notarize)"
fi

SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
echo
echo "Release artifact ready:"
echo "  DMG:    $DMG_PATH"
echo "  SHA256: $SHA256"
echo
echo "Next:"
echo "  1) Upload DMG to your website or GitHub Releases."
echo "  2) Update Homebrew cask SHA (orttaai.rb) if publishing via Homebrew."
echo "  3) Update Sparkle appcast if you are shipping in-app updates."
