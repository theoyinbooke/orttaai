#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM_ID="${CLOUDKIT_TEAM_ID:-3AL8T9L8FY}"
CONTAINER_ID="${CLOUDKIT_CONTAINER_ID:-iCloud.com.orttaai.Orttaai}"
ENVIRONMENT="${1:-development}"
SCHEMA_FILE="${SCHEMA_FILE:-$ROOT_DIR/CloudKit/OrttaaiCloudSchema.ckdb}"

if [[ "$ENVIRONMENT" != "development" ]]; then
  echo "Usage: $0 development" >&2
  echo "CloudKit schema files are imported into Development, then promoted with Deploy Schema Changes in CloudKit Console." >&2
  exit 64
fi

if ! xcrun cktool validate-schema \
  --team-id "$TEAM_ID" \
  --container-id "$CONTAINER_ID" \
  --environment "$ENVIRONMENT" \
  --file "$SCHEMA_FILE"; then
  cat >&2 <<'EOF'

Schema validation failed. If the error says no management token was found,
create a CloudKit management token in CloudKit Console for iCloud.com.orttaai.Orttaai,
then save it securely in Keychain with:

  xcrun cktool save-token --type management

EOF
  exit 65
fi

xcrun cktool import-schema \
  --team-id "$TEAM_ID" \
  --container-id "$CONTAINER_ID" \
  --environment "$ENVIRONMENT" \
  --validate \
  --file "$SCHEMA_FILE"

cat <<EOF

Imported $SCHEMA_FILE into the $ENVIRONMENT CloudKit schema.
To publish it for shipped apps, open CloudKit Console and use Deploy Schema Changes.
EOF
