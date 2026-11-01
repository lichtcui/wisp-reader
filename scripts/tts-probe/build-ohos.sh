#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk}"
NDK="${OHOS_NDK_HOME:-$DEVECO_SDK_HOME/default/openharmony}"
if [[ ! -x "$NDK/llvm/bin/aarch64-unknown-linux-ohos-clang++" && \
      -x "$NDK/native/llvm/bin/aarch64-unknown-linux-ohos-clang++" ]]; then
  NDK="$NDK/native"
fi
SHERPA_VERSION="${SHERPA_VERSION:-1.13.8}"
CACHE_ROOT="${TTS_PROBE_CACHE:-$HOME/.cache/source-reader/tts-probe}"
SHERPA_ROOT="${SHERPA_ROOT:-$CACHE_ROOT/sherpa-onnx-v${SHERPA_VERSION}-ohos-arm64-v8a}"
OUT="$ROOT/build/tts-probe"
APP_TEMPLATE="$ROOT/scripts/tts-probe/app"
APP_BUILD="$OUT/app"
APP_LIBS="$APP_BUILD/entry/libs/arm64-v8a"

CXX="${OHOS_CXX:-$NDK/llvm/bin/aarch64-unknown-linux-ohos-clang++}"
SYSROOT="${OHOS_SYSROOT:-$NDK/sysroot}"
LIBCXX="$NDK/llvm/lib/aarch64-linux-ohos/libc++_shared.so"

if [[ ! -x "$CXX" ]]; then
  echo "OHOS C++ compiler not found: $CXX" >&2
  exit 1
fi

if [[ ! -f "$SHERPA_ROOT/include/sherpa-onnx/c-api/c-api.h" ]]; then
  archive="$CACHE_ROOT/sherpa-onnx-v${SHERPA_VERSION}-ohos-arm64-v8a.tar.bz2"
  url="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${SHERPA_VERSION}/sherpa-onnx-v${SHERPA_VERSION}-ohos-arm64-v8a.tar.bz2"
  mkdir -p "$CACHE_ROOT"
  if [[ ! -s "$archive" ]]; then
    echo "Downloading sherpa-onnx OHOS runtime v${SHERPA_VERSION}..." >&2
    curl -fL --retry 5 --retry-delay 3 --retry-all-errors \
      --connect-timeout 20 --continue-at - \
      "$url" -o "$archive"
  fi
  stage="$(mktemp -d "$CACHE_ROOT/sherpa-extract.XXXXXX")"
  trap 'rm -rf "$stage"' EXIT
  tar -xjf "$archive" -C "$stage"
  src="$(find "$stage" -path '*/include/sherpa-onnx/c-api/c-api.h' -print -quit | sed 's#/include/sherpa-onnx/c-api/c-api.h##')"
  if [[ -z "$src" ]]; then
    echo "sherpa-onnx archive has no C API headers: $archive" >&2
    exit 1
  fi
  rm -rf "$SHERPA_ROOT"
  mkdir -p "$SHERPA_ROOT"
  cp -R "$src"/. "$SHERPA_ROOT"/
fi

for lib in libsherpa-onnx-c-api.so libonnxruntime.so; do
  if [[ ! -f "$SHERPA_ROOT/lib/$lib" ]]; then
    echo "Missing $SHERPA_ROOT/lib/$lib" >&2
    exit 1
  fi
done
if [[ ! -f "$LIBCXX" ]]; then
  echo "Missing OHOS libc++_shared.so: $LIBCXX" >&2
  exit 1
fi

mkdir -p "$OUT/bin" "$OUT/lib"
"$CXX" --sysroot="$SYSROOT" -std=c++17 -O2 -fPIC -Wall -Wextra -Werror \
  -I"$SHERPA_ROOT/include" \
  "$ROOT/scripts/tts-probe/tts_probe.cc" \
  -L"$SHERPA_ROOT/lib" \
  '-Wl,-rpath,$ORIGIN/lib' \
  -lsherpa-onnx-c-api -lonnxruntime \
  -o "$OUT/bin/tts_probe"

"$CXX" --sysroot="$SYSROOT" -std=c++17 -O2 -fPIC -shared \
  -Wall -Wextra -Werror \
  -I"$SHERPA_ROOT/include" -I"$SYSROOT/usr/include" \
  "$ROOT/scripts/tts-probe/tts_probe_napi.cc" \
  -L"$SHERPA_ROOT/lib" \
  '-Wl,-rpath,$ORIGIN' -Wl,-soname,libttsprobe.so \
  -lsherpa-onnx-c-api -lonnxruntime -lace_napi.z \
  -o "$OUT/lib/libttsprobe.so"

cp "$SHERPA_ROOT/lib/libsherpa-onnx-c-api.so" "$OUT/lib/"
cp "$SHERPA_ROOT/lib/libonnxruntime.so" "$OUT/lib/"
cp "$LIBCXX" "$OUT/lib/libc++_shared.so"

rsync -a --delete "$APP_TEMPLATE/" "$APP_BUILD/"
mkdir -p "$APP_LIBS"
cp "$OUT/lib/"*.so "$APP_LIBS/"

OHPM="${OHPM:-$DEVECO_SDK_HOME/../tools/ohpm/bin/ohpm}"
HVIGORW="${HVIGORW:-$DEVECO_SDK_HOME/../tools/hvigor/bin/hvigorw}"
if [[ ! -x "$OHPM" || ! -x "$HVIGORW" ]]; then
  echo "DevEco ohpm/hvigorw not found under $DEVECO_SDK_HOME/.." >&2
  exit 1
fi
(
  cd "$APP_BUILD"
  "$OHPM" install
  "$HVIGORW" assembleHap --mode module -p product=default \
    -p buildMode=debug --no-daemon
)

READELF="$NDK/llvm/bin/llvm-readelf"
if [[ -x "$READELF" ]]; then
  "$READELF" -d "$OUT/bin/tts_probe" > "$OUT/tts_probe.readelf.txt"
  "$READELF" -d "$OUT/lib/libttsprobe.so" > "$OUT/libttsprobe.readelf.txt"
fi

echo "Built: $OUT/bin/tts_probe"
echo "Built: $OUT/lib/libttsprobe.so"
echo "Prepared probe app: $APP_BUILD"
file "$OUT/bin/tts_probe" || true
