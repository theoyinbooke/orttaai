#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Generate/update Sparkle appcast.xml for Orttaai.

Usage:
  scripts/update_appcast.sh --version <x.y.z> [options]

Options:
  --version <x.y.z>         Release version used in GitHub download URL (required unless --dmg filename includes version).
  --dmg <path>              DMG artifact path (default: dist/<version>/Orttaai-<version>.dmg).
  --repo <owner/repo>       GitHub repository slug (default: theoyinbooke/orttaai).
  --output <path>           Appcast output path (default: Orttaai/Resources/appcast.xml).
  --sparkle-bin-dir <path>  Directory containing generate_appcast/sign_update.
  --ed-key-file <path>      Private EdDSA key file exported from Sparkle generate_keys -x.
  -h, --help                Show this help.
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

resolve_sparkle_tool() {
  local tool_name="$1"
  local explicit_bin_dir="${2:-}"

  if [[ -n "$explicit_bin_dir" ]]; then
    local explicit_path="$explicit_bin_dir/$tool_name"
    if [[ -x "$explicit_path" ]]; then
      printf '%s\n' "$explicit_path"
      return 0
    fi
    echo "Sparkle tool not executable: $explicit_path" >&2
    exit 1
  fi

  if command -v "$tool_name" >/dev/null 2>&1; then
    command -v "$tool_name"
    return 0
  fi

  local derived_data="${HOME}/Library/Developer/Xcode/DerivedData"
  if [[ -d "$derived_data" ]]; then
    local found_path=""
    found_path="$(find "$derived_data" -type f -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin/$tool_name" -print -quit 2>/dev/null || true)"
    if [[ -n "$found_path" && -x "$found_path" ]]; then
      printf '%s\n' "$found_path"
      return 0
    fi
  fi

  echo "Unable to find Sparkle tool '$tool_name'. Build once in Xcode or pass --sparkle-bin-dir." >&2
  exit 1
}

VERSION=""
DMG_PATH=""
REPO_SLUG="theoyinbooke/orttaai"
OUTPUT_PATH="Orttaai/Resources/appcast.xml"
SPARKLE_BIN_DIR=""
ED_KEY_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --dmg)
      DMG_PATH="${2:-}"
      shift 2
      ;;
    --repo)
      REPO_SLUG="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="${2:-}"
      shift 2
      ;;
    --sparkle-bin-dir)
      SPARKLE_BIN_DIR="${2:-}"
      shift 2
      ;;
    --ed-key-file)
      ED_KEY_FILE="${2:-}"
      shift 2
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

require_cmd python3
require_cmd find
require_cmd sed

if [[ -z "$VERSION" && -n "$DMG_PATH" ]]; then
  if [[ "$DMG_PATH" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    VERSION="${BASH_REMATCH[1]}"
  fi
fi

if [[ -z "$VERSION" ]]; then
  echo "Release version is required. Pass --version <x.y.z>." >&2
  exit 1
fi

if [[ -z "$DMG_PATH" ]]; then
  DMG_PATH="dist/$VERSION/Orttaai-$VERSION.dmg"
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

GENERATE_APPCAST_BIN="$(resolve_sparkle_tool generate_appcast "$SPARKLE_BIN_DIR")"
SIGN_UPDATE_BIN="$(resolve_sparkle_tool sign_update "$SPARKLE_BIN_DIR")"

if [[ -n "$ED_KEY_FILE" && ! -f "$ED_KEY_FILE" ]]; then
  echo "EdDSA key file not found: $ED_KEY_FILE" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
SIGNATURE_MAP="$WORK_DIR/signatures.tsv"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

cp "$DMG_PATH" "$WORK_DIR/"

if [[ -f "$OUTPUT_PATH" ]]; then
  cp "$OUTPUT_PATH" "$WORK_DIR/appcast.xml"
fi

DOWNLOAD_URL_PREFIX="https://github.com/$REPO_SLUG/releases/download/v$VERSION/"
RELEASE_NOTES_URL_PREFIX="https://github.com/$REPO_SLUG/releases/tag/v"
PROJECT_LINK="https://github.com/$REPO_SLUG"

generate_appcast_args=(
  --download-url-prefix "$DOWNLOAD_URL_PREFIX"
  --release-notes-url-prefix "$RELEASE_NOTES_URL_PREFIX"
  --link "$PROJECT_LINK"
)
if [[ -n "$ED_KEY_FILE" ]]; then
  generate_appcast_args+=(--ed-key-file "$ED_KEY_FILE")
fi
generate_appcast_args+=("$WORK_DIR")

"$GENERATE_APPCAST_BIN" "${generate_appcast_args[@]}"

: > "$SIGNATURE_MAP"
while IFS= read -r -d '' archive_path; do
  sign_update_args=()
  if [[ -n "$ED_KEY_FILE" ]]; then
    sign_update_args+=(--ed-key-file "$ED_KEY_FILE")
  fi
  sign_update_args+=("$archive_path")
  signature_line="$("$SIGN_UPDATE_BIN" "${sign_update_args[@]}")"
  ed_signature="$(printf '%s\n' "$signature_line" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
  content_length="$(printf '%s\n' "$signature_line" | sed -n 's/.*length="\([0-9][0-9]*\)".*/\1/p')"
  if [[ -n "$ed_signature" && -n "$content_length" ]]; then
    printf '%s\t%s\t%s\n' "$(basename "$archive_path")" "$ed_signature" "$content_length" >> "$SIGNATURE_MAP"
  fi
done < <(find "$WORK_DIR" -maxdepth 1 -type f \( -name '*.dmg' -o -name '*.zip' -o -name '*.tar' -o -name '*.tgz' -o -name '*.tbz' -o -name '*.tar.gz' -o -name '*.tar.bz2' \) -print0)

python3 - "$WORK_DIR/appcast.xml" "$SIGNATURE_MAP" <<'PY'
import sys
import xml.etree.ElementTree as ET
from urllib.parse import urlparse, unquote

appcast_path, signature_map_path = sys.argv[1], sys.argv[2]
sparkle_ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
dc_ns = "http://purl.org/dc/elements/1.1/"
ET.register_namespace("sparkle", sparkle_ns)
ET.register_namespace("dc", dc_ns)

signatures = {}
with open(signature_map_path, "r", encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        basename, signature, length = line.split("\t")
        signatures[basename] = (signature, length)

tree = ET.parse(appcast_path)
root = tree.getroot()

for enclosure in root.findall(".//enclosure"):
    url = enclosure.get("url")
    if not url:
        continue
    basename = unquote(urlparse(url).path.rsplit("/", 1)[-1])
    if basename in signatures:
        signature, length = signatures[basename]
        enclosure.set(f"{{{sparkle_ns}}}edSignature", signature)
        enclosure.set("length", length)

if hasattr(ET, "indent"):
    ET.indent(tree, space="    ")
tree.write(appcast_path, encoding="utf-8", xml_declaration=True)
PY

mkdir -p "$(dirname "$OUTPUT_PATH")"
cp "$WORK_DIR/appcast.xml" "$OUTPUT_PATH"

echo "Updated Sparkle appcast:"
echo "  Output:  $OUTPUT_PATH"
echo "  Version: $VERSION"
echo "  DMG:     $DMG_PATH"
