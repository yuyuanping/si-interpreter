#!/bin/sh
# Builds llama.cpp for iOS (device, arm64) as static libs and stages them into
# ios/llama-libs/ for Xcode to link. Run once before "xcodegen generate" and
# re-run after the vendored llama.cpp changes.
#
#   brew install cmake && ./scripts/build-llama.sh
#
# CPU-only build (Accelerate is on, Metal off for v1): the GGUF quantised decoders
# hit ~20-40 tok/s on comparable phone CPUs without a Metal lib bundle in the way.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
LLAMA="$ROOT/../app/src/main/cpp/llama.cpp"
BUILD="$LLAMA/build-ios"
OUT="$ROOT/llama-libs"

echo "== configuring llama.cpp for iOS device (arm64)"
cmake -S "$LLAMA" -B "$BUILD" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=OFF \
  -DGGML_BLAS=OFF \
  -DGGML_OPENMP=OFF \
  -DGGML_NATIVE=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TOOLS=OFF \
  -DLLAMA_BUILD_SERVER=OFF \
  -DLLAMA_BUILD_APP=OFF

echo "== building"
cmake --build "$BUILD" -j "$(sysctl -n hw.ncpu)"

echo "== staging static libs"
mkdir -p "$OUT"
rm -f "$OUT"/*.a
find "$BUILD" -name "*.a" -maxdepth 4 -exec cp {} "$OUT/" \;
ls -la "$OUT"

echo "== done. Expected in llama-libs/: libllama.a libggml.a libggml-base.a libggml-cpu.a"
echo "   (if the names differ, update the dependencies list in project.yml)"
