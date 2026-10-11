# P4 · 自建 ONNX Runtime 1.24.4 for OHOS arm64（交叉编译记录）

> 运行层新偏差/新坑同步追加进 `source-reader-tts/docs/tts-p0-report.md`（见 §14）。
> 本文件是仓库外的复现脚本与命令留档。

## 结论
- **ORT 版本 = 1.24.4**（不是 TTS-PLAN §4.5 写的 1.22.0）。理由：`ort` crate
  `2.0.0-rc.12` 只暴露到 `api-24`（`ort-sys` 的 `api-1x` feature 最高 `api-24`），
  而 **API 等级必须等于 ORT 内部 API 版本**，所以目标 ORT 只能是 **1.24.x** 这条线。
  1.22.0（API 22）会让 `ort` 的 `GetApi(24)` 返回 null → 运行时 panic。
- 交叉编译 **可以**用 DevEco NDK 的 `ohos.toolchain.cmake` 走通，但 ORT 上游对
  “Linux aarch64” 有 3 处硬编码假设需要 OHOS 补丁（见下）。

## 关键事实：OHOS target 的 rustc cfg
```
rustc --print cfg --target aarch64-unknown-linux-ohos
  target_arch="aarch64"  target_os="linux"  target_env="ohos"  target_family="unix"
```
两个后果：
1. `ctest`/`CMAKE_SYSTEM_PROCESSOR` 在 `ohos.toolchain.cmake` 下 = `aarch64`，
   → `onnxruntime_target_platform = aarch64`，ORT 的 Linux-aarch64 分支全部生效。
2. `ort` 的 `load-dynamic` 走 `target_os = "linux"` 分支 → dlopen `libonnxruntime.so`，
   **OHOS 天然支持**（HAP 原生库目录就是它）。不需要为 OHOS 特判。

## 工具链
```
NATIVE=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native
OHOS_TOOLCHAIN_FILE=$NATIVE/build/cmake/ohos.toolchain.cmake   # 替代 android.toolchain.cmake
OHOS_ARCH=arm64-v8a  OHOS_PLATFORM_LEVEL=12
CMAKE_MAKE_PROGRAM=$NATIVE/build-tools/cmake/bin/ninja
clang 15.0.4 (DevEco NDK)
```
- **BFLOAT16 gate 通过**：ORT `cmake/CMakeLists.txt:646` 的
  `check_cxx_compiler_flag(-march=armv8.2-a+bf16 HAS_ARM64_BFLOAT16)` 在 OHOS clang 下
  Success（冒烟已验）。fp16 同样 Success。
- **只采信安静窗口**：构建全程 `--parallel 4`（本机 4 核 8 线程，共享机器）。

## 对 ORT 源码的补丁（都是 OHOS/musl 的 libc 差异，已用 `#if` 收口）
1. `cmake/CMakeLists.txt` / `build.py`：Android 分支里注入 OHOS toolchain + `OHOS_ARCH`
   + `-march=armv8.2-a+bf16`（社区参数见 microsoft/onnxruntime#20895）。
   - `build.py` 增加 `OHOS_TOOLCHAIN_FILE` 环境变量开关；不设时行为与原来完全一致。
2. `onnxruntime/core/mlas/lib/mlasi.h`：OHOS clang **没有 `arm_bf16.h`**，
   `bfloat16_t` 仅在 TU 带 `-march=...+bf16` 时才存在。给不带该 flag 的 TU
   （sqnbitgemm kernel，只带 `+dotprod`）补一个 `typedef unsigned short bfloat16_t;`
   占位（`__ARM_FEATURE_BF16` 未定义时）。真实 SBGEMM kernel 仍带 `+bf16`。
3. `onnxruntime/core/platform/posix/env.cc`：musl(OHOS) **无 `pthread_setaffinity_np`**，
   在 `#if !defined(__APPLE__) && !defined(__ANDROID__) && ...` 里加 `!defined(__OHOS__)`
   （与 Android 同处理：跳过线程亲和性设置）。

## 复现命令
```bash
cd ~/Documents/playground/tts/p4
python3 -c "..."   # 见 build_ort_ohos.sh 内的 patch 步骤（build.py / mlasi.h / env.cc）
./build_ort_ohos.sh
# 产物：build/ort-ohos-arm64/Release/libonnxruntime.so
```

## 依赖镜像（绕开 GitHub 限速）
- 本机直连 GitHub 约 30 KB/s，`codeload` 亦被拖死；**系统代理 127.0.0.1:7897** 约 1.6 MB/s，
  `gh-proxy.com` 镜像约 14 MB/s。
- 做法：先把 `cmake/deps.txt` 里 41 个依赖预下到 `mirror/`（`mirror_deps.sh`），
  再让 `build.py --cmake_deps_mirror_dir` 走本地（**不要**用 `mirror/` 之外的路径，
  否则 `FetchContent` 仍会去 GitHub）。
- 源码用 codeload tarball 而非 `git clone`（clone 会在握手/HTTP2 层失败）；
  因此必须 `--skip_submodule_sync`（tarball 无 `.git`）。

## 版本光谱
| ORT | 内部 API | `ort` rc.12 可否 | 备注 |
|---|---|---|---|
| 1.16.3 | 16 | ❌ | 社区唯一 OHOS 预构建，仅冒烟 |
| 1.22.0 | 22 | ⚠ 需降 feature 到 api-22 | TTS-PLAN 原定；与 rc.12 默认不符 |
| **1.24.4** | 24 | ✅ | **P4 采用**，与 rc.12 默认 api-24 对齐 |
| 1.23.2 | 23 | ⚠ 需 api-23 | Mac 侧妥协（Intel macOS 无 ≥1.24 产物） |


## 实测结果（2026-09-28）
| 项 | 值 |
|---|---|
| 产物 | `build/ort-ohos-arm64/Release/libonnxruntime.so.1.24.4` |
| 体积 | **27 MB**（shared, Release, build-id sha1） |
| type | `ELF 64-bit LSB shared object, ARM aarch64` ✅ |
| SONAME | `libonnxruntime.so.1` |
| RUNPATH | `$ORIGIN` |
| NEEDED | `libc++_shared.so`, `libc.so`（musl） |
| 导出 | `OrtGetApiBase@@VERS_1.24.4` ✅ |
| 版本串 | `1.24.4`（二进制内） |
| 编译 | clang 15.0.4 (DevEco NDK) · Ninja · `--parallel 4` |
| 总耗时 | ≈ 2h40m（共享机器，4 核） |

## NAPI 侧（`gpt-sovits-tts-ohos`）实测
| 项 | 值 |
|---|---|
| 产物 | `libgpt_sovits_tts_ohos.so`，27 MB（stripped） |
| NEEDED | `libace_napi.z.so`（**无 libonnxruntime 的直接依赖** ⇒ `load-dynamic` 生效） |
| 导出 | `napi_register_module_v1` ✅ |
| OrtGetApiBase | **未定义符号**（运行时 dlopen 解析）✅ |
| 引擎 cross 编译 | `aarch64-unknown-linux-ohos` 全绿（onig_sys/tokenizers/jieba/rubato 等 C 依赖需 `CFLAGS_<target>` 带 `--sysroot`） |
