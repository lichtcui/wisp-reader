#!/usr/bin/env python3
"""Idempotent OHOS patches for ONNX Runtime 1.24.4 (see ORT-OHOS-BUILD.md).

Usage: patches_ort_ohos.sh <ORT_SRC> [<ORT_BUILD_DIR>]
The third patch (cpuinfo) targets the FetchContent copy under the build dir,
so pass the build dir too; if omitted it is skipped (re-run after `cmake` config).
"""
import sys, os, pathlib

src = pathlib.Path(sys.argv[1]).resolve()
build = pathlib.Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else None


def sub(path, old, new, label, marker="__OHOS__"):
    p = pathlib.Path(path)
    if not p.exists():
        print(f"SKIP {label}: {path} missing"); return
    s = p.read_text()
    if marker in s:
        print(f"SKIP {label}: already patched"); return
    assert old in s, f"{label}: anchor not found in {path}"
    p.write_text(s.replace(old, new))
    print(f"OK   {label}")


# 1) build.py -- route the Android branch to the OHOS toolchain (+bf16 for MLAS).
sub(src / "tools/ci_build/build.py",
    '''        android_toolchain_cmake_path = os.path.join(args.android_ndk_path, "build", "cmake", "android.toolchain.cmake")
        cmake_args += [
            "-DANDROID_PLATFORM=android-" + str(args.android_api),
            "-DANDROID_ABI=" + str(args.android_abi),
            "-DANDROID_MIN_SDK=" + str(args.android_api),
            "-DANDROID_USE_LEGACY_TOOLCHAIN_FILE=false",
        ]''',
    '''        ohos_toolchain = os.environ.get("OHOS_TOOLCHAIN_FILE")
        if ohos_toolchain:
            android_toolchain_cmake_path = ohos_toolchain
            cmake_args += [
                "-DOHOS_ARCH=" + str(args.android_abi),
                "-DOHOS_PLATFORM_LEVEL=12",
                "-DCMAKE_C_FLAGS=-Wno-unused-command-line-argument",
                "-DCMAKE_CXX_FLAGS=-Wno-unused-command-line-argument -march=armv8.2-a+bf16",
            ]
        else:
            android_toolchain_cmake_path = os.path.join(args.android_ndk_path, "build", "cmake", "android.toolchain.cmake")
            cmake_args += [
                "-DANDROID_PLATFORM=android-" + str(args.android_api),
                "-DANDROID_ABI=" + str(args.android_abi),
                "-DANDROID_MIN_SDK=" + str(args.android_api),
                "-DANDROID_USE_LEGACY_TOOLCHAIN_FILE=false",
            ]''',
    "build.py", marker="OHOS_TOOLCHAIN_FILE")
sub(src / "tools/ci_build/build.py",
    '''        if not args.android_sdk_path:
            raise BuildError("android_sdk_path required to build for Android")''',
    '''        if not args.android_sdk_path and not os.environ.get("OHOS_TOOLCHAIN_FILE"):
            raise BuildError("android_sdk_path required to build for Android")''',
    "build.py sdk-path", marker="OHOS_TOOLCHAIN_FILE")

# 2) mlasi.h -- OHOS clang has no arm_bf16.h; bfloat16_t exists only under +bf16.
sub(src / "onnxruntime/core/mlas/lib/mlasi.h",
    '#if defined(__aarch64__) && defined(__linux__)\ntypedef size_t(MLASCALL MLAS_SBGEMM_FLOAT_KERNEL)(',
    '#if defined(__aarch64__) && defined(__linux__)\n#if !defined(__ARM_FEATURE_BF16) // P4 OHOS\ntypedef unsigned short bfloat16_t;\n#endif\ntypedef size_t(MLASCALL MLAS_SBGEMM_FLOAT_KERNEL)(',
    "mlasi.h", marker="__ARM_FEATURE_BF16")


# 3) env.cc -- musl(OHOS) has no pthread_setaffinity_np.
sub(src / "onnxruntime/core/platform/posix/env.cc",
    '#if !defined(__APPLE__) && !defined(__ANDROID__) && !defined(__wasm__) && !defined(_AIX)',
    '#if !defined(__APPLE__) && !defined(__ANDROID__) && !defined(__wasm__) && !defined(_AIX) && !defined(__OHOS__)',
    "env.cc", marker="!defined(__OHOS__)")

# 4) cpuinfo CMakeLists -- treat OHOS as Linux so the arm64 sources are compiled.
if build:
    cpuinfo = list(build.glob("**/_deps/pytorch_cpuinfo-src/CMakeLists.txt"))
    if cpuinfo:
        p = cpuinfo[0]
        s = p.read_text()
        if 'STREQUAL "OHOS"' in s:
            print("SKIP cpuinfo: already patched")
        else:
            s = s.replace(
                'ELSEIF(NOT CMAKE_SYSTEM_NAME MATCHES "^(Windows|WindowsStore|CYGWIN|MSYS|Darwin|Linux|Android|FreeBSD|Emscripten)$")',
                'ELSEIF(NOT CMAKE_SYSTEM_NAME MATCHES "^(Windows|WindowsStore|CYGWIN|MSYS|Darwin|Linux|Android|OHOS|FreeBSD|Emscripten)$")')
            s = s.replace('CMAKE_SYSTEM_NAME STREQUAL "Linux"',
                          '(CMAKE_SYSTEM_NAME STREQUAL "Linux" OR CMAKE_SYSTEM_NAME STREQUAL "OHOS")')
            s = s.replace('CMAKE_SYSTEM_NAME MATCHES "^(Linux|Android)$"',
                          'CMAKE_SYSTEM_NAME MATCHES "^(Linux|Android|OHOS)$"')
            s = s.replace('CMAKE_SYSTEM_NAME MATCHES "^(Android|Linux)$"',
                          'CMAKE_SYSTEM_NAME MATCHES "^(Android|Linux|OHOS)$"')
            p.write_text(s)
            print("OK   cpuinfo")
    else:
        print("SKIP cpuinfo: source not found under build dir")
