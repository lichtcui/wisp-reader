# P4 工作区 — 端侧 TTS 真机（ORT 交叉编译 + NAPI + 内存/长稳）

权威方案：`../../source-reader-tts/TTS-PLAN.md` §9「P4 真机」；运行层偏差追加到
`source-reader-tts/docs/tts-p0-report.md` §14。本目录是仓库外的构建/产物区。

## 状态
| 步骤 | 状态 |
|---|---|
| 自建 ORT 1.24.4 for OHOS arm64 | ✅ **完成**（27 MB `.so`，aarch64 ELF） |
| NAPI 三函数 `.so` 交叉编译 | ✅ **完成**（`libgpt_sovits_tts_ohos.so`，27 MB） |
| 引擎 `aarch64-unknown-linux-ohos` 交叉编译 | ✅ 完成（全依赖通过） |
| P3 定稿分片（≤30 字）进引擎 | ✅ `seg::chunk_for_limit` + 单测对齐 harness |
| 真机加载冒烟 / RTF / 内存 / 长稳 | ✅ **完成**（HBN-AL80 / OHOS 6.1.1.120 / API 24） |
| 端侧 RTF 归因（线程扫描 + 逐片回归 + 内核符号） | ✅ 完成（结论：T2S 自回归环 1.82×） |
| 分片级并行吞吐测量（`ttsInitMulti`/`benchParallel`） | ✅ 完成（4 副本聚合 RTF 1.483 ⇒ 上限 1.68×，见 TTS-PLAN §9 P4 ⑤d） |
| 60 min 长稳终值 | ✅ **完成**（`STAB DONE n=483 wall=3609s rtf=1.924 fails=0 guard=0 fb=8`，见报告 §14.19） |

## 目录
```
src/onnxruntime-1.24.4/     ORT 源码（codeload tarball v1.24.4）
build/ort-ohos-arm64/       ORT 交叉编译产物（Release/libonnxruntime.so*）
gpt-sovits-tts-ohos/        NAPI 壳 crate（ttsInit/ttsSetReference/ttsSynthesize/ttsMetrics/ttsShutdown）
out/                        部署用产物：libonnxruntime.so / libgpt_sovits_tts_ohos.so / libc++_shared.so / ort_smoke.ohos
smoke/ort_smoke.c           dlopen + 版本号 + GetApi(24) 冒烟（不依赖 ort crate）
patches_ort_ohos.sh         ORT 的 4 处 OHOS 补丁（幂等，可重跑）
build_ort_ohos.sh           ORT 交叉编译入口
mirror_deps.sh              预下 ORT 依赖到 mirror/（绕 GitHub 限速）
ohos-env.sh                 Rust/cc-rs 的 OHOS arm64 环境
deploy_to_app.sh            真机部署（hdc file send -b 进 App 沙箱，1.2 GB bundle）
deploy_and_smoke.sh         主机侧推产物 + 冒烟（需设备可 exec，实测不支持，见报告 §14.7）
run_p4_ondevice.sh          UITest 驱动 A/B/C 三个门
ohos-tts-test/              真机验收 HAP（按钮 A–G：门 A/B/C、线程扫描、长稳、并行吞吐）
sample_mem.sh               长稳内存采样（hidumper Total Pss + /proc VmRSS/VmHWM）
archive/                    长稳原始日志 + 三份内存序列（stability-mem.tsv 为正式 60 min，见 §14.19）
ORT-OHOS-BUILD.md           ORT 交叉编译完整记录（命令/坑/实测）
```

## 复现（主机侧）
```bash
cd ~/Documents/playground/tts/p4
# 1) ORT（先下源码 + 镜像依赖，见 ORT-OHOS-BUILD.md）
./patches_ort_ohos.sh src/onnxruntime-1.24.4 build/ort-ohos-arm64   # cmake 配置后重跑一次
./build_ort_ohos.sh
# 2) NAPI 壳
source ohos-env.sh
cd gpt-sovits-tts-ohos && cargo build --release --target aarch64-unknown-linux-ohos
```
