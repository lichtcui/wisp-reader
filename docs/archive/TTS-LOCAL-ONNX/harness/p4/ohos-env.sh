# P4: reusable OHOS arm64 cross-compile environment for Rust (+ cc-rs C deps).
NATIVE=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native
export OHOS_NDK_HOME=$NATIVE
export TARGET=aarch64-unknown-linux-ohos
SYSROOT=$NATIVE/sysroot
CC=$NATIVE/llvm/bin/aarch64-unknown-linux-ohos-clang
CXX=$NATIVE/llvm/bin/aarch64-unknown-linux-ohos-clang++
AR=$NATIVE/llvm/bin/llvm-ar
export CC_aarch64_unknown_linux_ohos=$CC
export CXX_aarch64_unknown_linux_ohos=$CXX
export AR_aarch64_unknown_linux_ohos=$AR
export CFLAGS_aarch64_unknown_linux_ohos="--sysroot=$SYSROOT -fPIC"
export CXXFLAGS_aarch64_unknown_linux_ohos="--sysroot=$SYSROOT -fPIC"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER=$CC
export RUSTFLAGS="-C link-arg=--sysroot=$SYSROOT -C link-arg=-Wl,-rpath,\$ORIGIN"
