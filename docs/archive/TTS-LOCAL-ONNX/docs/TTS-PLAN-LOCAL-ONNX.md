# TTS-PLAN — 鸿蒙听书端侧自建 TTS 尽调与原型计划

日期：2026-09-26（P0）/ 2026-09-27（P1）
状态：**P0–P3 已完成**（P0/P1 见 [`docs/tts-p0-report.md`](tts-p0-report.md)；P2/P3 见 §9 及报告 §12/§13）；下一步 = §9 的 **P4 真机**
范围：**只做调查与计划**。本轮未改动任何代码（`entry/`、`rust/`、`.so` 全部未动）。
关系：现有 M5 用的是**系统 TTS**（Core Speech Kit `textToSpeech` → `AudioRenderer` → `AVSession`，见 `docs/progress.md` §「M5 结果」）。
本文档是**端侧自建 TTS 的并行增量调研**，与 M5 不冲突、不改动 M5。

> **一句话结论**：路线 A（GPT-SoVITS → ONNX → Rust/NAPI → 鸿蒙）是唯一能复用你手上模型的路径，
> 但端侧 int8 常驻内存实测指向 **约 1GB**（超原定 256MB 三到四倍），且鸿蒙侧零现成工程。
> 因此原型阶段**先只在 Mac 上验证「音质是否可用」**，再决定是否值得投入 OHOS 交叉编译。

> **（2026-09-29 更新）**：P4 真机已完成并收口。结论：GPT-SoVITS **端侧实时不可行**
> （RTF 下限 1.483，<1.0 不可达），§7 已拍板转 **路线 C / CosyVoice 2 混合方案**。

---

## 0. 决策记录（本轮已确认，可直接继承）

| # | 决策 | 说明 |
|---|---|---|
| 1 | **GPT-SoVITS 路线优先**（路线 A） | 保留手上 5 个音色优先，而非 sherpa-onnx 的通用 TTS |
| 2 | **本期只做 v2ProPlus** | 流萤 / 花火 / 卡芙卡 三个包；v4/v3 **明确排除** |
| 3 | **Mac 主机先行** | 先在 Mac 跑通「一段中文朗读」+ RTF/内存实测，通过后才上真机 |
| 4 | **256MB 放宽为实测值** | 内存验收改为「不 OOM、不崩、可连续 1–4h」，上限以真机实测为准 |
| 5 | **模型分发推迟决定** | 本期走「Mac 本地目录 + 手动导入」，不入 HAP、不做下载器 |

---

## 1. 本地模型成分表

路径：`/Users/lichtcui/Downloads/`

| 包 | 版本 | GPT ckpt | SoVITS pth | 参考音频 | 结论 |
|---|---|---|---|---|---|
| `流萤.zip` | v2ProPlus | ✅ 完整<br>155,313,312 B | ❌ 仅 **97.09%** 可解<br>缺 5,024,444 B | 6 条，3.24–4.70s<br>44.1kHz | **首选**，重下 pth 即可 |
| `花火.zip` | v2ProPlus | ✅ 完整<br>155,313,312 B | ❌ 仅 **99.90%** 可解<br>缺 164,845 B | 4 条，3.41–7.86s<br>44.1kHz | 重下 pth；**缺「中立」情绪** |
| `卡芙卡.zip` | v2ProPlus | ✅ 完整<br>155,313,312 B | ❌ 仅 **88.23%** 可解<br>缺 20,325,870 B | 4 条，3.42–8.85s<br>44.1kHz | 重下 pth；「中立」偏短 |
| `胡桃_ZH.zip` | **v4** + LoRA r32 | ✅ 完整<br>155,312,893 B | ✅ 完整（仅缺 `PK` 幻数）<br>75,549,998 B | 1 条，6.79s<br>48kHz | **v4 无转换器支持，本期排除** |
| `芙宁娜_ZH.zip` | **v4** + LoRA r32 | ❌ 仅 **73.06%** 可解<br>缺 41,840,662 B | ❌ **0.00%** 可解 | 1 条，7.04s<br>48kHz | 双文件损坏 + v4 不支持，排除 |

包内文件构成（除上表外无多余内容）：

- v2ProPlus 三包：`v2ProPlus/<角色>/<角色>-e10.ckpt`、`<角色>_e10_s<N>.pth`、`reference_audios/中文/emotions/*.wav`。
  无 README、无导出脚本、无 `*.onnx`、无配置文件。
- v4 两包：`v4/<角色>_ZH/<角色>_ZH-e10.ckpt`、`<角色>_ZH_e10_s<N>_l32.pth`、`train.log`、`reference_audios/中文/emotions/*.wav`。
  **`train.log` 是版本判定与训练参数的直接证据**。
- 五个包**均不含 ONNX**：全部需要自行导出（见 §5）。

**参考音频逐条明细**（全部 16bit 单声道，落在转换工具建议的 3–10s 区间）：

```
流萤    3.24s  44100Hz  【生气】小心，更多怪物进来了！准备开火！
        3.38s  44100Hz  【中立】…我应该会选择请求猎犬家系停止追捕。
        3.82s  44100Hz  【恐惧】…但感谢你出手相助，是真的。
        4.41s  44100Hz  【难过】抱歉，我不得不这么做……
        4.55s  44100Hz  【开心】我最喜欢这家店的橡木蛋糕卷，每天都要吃一个。
        4.70s  44100Hz  【吃惊】快起来啦…没有人靠磕头打商战的吧……
花火    3.41s  44100Hz  【恐惧】合作对象储备库…
        6.77s  44100Hz  【吃惊】…好吧，看你这个表情是不会相信我的…没事，我可以明天再来问你一遍！
        7.05s  44100Hz  【难过】——活在梦里的人们，真的能够远离痛苦，收获真正的幸福吗？
        7.86s  44100Hz  【开心】最近想根据性格给自己打造一个全新面具，换一副样子玩玩。有没有什么推荐？
卡芙卡  3.42s  44100Hz  【中立】黑塔用这么简单的小玩意藏她的宝贝？
        3.73s  44100Hz  【开心】不知道呢，我猜不透哪个答案才是你的真心话。
        7.81s  44100Hz  【难过】这里不好，太卜要走很长的路，对我也没什么好处。去前面再会吧。
        8.85s  44100Hz  【吃惊】啊，原来如此。黑塔的收藏一定独立于系统之外，所以不受影响的就是目标。
胡桃    6.79s  48000Hz  【默认】嘿嘿，毕竟找活人不是我擅长的事嘛，如果让我找的是「边界」另一边的人…
芙宁娜  7.04s  48000Hz  【默认】根据故事走向，前往特定情景吗？听起来挺新颖。所以信封里写了什么？
```

**听书适配性判断**：流萤最优（情绪覆盖面最全，含「中立」「难过」，且语音偏长句）；卡芙卡次之；
花火缺「中立」且样本偏短。听书主诉求是**长时间平稳叙述**，因此「中立」这类平稳样本比「生气／吃惊」更重要。

---

## 2. 破坏模式与修复可行性

| 事实 | 证据 |
|---|---|
| 五个**外层 zip 结构完全正常** | `delta == cd_size + 22`（尾部多出的字节就是中央目录 + EOCD 本身）。例：流萤 `cd_off=305,015,477`、`cd_size=2,828`、EOCD 偏移 `305,018,305`，与文件大小 305,018,327 差 22 即 EOCD 定长尾巴 |
| 损坏发生在**条目数据层**，不是结构层 | `unzip -t`：`流萤/花火/卡芙卡` → `invalid compressed data to inflate`；`芙宁娜` → `bad zipfile offset (local header sig)`；`胡桃` → `No errors detected` |
| 三种独立工具**交叉复现**同一错误 | Apple `unzip -t`、Python `zipfile`、`bsdtar -xf`（报 `ZIP decompression failed (-3)`）。**排除单一解析器假象** |
| `.pth` 是标准 PyTorch zip，**仅开头 2 字节幻数被改写** | 胡桃 pth 头 16 字节：`30 34 03 04 00 00 08 08 ...`；应为 `50 4B 03 04`（`PK\x03\x04`）。把首字节改回 `PK` 后 `zipfile.testzip() == None`，262 个条目全部可读 |
| 这类损坏**是社区已知模式，且有现成兜底** | `High-Logic/Genie-TTS` 的 `src/genie_tts/Converter/load_state_dict.py`：<br>`meta = f.read(2)` → `if meta != b"PK": data = b"PK" + f.read()`，即官方转换器**默认会补幻数前缀** |
| 流萤 pth **不可修复** | 解压流首字节为 `30 36 03 04`（= `"06"` + `\x03\x04`），与胡桃同属幻数被改写，且 deflate 流在 167,740,855 B 处就报错 → 数据本身缺失，**必须重下** |
| 解压失败点百分比 | 流萤 97.09%、花火 99.90%、卡芙卡 88.23%、芙宁娜 ckpt 73.06% / pth 0.00% |

> **结论**：胡桃/芙宁娜的 `.pth` 理论上可救活（Genie 的兜底路径正是为此），
> 但它们同时是 **v4**，当前无转换器支持（§6），故**不做修复投入**。
> 流萤/花火/卡芙卡的 `.pth` 属真损坏，**必须从原始渠道重下**。
>
> **⚠ P0 修正（2026-09-26）**：上一行「真损坏」的**成因被后续验证反转**。
> 本地三个 zip 的 sha256 与 ModelScope 仓库记录**不一致**（长度相同、内容不同）；
> 用 `aihobbyist/GPT-SoVITS_Model_Collection` 的 `resolve/master` 直链重下后，sha256 **逐字节吻合**，
> `.pth` 解出完整 172,765,299 B。即：**损坏来自当时的下载过程，源文件是好的**。
> 重下得到的 `.pth` 仍带「前 2 字节幻数被改写」（`30 36` 应为 `50 4B`），改回 `PK` 后 684 条目 `testzip=None`。
> 对照：胡桃源 zip 哈希本就一致；芙宁娜本地哈希同样不一致（v4，本期不动）。
> 详见 [`docs/tts-p0-report.md`](tts-p0-report.md) §2。

---

## 3. 版本谱系与模型结构

**版本判定来源 = 包内 `train.log`**（仅 v4 两包带日志，v2ProPlus 三包由 pth 体积 + ckpt `data.pkl` 判定）：

| 证据 | v2ProPlus（流萤/花火/卡芙卡） | v4（胡桃/芙宁娜） |
|---|---|---|
| `train.log` | 无 | `pretrained_s2G: GPT_SoVITS/pretrained_models/gsv-v4-pretrained/s2Gv4.pth` |
| `train.log` 关键项 | 无 | `lora_rank: 32`、`epochs: 10`、`batch_size: 8`、`fp16_run: True`、`version: v4` |
| pth 体积 | **172,765,299 B**（全量） | **75,549,998 B**（LoRA 小体积） |
| ckpt 内路径线索 | `logs/…/logs_s1_v2ProPlus`、`pretrained_s1: …/s1v3.ckpt` | 同左（ckpt 结构一致） |
| SoVITS pth 内容 | 全量权重 `ref_enc.*` / `quantizer.*` 等 | **88 个 LoRA key**：`cfm.base_model.model.estimator.transformer_blocks.*.attn.{to_q,to_k,to_v,to_out}.lora_{A,B}` |

**GPT（T2S）配置** — 从 ckpt 内 `data.pkl` 提取，**v2ProPlus 与 v4 完全一致**：

```
n_layer           = 24
head              = 16
hidden_dim        = 512
linear_units      = 2048
phoneme_vocab_size= 732
vocab_size        = 1025
EOS               = 1024
```

**训练超参（v4 train.log）**：`sampling_rate 32000`、`hop_length 640`、`semantic_frame_rate 25hz`、
`n_speakers 300`（**注意：单说话人微调仍沿用 300，不是 1**）、`freeze_quantizer True`、`gin_channels 512`。

> `n_speakers: 300` 与 `lora_rank: 32` 是后续排查「合成出来不像目标音色」时的关键线索。

---

## 4. 路线尽调（含来源，官方宣称 / 第三方实测分别标注）

### 4.1 Route A — GPT-SoVITS → ONNX → Rust → 鸿蒙

| 项目 | 事实 | 来源 |
|---|---|---|
| `bailu-obj/gpt-sovits-onnx-rs` | 7 star、0 issue、MIT、最近 commit `2026-07-23` | GitHub API |
| **唯一提供 Rust 原生流式 API** | `synthesize() -> Stream<Item = Result<f32, GSVError>>`、`synthesize_sync()`、`process_reference_sync()` | `src/lib.rs` L209/275/513/718 |
| v2ProPlus **端到端已验证** | `doc/v2proplus_validation.md`：导出产物齐全、SV embedding shape `[1, 20480]`、输出 mono 32kHz、同步推理 ~1447ms | 仓库文档（第三方实测） |
| 波形 parity 记录 | 时长 2.38s（76,160 samples）双方一致；RMS 0.00308 vs 0.00283；SV head max-abs diff < 0.00001 | 同上（第三方实测） |
| 速度 | v2ProPlus：PyTorch 992ms → Rust ONNX 548ms（**约 1.8×**）；v2Pro 910→400ms（约 2.3×） | `doc/pytorch_vs_onnx_speed.md`（第三方实测，macOS CPU） |
| 移动端实测 | 骁龙 8 Elite / Android 15：int8 T2S 775.3ms + SoVITS 1.07s = **E2E 1977ms** | `doc/perf_record.md`（第三方实测） |
| **音频质量自评** | README 表格中自评 **「★★☆☆☆（不稳定）」**，并主动建议 Android 场景改用 sherpa-onnx | 仓库 README（**作者自评，非第三方复现**） |
| 支持的版本 | 仅 **v2 / v2Pro / v2ProPlus**；`--version` 参数校验明确拒绝其它值 | `scripts/export/05_export.sh` L21、`lib/common.sh` `version_weight_paths()` |
| 导出栈要求 | **仅支持 macOS**；需 `02_patch.sh` 用 `patch/GPT_SoVITS/` **覆盖上游**（因官方 `t2s_model_onnx.py` 用内部 cache 字典，与 Rust 所需**外部 KV-cache** 不兼容） | `scripts/README.md` |

> ⚠️ **关键约束**：该项目的 ONNX 布局是**定制版**（外部 KV-cache），
> **与官方 `export_onnx.py` 及 Genie 的产物不通用**。Runtime 与 exporter 必须成对使用。

### 4.2 Route B — GPT-SoVITS → sherpa-onnx

| 项目 | 事实 | 来源 |
|---|---|---|
| `k2-fsa/sherpa-onnx` 健康度 | **14,967** star、最近 push `2026-09-22`、626 open issues | GitHub API |
| **不支持 GPT-SoVITS** | TTS 后端仅有 VITS / Matcha / Kokoro / Kitten / **ZipVoice** / Pocket / Supertonic；`csrc` 全树无 `sovits` | 仓库文件清单 + `csrc/offline-tts-*.cc/h` + `c-api.h` L2268–2441 |
| 但有真实 OHOS 支持 | `build-ohos-arm64-v8a.sh`、`harmony-os/SherpaOnnxTts` 官方示例、`ohpm install sherpa_onnx` 预构建 HAR | 仓库 + 官方文档 |

> ❌ **结论：Route B 不成立**。它无法加载你的任何模型 —— 这**不是工作量问题，是路径不存在**。
> 若坚持走 sherpa，等价于「放弃这 5 个音色，改用它的通用音色」。

### 4.3 Route C — sherpa-onnx ZipVoice（零样本克隆）

| 项目 | 事实 | 来源 |
|---|---|---|
| 定位 | offline **zero-shot voice-cloning**，需同时给 `--reference-audio` 与 `--reference-text` | 官方文档 `tts/zipvoice.html` |
| 模型体积 | `zipvoice-distill-int8-zh-en-emilia` **109.2MB**（下载量 93,901）+ `vocos_24khz.onnx` **54.2MB**（下载量 90,057） | GitHub release assets（**官方宣称体积，非实测**） |
| Rust API | `rust-api-examples/examples/zipvoice_tts.rs` 已存在 | 仓库 |
| **精度警告** | 官方明确：`--reference-text` 必须是参考音频的**逐字稿**，不匹配则合成质量显著下降 | 官方文档 |
| OHOS 可用性 | 走官方示例工程 + 预构建 HAR，**无需自建 ORT** | 官方文档 |

### 4.4 其它候选（已评估，未选）

| 项目 | star | 最近 push | 支持版本 | 判定 |
|---|---|---|---|---|
| `High-Logic/Genie-TTS` | 1,782 | 2026-08-30 | **V2 / V2ProPlus** | 无 Rust/OHOS 路径；**用作交叉验证的转换器**（见 §7） |
| `GPT-SoVITS-Devel/GPT-SoVITS_minimal_inference` | 57 | 2026-03-13 | — | Python + TensorRT，不适合端侧 |
| `GPT-SoVITS-Devel/GPT-SoVITS-cpp` | 20 | 2026-03-12 | — | C++ 绑定，更新停滞 |
| `ldqm1/gpt-sovits-rust-cpu` | 1 | 2026-08-25 | v2/v2ProPlus | 单 star 服务端项目，无可参考工程沉淀 |
| `Qcomm870/gpt-sovits-onnx-rs-assembled` | 1 | 2025-06-30 | — | 上游账号删除后的旧镜像，勿用 |

### 4.5 ONNX Runtime 的鸿蒙现实（**最大工程风险**）

| 事实 | 来源 |
|---|---|
| **ORT 官方无 OHOS 支持** | `microsoft/onnxruntime` issue **#20895** 仍靠社区手搓；v1.30.0 / v1.29.1 / v1.28.2 的 release assets **均无任何 ohos 产物** |
| 社区给出的可行 build 参数（**未附产物，属「宣称可行」**） | issue #20895 评论 `wqwz111`：`--android --android_abi=arm64-v8a --android_ndk_path=$HARMONY_NDK ... add `-DOHOS_ARCH=` + `-Wno-unused-command-line-argument` |
| **唯一现成 OHOS ORT 预构建** | 社区 `csukuangfj/onnxruntime-libs`：`onnxruntime-ohos-{arm64-v8a,armeabi-v7a,x86_64}-1.16.3.zip`（仅 1.16.3 一个版本） |
| `ort` 指向自建 ORT 的方式 | `ORT_LIB_PATH` / `ORT_LIB_PROFILE` 环境变量，或 `load-dynamic` 特性 + 运行时加载 |
| 版本错配风险 | `bailu` pin 的是 `ort = "=2.0.0-rc.12"`（期望较新 ORT），而社区 OHOS 预构建只有 **1.16.3** → **大概率不兼容** |

> 结论：**必须自建 ORT 1.22.0 for OHOS**（`bailu` 的 `build_for_android.sh` 用的正是 1.22.0），
> 社区 1.16.3 预构建**只能用于快速冒烟验证，不能作为最终方案**。

### 4.6 版本支持矩阵（**决定本期范围的硬约束**）

| 版本 | 官方 ONNX 导出 | bailu (Rust) | Genie (Python) | 你的包 |
|---|---|---|---|---|
| v1 | ✅ | ✅ | ❌ | — |
| v2 | ✅ `onnx_export.py` `vits_model="v2"` | ✅ | ✅ | — |
| **v2ProPlus** | ❌（导出脚本只处理 v1/v2） | ✅ | ✅ | **流萤 / 花火 / 卡芙卡** |
| v3 | ❌ | ❌ | ❌ | — |
| **v4** | ❌ | ❌ | ❌（issue #27 作者确认未支持） | **胡桃 / 芙宁娜** |

> **矛盾点**：GPT-SoVITS 官方 README 明确写「**V4 修复了 V3 非整数倍上采样导致的金属音问题，原生输出 48kHz**」，
> 即**音质更好的胡桃/芙宁娜，正好是 ONNX 工具链不支持的那一类**。这是整个方案的核心张力。

---

## 5. 显存/内存分析（**当前最大风险**）

v2ProPlus ONNX 产物（`mikv39/gpt-sovits-onnx-custom`，HF 官方清单）：

| 文件 | 全精度 | int8 |
|---|---|---|
| `bert.onnx` | 1197.5 MB | 169.9 MB |
| `g2pW.onnx` | 635.3 MB | 93.5 MB |
| `ssl.onnx` | 377.6 MB | 377.6 MB |
| `t2s_fs_decoder.onnx` | 318.9 MB | 87.2 MB |
| `t2s_s_decoder.onnx` | 315.3 MB | 80.2 MB |
| `vits.onnx` | 162.2 MB | 162.2 MB |
| `t2s_encoder.onnx` | 7.9 MB | 7.9 MB |
| `g2p_en/*` | 16.6 MB | 16.6 MB |
| **合计** | **约 4.0 GB** | **约 850 MB** |

**关键事实**：

1. **`ssl.onnx`（HuBERT，377.6MB）与 `bert.onnx` 必须同时常驻** —— 预处理管线要同时产出 SSL 特征与 BERT 特征，无法分时复用。
2. **`chinese-roberta-large` 无法通过量化/裁剪缩小** —— 它要喂 `bert_proj`（1024→512），缩了就破坏语义。
3. 实测常驻估算：int8 下 ssl 377 + bert 170 + vits 162 + 3×t2s 175 + g2pW 93 ≈ **约 0.9–1 GB**，
   再叠加 ONNX Runtime 的 arena allocator 与 KV-cache → **超过原定 256MB 的三到四倍**。
4. **没有任何同规模端侧实测基准可比**（GitHub 搜索 `repo:bailu-obj/gpt-sovits-onnx-rs memory/RSS/内存` → **0 条结果**；
   `gpt-sovits onnx android` 仓库搜索 → **0 条结果**）。因此内存只能靠 §10 P2 自己实测。

> 依 §0 决策 4，256MB 已放宽为「不 OOM / 不崩 / 可连续 1–4h」，**具体上限以 P2 实测为准**。

---

## 6. 风险矩阵（听书场景）

| 维度 | A: GPT-SoVITS→ONNX→Rust/OHOS | B: GPT-SoVITS→sherpa-onnx | C: sherpa ZipVoice |
|---|---|---|---|
| **稳定性** | ⚠️ 作者自评「不稳定」；单维护者、0 issue | — | ✅ 官方维护，14.9k star |
| **内存占用** | ❌ 约 1GB（超 256MB 3–4×） | — | ⚠️ 模型 109+54MB，需实测 |
| **流式能力** | ✅ Rust `Stream<f32>` + 逐样本回调 | — | ✅ 已验证 `synthesize_sync` + 回调 |
| **长文本处理** | ⚠️ 需自行按句切分（参考音频建议 3–10s） | — | ⚠️ 需按句切分 + 参考文本严格对齐 |
| **鸿蒙适配成熟度** | ❌ 零现成；需自建 ORT + 自写 NAPI | ❌ 路径不存在 | ✅ 官方示例工程 + 预构建 HAR |
| **音色/情感表现力** | ✅ v2ProPlus 接近原版；流萤含 6 种情绪样本 | — | ⚠️ 取决于参考音频质量与逐字稿精度 |
| **保留你的 5 个音色** | ✅ 可用 3 个（v2ProPlus） | ❌ 完全不可用 | ❌ 不可用（换成参考音频克隆） |
| **工程落地工作量** | 🔴 高（导出 + ORT 交叉编译 + NAPI + 内存调优） | 🔴 无解 | 🟢 低 |

**关键矛盾（明确标注）**：

- `bailu` README 自评音频「★★☆☆☆（不稳定）」且主动推荐改用 sherpa-onnx —— **与本次路线选择直接冲突**。
- 我**不采信该自评结论**，理由：① 属作者主观打分，无 A/B 样本、无第三方复现；② 未指明「不稳定」的具体表现
  （截断？重复？音色漂移？）；③ 同仓库的 `v2proplus_validation.md` 给出的波形 parity 数据（RMS/时长/SV diff < 1e-5）**反而是正向证据**。
- 但**同样不接受「路线 A 更优」的预设** —— 矩阵清楚显示 A 在**内存**与**鸿蒙成熟度**两项上是真短板。
- 该矛盾**只能靠 §10 P2 实际听音 + 实测判定**，本阶段**不下结论**。

---

## 7. 推荐路径与降级条件

> **2026-09-29 拍板**：主路线由 A **切换为路线 C / CosyVoice 2 混合方案**；GPT-SoVITS 标记为
> 「**端侧不可行**」（P4 实测：端侧 RTF 下限 1.483、两条并行杠杆均封顶，「<1.0」不可达，见 §9 P4 ⑨）。
> 下方 A 路线的锁定栈与工程决策为**历史记录**，新实施以「路线 C」小节为准。

**主路线 = A**（**已废弃**，2026-09-29 起转路线 C），实现栈**锁定**为：

```
bailu 的 patch/ + scripts/export/  （导出）
        ↓  产出「外部 KV-cache」定制 ONNX 布局
bailu 的 Rust runtime（ort 2.0.0-rc.12）
        ↓  NAPI（ohos-rs）
鸿蒙 App（复用 TtsController 的 PCM 队列 + AudioRenderer + AVSession）
```

**锁定理由**：Runtime 与 exporter 是**成对定制**的（§4.1 的 KV-cache 约束），
混用官方导出或 Genie 产物会导致模型加载失败。

**三条工程决策**：

1. **交叉验证**：同一 checkpoint 另用 **Genie-TTS 转换器**导出一份，比对 ONNX 图输入输出与波形，
   避免「单一来源」——若两者音质差异显著，说明定制导出的 parity 有问题。
2. **ORT 策略**：pin `ort = 2.0.0-rc.12` + `load-dynamic`，自建 **ORT 1.22.0 for OHOS**
   （走 issue #20895 社区参数）；社区 1.16.3 预构建仅作冒烟。
3. **降级条件（写死，不临时再议）**：满足**任一**条即转向路线 C，并把 GPT-SoVITS 标记为「端侧不可行」——
   - P2 听音后判定音质不可接受（明显机械音/串音/漏字），
   - 或 Mac 端 RTF 差到无法支撑听书（连续合成跟不上播放），
   - 或真机实测 OOM / 崩溃且调优无效。
   - **（2026-09-29 实际触发）**：§7 原文三条**均未触发**，但 P4 自带验收「端侧 RTF < 1.0」**未达标**
     （1.57–1.93），按 §7 精神**触发转向**——GPT-SoVITS 标记「端侧不可行」。

**明确不做**：

- ❌ 为 v4/v3 自写 ONNX 转换器（本期范围外）
- ❌ 移植 Genie 的 Python runtime 到端侧
- ❌ 让 sherpa-onnx 接入 GPT-SoVITS（路径不存在）
- ❌ 模型分发方案（§0 决策 5，推迟）

**路线 C / CosyVoice 2 混合方案（2026-09-29 起为主路线）**：

- **目标**：兑现「端侧实时听书」验收（CosyVoice 2 中文流式 RTF 0.2–0.6，感知质量达人类水平；
  支持粤语/四川话/上海话等，覆盖现有听书语料场景）。
- **架构**：短句**端侧流式直出**（候选运行时**首选自研 = 官方 ONNX 导出 + ORT for OHOS**；
  首包低至 ~150 ms 是**官方 GPU 口径**，CPU 端侧首包/RTF 需实测）；
  长文本**按语义 + 标点分段**（每段 ≤200 字，必须显式识别中文标点）；
  剩余兜底走**系统 TTS 回退**（复用 M5 链路）。
  > ⚠️ **P5 核实修正（2026-09-29）**：原文「官方鸿蒙 SDK `NativeNui`」**不存在**（上一轮 §7 拍板时的
  > 未经验证假设，官方仓库无任何 harmony/ohos/napi 端侧运行时）。端侧无现成 CosyVoice 运行时，本方案
  > 只能**自建**（官方 ONNX + ORT），详见下方修正块与 §9 P5。
- **验证路径**：① Mac Docker（纯 CPU 无实时性，只验流式接口/音质/分段正确性）→
  ② 鸿蒙手机（`HBN-AL80` Pura 70 Pro+ / 麒麟 9010 / 16 GB / API 24）短句流式 + 长段分段 +
  系统 TTS 回退。
- **代价与取舍**：手头 5 个 GPT-SoVITS 音色**无法 1:1 迁移**到 CosyVoice 2（后者为音色/韵律可控重建，
  非角色克隆）；若未来仍要保留既有音色，代价最低的是「云端/Mac 预生成 + 端侧只播放」。
- **下一步**：CosyVoice 2 POC（P5，见 §9 后续）。

**路线 C 端侧运行时候选（P5 核实，2026-09-29）**：

| 候选 | 现状 | 判定 |
|---|---|---|
| 官方鸿蒙 SDK（`NativeNui`） | **不存在**（官方仓库无 harmony/ohos/napi/native 端侧运行时；全网 0 命中） | ❌ 排除，勿再当既定事实 |
| 官方 ONNX 导出 | `export_onnx.py` **只导 `flow.decoder.estimator` 一个子模块**（opset 18）；LLM/vocoder 无官方 ONNX | ⚠️ 只有一部分，不够用 |
| sherpa-onnx | 支持的 TTS 仅 VITS / Matcha / Kokoro / ZipVoice，**无 CosyVoice、无 GPT-SoVITS** | ❌ 排除 |
| **自研 = 官方 ONNX + ORT for OHOS + NAPI** | LLM **可导 ONNX**（第三方已证：`cosyvoice3-onnxruntime` 全套导出含 LLM KV-cache 48 张量 FP16、`cosyvoice3-rknn-russian` 在 RK3588 端侧跑 hybrid CPU/NPU、`Lourdle/CosyVoiceForOnnx` Flow+HiFT 改造）；P4 已打通 ORT 1.24.4 for OHOS + NAPI 骨架 | ✅ **首选**，原方案不变 |
| onnxruntime-mobile | 本质 ORT 裁剪版；P4 已自建 ORT for OHOS，此路已通，非"新候选" | 并入自研 |
| MindSpore Lite / NNRt | GitHub 0 CosyVoice 先例；对自回归 LLM（KV cache + 动态 shape）支持有限，需脱离 ORT 另起炉灶 | ⚠️ 存在但不划算 |

> **P5 净结论（详见 §9 P5）**：「LLM 能否导 ONNX」这一最大不确定性**已被第三方先例证伪——可导出**。
> 端侧可行性的真正风险**转移到「CPU 端侧 RTF 是否达标」**（CosyVoice LLM = Qwen2 0.5B 自回归 + Flow
> Matching 10 步 euler 迭代，成本显著高于 GPT-SoVITS 的 t2s；P4 已证 GPT-SoVITS 端侧 RTF 下限 1.483）。
> 故 P5 的下一动作是**先做 Docker CPU 验证**（拿 Mac CPU 的 LLM tok/s + Flow 步耗时 + 总 RTF），
> **再**决定是否上鸿蒙 SDK POC；不要从「无端侧运行时」直接跳鸿蒙。

---

## 8. 待验证项（**必须实跑/实编才能确认的假设**）

| # | 假设 | 为何必须实跑 | 验证手段 | P2 状态 |
|---|---|---|---|---|
| — | *（状态列：P2 实测结论摘要，详见 §9 的 P2 结果；未完成项留待 P3/P4）* | | | |
| 1 | 转换后**音质是否真的可用** | bailu 自评「不稳定」是否成立，唯一证伪方式是听 | P2 人工听音 + 与 Python 基线 A/B | **客观可用**：SV 克隆度 0.86–0.91、0 截顶、语速正常；**长段有 2.3 s 复读**（§9 §⑤），主观听音留 P3 |
| 2 | Mac 端 **peak RSS** 与端侧可用内存 | 目前**无任何同规模端侧基准**（搜索 0 结果） | P2 实测 + P4 真机 | ✅ 实测 fp32 peak 3.86–4.20 GiB / int8 1.94–2.28 GiB；端侧仍待 P4 |
| 3 | ORT 1.22.0 能否用 OHOS toolchain 交叉编出 `.so` | 社区只给参数、**未附产物**，属宣称 | P4 实编 |
| 4 | `ort` rc.12 与自建 ORT 的 API/opset 兼容性 | rc.12 期望较新 ORT，1.16.3 大概率不兼容 | P4 实编 + 加载冒烟 |
| 5 | v2ProPlus 三个 t2s 分片在**长句**下的自回归稳定性 | 是否胡言乱语 / 提前 EOS / 重复，无法静态判断 | P3 长文本压测 | ✅ **已定性（P3）**：`pred_semantic` 正常、无胡言乱语；「复读」实为 **VITS 恒定尾部伪影**（≤30 字分片可压到 0/5），详见 §9 P3 §①/§⑦ |
| 6 | 参考音频 44.1kHz → 32kHz 重采样与 Python 基线一致 | 不一致会直接影响音色相似度 | P1 `compare_infer_metrics.py` | ✅ 间接确认：克隆度 0.86–0.91（未现音色偏差） |

---

## 9. 原型验证计划（P0–P4）

### P0 环境与权重（Mac）

```bash
# 1) 克隆上游（仅一次）
./scripts/export/01_clone.sh
# 2) 覆盖 patch（t2s_model_onnx.py 等，必须做，否则 KV-cache 不兼容）
./scripts/export/02_patch.sh
# 3) 装环境（conda 优先，python 3.10）
./scripts/export/03_setup_env.sh --source HF
# 4) 拉预训练依赖
./scripts/export/04_download_models.sh --version v2ProPlus
```

`04` 会拉：`s1v3.ckpt`、`v2Pro/v2Gv2ProPlus.pth`、`sv/pretrained_eres2netv2w24s4ep4.ckpt`、G2PW、`g2p_en`。

**重下损坏权重**并覆盖 `GPT_SoVITS/pretrained_models/` 下的 `s1v3.ckpt` 与 `v2Pro/s2Gv2ProPlus.pth`。
**不改原 zip**；旧文件解压到 `/tmp/tts-probe/`（见 §11）。

两条绕过下载的路径（推荐第 1 条，不改脚本）：

1. `ln -sfn` 到 `models/export/v2ProPlus/{gpt.ckpt,sovits.pth}`（`stage_export_models()` 正是这么 staging 的）；
2. `05_export.sh --output-dir` 指定输出目录 + 自备 reference wav。

**参考音色选择**：主用流萤「**【难过】抱歉，我不得不这么做……**」（4.41s，平稳长句，最适合听书）；
另用「【中立】…我应该会选择请求猎犬家系停止追捕。」做对照。
**参考文本 = 文件名去掉 `【情绪】` 前缀的部分**。

> **⚠ P0 修正（2026-09-26）**：【难过】的 4.41s 里**前 1.75s 是静音**，实际语音仅 **2.61s**
> （低于 3–10s 建议下限）；运行时不做静音裁剪，静音会进 SSL 特征。
> 已生成裁静音版 `models/v2ProPlus/流萤/ref.wav`（2.68s）并 staging 到 `models/export/v2ProPlus/ref.wav`。
> 因有效语音偏短，「【难过】最适合听书」这一判断**需在 P2 复验**；备选【中立】3.38s、【开心】4.40s。

#### P0 结果（2026-09-26，✅ 已完成）

| 步骤 | 结果 | 备注 |
|---|---|---|
| `01_clone.sh` | ✅ | 上游克隆到 `gpt-sovits-upstream/` |
| `02_patch.sh` | ✅ | 10 文件覆盖 + 新增 `export_onnx_v2.py` |
| `03_setup_env.sh` | ✅ | uv `.venv`（py 3.10.19）；**3 处平台偏差见报告 §3** |
| `04_download_models.sh --version v2ProPlus` | ✅ | `s1v3.ckpt` / `s2Gv2ProPlus.pth` / `sv/*.ckpt` / G2PW / g2p_en 全部 `testzip=None` |
| 重下三套角色权重 | ✅ | 流萤 / 花火 / 卡芙卡：sha256 与仓库一致，`torch.load` 通过（678 张量、含 `ref_enc`/`quantizer`） |
| staging `models/export/v2ProPlus/` | ✅ | 指向流萤（主用音色） |

- 下载源用 `--source HF-Mirror`（`ModelScope` 分支的 `HF_BASE` 仍指向 huggingface.co，本机直连超时）。
- 环境偏差（`onnxruntime-gpu` 无 osx wheel、`llvmlite` 需 pin、`onnxsim` 无 x86_64 wheel 而用 stub）
  与 `onnxsim` stub 的可审计性说明，见 [`docs/tts-p0-report.md`](tts-p0-report.md) §3/§4。
- 本机为 **Intel macOS 26.6.2（x86_64）**，与计划书假定的 Apple Silicon 不同 —— P2 的 RTF 基线需按此解读。

### P1 导出与校验

```bash
./scripts/export/05_export.sh --version v2ProPlus --export-name custom_v2proplus --no-quant
./scripts/export/validate_bundle.sh --bundle-dir gpt-sovits-upstream/onnx-patched/custom_v2proplus --expect-v2pro
./scripts/compare_infer_metrics.py --seed 42
```

- 先 `--no-quant` 保音质基线；量化版留到 P2 对比。
- 校验产物齐全：`ssl.onnx` / `bert.onnx` / `sv.onnx` / `g2pW.onnx` / `g2p_en/` / `{prefix}_t2s_*.onnx` / `{prefix}_vits.onnx`。

> **P1 前置（P0 已铺好）**：`models/export/v2ProPlus/` 当前 staging 的是**流萤**。
> **导出粒度 = 每个音色一份 bundle**：05 的 dummy input 用 `torch.randn` 假音频，**不读参考音频**；
> 参考音频/参考文本是 **P2 推理时**的运行时输入，故流萤【难过】与【中立】**共用同一份 bundle**。
> 已核实三套 `gpt.ckpt` 确有差异（295 张量中 294 个不同）→ 每个音色各导一份。
> 主用导出名 `liuying`；可选再导 `huahuo` / `kafuka`。
> 三套权重与参考音频固化在 `~/Documents/playground/tts/models/v2ProPlus/<角色>/`（sha256 见 P0 报告 §6）。

#### P1 结果（2026-09-26，✅ 已完成）

| 项 | 结果 |
|---|---|
| `05_export.sh --export-name liuying --no-quant` | ✅ 全流程跑通（导出 + `optimize_aio.py` onnxslim + opset 21） |
| `validate_bundle.sh --expect-v2pro` | ✅ `Bundle validation passed (prefix=liuying)` |
| 可选音色 `huahuo` / `kafuka` | ✅ 各导一份，同样通过校验与 ORT 加载 |
| 单份 bundle 体积 | **3.2 GB**（与 §5 估的 3–4 GB 一致） |
| 总耗时 | 单音色约 **16 分钟**（导出 ~3 min + optimize ~13 min，bert 占 ~2.5 min） |

**产物清单（`gpt-sovits-upstream/onnx-patched/liuying/`，全部 opset 21）**

| 文件 | 字节 | sha256（前 16） |
|---|---|---|
| `bert.onnx` | 1,197,473,531 | `35a7ea4dab0efe8c` |
| `g2pW.onnx` | 635,261,826 | `e44d7bbaa07b8456` |
| `ssl.onnx` | 377,674,588 | `093edf9b95bc604e` |
| `liuying_vits.onnx` | 337,721,049 | `aff04cdadb42f2fd` |
| `liuying_t2s_fs_decoder.onnx` | 318,891,897 | `2ff5713e12807f4f` |
| `liuying_t2s_s_decoder.onnx` | 315,280,985 | `2404d917ec868d04` |
| `sv.onnx` | 182,622,960 | `c841c0387fa3a6df` |
| `liuying_t2s_encoder.onnx` | 7,876,208 | `24c681334bcdac36` |
| `g2p_en/encoder_model.onnx` | 6,634,844 | `5df81746fe1872b6` |
| `g2p_en/decoder_model.onnx` | 9,999,491 | `2c199ceaa2411862` |
| `ref.wav`（P2 用，从 05 输入目录拷入） | 236,684 | `b287aefa07ef7e91` |

- `liuying.json`（在 `gpt-sovits-upstream/onnx/`）：`"Version": "v2ProPlus"`、`"IsV2Pro": true`、`Rate: 32000`。
- 图接口符合定制 KV-cache 布局：`*_t2s_s_decoder.onnx` 暴露 `iy` + **48 个外部 cache 输入**
  （`ik_cache_0..23` / `iv_cache_0..23`）+ `y_len` / `idx`；`*_vits.onnx` 输入含 `sv_emb`。
- 全部 10 个图 `onnx.checker` 通过，且用 `onnxruntime`（CPU, `ORT_DISABLE_ALL`）**逐个加载成功**（仅加载、不推理）。
- `huahuo` / `kafuka` 的 sha256 见 [`docs/tts-p0-report.md`](tts-p0-report.md) §11。

**新增平台偏差（Intel macOS / torch 2.2.2）**

上游工具链假设 **torch ≥ 2.6**；本机 Intel macOS 的 torch 上限是 **2.2.2**（无 2.6+ x86_64 wheel），
触发 4 个新偏差。均已用**可审计、可回滚**的方式修掉（见 P0 报告 §10.1），**未改 `patch/GPT_SoVITS/` 的 patch 语义**：

| # | 现象 | 处置 |
|---|---|---|
| 1 | `transformers` 拒绝 `torch.load` 加载 `.bin`（CVE-2025-32434，要求 torch ≥ 2.6） | 为 `chinese-hubert-base` / `chinese-roberta-wwm-ext-large` 生成 `model.safetensors`（保留原 `.bin`）；transformers 优先用 safetensors，不触发版本闸 |
| 2 | `torch.onnx.export` 不认 `dynamo=` kwarg | 在克隆副本上把 `_LEGACY_ONNX_KWARGS` 置空（该 kwarg 只是**关闭** dynamo，2.2.2 本就只有 legacy 导出器） |
| 3 | 同上，`opset_version=20` 报 `Unsupported ONNX opset version: 20`；降到 19 又报 `ReduceMean axes` checker 错（torch 实际已验证只能到 **17**） | 导出 opset 统一 20 → **17**；下游 `optimize_aio.py` 必跑 `convert_version(model, 21)`，最终 bundle 仍是 **opset 21**，与 2.6+ 主机一致 |
| 4 | transformers 默认 SDPA attention，torch 2.2.2 无法 trace（`TypeError: z_()`） | `HubertModel` / `AutoModelForMaskedLM` 显式 `attn_implementation="eager"`（数学等价，dummy trace 无掩码/填充位） |

> 处置落在 **工具链仓库**（仓库外）：新增 `scripts/export/lib/{patch_torch_legacy_export.py,ensure_safetensors.py}`，
> 并在 `05_export.sh` 增加两个**仅当 torch < 2.6 才触发**的兜底钩子——纯增量、幂等，torch ≥ 2.6 的主机行为不变。
> `patch/GPT_SoVITS/` 未改动；`02_patch.sh` 可随时还原上游副本。

**音色无关/相关的产物差异（实测）**

- 三份 bundle 中 `ssl.onnx` / `sv.onnx` **逐字节相同**（音色无关，可直接复用）。
- `bert.onnx` / `g2pW.onnx` 的 sha256 不同，但经比对**张量逐元素相同、拓扑/算子多重集相同**；
  差异只在 1–2 个 value_info 的符号维度**标签**（如 `input_ids_length` vs `token_type_ids_len`），
  属 onnxslim 的非确定性命名，**非语义差异**。
- 音色相关的是 `{prefix}_t2s_*.onnx` 与 `{prefix}_vits.onnx`（三套互不相同）→ **每音色一份 bundle 的结论成立**。

> P2 前置：`gpt-sovits-upstream/onnx-patched/liuying/ref.wav` 已放好（流萤【难过】裁剪版，2.683s，
> 与 P0 报告 §7.1 同一文件）。`models/export/v2ProPlus/` staging 已还原为**流萤**。
> `huahuo` / `kafuka` 的 bundle **未放 ref.wav**（其参考音频选择留到 P2，按需从
> `~/Documents/playground/tts/models/v2ProPlus/<角色>/中文/emotions/` 拷入）。

### P2 Mac 推理与指标（**决策门**）

```bash
cargo run --release --example gpt_sovits_demo -- \
  --model-path gpt-sovits-upstream/onnx-patched/custom_v2proplus \
  --ref-text "抱歉，我不得不这么做……" \
  --text "<测试文本>" --output output.wav
```

跑 3 类文本：① 短句 ② **一整个书页段落（300–500 字）** ③ 中英混排。
采集：**RTF**、T2S/VITS 分阶段耗时、**peak RSS**、**连续 100 次合成是否退化**（内存泄漏）。
再用 `optimize_aio.py` 出一份 int8，对比音质与内存。

**判定**：若音质不可接受或 RTF 无法支撑听书 → **立即触发 §7 降级条件，转路线 C**。


#### P2 结果（2026-09-27，✅ 已完成 — 决策门通过，带「单句 ≤ ~45 字」约束）

**环境**（与 §10 附录 / P0 报告 §5 同机）：

| 项 | 值 |
|---|---|
| 主机 | Intel MacBookPro16,2，i5-1038NG7（4 核 8 线程），16 GB，macOS 26.6.2 |
| 引擎 | Rust `cargo --release`，`ort` **2.0.0-rc.12**，链接 **ORT 1.23.2** dylib（API 23），8 intra-op 线程 |
| bundle | 全精度 fp32（3.2 GB）与 int8（1.2 GB），同源 `onnx-patched/liuying`（流萤） |

> **P2 新增偏差（必须先看）**：`ort` rc.12 默认要 **ORT 1.24 / API 24**，但微软**从 1.24 起不再发布 x86_64-macOS 的 ORT**（Intel 最后一版是 **1.23.2 / API 23**），
> 故 `download-binaries` 路径在 Intel macOS 直接失败（`ort does not provide prebuilt binaries for x86_64-apple-darwin`）。
> 处置（落在工具链仓库、纯可回滚，见 P0 报告 §12）：`ort` 改用 `default-features=false` + `api-23`，
> 并把 `ORT_LIB_LOCATION` 指向 venv 自带 `libonnxruntime.1.23.2.dylib` 做动态链接。
> 这与 §4.5 / §8 第 3–4 条完全同源：**ORT 版本与 API 等级是这条路线的硬约束**，P4 的 OHOS 自建 ORT 也必须 ≥1.24 才能配 rc.12。

**测量口径**（三条都写死，便于复现）：

- **RTF = 总合成耗时 / 音频时长**。总耗时取 demo 自报的「Synchronous Inference」`Average`（**仅合成**，不含 `TTSModel::new` 模型加载与参考音频 SSL/SV 预处理）。
- **T2S / VITS 分阶段**：直接从引擎 `DEBUG` 日志解析，`T2S Encoder`（对 `ssl_content` 取 prompt）、`T2S FS Decoder`（首趟预填）、`T2S S Decoder`（逐 token 自回归）、`SoVITS all`（VITS 合成）。
- **peak RSS**：`getrusage(RUSAGE_CHILDREN).ru_maxrss`（macOS 单位=字节）取**子进程峰值**；同一轮用 1 Hz `libproc` 采样 `ri_resident_size` 交叉验证。
  另记 **phys_footprint**（macOS 的「真实内存压力」口径，显著低于 RSS，见下表）。
  三态数值可差 25%（注意别把 `/usr/bin/time -l` 的口径当唯一真相）。

> **反噪声协议**：本机是共享机器。P2 头两小时遇到**外部进程把 4 核打满**（`duetexpertd`/`BiomeAgent`/`MTLAssetUpgraderD` 等），
> 使同一段文本从 4.6 s 飘到 34 s。故每格取 **K 次独立进程**（短句/基线 K=3，长段/混排 K=1），并在每轮记录 `loadavg_start`；
> 下表只采用 **load1 ≤ ~12** 的窗口。负载敏感，绝对值仅供参考。

**① 主表（fp32，流萤）—— RTF 与分阶段耗时**

| 文本 | 参考 | 字数 | 音频 | 总耗时(中位) | **RTF** | T2S S Decoder 均 | SoVITS 均 | g2pw 预处理 |
|---|---|---|---|---|---|---|---|---|
| 短句（30 字） | 【难过】 | 30 | 7.80 s | 7327 ms | **0.94** | 1728 ms | 1606 ms | 412 ms |
| 短句（30 字） | 【中立】 | 30 | 6.32 s | 5870 ms | **0.93** | 1277 ms | 1304 ms | 375 ms |
| 基线短句（中英，77 字，4 分片） | 【难过】 | 77 | 14.68 s | 12955 ms | **0.88** | 1424 ms | 1454 ms | 394 ms |
| 基线短句（中英，77 字，4 分片） | 【中立】 | 77 | 11.28 s | 10453 ms | **0.93** | 1162 ms | 1094 ms | 370 ms |
| **书页长段（444 字，11 分片）** | 【难过】 | 444 | 95.30 s | 93452 ms | **0.98** | 4133 ms/片 | 3666 ms/片 | 4547 ms |
| **书页长段（444 字，11 分片）** | 【中立】 | 444 | 85.66 s | 83118 ms | **0.97** | 3501 ms/片 | 3229 ms/片 | 5617 ms |
| **中英混排（251 字，4 分片）** | 【难过】 | 251 | 41.40 s | 38971 ms | **0.94** | 4747 ms/片 | 4207 ms/片 | 1751 ms |
| **中英混排（251 字，4 分片）** | 【中立】 | 251 | 36.04 s | 35175 ms | **0.98** | 4345 ms/片 | 3763 ms/片 | 1576 ms |

> **这一版是在「负载 7–16、无外部饿死」窗口下测的**；更早一次外部满载窗口下同样文本测得 RTF 2.6–7.3，**不可采信**，已弃用。
> 「基线短句」的分段器把 77 字切成 **4 个分片**（`。你好啊` / `这是一个测试` / `吃葡萄…` / `This demo…`），故其耗时≈4×短句，是分段行为导致、非模型退化。

**② int8 对比（同 bundle、同参考，`optimize_aio.py` 默认量化）**

| 文本 | 精度 | 音频 | 总耗时 | **RTF** | peak RSS | phys_footprint | bundle 体积 |
|---|---|---|---|---|---|---|---|
| 短句 | fp32 | 7.80 s | 7327 ms | 0.94 | 3.86 GiB | 2.70 GiB | 3.2 GB |
| 短句 | **int8** | 7.68 s | 5788 ms | **0.75** | **1.94 GiB** | **1.42 GiB** | 1.2 GB |
| 基线短句 | fp32 | 14.68 s | 12955 ms | 0.88 | 3.86 GiB | 2.49 GiB | 3.2 GB |
| 基线短句 | **int8** | 14.52 s | 10709 ms | **0.74** | 1.95 GiB | 1.47 GiB | 1.2 GB |
| 书页长段 | fp32 | 95.30 s | 93452 ms | 0.98 | 4.19 GiB | 2.87 GiB | 3.2 GB |
| 书页长段 | **int8** | 91.26 s | 71066 ms | **0.78** | **2.28 GiB** | **1.81 GiB** | 1.2 GB |
| 中英混排 | fp32 | 41.40 s | 38971 ms | 0.94 | 4.10 GiB | 2.75 GiB | 3.2 GB |
| 中英混排 | **int8** | 43.12 s | 33323 ms | **0.77** | 2.22 GiB | 1.74 GiB | 1.2 GB |

**int8 三赢**：更快（RTF 0.74–0.78）、内存近乎腰斩（peak 3.9→1.9 GiB、footprint 2.7→1.4 GiB）、体积 2.7×更小。
量化后的**客观克隆度 0.86–0.89，与 fp32 同级**（见 §③）→ **推荐 int8**。注意量化只作用于 `{prefix}_t2s_fs_decoder` / `{prefix}_t2s_s_decoder`（+ 4bit `g2pW`/`bert`）；
`vits` / `ssl` **不量化**（`optimize_aio.py` 明确跳过），故体积与内存不会落到 1/4。

**③ 参考音频复验（§7.2 悬念，✅ 结论：裁剪版【难过】够用）**

用 P1 已验证的 Kaldi-fbank → `sv.onnx`（eres2net）路径算**合成音频 vs 自身参考**的余弦相似度（客观音色克隆度）：

| 参考 | cos（4 类文本） | 结论 |
|---|---|---|
| 【难过】裁剪版 2.68 s | 0.86 / 0.87 / 0.88 / 0.90（短句×3 / 长段 / 混排 / 基线） | ✅ 落点与【中立】同级 |
| 【中立】3.38 s | 0.87–0.91 | ✅ 对照 |
| **int8**（【难过】） | 0.83 / 0.86 / 0.86 / 0.89（短句 / 长段 / 混排 / 基线） | ✅ 与 fp32 同级（同参考同文本）|

- 两条参考的克隆度**统计上无差别**（都 0.86–0.91），**没有出现**「2.61 s 有效语音 ⇒ 音色崩」的现象。
- 故 **P0 §7.2 的悬念解除**：【难过】裁剪版可用，**无需**退回【中立】/【开心】。
- 代价是时长差：同文本【难过】比【中立】多 15–30%（短句 7.80 vs 6.32 s、长段 95.3 vs 85.7 s）——【难过】更慢更拖，但仍在合理听书语速（4.7–6.1 字/秒）。
- 注意这条是**客观**克隆度（说话人向量），**不等于人耳自然度**；主观听音仍建议在 P3 抽 3 条对照。

**④ 质量与长稳**

- **截顶**：全部 12 组、peak ≤ 0.87，**0 个样本截顶**。RMS 0.10–0.13。
- **语速**：4.7–6.1 汉字/秒，符合中文听书区间（无「快读/吞字」迹象）。
- **进程内重复稳定**（20 次同文本）：耗时 avg 7940 ms（min 7561 / max 8788），**无退化漂移**——T2S S Decoder 首次 1246/2014 ms → 末次 1171/1987 ms 基本持平；
  内存末值 2.08 GiB（峰值 3.87 GiB），**无泄漏趋势**；KV cache **0 次重分配**。
- **100 次（早前高负载窗口）**：峰值 3.71 GiB、末值 2.69 GiB、**0 泄漏**、KV **0 重分配**、**0 崩**（但该轮耗时因外部负载不可采信，仅作「不崩/不漏」证据）。

**⑤ ⚠ 长文本重复缺陷（§8 第 5 条已坐实，是 P2 唯一实质风险）**

在 444 字长段里检测到 **2.32 s 逐采样完全相同**的片段，跨分片边界：

| 参考 | 重复出现处 | 相隔 | 性质 |
|---|---|---|---|
| 【难过】 | 19.5 s ↔ 90.5 s（跨「分片2 尾 + 0.3 s 间隔 + 分片3 头」） | 71 s | 逐采样 diff = 0.0 |
| 【中立】 | 26.5 s ↔ 81.0 s | 54.5 s | 逐采样 diff = 0.0 |

- **机制判定（证据链）**：VITS 在给定「同一 semantic-token 序列 + 同参考」时是**确定性**的，故**两个不同位置逐采样完全相同 ⇒ 该处 T2S 采样器吐出了同一串 semantic token**，
  即 **T2S 自回归在长上下文里「绕回」了已说过的语义**（不是静音填充、也不是拼接复用缓冲——重复块**跨分片边界、两侧文本不同**，且只出现在长文本上）。
  频谱侧佐证：该块有谐波结构（谱平坦度 0.073 vs 正常语音 0.364），能量低（RMS ≈ 语音的 1/4）是**那句话本身轻**，与「复读同一句」一致。
- **只在长文本触发**：444 字长段出现 1 处（≈2.3 s / 95 s）；**短句（7.8 s）与中英混排（41 s）无逐采样重复**。
  `int8` 长段未复现「逐采样相同」，仅在分片首尾出现**低能量包络高相似区**（包络 cos 0.97–0.99、逐采样 cos 0.56–0.98、**无 0 差**）——同一类低能量尾部现象，程度更轻。
  因此这是**采样依赖**的引擎级缺陷（默认 `temperature=1.0/top_k=4/top_p=0.9/rep_penalty=1.35`），与 §8 第 5 条预判一致。
- 影响面：听感上像「复读了一句」。**对整本听书是必须处理的风险**，但**不是 §7 的降级触发条件**（音质本身可用）。
  **必须在 P3 用非固定 seed + ASR 转录**坐实复读范围与频率（P2 只用固定 seed=42 各 1–3 次，不足以给复读率）。

**⑥ 决策门判定（按 §7 三条降级条件逐条核）**

| §7 降级条件 | P2 实测 | 判定 |
|---|---|---|
| 音质不可接受（机械音/串音/漏字） | 克隆度 0.86–0.91；0 截顶；语速正常；无漏字迹象（**长段有复读**，见 §⑤） | **不触发**（带复读约束） |
| Mac 端 RTF 撑不住听书 | 宽裕窗口 RTF **0.74–0.98**（int8 0.74–0.78） | **不触发** |
| 真机 OOM/崩溃 | 本期不做真机；Mac peak 1.9–4.2 GiB（int8 约 2 GiB） | **待 P4**（内存是最大风险，见 §5） |

> **结论：P2 决策门 = 通过（带两个约束）**。
> ① **必须用 int8 bundle**（RTF/内存双赢，客观指标不掉）；
> ② **长段必须先按标点切到 ≤ ~45 字再合成**（否则触发 §⑤ 复读）——这正是 P3 的分段策略，且**必须在 P3 用非固定 seed 复测**。
> 不触发 §7 降级、不需要转路线 C；阻塞点回到 §5 的**端侧内存**（int8 ~2 GiB 常驻，仍远超原定 256 MB）。

### P3 分段与长稳

> **本条原计划（保留作对照）**：按标点切分为 **≤30s** 的合成单元；采样参数用
> `temperature=1.0, top_k=4, top_p=0.9, repetition_penalty=1.35`（`InferParams::default()`）；连续跑 1h 统计失败/截断/异常 EOS 率。
> **P3 修正**：① `seg.rs` 的实际切分是**按句末标点**（`。！？.!?`，非逗号），444 字长段 → **11 片**；
> ② 「≤30s」是**时长**界，但真正与复读相关的是**每片音频时长**（见 §①）；③ 计划里的「30s」需改成**字数/时长双约束**。

#### P3 结果（2026-09-27，✅ 已完成 — 复读定性为 **VITS 输出尾部伪影**，非语义绕回）

**配置**：int8 bundle（`p2/bundles/liuying-int8`）＋ 流萤【难过】裁剪参考；采样参数除注明外为 `InferParams::default()`；
分片用引擎同源算法（`preprocessor/seg.rs` 的 `pre_seg_text` + 「≤上限时切在最后一个标点」）。
**脚手架**（仓库外）：`~/Documents/playground/tts/p3/harness/`（`chunker.py` 复刻 `seg.rs`、`loopdetect.py` 复读检测、
`p3run.py`/`sweep.py` 批量、`proc_sampler.py` libproc 内存采样、`asr.py` faster-whisper、`speaker_sim.py` 音色克隆度）；
引擎侧新增**一次性** example `examples/gpt_sovits_p3.rs`（一次加载、按给定分片列表合成、输出每片耗时/语义 token 数），
以及 `src/lib.rs` 里 **env 门控**（`GSV_DUMP_SEMANTIC`）的 `pred_semantic` 全量 token dump——**均不影响默认行为**。

##### ① 复读性质重定性（**推翻 P2 §⑤ 的「语义绕回」机制判定**）

P2 §⑤ 断言「T2S 采样器在长上下文里绕回已说过的语义」。P3 用两条独立证据**证伪**：

- **与文本无关**：合成 **6 段文本完全不同**的 ≈45 字句（每段音频 >6.5 s），**每一片都在同一偏移（≈6.5 s 起）出现逐采样完全相同（maxdiff = 0.0）的尾块**：

  | 分片 | 0 | 1 | 2 | 3 | 4 | 5 |
  |---|---|---|---|---|---|---|
  | 音频时长 | 9.28 s | 8.56 s | 10.04 s | 9.96 s | 9.88 s | 9.96 s |
  | 相同尾块起点/长度 | 6.50 s / 2.60 s | 6.52 s / 1.80 s | 6.56 s / 3.30 s | 6.52 s / 3.20 s | 6.56 s / 3.10 s | 6.58 s / 3.20 s |

  跨片比对：`chunk0[6.5:9.1]` 与 `chunk2/3/4/5` 同区间 **maxdiff = 0.0**，而与其自身片头/中段 maxdiff ≈ 0.75。**逐采样相同 ⇒ 与语义无关。**
- **不是可懂语音**：该尾块 `rms = 0.030`（正常语音 0.136，仅 ~1/4）、`peak ≈ 0.088`、谱平坦度 0.224（语音 0.275–0.292）、中心频率 2166 Hz（语音 ~3000 Hz）；
  用 faster-whisper 转写该区间得到**幻觉文本**（`"我愛你我愛你我愛你"` / `"字幕by索兰娅"`），不同片给出不同幻觉 ⇒ 无稳定语音内容。
- **token 层复核**：该尾块对应区间的 `pred_semantic` token 与片头 token **无一相同**（`identical=0/120`），
  故 **不是「采样器吐出同一串 token」**（P2 的推断链在此断掉），而是**音频/声学层**的产物。

**机制结论**：这是 **VITS（`{prefix}_vits.onnx`）的「恒定尾部伪影」**——每片波形在**固定偏移框**之后被一段**与文本、与语义 token 均无关**的固定含糊波形覆盖。
**触发条件 ≈「分片音频时长 > 6.5 s」**（见 §⑥ 的定量），**与引擎无关地由 VITS 图/其执行产生**，P3 不做修复（见 §⑧）。
> 附带修正：P2 报「2.32 s / 95.3 s 复读」是**漏检**；同一音频（`page_long__nanguo.wav`）实测存在 **6 处**跨分片相同尾块，最长 **8.0 s**（`44.814 s ↔ 65.014 s`，maxdiff 0.0），
> 但它们都在**同偏移框架**内，与 §① 的机制一致（P2 只标了其中 1 处）。

##### ② 复读率 vs 分片上限（非固定 seed，K=5；`cap=45` 另加 8 次）

「复读率」= **该次合成中出现 ≥1 个跨分片逐采样相同/近相同块（≥0.30 s）的运行占比**（见 §④ 口径）。

| 分片上限 | 分片数（444 字页） | 运行数 | 复读率 | 其中逐采样相同 | 最长块 | 分片音频中位 | 合成 RTF |
|---|---|---|---|---|---|---|---|
| **510**（引擎默认） | 11 | 25 | **64 %**（16/25） | 8 | 5.1 s | 8.5 s | 1.29 |
| 90 | 11 | 5 | 20 %（1/5） | 1 | 3.3 s | 8.3 s | — |
| 60 | 14 | 5 | 20 %（1/5） | 0 | 0.9 s | 7.0 s | — |
| **45** | 15 | 13 | **8 %**（1/13） | 1 | **0.3 s** | 6.6 s | 1.22 |
| **30** | 21 | 5 | **0 %**（0/5） | 0 | 0 s | 5.7 s | 1.18 |

- 单调性成立：**上限越小 → 分片音频越短 → 复读率与最长块越小**（与 §①「>6.5 s 触发」一致）。
- `cap=45` 那唯一一次残留是 **0.3 s 的逐采样相同块**（即单个 0.3 s `fragment_interval` 静音缓冲同窗），听感影响可忽略。
- > P2 建议「≤ ~45 字」在方向上正确，但**不够**：按 P3 实测，**只有 ≤30 字能给出 0/5**。

##### ③ 复读率 vs 采样参数（分片上限 510，非固定 seed，K=5）

| 参数组合 | 复读率 | 逐采样相同 | 最长块 | 合成 RTF | 音色克隆度 cos |
|---|---|---|---|---|---|
| `rep=1.35, t=1.0`（默认） | 60 %（3/5） | 2 | 4.8 s | 1.35 | 0.869 |
| `rep=1.60, t=1.0` | 80 %（4/5） | 3 | 4.5 s | 0.85 | 0.865 |
| `rep=2.00, t=0.7` | 60 %（3/5） | 1 | 5.1 s | 1.36 | 0.860 |
| `rep=1.35, t=0.6` | 40 %（2/5） | 1 | 4.5 s | 1.27 | 0.867 |
| `rep=2.00, t=0.35`（最激进） | 80 %（4/5） | 1 | 4.5 s | 0.85 | 0.868 |

- **采样参数不能消除复读**：连「rep 2.0 + 温度 0.35」这种强抑制组合仍 4/5。
  这与 §① 的机制判定**互相印证**（伪影是 VITS 输出层的，采样器影响不到它）；P2 §⑤「采样依赖」的推断**被否定**。
- **音色代价可忽略**：五种参数的克隆度 0.860–0.869，落在 P2 基线 0.86–0.91 内，**无回退**。
  故 v1 **采样参数保持 `InferParams::default()` 不动**（调参无收益、且改默认会抬高与上游 Python 基线的偏差）。

##### ④ 1h 长稳（**最终配置**：int8 + 上限 45 + 默认参数 + 非固定 seed）

| 项 | 值 |
|---|---|
| 时长 / 吞吐 | 墙钟 **81 min**（合成 4846 s；音频 **5545 s**；960 分片，`cap=45`） |
| 失败 / 异常 | **0 失败**、**0 截断**（`idx ≥ 1500` 跑满上限 **0 次**）、**0 panic**、**KV cache 重分配 0 次** |
| EOS | 960 次全部「提前 EOS」正常停止；`pred_semantic len` 34–278（无异常长尾） |
| 内存 | peak RSS **2.23 GiB** / peak footprint 2.39 GiB；末值 1.45 / 2.35 GiB |
| 泄漏 | RSS 漂移 +0.54 GiB ≈ harness **累积输出的 PCM 字节**（0.43 GiB 预期，同量级）⇒ **判为无泄漏**；footprint 更稳（2.11→2.35 GiB） |
| 复读 | 24 个去重分片里 **10/24（42 %）音频 > 6.5 s**，其中共享同一「恒定尾块签名」；估算 **约 12 %（6.5 s 阈值）～16 %（6.0 s 阈值）的构造音频是伪影**（含被覆盖的可懂内容） |
| 负载 | `load1` ≈ 4.1–11.1（轮内变化大，见报告 §12.2 噪声协议） |

##### ⑤ 最终 RTF 复测（int8，`cap=45`，**安静窗口** `load1 ≈ 1.7–11`）

| 文本 | 字数 | 分片 | 音频 | 合成 RTF | peak RSS | 复读 |
|---|---|---|---|---|---|---|
| 短句 | 30 | 2 | 7.26 s | **0.92** | 1.85 GiB | 0 |
| 基线（中英短） | 90 | 4 | 13.64 s | **0.87** | 1.91 GiB | 0 |
| 书页长段 | 444 | 15 | 97.72 s | **0.82** | 2.04 GiB | 0 |
| 中英混排 | 271 | 9 | 41.26 s | **0.78** | 2.00 GiB | 0 |

> 与 P2（RTF 0.74–0.78）同带、略高，差异来自分片更碎与外部负载；**全部 < 1.0 ⇒ 仍可支撑实时听书**。

##### ⑥ 分片上限对预处理与 RTF 的影响

| 分片上限 | 分片数 | g2pw 预处理（444 字页，总） | 每片调用 | 合成 RTF |
|---|---|---|---|---|
| 510 | 11 | 5.42 s | 385 ms | 1.29 |
| 45 | 15 | ~6.50 s | — | 1.22 |
| 60 | 14 | 6.03 s | 449 ms | — |
| 30 | 21 | — | — | 1.18 |

- 分片越碎，g2pw 调用越多、预处理总耗时**小幅上升**（510→45 约 +20 %），但**合成 RTF 基本不变**（甚至略降）。
  1h 长稳里 g2pw 每片中位 **404 ms**、960 片合计 **391 s**（占墙钟约 8 %）——**不构成瓶颈**。

##### ⑦ 最终配置与结论

**定稿（P4 基准配置）**：
1. **int8 bundle**（P2 决策，沿用）；
2. **分片上限 = 30 字**（唯一在全部测试中 **0 复读** 的配置）；若预处理耗时敏感，可放宽到 **45 字**（1/13，残留 ≤0.3 s）；
3. **采样参数 = `InferParams::default()`**（`t=1.0, top_k=4, top_p=0.9, rep=1.35`）——调参无收益、会抬高与上游偏差；
4. **不固定 seed**（固定 seed 在本引擎**无位级可复现性**，见报告 §13；且固定 seed 不降低复读率）。

**「复读是否已被消除」= 未消除、但已**压到可忽略**：
- 复读**不是**「长文本语义绕回」（P2 判定错误），而是 **VITS 的恒定尾部伪影**，触发条件是**分片音频时长 > 6.5 s**；
- 靠分片只能**降低概率、缩短残留**（510→30 时复读率 64 %→0 %），**不能根除机制**；
- 在最终配置（30 字 + 默认参数）下，P3 的全部测试**未再观测到跨分片复读**；但样本量有限（K=5），**不能宣称「永不发生」**。

##### ⑧ 残余风险与处置（对听书场景的影响）

- **影响评估**：伪影是**低能量（约语音 1/4）的含糊人声**，位置在整片尾部、时长随分片时长增长；听感上像「句尾拖出一段听不清的糊音」。
  它**不会静音、不会崩**，也不会像「复读一整句」那样扰乱语义理解——比 P2 描述的「复读一句」**轻得多**。
- **是否触发 §7 降级**：**不触发**。§7 三条（音质不可接受 / RTF 撑不住 / 真机 OOM）均未被命中；伪影属「必须处理但不降级」的风险。
- **建议的处置（进 P4，按成本从低到高）**：
  1. **逐片时长守门**：合成后按 `audio_len ≈ 1280 × semantic_len` 预测片长，**> 6.6 s 的片**标红；
  2. **句级重试**：对超长片（或守门标红片）**重新合成 1 次**（伪影是随机的，重试有较大概率拿到干净片）——P4 若要更省事，也可只对超长片做「裁掉 >6.5 s 尾部」的兜底；
  3. **回退策略**：若某片连续 2 次重试仍超长，**回退到系统 TTS（M5）**播该片（M5 链路已在，切换成本低）；
  4. **报告口径**：把这套「守门 → 重试 → 回退」的命中率纳入 P4 的验收指标。
- **对 v1 听书方案的净结论**：路线 A **仍然可行**；把「分片 ≤30 字 + 逐片时长守门 + 句级重试」作为**端侧 TTS 的必备部件**写进 P4，而非事后补丁。

### P4 真机（**仅 P0–P3 通过后启动**）

- 自建 ORT 1.22.0 for OHOS arm64 → `ORT_LIB_PATH` 指向产物 → `ohrs build` 交叉编译。
- NAPI 新增三函数（草案）：

```ts
ttsInit(dir: string): Promise<void>
ttsSetReference(wavPath: string, refText: string): Promise<void>
ttsSynthesize(text: string, paramsJson: string): Promise<{ pcm: ArrayBuffer, sampleRate: number }>
```

- chunk 回调接**现有** `AudioRenderer` 播放；复用 `model/TtsController.ets` 的「按段落收集 PCM」队列骨架
  —— 其结构**天然适配**原生合成（把系统 TTS 的 `onData` 换成 NAPI chunk 即可）。
- **验收**：3.5 小时连续听书不崩、不 OOM、切后台不断、进度回写正常。

#### P4 结果（2026-09-28，**主机侧 + 真机均完成**；结论见 ⑨）

> **前提修正（重要）**：原计划「自建 **ORT 1.22.0**」**不成立**。`ort = 2.0.0-rc.12` 只暴露到
> **api-24**（`ort-sys` 的 `api-1x` feature 最高 `api-24`），而 **API 等级必须等于 ORT 内部 API 版本**，
> 所以目标 ORT 只能是 **1.24.x** 这条线（1.22.0=API 22 → `GetApi(24)` 返回 null → 运行时 panic）。
> **P4 实际采用 ORT 1.24.4**（§4.5 的「自建 ORT 1.22.0」据此更正；1.16.3 预构建仍只作冒烟结论不变）。

##### ① 自建 ORT 1.24.4 for OHOS arm64（✅ 完成）

| 项 | 值 |
|---|---|
| 产物 | `libonnxruntime.so.1.24.4`，**27 MB** |
| type | `ELF 64-bit LSB shared object, ARM aarch64` ✅ |
| SONAME / RUNPATH | `libonnxruntime.so.1` / `$ORIGIN` |
| NEEDED | `libc++_shared.so`, `libc.so`（musl） |
| 导出 | `OrtGetApiBase@@VERS_1.24.4` ✅；版本串 `1.24.4` |
| 编译 | clang 15.0.4（DevEco NDK）· Ninja · `--parallel 4` · ≈ 2 h 40 m（共享机器） |
| 交叉编译通 | ✅（**BFLOAT16 gate 通过**，见 §4.5 的担忧已被证伪） |

- 命令（社区参数，microsoft/onnxruntime#20895）：
  ```bash
  NATIVE=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native
  export OHOS_TOOLCHAIN_FILE=$NATIVE/build/cmake/ohos.toolchain.cmake
  python tools/ci_build/build.py --build_dir=... --config Release     --android --android_abi=arm64-v8a --android_ndk_path=$NATIVE --android_sdk_path=$NATIVE     --skip_tests --skip_submodule_sync --cmake_generator=Ninja --build_shared_lib     --parallel 4 --cmake_deps_mirror_dir=<mirror> --compile_no_warning_as_error
  ```
- **ORT 上游需 4 处 OHOS 补丁**（均用 `#if` 收口，非 OHOS 不受影响）：
  1. `tools/ci_build/build.py`：Android 分支注入 OHOS toolchain + `OHOS_ARCH` + `-march=armv8.2-a+bf16`；
  2. `onnxruntime/core/mlas/lib/mlasi.h`：OHOS clang **无 `arm_bf16.h`**，给不带 `+bf16` 的
     TU（sqnbitgemm，只带 `+dotprod`）补 `typedef unsigned short bfloat16_t;` 占位；
  3. `onnxruntime/core/platform/posix/env.cc`：musl 无 `pthread_setaffinity_np`，加 `!defined(__OHOS__)`；
  4. `cpuinfo` 的 `CMakeLists.txt`：`CMAKE_SYSTEM_NAME` 不认 `OHOS` → 把 OHOS 当 Linux（否则 arm64 源不编译，
     链接报 `undefined symbol: cpuinfo_isa`）。
- 依赖：41 个 `FetchContent` 包预下到本地 mirror（本机直连 GitHub ≈30 KB/s → `gh-proxy.com` ≈14 MB/s）。
- **降级判定**：**未触发**。1.24.4 编得出 ⇒ 无需退回「rc.12 + 1.23.2/api-23」的 Mac 妥协方案。

##### ② 引擎 + NAPI 交叉编译（✅ 完成，待设备）

| 项 | 值 |
|---|---|
| 引擎 `rlib` | `aarch64-unknown-linux-ohos` 全绿（onig_sys/tokenizers/jieba/rubato 等 C 依赖需 `CFLAGS_<target>` 带 `--sysroot`） |
| NAPI 产物 | `libgpt_sovits_tts_ohos.so`，**27 MB**（stripped） |
| NEEDED | `libace_napi.z.so`（**无 `libonnxruntime` 直接依赖** ⇒ `load-dynamic` 生效，运行时 dlopen） |
| 导出 | `napi_register_module_v1` ✅；`OrtGetApiBase` 为**未定义符号**（dlopen 解析）✅ |
| 语义 | `ttsInit` / `ttsSetReference` / `ttsSynthesize` / `ttsMetrics` / `ttsShutdown`（JSON 进、`reason` 失败键） |

- **`load-dynamic` 在 OHOS 天然可用**：rustc 对 OHOS 报 `target_os="linux"` + `target_env="ohos"`，
  `ort` 走 Linux 分支 dlopen `libonnxruntime.so`，无需 OHOS 特判。
- **分片在端侧怎么切**：P3 定稿（≤30 字 + 标点）已下沉到引擎
  `seg::chunk_for_limit(text, max_len)`（`enforce_max(pre_seg_text(..), 30)`），
  **与 P3 harness 单测对齐**（444 字页 → 11/15/21 片 @ 510/45/30），ArkTS 不再复刻切分。

##### ③ §⑧ 处置的落地（✅ 已实现，待真机跑数据）

- 守门 + 重试做进引擎 `TTSModel::synthesize_guarded(text, …, maxAudioSec, maxRetries)`：
  阈值量的是**预测 VITS 波形长**（`1280 × semanticLen / 32000 s`，即伪影可覆盖的跨度），
  **不是**后处理缓冲（后者还含 0.3 s `fragment_interval` 静音）；
- 超阈重合成 1 次；仍超阈 → `over_limit=true`（交宿主系统 TTS 回退）；
- NAPI 暴露 `ttsMetrics()`（`guardHits/retries/retrySuccesses/fallbacks` + 命中率），供验收表直接取数。

##### ④ 端侧 RTF（真机，`cap=30`，与 Mac 同口径）

设备：`HBN-AL80` / `OpenHarmony-6.1.1.120` / API 24 / 12 CPU（4 大 + 8 小）/ 16 GB。
驱动：`p4/ohos-tts-test` 的 NAPI 验收 HAP（按钮 C，`benchSynthesize`，`getrusage` 计时，
与 Mac 的 `p4/tts-bench rtf <case> 30 1` 是同一份引擎代码与同一份 `cases.json`）。

| 用例 | 片数 | 端侧音频 | 端侧 RTF（`-O3`，性能模式 602） | Mac RTF（`cap=30` 同口径） |
|---|---|---|---|---|
| `short_zh` | 2 | 8.2 s | **1.570** | 0.825 |
| `baseline_doc` | 5 | 14.2 s | **1.745** | 0.819 |
| `page_long` | 21 | 97.0 s | **1.926** | 0.89 † |
| `mixed_zh_en` | 14 | 44.5 s | **1.884** | 0.916 |
| **ALL** | 42 | 163.9 s | **1.881** | 0.82–0.92 |

† Mac 今日 `page_long` 那次撞上共享机器 load 尖峰（load1 2.0 → 12.7，单次跑到 1.517）**不采信**，
取 P3 复测的 0.89；`0.82–0.92` 与 P3 的 `cap=45` 基准（0.78–0.92）同带。

- `threadUtil ≈ 3.9`（4 线程真的在跑）；`guard=0`，`page_long` 有 1 片 `overLimit`（cap=30 下的尾部伪影，见 ⑧）。
- 换 `-Oz` 壳、正常电源模式的同口径全量：`1.504 / 1.515 / 1.889 / 1.897`，**ALL 1.842**。
  ⇒ **端侧 RTF 1.5–1.9 是稳定结论**：电源模式（600/602）在噪声内；编译档 `-Oz→-O3` **只**改善固定开销
  那一段（§14.13），不改变区间。
- 单核对照（排除"只是核少"，`GSV_INTRA_THREADS=1`，同口径、Mac load1≈2.5–3.9）：

  | 用例 | Mac 单线程 | 端侧单线程 | 比 |
  |---|---|---|---|
  | `short_zh` | 1.658 | 2.550 | 1.54× |
  | `baseline_doc` | 1.615 | 2.466 | 1.53× |

  ⇒ **端侧单核慢 ≈1.5×**（Ice Lake 的 AVX-512/VNNI 对 ARM dotprod/i8mm 的单核优势）；
  而线程扩展性 Mac 1→4 线程 **2.0×**、端侧 1→8 线程只 **1.32×** ⇒ 端侧还额外丢掉了一半的并行收益。
- **判定：P4 验收「端侧 RTF < 1.0 才算不降级」→ ❌ 未达标（1.57–1.93）**。

##### ⑤ 端侧 RTF 的归因（逐条排除，证据在 `p4/`）

**(a) 线程/池/自旋（按钮 D，性能模式，`-Oz`，`short_zh + baseline_doc`）**

| 档位 | ALL RTF | threadUtil | 备注 |
|---|---|---|---|
| `default8`（P3 默认：8 intra + 自旋 + 每会话独立池） | 1.901 | 3.9 | 端侧 `get_hw_big_cores()` fallback 到 8 |
| `intra1` | **2.495** | 1.00 | 单链单核 |
| `intra2` | 1.930 | 1.97 | |
| `intra4` | 1.894 | 3.90 | |
| `intra8` | 1.928 | 7.58 | 8 线程只多烧 CPU |
| `intra4-nospin` | 1.771 | 3.35 | |
| `shared4-nospin` | **1.708** | 3.89 | 共享全局池 + 关自旋，最好也只比默认好 10% |

⇒ **1→8 线程只买到 1.32×**（Amdahl 串行占比 ≈72%）。线程侧**调优无效**。

**(b) 逐片回归：差距全部落在 T2S 自回归环**

用每片 `ms` 对 `semanticLen`（`sem = (audio_sec − 0.3) × 25`）做线性回归：

| 平台 | 拟合式 | R² |
|---|---|---|
| Mac（P3 `fin30` 5 轮 × 21 片） | `ms = 884 + 40.66·sem` | 0.77 |
| 端侧（Gate C `page_long` 逐片） | `ms = 884 + 73.81·sem` | 0.93 |

- **每片固定开销 884 ms ↔ 884 ms（1.00×，完全一致）**：特指每片都要跑的 BERT/g2pW/encoder/VITS/后处理。
- **每语义 token：40.7 ms ↔ 73.8 ms（1.82×）**：GPT 自回归解码环（`s_decoder`+`fs_decoder`，串行逐 token）。
- 即：端侧 RTF 的劣势 ≈ **1.82 × 自回归环占比**，而不是"整体慢 2 倍"。

**(c) 已排除的其它假设**

| 假设 | 结论 | 证据 |
|---|---|---|
| 小核漂移 | 否 | `threadCpus()`：ORT worker 落 CPU 4–11（大核簇） |
| 计时口径差异 | 否 | Mac 用同一 `tts-bench` 同口径复测（当日 load1 2.3→18 的窗口不采信；P3 安静窗口 0.78–0.92 一致） |
| ORT int8 内核缺失 | 否 | `llvm-nm` 见 `MlasGemmU8X8KernelUdot` / `S8S8KernelSDot` / `Smmla` / `KleidiAI` 均在 |
| 编译档（`-Oz`） | 只解释固定开销 | `-Oz → -O3` 改善集中在短用例（见 §14.13），`page_long` 噪声内 |
| 主线程阻塞 / hostile ambient load | 否 | 设备 load≈0；`threadUtil 3.88`；UI 全程 `await` |

**(d) 唯一未闭合的杠杆：分片级并行**

- 单链 RTF 2.50 且 `threadUtil=1.00` ⇒ **一条链基本吃饱一个核**，而**线程内**并行只 1.32×
  ⇒ 瓶颈是**延迟**（每 token 的小算子 + 自回归串行），不是带宽/算力 ⇒ **N 条独立链并行理论上 ≈ N× 吞吐**（4 路 ≈ 0.6）。
- 工程障碍（现状即串行）：引擎 `TTSModel::synthesize_*` 是 `&mut self`，NAPI 壳又是全局 `Mutex<EngineState>`。
- 测量手段：`ttsInitMulti` / `benchParallel`（每副本 1 线程、非自旋、独立池 + 大核绑定），结果见下表。

| 配置 | 分片数 | 音频 | 墙钟 | **聚合 RTF** | 对照：单链 1 线程 2.495 / 单链 8 线程 1.901 |
|---|---|---|---|---|---|
| 2 副本，自由调度 | 6 | 20.0 s | 37.7 s | **1.889** | 只有单链 8 线程的水平 |
| 2 副本，绑核 `4,6` | 6 | 20.5 s | 51.0 s | 2.490 | 更差 |
| 4 副本，自由调度 | 12 | 40.0 s | 59.3 s | **1.483** | 4 份模型各 3 片 |
| 4 副本，绑核 `4,6,8,10` | 12 | 40.0 s | 87.4 s | 2.183 | 更差 ⇒ 该集合不是大核 |

- **结论：分片级并行这条杠杆实测不成立。** 4 条独立链只把吞吐提到 `2.495 / 1.483` = **1.68×**（理论 4×），
  端侧 RTF 的**实测下限 = 1.483**，仍 >1.0。
- 争用证据（2 副本 free）：6 片逐片耗时之和 **69.4 s**，墙钟只有 **37.7 s** ⇒ 两链确实重叠 **1.84×**，
  但**每条链自己慢了 ~1.4×**，净收益只剩 1.33×。4 副本同理（最慢链的 59.3 s 决定墙钟）。
- 同一副本不同 CPU 差 ~2×（4.9 s 音频：6.9 s vs 20.4 s）⇒ 设备上各 CPU 可用算力差异很大，
  且 `4;6;8;10` **不是**纯大核集（绑它反而更慢）。
- **已排除"假瓶颈"**：引擎推理路径**没有全局锁**（只有只读 lazy 静态 + 建会话期的 `RwLock`），
  `run_async_in_context` 用的是多线程 tokio runtime ⇒ 并行是真的，瓶颈是**共享资源争用**。
- 复现：HAP 按钮 **F（2 副本）/ G（4 副本）** → `ttsInitMulti(dir, copies, ref.wav, refText, "{}")`
  ＋ `benchParallel({"chunks":[...], "cpus":[...]})`；副本各持 1 线程非自旋池，按 `i % copies` 轮转分片。
- **要看的是聚合 RTF**（`wall / 总音频`），不是单链 RTF：单链 2.5 时，4 条独立链并行**理论上** ≈0.6。
- **代价与边界**：多副本 = 权重 ×N（4 副本 ≈ 4×1.2 GB 驻留），所以这只是**测量装置**；
  生产化必须把引擎改成 `&self`（8 个 session 共享、并发 `Run`），**属于新的工作项**。

##### ⑥ 真机内存（**Pss 口径**，§13.4）

采样：`p4/sample_mem.sh`（`hidumper --mem <pid>` 的 **Total Pss** 为主口径，`/proc/<pid>/status` 作辅证）。

| 时刻（长稳进行中） | Total Pss | VmRSS | VmHWM | RssAnon |
|---|---|---|---|---|
| 装载完成 + 3 min（n≈20） | 1.95 GiB | 2.08 GiB | 2.11 GiB | 1.96 GiB |
| n≈50 | 1.96 GiB | 2.09 GiB | 2.12 GiB | 1.97 GiB |
| n=150（19 min） | **1.99 GiB** | 1.76 GiB † | **2.13 GiB** | 1.65 GiB † |

- † `VmRSS`/`RssAnon` 在 23:31 之后**回落**（1.99 → 1.11 GiB 再回 1.76 GiB），是页回收/文件页被丢掉的表现
  ⇒ 又一次印证 §13.4「RSS 不可作主口径」；**Pss 单调且平缓（+0.04 GiB / 19 min）**，`VmHWM` 2.13 GiB 封顶。
- 与 Mac 同带：P3 端 `peak RSS 1.85–2.04 GiB` / `peak footprint ≈2.4 GiB`。**无 OOM、无增长性泄漏迹象**。
- 模型常驻（Gate B 后、未跑推理）：`hidumper` Total Pss **1.74 GiB** / `VmRSS` 1.87 GiB。

##### ⑦ §8 守门 / 重试 / 回退命中率（真机，`cap=30` + 重试 1 次）

| 场景 | 片数 | guard 命中 | 重试成功 | 回退（`overLimit`） |
|---|---|---|---|---|
| ① 强制触发（`maxAudioSec=3.0`，`retry=1`） | 6 | 2（pred 4.76 / 4.56 s） | 0 | 2 |
| ② 自然命中（生产路径 `ttsSynthesize(retry=1)`，10 min） | 54 | **1（1.9 %）** | **0** | 1 |
| ③ Gate C 全量（bench 路径 `retry=0`，两次） | 42 ×2 | 0 / 1 | — | 0 / 1 |
| ④ 60 min 长稳（前 31 min，`retry=0`） | 150 | 0 | — | 5（3.3 %） |

- **阶梯可用**：强制触发证实「守门 → 重试 1 次 → 仍超 → `overLimit` 交宿主」链路与计数正确
  （`ttsMetrics()` 口径：`synthesizes 60 / guardHits 3 / retries 3 / retrySuccesses 0 / fallbacks 3`）。
- ⚠️ **重试成功率实测 0（0/3）**：守门量的是**预测 VITS 波形长**（`1280·sem/32000`），
  它是采样产物、不是尾部伪影长度；`cap=30` 下真超阈的片基本是"文本本身偏长"，重采样落不回阈值内
  ⇒ §⑧ 原文设想的"伪影随机、重试大概率干净"在本配置下**得不到支持**，能兜住这些片的只有**回退**。
- 自然命中率 **1.9 %（1/54）～3.3 %（5/150）**（`cap=30`），与 P3 §②（`cap=30` 为 0/5）方向一致。
- `ttsMetrics()` 在端侧可直接读全部计数与比率（Gate B 实测返回正常）。

##### ⑧ ≥1 h 纯合成长稳（真机）

配置：`cap=30` + `retry=0`（bench 路径）+ P3 定稿参数、**非固定 seed**、正常电源模式（600）、UI 停前台、
池 = 4 用例的 42 片循环。首轮开始 23:20:41；重跑（2026-09-29 09:50:03 起，按钮 E）开始后**边跑边落盘**
（`p4/sample_mem.sh` → `stability-mem.tsv`）。

> **2026-09-29 已闭环**：首轮 31 min 处 USB 掉线丢现场；重跑**跑满 60.15 min 未中断**，终值见下表最末行。

| 里程碑 | n（片） | 墙钟 | 音频 | RTF | 失败 | guard | 回退 | 异常 EOS |
|---|---|---|---|---|---|---|---|---|
| 5 min | 25 | 198 s | 104 s | 1.907 | 0 | 0 | 1 | 0 |
| 11 min | 50 | 352 s | 190 s | 1.854 | 0 | 0 | 1 | 0 |
| 19 min | 100 | 751 s | 384 s | 1.955 | 0 | 0 | 3 | 0 |
| 25 min | 125 | 945 s | 484 s | 1.952 | 0 | 0 | 3 | 0 |
| 31 min | 150 | 1148 s | 588 s | 1.952 | 0 | 0 | 5 | 0 |
| **60 min 终值（重跑）** | **483** | **3609 s** | **1874.8 s** | **1.924** | **0** | **0** | **8** | **0** |

- **0 失败 / 0 panic / 0 异常 EOS**；RTF 稳定在 **1.85–1.96**（无热降频劣化）；`shortEos` 代理指标全程 0。
- `回退 5/150 = 3.3%`：`cap=30` 下仍偶发预测片长 >6.6 s 的片（bench 路径 `retry=0`，故记在 `overLimit`）。
- ⚠️ **首轮本表只到 31 min**：00:0x 时**本机 USB 掉线**（`hdc list targets` → `[Empty]`，USB 总线上已无手机），
  采样与日志读取中断；**合成本身未中断**（跑在手机上，与 hdc 无关），但最终 `STAB DONE` 行需重连后补读。
  ⇒ 首轮**未能计入"≥1 h 不崩不 OOM"的完整验收**。
- ✅ **重跑终值（2026-09-29 09:50:03 – 10:50，按钮 E，边跑边落盘）**：
  `STAB DONE n=483 wall=3609s audio=1874.8s rtf=1.924 fails=0 guard=0 fb=8 shortEos=0 maxChunkMs=15517`
  - **跑满 60.15 min 未中断**；RTF **1.924** 与首轮 31 min 的 1.952 同带 ⇒ **无热降频劣化**；
  - **0 失败 / 0 panic / 0 异常 EOS**；`maxChunkMs=15517`（最坏单片 15.5 s，落在护栏内）；
  - `回退 8/483 = 1.66 %`（`cap=30`，bench 路径 `retry=0`，仍记 `overLimit`），与首轮 3.3 %（5/150）同带；
  - 内存（`stability-mem.tsv`）：Total Pss **≈1.93→2.13 GB 平稳**（10 采样点）、`VmHWM` **2.30 GB 封顶**，
    **无 OOM、无崩溃** ⇒ 「≥1 h 不崩不 OOM」**完整验收通过**（数据与坑见报告 §14.19）。
  - ⚠️ **新坑（重跑周期内确认）**：长稳期间**拿起手机 / 切后台**会触发 `minimizeAllScene`，OHOS **冻结 JS 线程**、
    长稳中断；**仅唤醒屏幕无害**（对策见报告 §14.19）。
- 「截断数（idx ≥ 1500）」口径说明：`cap=30` + 端侧 RTF≈1.95 时，1 h 只能跑 ≈**440 片**，
  **1 h 内无法到 idx ≥ 1500**（P3 的 960 片是 Mac + `cap=45`）⇒ 该阈值需 ≥3.5 h 才可能触及。

##### ⑨ §7 三条降级条件的逐条判定（**P4 收口**）

| 条件 | 判定 | 依据 |
|---|---|---|
| ① 音质不可接受 | **未触发** | P2/P3：SV 克隆度 0.86–0.91、0 截顶、0 失败 |
| ② Mac 端 RTF 撑不住听书 | **未触发** | P3 int8 `0.78–0.92 < 1.0`（P4 同口径复测一致） |
| ③ 真机 OOM / 崩溃且调优无效 | **未触发** | 见 ⑥/⑧：Pss 稳定、无崩溃、无 OOM |
| ④ **端侧 RTF < 1.0（P4 自带验收，§7 原文未预见）** | **❌ 未达标** | ④ 表：1.57–1.93；线程侧已证调优无效（⑤a），编译档/电源模式不改变结论 |

> **净结论（2026-09-29 更新）**：§7 写死的三条降级条件**均未触发**（音质、Mac RTF、真机内存/稳定性都过关），
> 但 **P4 自带验收「端侧 RTF < 1.0」不达标**——这是 §7 未预见的新情形，**不能靠"未触发 §7"就宣称 P4 通过**。
> - 归因已闭合：劣势 = 每语义 token 1.82× 的 T2S 自回归环（固定开销与 Mac 1.00× 一致）。
> - **两条并行杠杆都已实测封顶**：线程内 1→8 线程 **1.32×**（⑤a）、分片级 1→4 独立链 **1.68×**（⑤d）
>   ⇒ 端侧 RTF **实测下限 1.483**，「端侧 RTF < 1.0」在本设备 + 本栈上**不可达**（不是调参问题）。
> - **长稳已闭环（⑧ 重跑终值）**：60.15 min 无中断、`RTF 1.924`、0 失败 / 0 崩溃 / 0 异常 EOS、
>   Pss 平稳（1.93→2.13 GB）、`VmHWM` 2.30 GB 封顶 ⇒ **P4 全部验证项完成**。
> - **方向决策（2026-09-29 已拍板）**：**转路线 C / CosyVoice 2 混合方案**（§7 已同步改写）。
>   GPT-SoVITS 标记「**端侧不可行**」；CosyVoice 2 中文流式 RTF 0.2–0.6（**GPU 口径**），
>   短句流式直出、长段语义分段（≤200 字、中文标点）、系统 TTS 回退兜底。
>   ⚠️ 本块原文「官方鸿蒙 SDK `NativeNui`」经 **P5 核实不存在**（见 §7 修正块与 §9 P5）。
>   若未来仍要保留 GPT-SoVITS 音色，代价最低的路径是「云端/Mac 预生成 + 端侧只播放」。
>   下一步 = CosyVoice 2 POC（P5）。

#### P5 结果（2026-09-29，**核实「鸿蒙侧端侧运行时现状」+ 决定是否值得上鸿蒙 SDK POC**）

> 本阶段为**调研/核实**（无实跑）。结论：**官方无鸿蒙端侧运行时（`NativeNui` 不存在），但自建「官方
> ONNX 导出 + ORT for OHOS + NAPI」技术可行**（LLM 可导 ONNX 已被第三方先例证伪不确定性）；真正风险
> 转移到**「CPU 端侧 RTF 是否达标」**，故**下一步 = Docker CPU 验证**，而非直接上鸿蒙 SDK POC。

##### ① 鸿蒙侧端侧运行时现状（核实结论）

| 事实 | 核实结果 | 证据 |
|---|---|---|
| `NativeNui` / 官方鸿蒙 SDK | ❌ **不存在** | 官方仓库 `QwenAudio/CosyVoice` 全量 `git/trees`（232 项）无 harmony/ohos/napi/native/hap 目录；GitHub 检索 `cosyvoice+{nnrt/mindspore/arkts/hap/harmony}` 均 0 命中 |
| 官方运行时范围 | 仅三套，均**非端侧** | `runtime/python`（FastAPI/gRPC）、`runtime/triton_trtllm`（GPU 服务）、Python 脚本推理 |
| 官方 ONNX 导出 | ⚠️ **只导一个子模块** | `cosyvoice/bin/export_onnx.py`（114 行）仅导 `flow.decoder.estimator.fp32.onnx`（opset 18）；**LLM / hift 无官方 ONNX** |
| sherpa-onnx | ❌ 无 CosyVoice / GPT-SoVITS | 官方 TTS 支持列表：VITS / Matcha / Kokoro / ZipVoice |
| **LLM 能否导 ONNX（最大不确定性）** | ✅ **可导出，已证伪** | 三个第三方先例（见下） |

**LLM 可导 ONNX 的第三方先例**：

| 项目 | 星 | 最新活动 | 导出范围 | 关键信息 |
|---|---|---|---|---|
| `zhangluoyang/cosyvoice3-onnxruntime` | 1 | 2026-08 | frontend + **LLM（KV-cache 48 张量，FP16）+ flow DiT + hift 全套** | 有 `infinite_stream` 长期流式（听书场景刚需）、已发 ModelScope 预转换模型；LLM 需保存 48 个动态 KV Cache 张量、flow DiT 单步图 **复用 10 次**（euler + CFG） |
| `MasterVVK/cosyvoice3-rknn-russian` | 5 | 2026-02 | LLM ONNX FP32 + Flow DiT RKNN + HiFT ONNX | **RK3588 端侧 hybrid CPU/NPU**；LLM FP32 **仅 7.5 tok/s**（非实时）；`extract_llm_as_qwen2.py` + `export_llm_onnx.py` 带 KV-cache 导出 |
| `Lourdle/CosyVoiceForOnnx` | 17 | 2025-12 | Flow + HiFT ONNX 改造 | 提供 TorchScript/ONNX 适配 patch；compose flow+hift |

**关键结构事实**（`CosyVoice2-0.5B` `cosyvoice2.yaml`）：
- LLM = `Qwen2LM`/`Qwen2Encoder`（Qwen2 0.5B，`llm_input/output_size 896`，`speech_token_size 6561`）+ `ras_sampling`（top_p 0.8 / top_k 25 重复感知采样）——自回归 + 采样，与 GPT-SoVITS t2s 同类但**网络更大**。
- flow = `CausalMaskedDiffWithXvec`（Flow Matching，`CausalConditionalCFM`，euler solver，CFG 0.7）→ **10 步迭代**，额外成本。
- hift = `HiFTGenerator`（vocoder）；`sample_rate 24000`；token 帧率 25 Hz。
- 模型文件：`llm.pt` 2.02 GB / `flow.pt`+`flow.cache.pt` ~450 MB×2 / `hift.pt` 83 MB / `speech_tokenizer_v2.onnx` 496 MB / `campplus.onnx` 28 MB。

##### ② 是否值得上鸿蒙 SDK POC —— 判定

> **结论：暂不直接上鸿蒙 SDK POC；先做 Docker CPU 验证。** 理由：

1. 「是否存在鸿蒙端侧运行时」→ **否**（无现成，只能自建），但「自建是否可能」→ **是**（ORT for OHOS
   已在 P4 打通，NAPI 骨架、PCM 播放链路、seg 分段、多语言 TTS 体验均已有；仅缺 CosyVoice 的导出 +
   自回归/Flow 解码环）。
2. 鸿蒙 POC 的**前置未知量是「CPU 端侧 RTF」**，而这是**纯计算特性**，可先在 Mac CPU（Docker）拿到
   数量级基准，成本远低于鸿蒙交叉编译 + NAPI + 真机调试。
3. 证据**偏悲观**：LLM 是 Qwen2 0.5B 自回归（比 GPT-SoVITS t2s 大）+ Flow 10 步迭代；P4 已证
   GPT-SoVITS 端侧自回归每 token 慢 1.82×、RTF 下限 1.483；RK3588 上 LLM 仅 7.5 tok/s（≥RTF 3.3）；
   官方 RTF 0.2–0.6 是** GPU** 数字。若 Mac CPU RTF 已 ≫1.0，鸿蒙 CPU 只会更差，无需上鸿蒙。
4. 但「短句流式 + 长段分段 + 系统 TTS 回退」的**混合架构本就容忍端侧慢**（短句首包低即可、长文本靠
   分段流水线），所以只要**分段流水线能跟上播放**（不等于单链 RTF <1.0，可用预生成/缓冲弥合延迟
   尖峰），端侧仍有价值——这需要 Docker 验证「音质 + 分段正确性 + RTF 量级」三者后综合判断。

##### ③ 鸿蒙侧验证清单（**仅 Docker 验证通过后启用**；设备 `HBN-AL80` / 麒麟 9010 / 16 GB / API 24）

| # | 验证项 | 口径 / 阈值（建议） |
|---|---|---|
| 1 | 模型分发与装载 | 全 ONNX 部署包（LLM FP16 + flow + hift + frontend）约 **3–4 GB**；`hdc file send -b` 进沙箱，装载后驻留内存测 Pss/VmHWM |
| 2 | 首包延迟 | 短句（≤50 字）从文本到第一块 PCM，参照官方 150 ms（GPU），CPU 端侧目标 **<1 s 感知可接受，实测记录** |
| 3 | 单链 RTF | 与 Mac 同口径 `getrusage`；记录 LLM tok/s + Flow 每步 ms 分项归因 |
| 4 | 流式 chunk 对齐 | 边合成边播放，AudioRenderer 不欠载（underrun）的**最低预生成缓冲长度** |
| 5 | 分段正确性 | ≤200 字 + 中文标点切段的语义完整性（复用 P3 的 444 字页基准语料） |
| 6 | 系统 TTS 回退 | 超阈值 / 失败时切 M5 链路；统计命中率 |
| 7 | ≥1 h 长稳 | 不崩 / 不 OOM / KV-cache 重建不中断（`minimizeAllScene` 冻结 JS 的坑沿用 P4 对策） |
| 8 | 音质主观 A/B | 与官方 Python 基线、与系统 TTS 三方听音 |

##### ④ 技术路径与工程量分级（自建运行时，若 Docker 结论支持上鸿蒙）

| 级 | 内容 | 复用 / 新增 |
|---|---|---|
| L0 Mac 端到端 | Rust 加载全 ONNX（复用 `Lourdle` 或 `cosyvoice3-onnxruntime` 导出）+ 自回归 + Flow 迭代 + hift，跑通并测 Mac RTF | 新增：CosyVoice 导出脚本适配 + Rust 解码环；复用 P4 ORT/`ort` rc 封装思路 |
| L1 导出自动化 | LLM（带 KV-cache，FP16）/ flow（DiT 单步）/ hift / frontend 全套导出脚本 + 部署包 manifest（sha256） | 参考 `cosyvoice3-onnxruntime` 导出；**新增工作量** |
| L2 流式工程化 | KV-cache 复用 + `ras_sampling` + chunk 回调对齐 AudioRenderer 边播边合成 | 复用 M5 `TtsController` PCM 队列骨架；NAPI 语义沿用 P4 `ttsInit/Synthesize` |
| L3 量化/音质回归 | LLM int8/FP16 精度回归、flow 提速（减少 CFG 步）、音质 A/B | 复用 P3 音质方法 |

**风险（按严重度）**：
1. **CPU 端侧 RTF ≫1.0**（自回归 Qwen2 + Flow 10 步双重成本）——**最大风险**，Docker 先行证伪/证实；
2. LLM ONNX 的 KV-cache 动态图在 ORT for OHOS 上能否跑稳（P4 未验过 KV-cache 动态 shape，需实测）；
3. 模型体积 3–4 GB + 驻留内存超 App 预算（16 GB 设备尚可，但需复核）。

**替代路径（若 Docker RTF 证伪、或干脆不做端侧）**：
- **云端 / Mac 预生成 + 端侧只播放**（保留 5 个 GPT-SoVITS 音色时代价最低，已被 §7 认可）；
- **保持系统 TTS**（M5 链路，今日即用）。

**下一步动作（P5 收口）**：Docker 验证 CosyVoice 2（流式接口 / 音质 / 分段正确性 + **Mac CPU RTF 量级
= 决定性输入**），结论回填本 §9 与 §7。


---

## 10. 复现附录（**`/tmp` 被清理后仍可重建本文档全部数据**）

> ⚠️ 所有操作**只读原 zip**，解压只写 `/tmp/tts-probe/`。

### A. 侦察命令

```bash
ls -la /Users/lichtcui/Downloads/流萤.zip /Users/lichtcui/Downloads/花火.zip \
       /Users/lichtcui/Downloads/卡芙卡.zip /Users/lichtcui/Downloads/胡桃_ZH.zip \
       /Users/lichtcui/Downloads/芙宁娜_ZH.zip
for f in 流萤 花火 卡芙卡 胡桃_ZH 芙宁娜_ZH; do
  echo "=== $f"; unzip -t "/Users/lichtcui/Downloads/$f.zip" | tail -4
done
```

### B. 中文文件名解压脚本（**必需**）

Apple 自带 `unzip 6.00` **不支持 `-O`**，FB 内文件名是 GBK，直接用 `unzip` 会得到乱码路径。
必须用 Python `zipfile` + `cp437 → gbk` 转码：

```python
import zipfile, os
NAMES = ["流萤", "花火", "卡芙卡", "胡桃_ZH", "芙宁娜_ZH"]
for n in NAMES:
    src = f"/Users/lichtcui/Downloads/{n}.zip"
    out = f"/tmp/tts-probe/{n}"            # 只写 /tmp，不改原 zip
    os.makedirs(out, exist_ok=True)
    with zipfile.ZipFile(src) as z:
        for info in z.infolist():
            # 关键：zip 条目名是 cp437 字节流，实际编码为 GBK
            name = info.orig_filename.encode("cp437", errors="replace").decode("gbk", "replace")
            target = os.path.join(out, name)
            if name.endswith("/"):
                os.makedirs(target, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            try:
                with z.open(info) as s, open(target, "wb") as d:
                    d.write(s.read())
            except Exception as e:
                print("FAIL", n, name, e)   # 预期：损坏条目在此报错
```

同时列出成分表（不依赖解压）：

```python
import zipfile
for n in NAMES:
    with zipfile.ZipFile(f"/Users/lichtcui/Downloads/{n}.zip") as z:
        print("#" * 8, n)
        for i in z.infolist():
            name = i.orig_filename.encode("cp437", "replace").decode("gbk", "replace")
            print(f"  {i.file_size:>12,}  {name}")
```

### C. 损坏程度探测（复现 §1 的百分比）

```python
import zipfile, zlib, struct

def decoded_bytes(zip_path, info):
    """逐块 inflate，返回成功解出的字节数与错误信息。"""
    with open(zip_path, "rb") as f:
        f.seek(info.header_offset)
        hdr = f.read(30)
        nlen = int.from_bytes(hdr[26:28], "little")
        elen = int.from_bytes(hdr[28:30], "little")
        f.seek(info.header_offset + 30 + nlen + elen)
        data = f.read(info.compress_size)
    d = zlib.decompressobj(-15)
    out = bytearray()
    CH = 1 << 20
    for pos in range(0, len(data), CH):
        try:
            out += d.decompress(data[pos:pos + CH])
        except Exception as e:
            return len(out), str(e)
    return len(out), "OK"

TARGETS = ["流萤", "花火", "卡芙卡", "胡桃_ZH", "芙宁娜_ZH"]
for n in TARGETS:
    zp = f"/Users/lichtcui/Downloads/{n}.zip"
    with zipfile.ZipFile(zp) as z:
        for i in z.infolist():
            if i.filename.endswith("/") or i.compress_type != 8:
                continue
            name = i.orig_filename.encode("cp437", "replace").decode("gbk", "replace")
            if not name.endswith((".ckpt", ".pth")):
                continue
            got, err = decoded_bytes(zp, i)
            pct = got / max(i.file_size, 1) * 100
            print(f"{n:8s} {name.split('/')[-1][-22:]:24s} {got:>12,}/{i.file_size:>12,} = {pct:6.2f}%  {err}")
```

**预期输出**（与 §1 表格一致）：

```
流萤    流萤_e10_s250.pth       167,740,855/172,765,299 =  97.09%  invalid literal/length/distance code
花火    花火_e10_s80.pth        172,600,454/172,765,299 =  99.90%  invalid stored block lengths
卡芙卡  卡芙卡_e10_s140.pth     152,439,429/172,765,299 =  88.23%  invalid block type
胡桃_ZH 胡桃_ZH_e10_s860_l32.pth 75,549,998/ 75,549,998 = 100.00%  OK
芙宁娜_ZH 芙宁娜_ZH-e10.ckpt    113,472,231/155,312,893 =  73.06%  invalid code lengths set
芙宁娜_ZH 芙宁娜_ZH_e10_s950_l32.pth      0/ 75,549,998 =   0.00%  invalid stored block lengths
```

### D. 外层 zip 结构正常性验证（复现 §2 的 `delta == cd_size + 22`）

```python
import struct
for n in TARGETS:
    data = open(f"/Users/lichtcui/Downloads/{n}.zip", "rb").read()
    idx = data.rfind(b"PK\x05\x06")
    cd_size, cd_off = struct.unpack("<II", data[idx + 12:idx + 20])
    print(f"{n:8s} size={len(data):,} eocd={idx:,} cd_off={cd_off:,} cd_size={cd_size:,} "
          f"delta={len(data) - idx}  end_cd={cd_off + cd_size:,}")
    # delta 恒为 22（EOCD 定长），且 end_cd == idx → 结构完好
```

### E. GPT `data.pkl` 配置提取（复现 §3）

```python
import zipfile, struct

def read_gpt_config(ckpt_path):
    with zipfile.ZipFile(ckpt_path) as z:
        pkl = [i for i in z.infolist() if i.filename.endswith("data.pkl")][0]
        d = z.read(pkl)
    keys = [b"n_layer", b"head", b"hidden_dim", b"linear_units",
            b"phoneme_vocab_size", b"vocab_size", b"EOS"]
    out = {}
    for k in keys:
        # 精确锚定 "X" + 4 字节长度 + key：否则 "vocab_size" 会误命中
        # "phoneme_vocab_size" 的尾部
        pat = b"X" + struct.pack("<I", len(k)) + k
        i = d.find(pat)
        if i < 0:
            continue
        p = i + len(pat)
        if d[p:p + 1] == b"r":      # LONG_BINPUT：opcode + 4 字节 memo
            p += 5
        elif d[p:p + 1] == b"q":    # BINPUT：opcode + 1 字节 memo
            p += 2
        op = d[p]
        if op == 0x4B:              # BININT1
            out[k.decode()] = d[p + 1]
        elif op == 0x4D:            # BININT2
            out[k.decode()] = struct.unpack("<H", d[p + 1:p + 3])[0]
        elif op == 0x4A:            # BININT（4 字节有符号）
            out[k.decode()] = struct.unpack("<i", d[p + 1:p + 5])[0]
    return out

print(read_gpt_config("/tmp/tts-probe/流萤/v2ProPlus/流萤/流萤-e10.ckpt"))
# 预期：{'n_layer': 24, 'head': 16, 'hidden_dim': 512, 'linear_units': 2048,
#        'phoneme_vocab_size': 732, 'vocab_size': 1025, 'EOS': 1024}
# 四个包（含 v4 胡桃）输出一致。
```

### F. 参考音频元数据（复现 §1 明细）

```python
import wave, glob, os
for w in sorted(glob.glob("/tmp/tts-probe/**/*.wav", recursive=True)):
    with wave.open(w) as f:
        print(f"{f.getnframes()/f.getframerate():5.2f}s {f.getframerate()}Hz "
              f"{f.getnchannels()}ch {f.getsampwidth()*8}bit  "
              f"{os.path.basename(w)[:40]}")
```

### G. 来源链接清单

**本地资产**
- `/Users/lichtcui/Downloads/{流萤,花火,卡芙卡,胡桃_ZH,芙宁娜_ZH}.zip`
- `/Users/lichtcui/Documents/playground/tts/models/v2ProPlus/<角色>/{gpt.ckpt,sovits.pth}`（P0 修复后的可用权重）

**角色音色来源（P0 定位，此前未记录）**
- ModelScope `aihobbyist/GPT-SoVITS_Model_Collection` → `星穹铁道/中文/{流萤,花火,卡芙卡}.zip`
- 直链：`https://www.modelscope.cn/models/aihobbyist/GPT-SoVITS_Model_Collection/resolve/master/星穹铁道/中文/<角色>.zip`
- 校验：`流萤 536c1c69…` / `花火 562fee3a…` / `卡芙卡 ab501b22…`（详见 P0 报告 §2/§6）

**GPT-SoVITS 上游**
- https://github.com/RVC-Boss/GPT-SoVITS
- https://github.com/RVC-Boss/GPT-SoVITS/blob/main/GPT_SoVITS/onnx_export.py （只处理 v1/v2）

**路线 A**
- https://github.com/bailu-obj/gpt-sovits-onnx-rs
- https://github.com/bailu-obj/gpt-sovits-onnx-rs/blob/main/doc/v2proplus_validation.md
- https://github.com/bailu-obj/gpt-sovits-onnx-rs/blob/main/doc/pytorch_vs_onnx_speed.md
- https://github.com/bailu-obj/gpt-sovits-onnx-rs/blob/main/doc/perf_record.md
- https://github.com/bailu-obj/gpt-sovits-onnx-rs/tree/main/scripts/export
- https://huggingface.co/mikv39/gpt-sovits-onnx-custom （ONNX 产物体积清单）

**路线 B / C**
- https://github.com/k2-fsa/sherpa-onnx
- https://github.com/k2-fsa/sherpa-onnx/blob/master/build-ohos-arm64-v8a.sh
- https://k2-fsa.github.io/sherpa/onnx/harmony-os/tts.html
- https://k2-fsa.github.io/sherpa/onnx/tts/zipvoice.html
- https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models （ZipVoice 体积）

**交叉验证转换器**
- https://github.com/High-Logic/Genie-TTS
- https://github.com/High-Logic/Genie-TTS/blob/master/src/genie_tts/Converter/load_state_dict.py （`PK` 幻数兜底）
- https://github.com/High-Logic/Genie-TTS/blob/master/src/genie_tts/Converter/Converter.py （按体积分派 v2 / v2ProPlus）
- https://github.com/High-Logic/Genie-TTS/issues/27 （作者确认未支持 v4）

**ONNX Runtime**
- https://github.com/microsoft/onnxruntime/issues/20895 （OHOS 构建，社区参数）
- https://huggingface.co/csukuangfj/onnxruntime-libs （唯一 OHOS 预构建，1.16.3）
- https://ort.pyke.io/setup/linking （`ORT_LIB_PATH` / `load-dynamic`）

---

## 11. 明确不做 / 已知限制

- 本次**未写任何业务代码**，未改 `entry/`、`rust/`、`.so`。
- 未改 `plan.md`、`README.md` 里程碑表 —— TTS 增量**尚未立项**，等 P2 结论后再决定是否进里程碑。
- 未动 `HANDOFF-S3/S4.md`、`TASKS.md`、`ROOT-CAUSE.md`。
- **v4/v3 明确排除**，胡桃/芙宁娜本期不投入修复（尽管其 pth 理论可救）。
- **模型分发方案未定**（§0 决策 5），P4 若启动需先定此方案。
- 本文档为**活文档**：P0–P4 实测结果应**回填到 §8 / §9**，不要另开新文件。
- **P0 执行记录另见 [`docs/tts-p0-report.md`](tts-p0-report.md)**（分支 `tts/mac-p0`，基线 `0eb1e1c`）：
  环境快照、权重 sha256、目录布局、复现命令、已知偏差。P0 **未改 `entry/` / `rust/` / `.so`**。
