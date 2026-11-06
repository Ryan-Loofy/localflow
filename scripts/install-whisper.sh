#!/usr/bin/env bash
set -euo pipefail

MODEL_NAME="${1:-small.en}"
case "$MODEL_NAME" in
  small|small.en|medium|medium.en) ;;
  *)
    echo "Model must be one of: small, small.en, medium, medium.en" >&2
    exit 2
    ;;
esac

if ! command -v cmake >/dev/null 2>&1; then
  echo "cmake is required. Install it first (for example: brew install cmake)." >&2
  exit 1
fi

USER_HOME_DIR="$(dscl . -read "/Users/$USER" NFSHomeDirectory | awk '{print $2}')"
SUPPORT_DIR="${LOCALFLOW_SUPPORT_DIR:-$USER_HOME_DIR/Library/Application Support/LocalFlow}"
WHISPER_DIR="$SUPPORT_DIR/whisper.cpp"
mkdir -p "$SUPPORT_DIR"

if [[ ! -e "$WHISPER_DIR" ]]; then
  git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git "$WHISPER_DIR"
elif [[ ! -d "$WHISPER_DIR/.git" ]]; then
  echo "$WHISPER_DIR already exists but is not a whisper.cpp checkout." >&2
  exit 1
fi

cmake -S "$WHISPER_DIR" -B "$WHISPER_DIR/build" -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON
cmake --build "$WHISPER_DIR/build" --config Release -j "$(sysctl -n hw.logicalcpu)"
bash "$WHISPER_DIR/models/download-ggml-model.sh" "$MODEL_NAME" "$WHISPER_DIR/models"

echo "Installed whisper-cli at $WHISPER_DIR/build/bin/whisper-cli"
echo "Installed model at $WHISPER_DIR/models/ggml-$MODEL_NAME.bin"
if [[ "$MODEL_NAME" != "small.en" ]]; then
  echo "Update whisperModel in settings.json to the model path above."
fi
