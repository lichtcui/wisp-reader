#!/bin/zsh
# P4: cross-compile ONNX Runtime 1.24.4 for OHOS arm64 (DevEco NDK 15.0.4).
# Toolchain recipe from microsoft/onnxruntime issue #20895 (community).
set -e
NATIVE=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native
export OHOS_TOOLCHAIN_FILE=$NATIVE/build/cmake/ohos.toolchain.cmake
export PATH=$NATIVE/build-tools/cmake/bin:$PATH
PY=/Users/lichtcui/Documents/playground/tts/gpt-sovits-onnx-rs/gpt-sovits-upstream/.venv/bin/python
SRC=$HOME/Documents/playground/tts/p4/src/onnxruntime-1.24.4
cd "$SRC"
exec $PY tools/ci_build/build.py \
  --build_dir=$HOME/Documents/playground/tts/p4/build/ort-ohos-arm64 \
  --config Release \
  --android --android_abi=arm64-v8a \
  --android_ndk_path=$NATIVE --android_sdk_path=$NATIVE \
  --skip_tests --skip_submodule_sync --cmake_generator=Ninja \
  --build_shared_lib \
  --parallel 4 \
  --cmake_deps_mirror_dir=$SRC/mirror \
  --compile_no_warning_as_error
