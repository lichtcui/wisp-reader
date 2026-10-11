# TTS 跟进调研 — ORT 升级 / 降级方案 / 服务器 TTS

日期：2026-10-02
分支：`tts/mac-p0`（worktree `/Users/lichtcui/Documents/playground/source-reader-tts`）
前序（勿返工）：[`progress.md`](../../../progress.md) §「端侧自建 TTS（Route C / ZipVoice）调研结论」、
[`ZIPVOICE-ONNXRUNTIME-DYNAMIC-SHAPE.md`](ZIPVOICE-ONNXRUNTIME-DYNAMIC-SHAPE.md)、
[`HANDOFF-S11.md`](HANDOFF-S11.md)
范围：**只调研、不改代码、不 commit**。本报告回答三个问题，末附「投入/成功率」排序清单供拍板。

---

## 0. 一句结论（速览）

| 问题 | 结论 | 可行性 | 新增工作量 | 风险 |
|---|---|---|---|---|
| ① 自行交叉编译 ORT 1.20+ 重打 .har | **实质捷径已打开**：本机在 P4 已编出 **ORT 1.24.4 for OHOS arm64 并真机验证过**（GPT-SoVITS 路线）；缺口只剩「重编 sherpa-onnx C API 换 ORT + 重打 .har + 真机回归」 | **高** | 半人天（多数是等编译）+ 一次真机回归 | 无法先验保证无杂音，只能回归验证 |
| ② 降级方案（不重编 ORT） | **全部堵死或同成本**：换 vocoder（hifigan 同样踩 `GetShape`）、换模型（全走动态 shape + 缺 OHOS 实证）、退版本（同属自编 ORT） | **极低** | — | 高，不推荐 |
| ③ 服务器 TTS | 端侧兜不住时可走，但**违反 AGENTS.md「v1 不做在线 TTS」**，需先拍板改决策 | 中 | 服务器服务 + App 网络取流 + 缓存 | 延迟/隐私/断网/成本 |

**一句话建议**：先走 ① 的「复用 1.24.4 + 重打 .har」这条最小闭环（半人天、成功率最高）拿一个真机回归数据点；
若仍杂音，再决定「退回系统 TTS（当日可上）」还是「推翻决策上服务器 TTS」。

---

## 1. 问题① — 自行交叉编译 ORT 1.20+ 到 OHOS 并重打 .har

### 1.1 最重要的发现：本机已经编出并真机验证过 ORT 1.24.4 for OHOS arm64

TTS-PLAN §9 P4 阶段（GPT-SoVITS 路线）**已经解决过「自建 ORT for OHOS」这个最大工程风险**，产物还在本机：

| 证据 | 值 | 来源 |
|---|---|---|
| 产物 | `/Users/lichtcui/Documents/playground/tts/p4/build/ort-ohos-arm64/Release/libonnxruntime.so.1.24.4`（**28,176,512 B**） | 本机 `ls` |
| 导出 | `OrtGetApiBase@@VERS_1.24.4`；SONAME `libonnxruntime.so.1`；NEEDED `libc++_shared.so` + `libc.so`(musl) | `llvm-readelf`（本报告复验）+ `p4/ORT-OHOS-BUILD.md` |
| 源码树 | `/Users/lichtcui/Documents/playground/tts/p4/src/onnxruntime-1.24.4`（4 处 OHOS patch 已打、`include/onnxruntime/core/session/onnxruntime_cxx_api.h` 齐全） | 本机 `ls` |
| 复现脚本 | `p4/build_ort_ohos.sh` + `p4/patches_ort_ohos.sh`（幂等）+ `p4/ORT-OHOS-BUILD.md` | 本机 |
| 真机验证 | P4 用该 1.24.4 跑 GPT-SoVITS：60.15 min 长稳、0 崩溃、KV-cache（**动态 shape**）0 次重分配、Pss 平稳 | TTS-PLAN §9 P4 ⑥/⑧ |

> 这意味着问题①里最贵的一步（ORT 交叉编译）**在本机是「已完成」状态**，不是「待论证」。
> 剩下的是「sherpa-onnx 这一边重编 + 重打 .har + 真机回归」。

### 1.2 ORT 上游对 OHOS 的交叉编译支持现状

**结论：ORT 上游到现在（截至 v1.30.0 / 2026-09）仍无原生 OHOS toolchain 支持**，`tools/ci_build/build.py`
只认 Android；OHOS 全凭「把 `ohos.toolchain.cmake` 伪装成 Android toolchain + `CMAKE_SYSTEM_NAME=Linux`」的社区姿势。证据：

| 事实 | 证据 |
|---|---|
| ORT release assets 无任何 ohos 产物（v1.29.1 / v1.28.2 / v1.30.0 均如此） | microsoft/onnxruntime release 列表（TTS-PLAN §4.5 已核） |
| 唯一的社区 OHOS 构建配方公开在 csukuangfj/onnxruntime-libs | `.github/workflows/harmony-os-shared.yaml`（本报告拉取全文） |
| 该 workflow 注释写明工具链硬约束：**clang 15.0.4 不支持 `bfloat16_t`**，故对 arm64 要大批 `sed` 剥离 bf16/fp16 代码路径 | workflow 顶部注释 + `patch` step 全文 |
| 实际 OHOS 产物（文件探测） | 见下 1.2.1 |

#### 1.2.1 csukuangfj/onnxruntime-libs 的 OHOS 产物与分支实测

用 GitHub API 逐个 release 探测 assets 的 `ohos` 条目：

| 版本 | OHOS 产物 | 结论 |
|---|---|---|
| **1.16.3** | `onnxruntime-ohos-arm64-v8a-1.16.3.zip` + `armeabi-v7a` + `x86_64`（**三 ABI 全**） | 唯一跑通 arm64 的版本（即 .har 里这块） |
| **1.28.2** | `armeabi-v7a-1.28.2.zip` + `x86_64-1.28.2.zip`（**无 arm64-v8a**） | arm64 构建**失败**，只有 32 位/x86_64 出了产物 |
| 1.17~1.27、1.29、1.30 | **无 ohos 条目** | 未产出/未尝试 |

分支探测（`/branches`）：`harmony-os`、`open-harmony`、`onnxruntime-1.27.0`、`v1.22.0`、`fix-1.28.2`、
`update-1.28.2` 等存在，但根目录都只有 `.github` + `README.md`（**没有任何术版本 OHOS 产物或新 patch 沉淀**；
真正的构建逻辑在 master 的 `.github/workflows/harmony-os-shared.yaml`，且 version 是 `workflow_dispatch` 输入项）。

**净结论**：csukuangfj 的公开配方**理论上**任意版本可触发，但实测 **arm64-v8a 只有 1.16.3 成功**；1.28.2 的 arm64 没编出来。
这正好反证：**「升级版 OHOS ORT arm64」不能指望社区现成，只能自己编** —— 而本机 P4 已经把它编出来了（用另一套
`build.py + -march=armv8.2-a+bf16` 的补丁路线，保留了 bf16 加速，比 csukuangfj 的「全剥 bf16」更优）。

#### 1.2.2 为什么 P4 的 1.24.4 能编、csukuangfj 的 1.28.2 arm64 编不出

两者对 clang 15.0.4「无 `arm_bf16.h`」这个同一问题的处理不同：

| 路线 | 处理 | 结果 |
|---|---|---|
| csukuangfj workflow | 把所有 bf16/fp16 源文件 `sed` 全删 + `MlasBf16AccelerationSupported=false` 桩 | 1.16.3 三个 ABI 都成；**1.28.2 arm64 失败**（新版 MLAS bf16 依赖更深的路径没被这套 sed 覆盖） |
| **本机 P4 recipe** | 保留 bf16 路径，加 `-march=armv8.2-a+bf16` 到 CXXFLAGS + 给缺 `arm_bf16.h` 的单个 TU 补 `typedef unsigned short bfloat16_t;` + `env.cc`/`cpuinfo` 两处 `#if` 收口 | **1.24.4 arm64 成功，真机验证 OK** |

> → 推荐复用 **1.24.4**，而不是去追 1.28.2：1.24.4 已经真机验证过动态 shape（KV-cache），且 Mac 侧 1.28.2
> 修 vocos 的「正确性」证据与 1.24.4 同属「新版 ORT 修掉了 1.16.3 的动态 shape GetShape 回归」这条因果链，
> **没有证据表明必须 1.28 才修**。若 1.24.4 回归仍杂音，再升级 1.28.2（需把 P4 三处 patch 重新对 1.28.2 源码锚定，风险略升）。

### 1.3 重打 .har 的链路（关键：不能只换 `libonnxruntime.so`，必须重编 C API）

`.har` 是 gzip 压缩的 tar（非 zip），当前 arm64 内含 4 个 `.so`（本机解包实测）：

| 文件 | 大小 | 说明 |
|---|---|---|
| `libs/arm64-v8a/libonnxruntime.so` | 12.9 MB | ORT 1.16.3 |
| `libs/arm64-v8a/libsherpa-onnx-c-api.so` | 3.75 MB | sherpa 的 C API（**直接**依赖 ORT） |
| `libs/arm64-v8a/libsherpa_onnx.so` | 749 KB | NAPI 绑定（依赖 C API） |
| `libs/arm64-v8a/libc++_shared.so` | 1.26 MB | (musl) 运行时 |

**为什么「只换 `libonnxruntime.so`」不成立** —— 用 `llvm-readelf --dyn-syms` 实测符号版本绑定：

```
旧 ORT 1.16.3（.har）:        OrtGetApiBase@@VERS_1.16.3
libsherpa-onnx-c-api.so UND:  OrtGetApiBase@VERS_1.16.3     ← 语义绑定旧版本名
新 ORT 1.24.4（P4 产物）:      OrtGetApiBase@@VERS_1.24.4
```

动态链接器按版本名解析，`@VERS_1.16.3` 的引用在只导出 `@@VERS_1.24.4` 的新库里**解析不到 → 加载即失败**。
（社区 issue #2633 评论里「提示找不到 `OrtGetApiBase` 符号」正是同一类混库症状的旁证。）

**正确链路**（`build-ohos-arm64-v8a.sh` 本就直接支持，无需改动 sherpa 源码）：

1. sherpa-onnx 的 `cmake/onnxruntime.cmake`（v1.13.8 L156-236）读环境变量
   `SHERPA_ONNXRUNTIME_LIB_DIR` / `SHERPA_ONNXRUNTIME_INCLUDE_DIR` 决定链接哪个 ORT；
   这两个变量由 `build-ohos-arm64-v8a.sh` 里 `onnxruntime_dir` 导出。
2. 把 `onnxruntime_version=1.16.3` 换成 `1.24.4`，并预先把本机 P4 的
   `libonnxruntime.so*` + 头文件铺成 `onnxruntime-ohos-arm64-v8a-1.24.4/{lib,include}`（跳过该脚本的 wget）。
3. `cmake -DOHOS_ARCH=arm64-v8a ... && make -j2 && make install/strip` → 重编出 **`libsherpa-onnx-c-api.so`（新版本符号）+ 用新头文件编译的 ORT C++ wrapper**。
4. 脚本末尾已把 `libsherpa-onnx-c-api.so` + `libonnxruntime.so` 拷进
   `harmony-os/SherpaOnnxHar/sherpa_onnx/src/main/cpp/libs/arm64-v8a`，再跑该 HAP 工程的 `hvigor` 重打 `.har`。

**可复用的部分**：NAPI 绑定 `libsherpa_onnx.so` 的 UND 符号里 **没有** 任何 `Ort*`（只有 `SherpaOnnx*`）+ 它
`NEEDED` 的是 `libsherpa-onnx-c-api.so`，故其**可原样复用**（或按需随 C API 一起重编，更保险但非必需）。

### 1.4 问题① 的可行性 + 工作量 + 风险

| 项 | 评估 |
|---|---|
| **可行性** | **高**。ORT 交叉编译 = 已完成（P4 产物在盘）；剩下「sherpa-onnx 重编 + 重打 .har」是官方脚本原生支持的流程，无未知深坑 |
| **工作量** | ~半人天：铺 1.24.4 lib/include（10 min）→ 改脚本版本号并跑 sherpa-onnx cmake/make（装依赖 ~0.5-1h + 编译 ~0.5-1h）→ 重打 .har（~15 min）→ 装包/真机回归（~1-2h，含反复 hdc 重连） |
| **风险/不确定性** | ① 1.24.4 是否 100% 修掉 vocos 的 `GetShape` 回归——**只能真机回归确认，无法先验保证**（见 1.5）；② 若仍杂音需上 1.28.2（P4 三处 patch 锚点可能漂移，重编 ~2-3h）；③ 换 ORT 后 sherpa 偶发原生 SIGSEGV/SIGKILL（HANDOFF-S11 §4②）是否会变——也需回归观察 |

### 1.5 「能否确认无杂音」的诚实答案 + 最小验证闭环

**诚实答案：不能先验确认。** 升级 ORT 只能消除「已确诊的 1.16.3 动态 shape GetShape 随机帧数」这一**个** bug；
它**不能**保证 vocos/sherpa 在 OHOS 上没有第二个问题。证据是「同一代码 + 同一模型在 Mac 1.28.2 正常」只证明
1.28.2 这条路是对的，不等于 1.24.4 在 OHOS 也 100% 干净——所以必须真机回归。

**最小可验证闭环（拿一个数据点，别一次做全）**：

1. 重打 .har（换 `libonnxruntime.so` + `libsherpa-onnx-c-api.so`）。
2. 装包，进 设置 →「ZipVoice 离线听书测试」，**只看一个指标**：`tts-generate-done` 里 `out.samples.length`。
   - **判据**：`len` 稳定回到 **~81,234**（317 帧 × 256 hop ≈ 81,152，与 Mac 3.38s@24k 对齐），连续 ≥5 次不再在 26万~41万随机跳动 → GetShape bug 已消除。
   - 再用 3 个 ref（流萤/花火/卡芙卡）各来一次人工听声，确认无电流乱码。
3. 通过后再上听书页 2h 长稳（观察 SIGSEGV/SIGKILL、`ZvDiag` 计数）。

> 只要第 2 步 `len` 回归 ~81k 且听感干净，即判定 ① 成功；否则转 1.24.4→1.28.2 重试或走③/回系统 TTS。

---

## 2. 问题② — 降级方案（不重编 ORT 的前提下端侧出声）

### 2.1 换 vocoder：vocos → hifigan（⚠ 判断：堵死，两重原因）

sherpa-onnx **确实内置了 hifigan vocoder**（`csrc/hifigan-vocoder.cc`），且 `vocoder.cc` 按模型元数据
`model_type`（`hifigan` | `vocos` | `matcha-tts vocos`）自动分派。但两重原因使它不构成「绕开」：

1. **同样脆弱**（根因未绕开）。`hifigan-vocoder.cc::Run()` 对输出同样调
   `out[0].GetTensorTypeAndShapeInfo().GetShape()`，只是换成分量的读法：

   ```cpp
   // hifigan-vocoder.cc（本报告拉取全文，L56-65）
   std::vector<int64_t> audio_shape = out[0].GetTensorTypeAndShapeInfo().GetShape();
   int64_t total = 1;
   for (auto i : audio_shape) total *= i;   // (1,1,total)/(1,total)/(total,)
   return {p, p + total};
   ```

   与 vocos 读 `shape[2]` 一样，`total` 也来自同一个被污染的 `GetShape()`。若污染点命中
   hifigan 输出的动态最后一维（音频样本数），`total` 同错 → 一样越界读垃圾。**「total=全维相乘」并不能防御该污染。**
2. **模型不匹配**：ZipVoice 解码器输出是给 vocos 用的 mel 特征（vocos_24khz，n_mels 与 n_fft 按 vocos 约定），
   sherpa-onnx 官方 release 里的 hifigan vocoder 是 80 维 mel、面向 VITS 系（采样率/维数与 vocos 不一致）；
   生造一个「24kHz hifigan + ZipVoice 解码器」组合还需要自行导出匹配的 hifigan onnx 并注入 `model_type=hifigan`
   元数据——**这本身又是一条没有现成产物的小工程**。

结论：换 vocoder **绕不开根因**（同样走被污染的 `GetShape()`），且引入模型适配新风险。**不推荐**。

### 2.2 换模型：VITS / Matcha / Kokoro / Pocket / Supertonic（⚠ 判断：与 vocos 同病，且无 OHOS 实证）

逐个看输出路径（源码 grep，`csrc/*.cc/h`）：

| 模型 | 输出路径 | 是否避开 vocos 的 `shape[2]` | 是否避开动态 `GetShape` |
|---|---|---|---|
| VITS | `offline-tts-vits-impl.h` L519：`audio = model_->Run(...)` 直接出波形（内嵌 decoder，**无独立 vocoder**） | 是（不读 vocos `shape[2]`） | **否**——波形长度仍是文本相关动态 shape，读法等价 |
| Kokoro | `offline-tts-kokoro-impl.h` L441：`audio = model_->Run(...)` 直接出波形 | 是 | **否**——动态 shape |
| Matcha | `matcha-impl.h` L52/134 `vocoder_ = Vocoder::Create(config.model)` | 否——与 ZipVoice 走**同一个** vocos/hifigan 分派 | **否** |
| ZipVoice | `zipvoice-impl.h` L36/46 `vocoder_ = Vocoder::Create(...)` | 否（当前用的就是 vocos） | **否** |
| Pocket | `pocket-impl.h` L398-428：Mimi decoder 逐 chunk `RunMimiDecoder` | 是（不用 vocos） | **否**——每个 chunk 输出仍动态 shape |

**关键判断**：本 bug 的根因是「ORT 1.16.3 OHOS 对**动态 shape 输出**的 `GetShape()` 返回垃圾」。而 TTS 的
音频长度天然随文本变 → **所有**模型输出都是动态 shape → **全部暴露在同一根因下**，只是触发点在各自读 shape 的代码行。
换模型只是把「vocos 读 `shape[2]`」换成「VITS/Kokoro/Pocket 读 `(1,1,T)` 里的 `T`」，**本质不避雷**。

**社区实证**：检索 sherpa-onnx issue，**没有任何「HarmonyOS/OpenHarmony 上非 vocos TTS 出声正常」的报告**；
相反条目是：`#2633`（OpenHarmony 5.0 TTS `libsherpa-onnx-c-api.so` SIGSEGV，32 位 ARM，异步回调路径）、
`#2816`（RK3566/鸿蒙 5.0 TTS 例程闪退/`createCircularBuffer` 缺失）、`#2120`（官方对 ORT 版本/混库的说明）。
**没有**「换 VITS/Kokoro/Matcha 就正常」的正例。

> 附带说明一条「半绕开」思路并判死：给 `vocos-vocoder.cc` 打补丁，不读 output `GetShape`，改从**输入 mel 的
> shape** 推导 `num_frames`（再 ×hop stride）。但输入 mel 同样动态 shape（也走 GetShape），且 `out[1]/out[2]`（real/imag）
> 同样要数帧——等于换一个同样被污染的形状来源，**不成立**。真要修得改 sherpa 源码 + 仍绕不开 ORT 动态 shape，
> 成本 ≈ 问题① 的重编量、成功率更低，**不如直接升级 ORT**。

结论：换模型/换 vocoder **均不能在不重编 ORT 的前提下可靠出声**。**不推荐**。

### 2.3 退版本：ORT 1.14 / 1.15

- csukuangfj/onnxruntime-libs 的 OHOS 产物**只有 1.16.3 一个 arm64 版本**（上面 1.2.1 表：1.14/1.15 无 ohos 条目）。
- 即「退版本」也**必须自己编** → 成本归入问题①。
- 且**无证据**「1.14/1.15 反而没有这个动态 shape 回归」——1.16.x 本身就不算新，bug 更可能是 OHOS 交叉编译这一异类
  build 路径（csukuangfj 的 `CMAKE_SYSTEM_NAME=Linux` + 大量 sed）引入，而不是「版本新引入」。反向退版本无理论依据。

结论：退版本**无现成产物、无理论依据**，等价问题① 成本却更低胜率。**不推荐**。

### 2.4 问题② 小结

| 方案 | 结论 | 改面 | 真机验证 | 证据 |
|---|---|---|---|---|
| vocos→hifigan | ❌ 同踩 `GetShape` + 模型不匹配 | sherpa 源码 + 新模型 | 阶跃验证样本数 | `hifigan-vocoder.cc` L56-65 全文 |
| 换 VITS/Kokoro/Matcha/Pocket | ❌ 全部动态输出同病、无 OHOS 实证 | 换模型 + 配置 | 同 ZvDiag | 各 `offline-tts-*-impl.h` grep + issue #2633/#2816/#2120 |
| 退 ORT 1.14/1.15 | ❌ 无现成、无依据 | 同 ① | — | onnxruntime-libs 文件探测（无该版本 ohos） |
| 改 sherpa 源码绕 `GetShape` | ❌ 输入也动态、成本 ≈ ① 而胜率更低 | sherpa 源码 | — | `vocos-vocoder.cc` 输入/输出均动态 |

**净结论**：**不存在「不重编 ORT 却能在端侧可靠出声」的降级方案。** 要么升级 ORT（①），要么端侧这条路在
「修正 ORT 之前」就是堵死的；在那之前可用的「端侧出声」只有现有 M5 系统 TTS。

---

## 3. 问题③ — 服务器 TTS 是不是退路

### 3.1 先纠正一个前提：sherpa-onnx 的 websocket server 是 ASR，不是 TTS

sherpa-onnx 仓库里的 `offline-websocket-server.cc` / `online-websocket-server.cc` 是**语音识别**服务器
（`offline-websocket-server-impl.h` include `offline-recognizer.h`、`OfflineRecognizer recognizer_`）。**没有现成的
TTS websocket server**。服务器 TTS 需要自己写一层薄壳（二选一）：

| 路径 | 说明 | 新增量 |
|---|---|---|
| sherpa-onnx 自定义服务 | pip 版 sherpa-onnx + 现有 `offline-tts` API，包一层 FastAPI/websocket：收文本 → 合成 → 回 PCM | ~100 行 Python（无新算法） |
| GPT-SoVITS 服务 | 官方 `api_v2.py`（FastAPI）已有 TTS 端点，可直接跑 | 部署 + 适配 `ref` 音色 |

两者产出 PCM（24k 或 32k）都可喂回现有 `AudioRenderer`（采样率可切）。

### 3.2 改造工作量 vs 复用现有 TtsController

| 层 | 现状（M5/TtsController） | 服务器化改动 |
|---|---|---|
| PCM 来源 | 系统 TTS `onData` / ZipVoice worker `f32ToS16` | 换成「HTTP/WS 拉回 PCM（S16LE/F32）」；**复用同一个字节队列 `fill`/`ReqBuffer`/`enqueueParagraph`** |
| AudioRenderer/AVSession/后台/定时/进度 | 已完整（M5） | **0 改动**（PCM 入口换，下游不变） |
| 段落节奏/高亮/回写 | 已完整 | 0 改动 |
| 新增 | — | ① 服务端部署；② App 网络层（逐段请求 + 超时/重试）；③ 预取队列从「本地合成 2 段」改成「网络预取 2-3 段」；④ 断网/失败回退系统 TTS |
| **总工作量估算** | — | 服务端 **≤ 半人天**（起服务）；App 端 **1-2 人天**（网络取流 + 预取 + 回退 + 缓存），比「从零接 TTS」「重编 ORT」里的 C++ 活更轻，但**不是零** |

### 3.3 代价清单（对照 AGENTS.md「v1 不做在线 TTS」）

| 代价 | 量化/说明 |
|---|---|
| **延迟** | 逐段合成：本地 ZipVoice 单段 RTF 0.49；服务器需加「文本上行 + 合成 + PCM 下行」RTT，逐段有首包延迟；可用「预取 2-3 段」兜住，但段落边界/翻章仍有追尾 |
| **隐私** | 正文文字**出端**到你的服务器；听书是整本书全文，隐私暴露面大 |
| **带宽** | PCM 24k mono S16LE = **48 KB/s ≈ 2.8 MB/min**；一整本《…》按听听几小时计，每小时 ~168 MB（若用 opus/压缩可降到 ~1/10，但要加编解码） |
| **断网不可用** | 无网完全不可用（不像系统 TTS 离线）；需回退系统 TTS |
| **服务器成本** | 一台小 VPS 跑 sherpa-onnx TTS（CPU）即可，但并发放大后 CPU 吃紧；sherpa ZipVoice CPU RTF ~0.35-0.5 意味着单核 1 分钟最多出 ~2-3 分钟音频，多用户要排队/扩容 |
| **本地缓存（是否 v1 必做）** | **可不做**：同一本书重复听时才有收益；v1 听书是「顺序流式播放 + 预取 2-3 段」，缓存命中率低。`ponytail:` v1 先不缓 PVoice，真有人反复听同一本书再按「原书+段落 hash → PCM 文件」加缓存，落沙箱 filesDir |

### 3.4 两个可执行结论（对照 AGENTS.md 第 40 行「v1 不做：在线 TTS」）

**结论 A（维持现状，不破决策）**：**不上服务器 TTS**，听书默认继续用 M5 系统 TTS。
- 端侧 ZipVoice 在「修正 ORT 之前」只作隐藏开关/实验入口，不进入 v1 验收。
- 动作 = **零改动**。这是**今日即可上线**的结论。

**结论 B（若要上服务器 TTS，最小改动边界）**：
- 先**改决策**（AGENTS.md 第 40 行删除「在线 TTS」，progress.md 同步），这不是代码而是拍板。
- 最小改动 = 给 `TtsController` 增加一个「Remote 引擎」：`engineKind=REMOTE`，把 `enqueueParagraph` 的来源
  由本地合成换成 `fetch(synthesis-server/{text,refId})→ArrayBuffer`，其余 `fill`/`ReqBuffer`/AudioRenderer/AVSession
  **全复用**；失败回退 `TTS_ENGINE_SYSTEM`。
- 服务端 = GPT-SoVITS `api_v2.py`（复用三个 v2ProPlus 音色）或 sherpa-onnx 薄壳（~100 行）。
- **不改**：书架/阅读页/段落高亮/进度回写/目录逻辑。

> 净判断：服务器 TTS **技术上随时可上、代价可控**，但它改变的是「听书是否离线可用 + 全书文本出端」这两条
> 产品性质，不是纯工程问题。**在把 ① 的重打 .har 回归跑完之前，不建议为它翻决策。**

---

## 4. 建议清单（按「投入 / 成功率」排序，供拍板）

| # | 方案 | 投入 | 成功率 | 结论 |
|---|---|---|---|---|
| **1** | **复用 P4 的 ORT 1.24.4 + 重编 sherpa-onnx C API + 重打 .har + 真机回归**（问题①） | 半人天（ORT 已编好） | **高**（唯一真机未知点是「1.24.4 是否完全修掉 vocos GetShape」，但因果链强） | **首选，建议就做这一步拿数据点** |
| 2 | ① 回归仍杂音 → 升 1.28.2（P4 patch 重新锚定 + 重编 ORT） | 2-3h 编译 + 排错 | 中（patch 锚点可能漂移） | ① 的备用升档 |
| 3 | 退回/维持 **系统 TTS（M5）** | **0** | 100%（已真机验证） | 永远兜底，当前线上即为此 |
| 4 | **服务器 TTS**（GPT-SoVITS api_v2 或 sherpa 薄壳 + App 远端取流） | 服务端 ≤半人天 + App 1-2 人天 | 高（技术成熟）但**翻「v1 不做在线 TTS」决策 + 付隐私/延迟/带宽/断网代价** | 只在①②都否后考虑 |
| 5 | 换 vocoder/换模型/退 ORT 版本（问题②） | — | **极低**（同踩 `GetShape`、无 OHOS 实证） | **否掉，勿投入** |

**拍板问题就一个**：是否现在就花半人天走 #1 的「重打 .har 真机回归」？
- 若 **同意** → 下一步按 §1.3/§1.5 执行（铺 lib/include → 改脚本 → 编译 → 重打 .har → 只看 `len` 回 ~81k + 听声）。
- 若 **不同意** → 端侧自建 TTS 维持「暂不可用」，听书用系统 TTS（#3），并把「是否上服务器 TTS（#4）」作为独立决策单。

---

## 5. 证据来源索引

**本机产物 / 脚本（可复核）**
- ORT 1.24.4 产物：`~/Documents/playground/tts/p4/build/ort-ohos-arm64/Release/libonnxruntime.so.1.24.4`（28,176,512 B）
- ORT 1.24.4 源码树 + patch：`~/Documents/playground/tts/p4/src/onnxruntime-1.24.4`、`p4/patches_ort_ohos.sh`、`p4/build_ort_ohos.sh`、`p4/ORT-OHOS-BUILD.md`
- sherpa .har：`entry/libs/sherpa_onnx-v1.13.8.har`（14,774,722 B；解包见 `tar -xzf`）
- 符号版本证据：`llvm-readelf --dyn-syms` 对上述 3 个 .so 的输出（本报告 §1.3 引用）

**GitHub（本次拉取）**
- sherpa-onnx `build-ohos-arm64-v8a.sh`（master 与 `v1.13.8` 同源，L81 `onnxruntime_version=1.16.3`；L91/92 导出 `SHERPA_ONNXRUNTIME_LIB_DIR/INCLUDE_DIR`）
- sherpa-onnx `cmake/onnxruntime.cmake`（v1.13.8，L156-236 读 `SHERPA_ONNXRUNTIME_{LIB,INCLUDE}_DIR`）
- sherpa-onnx `csrc/vocos-vocoder.cc`（`Run()` L82-124：`GetShape`→`shape[2]`→istft）、`csrc/hifigan-vocoder.cc`（L56-65：`GetShape`→`total=∏dims`）、`csrc/vocoder.cc`（`model_type` 分派）、`csrc/offline-websocket-server-impl.h`（ASR-only，include `offline-recognizer.h`）
- `csukuangfj/onnxruntime-libs`：releases 文件探测（OHOS 仅 1.16.3 三 ABI / 1.28.2 二 ABI 无 arm64）；`master/.github/workflows/harmony-os-shared.yaml`（顶注 clang 15.0.4 无 bfloat16_t + bf16/fp16 剥离 patch）
- microsoft/onnxruntime issue #20895（社区 OHOS 参数，TTS-PLAN §4.5 已引）
- sherpa-onnx issues：#2633（OpenHarmony 5.0 TTS 原生 SIGSEGV + 评论“找不到 OrtGetApiBase 符号”）、#2816（RK3566/鸿蒙 TTS 闪退）、#2120（官方 ORT 版本说明）

**既定事实（勿返工，见前序文档）**
- 根因与证据链：`docs/bugfix/ZIPVOICE-ONNXRUNTIME-DYNAMIC-SHAPE.md`
- Mac 1.28.2 vs 真机 1.16.3 的帧数对照：`docs/bugfix/...` §2 表；P6 打通/坑：`docs/tts-p6-report.md`；②③接入与遗留：`docs/handoff/HANDOFF-S11.md`
---

## 6. 回归结果（2026-10-01 实测，推翻了 §0 表里①的乐观预期）

按 §1.5 的最小闭环实际执行了「复用 1.24.4 + 重编 sherpa-onnx C API + 重打 .har + 真机回归」，**结论：没修好，且把根因钉得更深**。

| 项 | 结果 |
|---|---|
| 重编 `libsherpa-onnx-c-api.so` | ✅ 符号 `OrtGetApiBase@VERS_1.24.4`（确认真机加载的是新 ORT；`init-tts-done` 正常过） |
| 重打 .har（换 c-api + 双文件名 ORT） | ✅ hvigor 确认把 `libonnxruntime.so.1` 打进 HAP（`libs/arm64-v8a/`） |
| 真机听声 | ❌ 仍乱码（用户：只有「青草气味」4 字清晰，其余电流声） |
| 关键日志 | `VOCOS-FIX out=[1,513,1614] mel=[1,100,1614] num_frames=1614` → `ZvDiag len=412928 ... 全 NaN` |
| Mac 地面真值 | 同文本同参考：**103168 样本 = 3.444s**（≈400 帧） |

**根因修正（比 bugfix 文档 §2 更精确）**：不是「vocos 的 `shape[2]` 单独坏」，而是
**ORT-OHOS 对一切动态 shape 输出的 `GetShape()` 都返回 ~4× 虚高帧数**（静态维正常：`513=n_fft/2+1`、
`100=n_mels` 都对；动态帧数 1614 vs 正确 400）。证据链：

1. `offline-tts-zipvoice-impl.h` L455 `mel.GetTensorTypeAndShapeInfo().GetShape()` 读 decoder 输出的 `T=mel_shape[1]`，OHOS 上读到 1614（正确 400）→ `Transpose(mel_data, T, C)` 用错 stride 越界 → mel 内容先烂。
2. 随后 `new_shape={1,C,T}` 用错的 T 建 `mel_new`，vocos 收到的输入就是 1614 帧 → vocos 输出 1614 帧 → istft 出 412928 样本全 NaN。
3. 所以「换 vocoder」「从 mel 推帧数」都失效——mel 的 GetShape 也坏。
4. ORT 1.16.3 与 1.24.4 表现一致 → **版本无关，是 OHOS 交叉编译（`CMAKE_SYSTEM_NAME=Linux`+musl）这一异类路径的动态 shape 固有 bug**。

**对 §0/§4 建议表的修订**：① 的「高可行性/高成功率」被证伪；①②⑤（升级/降级/换型）全部判定**端侧不可行**。
剩余理论出路仅「改 sherpa 源码：用 `tokens.size()` 反推 mel 帧数」——给第三方模型反推内部上采样率，脆弱且随
sherpa 升级会碎，**不推荐投入**。端侧自建音色路线的正确结论 = **待 ORT 上游/社区修复 OHOS 动态 shape 前封存**。

### 6.1 同类 app 的离线听书做法（GitHub 实证）

检索到 `end-web/HarmonyOS-book`（「简听」，HarmonyOS 6.0+ 听书/阅读 app，35 ⭐，2026-09 活跃），其
`entry/src/main/ets/service/text/TextToSpeechService.ets` 是现成的行业做法证据：

- **离线朗读 = 系统 TTS**：`@kit.CoreSpeechKit` 的 `textToSpeech.createEngine({language, person, online:1, ...})`（`online:1` 偏好在线、无网回退本地）→ `listVoices` + `downloadVoice` 下载离线音色 → `engine.speak(text, {...playType:1...})`；分段 + 逐段高亮 + AVSession/后台锁屏播控。
- **自定义音色 = HTTP 云 TTS**（非端侧合成）：`CustomTtsConfig`（`url/method/body/header`）+ `HttpTtsPlayer` 逐句请求并「当前句+后续两句」预取；离线不可用。

即：**主流鸿蒙看书 app 的「离线听书」走的都是系统 TTS（Core Speech Kit）+ 下载离线音色**——这正是本项目 M5
已实现且真机验证的方案；其余自定义音色一律走云端 HTTP，没有 app 在端侧跑神经声码器。本项目对「端侧自建音色」的
探索（GPT-SoVITS RTF 1.483、ZipVoice ORT 动态 shape）属于超出行业默认的增量，两头均撞上鸿蒙生态缺失（端侧无现成
ORT/CosyVoice 运行时）。
