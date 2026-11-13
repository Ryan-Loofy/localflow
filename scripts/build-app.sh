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
install -m 644 "$PROJECT_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
# The speech and cleanup servers ship inside the app (built by scripts/build-servers.sh).
VENDOR_BIN="$PROJECT_DIR/vendor/bin"
if [[ -x "$VENDOR_BIN/whisper-server" && -x "$VENDOR_BIN/llama-server" ]]; then
  install -m 755 "$VENDOR_BIN/whisper-server" "$VENDOR_BIN/llama-server" "$CONTENTS_DIR/MacOS/"
elif [[ "${LOCALFLOW_REQUIRE_SERVERS:-0}" == 1 ]]; then
  echo "vendor/bin is missing whisper-server or llama-server: run ./scripts/build-servers.sh" >&2
  exit 1
fi
# A stable identity keeps macOS permissions (Accessibility, Microphone) across rebuilds;
# ad-hoc signing changes the app's identity every build. Certificate: scripts/localflow-signing-cert.pem.
# LOCALFLOW_SIGN=adhoc forces ad-hoc signing, which is what a downloadable release uses.
SIGNING_IDENTITY="LocalFlow Local Signing"
if [[ "${LOCALFLOW_SIGN:-}" != adhoc ]] && security find-identity -v -p codesigning | grep -q "\"$SIGNING_IDENTITY\""; then
  SIGN_AS="$SIGNING_IDENTITY"
else
  [[ "${LOCALFLOW_SIGN:-}" == adhoc ]] || echo "warning: '$SIGNING_IDENTITY' not in the keychain; signing ad-hoc (permissions reset on every rebuild)" >&2
  SIGN_AS="-"
fi
# Sign the nested servers first, then the app around them.
for helper in "$CONTENTS_DIR/MacOS/whisper-server" "$CONTENTS_DIR/MacOS/llama-server"; do
  [[ -e "$helper" ]] && codesign --force --sign "$SIGN_AS" "$helper"
done
codesign --force --sign "$SIGN_AS" "$APP_DIR"

echo "Built $APP_DIR"
