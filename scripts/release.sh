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
# The mounted disk shows the app icon too.
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
rm -f dist/LocalFlow.dmg
hdiutil create -quiet -volname "LocalFlow" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$STAGE.rw.dmg"
MOUNT="$(mktemp -d)"
hdiutil attach -quiet -nobrowse -mountpoint "$MOUNT" "$STAGE.rw.dmg"
SetFile -a C "$MOUNT"
hdiutil detach -quiet "$MOUNT"
hdiutil convert -quiet "$STAGE.rw.dmg" -format UDZO -o dist/LocalFlow.dmg
rm -f "$STAGE.rw.dmg"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
echo "Built dist/LocalFlow.dmg (version $VERSION, $(du -h dist/LocalFlow.dmg | cut -f1))"
shasum -a 256 dist/LocalFlow.dmg
