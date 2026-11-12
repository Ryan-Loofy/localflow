#!/usr/bin/env bash
# Builds the downloadable LocalFlow.dmg: the app with both servers inside, signed ad hoc.
# Usage: ./scripts/release.sh   (output: dist/LocalFlow.dmg)
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
./scripts/test.sh
LOCALFLOW_SIGN=adhoc LOCALFLOW_REQUIRE_SERVERS=1 ./scripts/build-app.sh
codesign --verify --strict "dist/LocalFlow.app"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto dist/LocalFlow.app "$STAGE/LocalFlow.app"
ln -s /Applications "$STAGE/Applications"
rm -f dist/LocalFlow.dmg
hdiutil create -quiet -volname "LocalFlow" -srcfolder "$STAGE" -fs HFS+ -format UDZO dist/LocalFlow.dmg
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
echo "Built dist/LocalFlow.dmg (version $VERSION, $(du -h dist/LocalFlow.dmg | cut -f1))"
shasum -a 256 dist/LocalFlow.dmg
