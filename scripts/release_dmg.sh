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
  --spm-packages-dir <path> SwiftPM packages/artifacts cache dir (default: .spm-local).
  --configuration <name>    Build configuration (default: Release).
  --app-name <name>         App bundle name (default: Orttaai).
  --team-id <id>            Apple Team ID (default: from Xcode build settings).
  --notary-profile <name>   notarytool keychain profile (default: orttaai-notary).
  --output-dir <path>       Artifact directory root (default: dist).
  --derived-data-path <path> Xcode build output directory.
  --dmg-theme <mode>        DMG background theme: auto|light|dark (default: auto).
  --no-whats-new            Release without a What's New card (a hotfix with nothing to tell).
  -h, --help                Show this help.

Prerequisites:
  - Developer ID Application cert installed locally.
  - notarytool profile stored:
      xcrun notarytool store-credentials "orttaai-notary" \
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
SPM_PACKAGES_DIR=".spm-local"
CONFIGURATION="Release"
APP_NAME="Orttaai"
NOTARY_PROFILE="orttaai-notary"
OUTPUT_DIR="dist"
DERIVED_DATA_PATH=""
VERSION_OVERRIDE=""
TEAM_ID_OVERRIDE=""
SKIP_NOTARIZE=0
SKIP_WHATS_NEW=0
DMG_THEME="auto"

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
    --spm-packages-dir)
      SPM_PACKAGES_DIR="${2:-}"
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
    --derived-data-path)
      DERIVED_DATA_PATH="${2:-}"
      shift 2
      ;;
    --dmg-theme)
      DMG_THEME="${2:-}"
      shift 2
      ;;
    --skip-notarize)
      echo "--skip-notarize is disabled for this project. Notarization is always required." >&2
      exit 1
      ;;
    --no-whats-new)
      SKIP_WHATS_NEW=1
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

case "$DMG_THEME" in
  auto|light|dark) ;;
  *)
    echo "Invalid --dmg-theme value: $DMG_THEME (expected auto, light, or dark)." >&2
    exit 1
    ;;
esac

require_cmd xcodebuild
require_cmd xcrun
require_cmd hdiutil
require_cmd python3
require_cmd codesign
require_cmd spctl
require_cmd security
require_cmd shasum
require_cmd ditto

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "Project not found: $PROJECT_PATH" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"

XCODEBUILD_COMMON_ARGS=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
)
if [[ -n "$DERIVED_DATA_PATH" ]]; then
  XCODEBUILD_COMMON_ARGS+=(-derivedDataPath "$DERIVED_DATA_PATH")
fi
if [[ -n "$SPM_PACKAGES_DIR" ]]; then
  XCODEBUILD_COMMON_ARGS+=(
    -clonedSourcePackagesDirPath "$SPM_PACKAGES_DIR"
  )
fi

BUILD_SETTINGS="$(xcodebuild "${XCODEBUILD_COMMON_ARGS[@]}" -showBuildSettings)"
MARKETING_VERSION="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/MARKETING_VERSION =/{print $2; exit}')"
TEAM_ID_FROM_XCODE="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/DEVELOPMENT_TEAM =/{print $2; exit}')"

VERSION="${VERSION_OVERRIDE:-$MARKETING_VERSION}"
TEAM_ID="${TEAM_ID_OVERRIDE:-$TEAM_ID_FROM_XCODE}"

if [[ -z "${VERSION:-}" ]]; then
  echo "Unable to resolve app version. Pass --version." >&2
  exit 1
fi

# Every release tells people what changed: 1-3 highlights for this version
# in WhatsNewCatalog.swift. See docs/whats-new.md.
WHATS_NEW_CATALOG="Orttaai/Core/WhatsNew/WhatsNewCatalog.swift"
if [[ "$SKIP_WHATS_NEW" -eq 0 ]] && ! grep -q "WhatsNewRelease(version: \"$VERSION\"" "$WHATS_NEW_CATALOG"; then
  echo "No What's New for $VERSION. Add 1-3 highlights to $WHATS_NEW_CATALOG (see docs/whats-new.md)," >&2
  echo "or pass --no-whats-new for a hotfix with nothing to tell." >&2
  exit 1
fi

if [[ -z "${TEAM_ID:-}" ]]; then
  echo "Unable to resolve Team ID. Pass --team-id." >&2
  exit 1
fi

echo "==> Notarization profile: $NOTARY_PROFILE"

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
EXPORT_OPTIONS_PLIST="$ARTIFACT_ROOT/ExportOptions.plist"
DMG_PATH="$ARTIFACT_ROOT/${APP_NAME}-${VERSION}.dmg"
APP_PATH="$EXPORT_PATH/${APP_NAME}.app"
ARCHIVED_APP_PATH="$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app"
DMG_BACKGROUND_SOURCE="$ARTIFACT_ROOT/dmg-background-source.png"
DMG_VOLUME_ICON_SOURCE=""

rm -rf "$ARTIFACT_ROOT"
mkdir -p "$ARTIFACT_ROOT"

if [[ -n "$SPM_PACKAGES_DIR" ]]; then
  echo "==> Resolving Swift packages (cache: $SPM_PACKAGES_DIR)"
else
  echo "==> Resolving Swift packages"
fi
xcodebuild -resolvePackageDependencies "${XCODEBUILD_COMMON_ARGS[@]}"

echo "==> Archiving app ($SCHEME, $CONFIGURATION)"
# Keep archive signing automatic to avoid forcing Developer ID onto SwiftPM dependency targets.
# Developer ID signing is applied after archive by re-signing the archived .app bundle.
xcodebuild archive \
  "${XCODEBUILD_COMMON_ARGS[@]}" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  SKIP_INSTALL=NO \
  -allowProvisioningUpdates

if [[ ! -d "$ARCHIVED_APP_PATH" ]]; then
  echo "Archive failed: app bundle not found at $ARCHIVED_APP_PATH" >&2
  exit 1
fi

# Xcode 27 can archive SwiftPM object files under Products/Users, which makes
# Developer ID export treat the archive as having multiple root items.
rm -rf "$ARCHIVE_PATH/Products/Users"

# Some Xcode 27 archive runs omit ApplicationProperties even when the app
# bundle is present. Developer ID export uses this metadata to classify the
# archive, so restore it from the archived app when needed.
if ! /usr/libexec/PlistBuddy -c 'Print :ApplicationProperties' "$ARCHIVE_PATH/Info.plist" >/dev/null 2>&1; then
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ARCHIVED_APP_PATH/Contents/Info.plist")"
  SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ARCHIVED_APP_PATH/Contents/Info.plist")"
  BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ARCHIVED_APP_PATH/Contents/Info.plist")"
  CODESIGN_DETAILS="$(codesign -dvvv "$ARCHIVED_APP_PATH" 2>&1)"
  ARCHIVE_SIGNING_IDENTITY="$(awk -F= '/^Authority=/{print $2; exit}' <<< "$CODESIGN_DETAILS")"
  /usr/libexec/PlistBuddy -c 'Add :ApplicationProperties dict' "$ARCHIVE_PATH/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :ApplicationProperties:ApplicationPath string Applications/$APP_NAME.app" "$ARCHIVE_PATH/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :ApplicationProperties:Architectures array' "$ARCHIVE_PATH/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :ApplicationProperties:Architectures:0 string x86_64' "$ARCHIVE_PATH/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :ApplicationProperties:Architectures:1 string arm64' "$ARCHIVE_PATH/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :ApplicationProperties:CFBundleIdentifier string $BUNDLE_ID" "$ARCHIVE_PATH/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :ApplicationProperties:CFBundleShortVersionString string $SHORT_VERSION" "$ARCHIVE_PATH/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :ApplicationProperties:CFBundleVersion string $BUNDLE_VERSION" "$ARCHIVE_PATH/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :ApplicationProperties:SigningIdentity string $ARCHIVE_SIGNING_IDENTITY" "$ARCHIVE_PATH/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :ApplicationProperties:Team string $TEAM_ID" "$ARCHIVE_PATH/Info.plist"
fi

echo "==> Exporting app for Developer ID distribution"
plutil -create xml1 "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c 'Add :method string developer-id' "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c 'Add :signingStyle string automatic' "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c 'Add :signingCertificate string Developer ID Application' "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c 'Add :destination string export' "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c 'Add :stripSwiftSymbols bool true' "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c 'Add :iCloudContainerEnvironment string Production' "$EXPORT_OPTIONS_PLIST"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
  -allowProvisioningUpdates

if [[ ! -d "$APP_PATH" ]]; then
  echo "Export failed: app bundle not found at $APP_PATH" >&2
  exit 1
fi

if [[ -f "Orttaai/Resources/dmg-volume-icon.icns" ]]; then
  DMG_VOLUME_ICON_SOURCE="Orttaai/Resources/dmg-volume-icon.icns"
elif [[ -f "$APP_PATH/Contents/Resources/AppIcon.icns" ]]; then
  DMG_VOLUME_ICON_SOURCE="$APP_PATH/Contents/Resources/AppIcon.icns"
fi

echo "==> Verifying app signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "==> Skipping Gatekeeper app assessment pre-notarization"

echo "==> Creating DMG"
# Optional polished Finder background.
DMG_BACKGROUND=""
if [[ -f "Orttaai/Resources/dmg-background.png" ]]; then
  DMG_BACKGROUND="Orttaai/Resources/dmg-background.png"
elif [[ -f "scripts/generate_dmg_background.swift" ]]; then
  if ! swift "scripts/generate_dmg_background.swift" \
    --output "$DMG_BACKGROUND_SOURCE" \
    --app-path "$APP_PATH" \
    --app-name "$APP_NAME" \
    --theme "$DMG_THEME"; then
    echo "Warning: could not generate DMG background; continuing without a custom background."
  elif [[ -f "$DMG_BACKGROUND_SOURCE" ]]; then
    DMG_BACKGROUND="$DMG_BACKGROUND_SOURCE"
  fi
fi

scripts/make_dmg.sh \
  --app "$APP_PATH" \
  --output "$DMG_PATH" \
  --volume-name "$APP_NAME" \
  --work-dir "$ARTIFACT_ROOT" \
  ${DMG_BACKGROUND:+--background "$DMG_BACKGROUND"} \
  ${DMG_VOLUME_ICON_SOURCE:+--volume-icon "$DMG_VOLUME_ICON_SOURCE"}
rm -f "$DMG_BACKGROUND_SOURCE"

echo "==> Signing DMG"
codesign --sign "$DEVELOPER_ID_SHA" --timestamp "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

# Clean up intermediate exported .app bundles that macOS Launch Services and
# TCC will index, creating duplicate Spotlight entries and stale permission records.
# Preserve the release archive for distribution diagnostics and recovery.
echo "==> Cleaning intermediate app bundles (prevents stale Spotlight/TCC entries)"
rm -rf "$EXPORT_PATH"

if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
  echo "==> Submitting DMG for notarization"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

  echo "==> Stapling DMG"
  xcrun stapler staple "$DMG_PATH"

  echo "==> Verifying DMG Gatekeeper assessment"
  SPCTL_OUTPUT=""
  if ! SPCTL_OUTPUT="$(spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH" 2>&1)"; then
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
echo "  3) Publish the GitHub release."
echo "  4) Sparkle appcast will auto-publish from GitHub Actions once the release is published."
