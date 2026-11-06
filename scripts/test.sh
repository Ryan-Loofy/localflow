#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/.build/self-test"
mkdir -p "$OUTPUT_DIR"

xcrun swiftc \
  "$PROJECT_DIR/Sources/LocalFlow/DictationStateMachine.swift" \
  "$PROJECT_DIR/Sources/LocalFlow/AppSettings.swift" \
  "$PROJECT_DIR/Sources/LocalFlow/AudioRecorder.swift" \
  "$PROJECT_DIR/Sources/LocalFlow/HotkeyMonitor.swift" \
  "$PROJECT_DIR/Sources/LocalFlow/TranscriptCleaner.swift" \
  "$PROJECT_DIR/Sources/LocalFlow/DebugLog.swift" \
  "$PROJECT_DIR/Tests/SelfTest/main.swift" \
  -o "$OUTPUT_DIR/localflow-self-test"

"$OUTPUT_DIR/localflow-self-test"
