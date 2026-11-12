#!/usr/bin/env bash
# Installs the two background services LocalFlow uses, as login items that stay running:
#   com.localflow.whisper  whisper-server on 127.0.0.1:8178 with the model kept loaded
#   com.localflow.ollama   Ollama on 127.0.0.1:11434 with the cleanup model kept loaded
# Pass --caps-lock to also make Caps Lock the dictation key (it stops working as Caps Lock).
# Safe to run again: each service is replaced, not duplicated.
set -euo pipefail

CAPS_LOCK=0
for arg in "$@"; do
  case "$arg" in
    --caps-lock) CAPS_LOCK=1 ;;
    *) echo "Unknown option: $arg (only --caps-lock is supported)" >&2; exit 2 ;;
  esac
done

CLEANUP_MODEL="qwen2.5:7b"
SUPPORT_DIR="$HOME/Library/Application Support/LocalFlow"
WHISPER_DIR="$SUPPORT_DIR/whisper.cpp"
WHISPER_SERVER="$WHISPER_DIR/build/bin/whisper-server"
WHISPER_MODEL="$WHISPER_DIR/models/ggml-small.en.bin"
AGENTS="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"

[[ -x "$WHISPER_SERVER" ]] || { echo "whisper-server not found. Run ./scripts/install-whisper.sh first." >&2; exit 1; }
[[ -f "$WHISPER_MODEL" ]] || { echo "Whisper model not found at $WHISPER_MODEL. Run ./scripts/install-whisper.sh small.en first." >&2; exit 1; }
OLLAMA_BIN="$(command -v ollama || true)"
[[ -n "$OLLAMA_BIN" ]] || { echo "Ollama not found. Run: brew install ollama" >&2; exit 1; }
# Homebrew's own ollama service would hold the same port, and it unloads the model after 5 idle minutes.
if command -v brew >/dev/null && brew services list 2>/dev/null | grep -q '^ollama .*started'; then
  brew services stop ollama >/dev/null
fi

mkdir -p "$AGENTS"

install_agent() {
  local label="$1" plist="$AGENTS/$1.plist"
  cat > "$plist"
  plutil -lint "$plist" >/dev/null
  # Stopping is asynchronous: starting again before the old copy is gone fails with error 5.
  if launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then
    launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
    for _ in $(seq 1 20); do
      launchctl print "$DOMAIN/$label" >/dev/null 2>&1 || break
      sleep 0.5
    done
  fi
  launchctl bootstrap "$DOMAIN" "$plist"
  echo "Started $label"
}

install_agent com.localflow.whisper <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.localflow.whisper</string>
  <key>ProgramArguments</key>
  <array>
    <string>$WHISPER_SERVER</string>
    <string>-m</string><string>$WHISPER_MODEL</string>
    <string>--host</string><string>127.0.0.1</string>
    <string>--port</string><string>8178</string>
    <string>-l</string><string>en</string>
    <string>-nt</string>
    <string>-nf</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/tmp/localflow-whisper.log</string>
  <key>StandardOutPath</key><string>/tmp/localflow-whisper.log</string>
</dict>
</plist>
EOF

install_agent com.localflow.ollama <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.localflow.ollama</string>
  <key>ProgramArguments</key>
  <array><string>$OLLAMA_BIN</string><string>serve</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OLLAMA_KEEP_ALIVE</key><string>-1</string>
    <key>OLLAMA_FLASH_ATTENTION</key><string>1</string>
    <key>OLLAMA_KV_CACHE_TYPE</key><string>q8_0</string>
    <key>OLLAMA_HOST</key><string>127.0.0.1:11434</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/tmp/localflow-ollama.log</string>
</dict>
</plist>
EOF

echo "Waiting for Ollama..."
for _ in $(seq 1 30); do
  curl -s -m 2 -o /dev/null http://127.0.0.1:11434/ && break
  sleep 1
done
curl -s -m 2 -o /dev/null http://127.0.0.1:11434/ || { echo "Ollama did not start; see /tmp/localflow-ollama.log" >&2; exit 1; }
echo "Downloading the cleanup model ($CLEANUP_MODEL, about 4.7 GB) if it is not already here..."
OLLAMA_HOST=127.0.0.1:11434 "$OLLAMA_BIN" pull "$CLEANUP_MODEL"

# This route cleans up with Ollama, not the server bundled in the downloadable app.
mkdir -p "$SUPPORT_DIR"
/usr/bin/python3 -I - "$SUPPORT_DIR/settings.json" "$CLEANUP_MODEL" <<'PY'
import json, os, sys
path, model = sys.argv[1], sys.argv[2]
settings = json.load(open(path)) if os.path.exists(path) else {}
llm = {"enabled": True, "fallbackToRawTranscript": True, "apiKeyEnvironmentVariable": "LLM_API_KEY"}
llm.update(settings.get("llm", {}))
llm.update({"baseURL": "http://127.0.0.1:11434/v1", "model": model})
settings["llm"] = llm
json.dump(settings, open(path, "w"), indent=2, sort_keys=True)
os.chmod(path, 0o600)
PY

if [[ "$CAPS_LOCK" == 1 ]]; then
  # Caps Lock (HID usage 0x39) becomes F13 (0x68) on every keyboard, re-applied at each login.
  MAP='{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x700000068}]}'
  install_agent com.localflow.capslock-f13 <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.localflow.capslock-f13</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/hidutil</string><string>property</string><string>--set</string><string>$MAP</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
  mkdir -p "$SUPPORT_DIR"
  /usr/bin/python3 -I - "$SUPPORT_DIR/settings.json" <<'PY'
import json, os, sys
path = sys.argv[1]
settings = json.load(open(path)) if os.path.exists(path) else {}
settings["hotkey"] = {"key": "f13", "modifiers": []}
json.dump(settings, open(path, "w"), indent=2, sort_keys=True)
os.chmod(path, 0o600)
PY
  echo "Caps Lock is now the dictation key."
fi

# A running LocalFlow reads its settings at launch, so restart it to pick up any change.
if pgrep -x LocalFlow >/dev/null; then
  osascript -e 'quit app "LocalFlow"' >/dev/null 2>&1 || true
  sleep 2
  open -a LocalFlow
fi
echo "Background services ready."
