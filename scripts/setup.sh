#!/usr/bin/env bash
# One-command LocalFlow setup. Run from the repo folder:  ./scripts/setup.sh
# Add --caps-lock to make Caps Lock the dictation key instead of fn.
# Safe to run again after a failure or an update.
set -euo pipefail
cd "$(dirname "$0")/.."

say_step() { printf '\n==> %s\n' "$1"; }

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "LocalFlow needs an Apple Silicon Mac (M1 or later)." >&2
  exit 1
fi
MEM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
if (( MEM_GB < 16 )); then
  echo "Note: this Mac has ${MEM_GB} GB of memory. LocalFlow works best with 16 GB or more; it may be slow."
fi

say_step "Checking Apple's command line tools"
if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install || true
  echo "A window opened to install Apple's command line tools. Finish it (about 5 to 10 minutes), then run this command again."
  exit 1
fi

say_step "Checking Homebrew"
if ! command -v brew >/dev/null 2>&1; then
  [[ -x /opt/homebrew/bin/brew ]] || /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

say_step "Installing cmake and Ollama"
for pkg in cmake ollama; do
  brew list --formula "$pkg" >/dev/null 2>&1 || brew install "$pkg"
done

say_step "Building whisper.cpp and downloading the speech model (about 470 MB)"
WHISPER_DIR="$HOME/Library/Application Support/LocalFlow/whisper.cpp"
if [[ -x "$WHISPER_DIR/build/bin/whisper-server" && -f "$WHISPER_DIR/models/ggml-small.en.bin" ]]; then
  echo "Already installed."
else
  ./scripts/install-whisper.sh small.en
fi

say_step "Testing and installing the LocalFlow app"
./scripts/test.sh
./scripts/install-app.sh

say_step "Starting the background services"
./scripts/install-services.sh "$@"

say_step "Opening LocalFlow"
open /Applications/LocalFlow.app
sleep 2
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

cat <<'EOF'

Almost done. macOS needs you to allow LocalFlow:
  1. Allow the Microphone prompt if one appears.
  2. In the Accessibility window that just opened, switch LocalFlow on
     (if it is missing, click + and choose /Applications/LocalFlow.app).
  3. Do the same under Input Monitoring.
LocalFlow starts listening a few seconds after Accessibility is on; no restart needed.

To dictate: tap your dictation key, talk, then tap it again or press Enter.
EOF
