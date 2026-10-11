# TTS-PLAN — 鸿蒙听书端侧自建 TTS 尽调与原型计划

> **状态：已封存（2026-10-12），不再是待办计划。** 本计划已执行到 P6：原型真机跑通（ZipVoice 端侧 RTF 0.49–0.54，快于实时），
> 但 OHOS 交叉编译的 ORT 对一切动态 shape 输出的 `GetShape()` 返回 ~4× 虚高帧数 ⇒ 波形全 NaN / 电流声；
> 升级 ORT、降级、换 vocoder、换模型四条路同因堵死。**重启前提 = ORT 上游修复**。
> 决策见 [`decisions.md` D12](../decisions.md)；证据、脚本、测量结果与未推送代码见
> [`archive/TTS-LOCAL-ONNX/`](../archive/TTS-LOCAL-ONNX/README.md)；当前线上方案见
> [`TTS-ENGINE-COMPARISON.md`](./TTS-ENGINE-COMPARISON.md) 与 [`../remote-tts-deploy.md`](../remote-tts-deploy.md)。
> **本文只作历史调研留存**：下方「下一步 = §10 的 P0」等表述是撰写当时的状态，勿当待办执行。

日期：2026-09-26（状态更新：2026-10-12 封存）
状态：**已封存**（撰写时为「调查完成，原型未开始」；P0–P6 已跑完并封存，见顶部横幅与 D12）
范围：**只做调查与计划**。本轮未改动任何代码（`entry/`、`rust/`、`.so` 全部未动）。
关系：现有 M5 用的是**系统 TTS**（Core Speech Kit `textToSpeech` → `AudioRenderer` → `AVSession`，见 `docs/progress.md` §「M5 结果」）。
本文档是**端侧自建 TTS 的并行增量调研**，与 M5 不冲突、不改动 M5。

> **一句话结论**：路线 A（GPT-SoVITS → ONNX → Rust/NAPI → 鸿蒙）是唯一能复用你手上模型的路径，
> 但端侧 int8 常驻内存实测指向 **约 1GB**（超原定 256MB 三到四倍），且鸿蒙侧零现成工程。
> 因此原型阶段**先只在 Mac 上验证「音质是否可用」**，再决定是否值得投入 OHOS 交叉编译。

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

**主路线 = A**，实现栈**锁定**为：

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

**明确不做**：

- ❌ 为 v4/v3 自写 ONNX 转换器（本期范围外）
- ❌ 移植 Genie 的 Python runtime 到端侧
- ❌ 让 sherpa-onnx 接入 GPT-SoVITS（路径不存在）
- ❌ 模型分发方案（§0 决策 5，推迟）

---

## 8. 待验证项（**必须实跑/实编才能确认的假设**）

| # | 假设 | 为何必须实跑 | 验证手段 |
|---|---|---|---|
| 1 | 转换后**音质是否真的可用** | bailu 自评「不稳定」是否成立，唯一证伪方式是听 | P2 人工听音 + 与 Python 基线 A/B |
| 2 | Mac 端 **peak RSS** 与端侧可用内存 | 目前**无任何同规模端侧基准**（搜索 0 结果） | P2 实测 + P4 真机 |
| 3 | ORT 1.22.0 能否用 OHOS toolchain 交叉编出 `.so` | 社区只给参数、**未附产物**，属宣称 | P4 实编 |
| 4 | `ort` rc.12 与自建 ORT 的 API/opset 兼容性 | rc.12 期望较新 ORT，1.16.3 大概率不兼容 | P4 实编 + 加载冒烟 |
| 5 | v2ProPlus 三个 t2s 分片在**长句**下的自回归稳定性 | 是否胡言乱语 / 提前 EOS / 重复，无法静态判断 | P3 长文本压测 |
| 6 | 参考音频 44.1kHz → 32kHz 重采样与 Python 基线一致 | 不一致会直接影响音色相似度 | P1 `compare_infer_metrics.py` |

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

### P1 导出与校验

```bash
./scripts/export/05_export.sh --version v2ProPlus --export-name custom_v2proplus --no-quant
./scripts/export/validate_bundle.sh --bundle-dir gpt-sovits-upstream/onnx-patched/custom_v2proplus --expect-v2pro
./scripts/compare_infer_metrics.py --seed 42
```

- 先 `--no-quant` 保音质基线；量化版留到 P2 对比。
- 校验产物齐全：`ssl.onnx` / `bert.onnx` / `sv.onnx` / `g2pW.onnx` / `g2p_en/` / `{prefix}_t2s_*.onnx` / `{prefix}_vits.onnx`。

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

### P3 分段与长稳

- 按标点切分为 **≤30s** 的合成单元；采样参数用 `temperature=1.0, top_k=4, top_p=0.9, repetition_penalty=1.35`
  （即 `InferParams::default()`）。
- **连续跑 1h** 脚本化合成，统计失败 / 截断 / 异常 EOS 率。

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
