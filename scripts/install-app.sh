#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$PROJECT_DIR/dist/LocalFlow.app"
DESTINATION_APP="/Applications/LocalFlow.app"

"$PROJECT_DIR/scripts/build-app.sh"
ditto "$SOURCE_APP" "$DESTINATION_APP"
codesign --verify --deep --strict "$DESTINATION_APP"

echo "Installed $DESTINATION_APP"
echo "Open it once, then grant the three permissions described in README.md."
