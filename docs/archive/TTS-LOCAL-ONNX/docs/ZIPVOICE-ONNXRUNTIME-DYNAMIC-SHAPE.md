# ZipVoice 真机乱码根因 — onnxruntime 1.16.3 OHOS 版动态 shape 的 GetShape() bug

日期：2026-10-01
分支：`tts/mac-p0`（worktree `/Users/lichtcui/Documents/playground/source-reader-tts`）
关联：`docs/handoff/HANDOFF-S11.md`（②③ 完成）、`docs/tts-p6-report.md`（P6 打通）

## 1. 现象

真机 ZipVoice（distill-int8 zh-en-emilia + vocos_24khz）合成出声，但音频是：
- 前半/大部分是「电流乱码」，只有末尾 3-4 个字能听清（有些 run 全乱 + 极轻微人声）；
- 每次 run 的结果都不同（乱码位置/长度随机）。

`ZvDiag` 日志（worker 里 dump `out.samples`）直接抓到：`out.samples.length` 每次都在
**26 万 ~ 41 万**之间随机跳动（正确值应 ~8.1 万），且 async 路径下整个数组是 **NaN**。

## 2. 根因（已逐源码定位）

不是 ArkTS 代码，也不是 sherpa-onnx 的 ArkTS 封装。是 **sherpa-onnx 官方 OHOS `.har`
内置的 onnxruntime 版本过旧**：

| 环境 | onnxruntime | vocos 帧数（`shape[2]`）| 结果 |
|---|---|---|---|
| Mac（`sherpa-onnx-offline-tts` CLI，同 v1.13.8 + 同模型 md5 一致）| **1.28.2** | 稳定 317 | 81234 样本 = 3.38s，正常语音 |
| 真机（`sherpa_onnx-v1.13.8.har`）| **1.16.3** | 随机 1030~1613 | 26 万~41 万样本，乱码 |

调用链（`sherpa-onnx/csrc/offline-tts-zipvoice-impl.h` → `vocos-vocoder.cc`）：

```cpp
// vocos-vocoder.cc Run()
std::vector<int64_t> shape = out[0].GetTensorTypeAndShapeInfo().GetShape();
stft_result.num_frames = shape[2];              // ← 帧数，设备上读到随机巨大值
stft_result.real.resize(shape[1] * shape[2]);   // ← 按错误帧数 resize
// 循环按 shape[2] 帧填充，但真实 tensor 只有正确帧数 → 越界读 = 前段垃圾
knf::IStft istft(stft_config);
return istft.Compute(stft_result);              // ← 波形长度 = f(num_frames)，随之巨大
```

onnxruntime 1.16.3 的 OHOS 交叉编译版对「动态 shape 输出」（ZipVoice flow-matching decoder
输出的 mel 帧数 T 依赖文本/参考长度）的 `GetShape()` 返回值不稳定（符号/垃圾），而 1.28.2 正常。
这就是「同一份 sherpa-onnx 代码 + 同一模型，Mac 对、设备错」的原因。P6 报告里的
「412928 采样」其实也是这个 bug 的体现（一直错，只是当时没真听）。

## 3. 已排除 / 已确认正确的 ArkTS 用法（保留）

逐行对照 `harmony-os/.../non-streaming-tts.cc` 确认：

- **async `generateAsyncWithConfig`** 在 OHOS NAPI 里另有 use-after-free 风险（历史 #3781），
  应改用 **sync `generateWithConfig`**。
- **`enableExternalBuffer=false`** 才是安全用法（源码里 `std::copy` 后 destroy；`true` 是零拷贝、
  依赖 GC finalizer，风险高）。Worker 现已用 `sync + enableExternalBuffer=false`——这是「正确姿势」，
  onnxruntime 修好后直接可用。
- reference 传递正确（`reference_audio_len=81096`、`reference_sample_rate=24000`）。
- `numThreads` 1 和 4 都试过，无关；`provider` 只有 `cpu`（OHOS 版没编 XNNPACK/NNAPI，
  日志 `Available providers: <private>. Fallback to cpu!`）。

## 4. 三个「升级/绕过」方向全部堵死

| 方向 | 结论 |
|---|---|
| 升级 sherpa-onnx | ❌ v1.13.8（2026-09-10）已是最新 release；`master` 分支 `vocos-vocoder.cc` 与 v1.13.8 零差异（未有针对 fix）|
| 换 execution provider | ❌ OHOS onnxruntime 1.16.3 只编了 CPU EP |
| 换 onnxruntime 版本 | ❌ `csukuangfj/onnxruntime-libs` 只有 OHOS 的 `1.16.3`（1.17.4/1.18.1/1.19.2/1.20.0/1.28.2 的 ohos zip 全 404）；要换需自行从源码交叉编译 onnxruntime 到 OHOS |

## 5. 结论与建议

- **端侧 ZipVoice 在真机当下不可用**（受 onnxruntime 1.16.3 动态 shape bug 限制），
  属底层运行时问题，非本项目可修。
- 听书引擎默认仍为**系统 TTS**（`TTS_ENGINE_SYSTEM`），ZipVoice 是可选开关，线上无影响。
- 若要继续端侧路线，唯一实质路径是「**自行交叉编译 onnxruntime 1.20+ 到 OHOS 并重打 .har**」（大工程），
  或等 sherpa-onnx 官方出更高版本 OHOS onnxruntime。
- 已保留正确的 ArkTS 用法（sync + `enableExternalBuffer=false`）与三个 ref 音色注入，
  将来 onnxruntime 更新后无需重写，只需重新验证 `ZvDiag` 的 `len` 回到 ~8 万。