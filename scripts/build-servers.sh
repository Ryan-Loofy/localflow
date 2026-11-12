#!/bin/bash
# Builds single-file, Metal-embedded whisper-server and llama-server for arm64, macOS 13+.
# Run from anywhere: ./scripts/build-servers.sh  (output: vendor/bin, which build-app.sh bundles)
set -euo pipefail
mkdir -p "$(dirname "$0")/../vendor"
cd "$(dirname "$0")/../vendor"
WT="${WHISPER_TAG:-v1.9.5}"   # whisper.cpp release
LT="${LLAMA_TAG:-b12321}"    # llama.cpp release
echo "whisper.cpp $WT  llama.cpp $LT"
[[ -d whisper.cpp ]] || git clone -q --depth 1 --branch "$WT" https://github.com/ggml-org/whisper.cpp
[[ -d llama.cpp ]] || git clone -q --depth 1 --branch "$LT" https://github.com/ggml-org/llama.cpp
COMMON=(-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON
        -DGGML_NATIVE=OFF -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0)
cmake -S whisper.cpp -B whisper.cpp/build-static "${COMMON[@]}" -DWHISPER_BUILD_TESTS=OFF > whisper-cmake.log
cmake --build whisper.cpp/build-static --config Release -j "$(sysctl -n hw.logicalcpu)" --target whisper-server > whisper-build.log
cmake -S llama.cpp -B llama.cpp/build-static "${COMMON[@]}" -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF > llama-cmake.log
cmake --build llama.cpp/build-static --config Release -j "$(sysctl -n hw.logicalcpu)" --target llama-server > llama-build.log
mkdir -p bin
cp whisper.cpp/build-static/bin/whisper-server llama.cpp/build-static/bin/llama-server bin/
echo "$WT" > bin/whisper.version; echo "$LT" > bin/llama.version
otool -L bin/whisper-server bin/llama-server
ls -la bin
