#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/LocalFlow.app"
CONTENTS_DIR="$APP_DIR/Contents"

cd "$PROJECT_DIR"
swift build -c release --product LocalFlow
BIN_DIR="$(swift build -c release --show-bin-path)"

if [[ -e "$APP_DIR" ]]; then
  APP_BACKUP="$PROJECT_DIR/dist/LocalFlow.previous.app"
  if [[ -e "$APP_BACKUP" ]]; then
    APP_BACKUP="$PROJECT_DIR/dist/LocalFlow.previous.$(date -u +%Y%m%d-%H%M%S).app"
  fi
  mv "$APP_DIR" "$APP_BACKUP"
fi

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
install -m 755 "$BIN_DIR/LocalFlow" "$CONTENTS_DIR/MacOS/LocalFlow"
install -m 644 "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
# A stable identity keeps macOS permissions (Accessibility, Microphone) across rebuilds;
# ad-hoc signing changes the app's identity every build. Certificate: scripts/localflow-signing-cert.pem.
SIGNING_IDENTITY="LocalFlow Local Signing"
if security find-identity -v -p codesigning | grep -q "\"$SIGNING_IDENTITY\""; then
  codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_DIR"
else
  echo "warning: '$SIGNING_IDENTITY' not in the keychain; signing ad-hoc (permissions reset on every rebuild)" >&2
  codesign --force --deep --sign - "$APP_DIR"
fi

echo "Built $APP_DIR"
