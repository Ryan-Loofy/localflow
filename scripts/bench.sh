#!/usr/bin/env bash
# Runs the cleanup prompt for every style against a real model. Not part of test.sh: it needs a model server.
# Usage: scripts/bench.sh [base URL] [model]   (defaults: Ollama on 127.0.0.1:11434, qwen2.5:7b)
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/.build/bench"
mkdir -p "$OUTPUT_DIR"
xcrun swiftc -o "$OUTPUT_DIR/localflow-bench" \
  "$PROJECT_DIR/Sources/LocalFlow/AppSettings.swift" \
  "$PROJECT_DIR/Sources/LocalFlow/TranscriptCleaner.swift" \
  "$PROJECT_DIR/Sources/LocalFlow/Personalization.swift" \
  "$PROJECT_DIR/Sources/LocalFlow/DebugLog.swift" \
  "$PROJECT_DIR/Tests/Bench/main.swift"
"$OUTPUT_DIR/localflow-bench" "$@"
