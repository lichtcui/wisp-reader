# 远程 TTS 引擎选型与「杂音」根因（T-TTS 系列）

> 背景：远程听书（VPS 上的 sherpa-onnx）被反馈两个问题 —— **朗读跟不上（RTF）** 与 **大量杂音**。
> 本文记录症状定位、已实施的修复、各引擎在本机（4C Xeon / 3.9G）上的**实测**数据，以及"要角色音色又要 RTF<1"这一约束下唯一可行的路线。
> 部署与运维细节见 [`../remote-tts-deploy.md`](../remote-tts-deploy.md)；GPT-SoVITS 相关早期调研见 [`TTS-PLAN.md`](./TTS-PLAN.md)。

<!-- TOC:BEGIN -->
- 0. 结论先行 — L10
- 1. 症状定位：所谓"杂音"到底是什么 — L20
- 2. 步数 ↔ RTF ↔ 音质（实测，卡芙卡，VPS 4C） — L34
- 3. 已实施的修复（v1.1.0 管线） — L45
  - 修复前后对比（实测） — L57
- 4. 引擎矩阵（本机实测 / 硬约束筛选） — L70
  - VITS 样本已生成供试听 — L86
- 5. 推荐路线：微调 VITS → 导出 sherpa-onnx — L96
  - 产出的目标目录（与现用模型同构） — L109
  - 已知前提与坑 — L117
- 6. 残余风险（与文件位置） — L125
- 7. 内存与稳定性 — L134
- 8. 参考 — L142
<!-- TOC:END -->

## 0. 结论先行

1. **「杂音」不是噪声，是少步数 flow-matching 的频谱缺陷**：`num_steps=2/3` 时 200–300Hz 能量占比高达 47%，而 600–1500Hz 临场频段只剩 8–12%。听感就是"低频轰鸣 / 浑浊 / 嗡嗡声"。**提高步数能改善但代价是 RTF 爆炸**：`steps=6` 已到 RTF 1.485。
2. **高通滤波是错的修法**（会削掉女声基频），正确修法是 **去浑浊 EQ + 临场提升 + 响度归一**，已在 v1.1.0 管线落地。
3. **真正让朗读"跟不上"的根因是余量不足**：`steps=3` 时 RTF 0.84，服务端 `_lock` 串行，全链路吞吐只剩 1.19× 实时 —— 任何抖动都会耗尽预取缓冲。**必须把 RTF 降到 0.4 附近才有 2× 余量。**
4. **实测 `sherpa-onnx-vits-zh-ll` RTF 0.398–0.431、RSS 184–294MB**，比现用 ZipVoice **快 2.1 倍、内存低 2.7 倍**，且是单次前向、**没有"步数 vs 音质"的矛盾**。
5. 因此结论是：**运行时换成 VITS 架构；音色通过微调解决**。VITS 是这台机器上唯一能同时满足「中文 + 可训练成任意音色 + RTF<1」的架构。训练链路（VITS-fast-fine-tuning → 导出 sherpa-onnx ONNX）已被 sherpa-onnx 官方支持并有一键工具，见 §5。

> 早期曾按官方 Pi4 表（`vits-melo-tts-zh_en` 2.518 @4线程）外推"VITS 在这台机器上 RTF 1.3–1.7、不可行"。**该外推是错的**：本机 4C Xeon 8173M 比 Pi4 快约 5 倍，实测 0.40。本文所有性能数字均为本机实测，不再引用外推值。

## 1. 症状定位：所谓"杂音"到底是什么

对合成音频与参考音频做逐频段能量占比（`app.py` 的 `_profile()`，哈宁窗 + 分带求和）：

| 候选病因 | 实测值 | 判定 |
|---|---|---|
| 低频隆隆声（0–120Hz） | 合成 **0.0%** / 参考 0.0% | ✗ 排除 |
| 直流漂移 | ~0.00005 | ✗ 排除 |
| 削波失真 | 0% 采样点 | ✗ 排除 |
| 高频嘶声（>10kHz） | 0.02–0.46% | ✗ 排除 |
| **200–300Hz 过量 + 600–1500Hz 缺失** | **合成 47.3% / 7.8%，参考显著更均衡** | **✓ 这就是"杂音"** |

**机制**：ZipVoice 是 flow-matching 零样本克隆模型，`num_steps` 决定 ODE 求解精度。步数不足时高频细节未被复原，能量堆积在低频共振峰 —— 不是"加了噪声"，而是"该有的高频没生成出来"。

## 2. 步数 ↔ RTF ↔ 音质（实测，卡芙卡，VPS 4C）

| `NUM_STEPS` | RTF | 200–300Hz | 600–1500Hz | 评价 |
|---|---|---|---|---|
| 2 | **0.558** | 47.3% | 7.8% | 快但很浑浊 |
| 3（现用） | **0.834** | 47.8% | 12.1% | 仍是浑浊，余量已只剩 1.2× |
| 6 | **1.485** | 35.2% | 18.4% | 音质可接受，**但已不能实时** |
| 12 | **2.943** | — | — | 不可用 |

**结论：在这台机器上，ZipVoice 没有任何一档配置能同时做到「实时」与「不浑浊」。** 这是架构约束，不是参数调优问题 —— 也是换引擎的根本理由。

## 3. 已实施的修复（v1.1.0 管线）

`server/app.py` v1.1.0 在推理之后串了一条纯 numpy 后处理链（VPS 上**没有 scipy / soundfile / ffmpeg / sox**，一切都得自己实现）：

| 环节 | 实现 | 目的 |
|---|---|---|
| `_resample_fft()` | 加载时把参考音频一次性重采样到 24kHz | 消除**每请求**新建 44.1k→24k 重采样器（老版本 6 天长到 2.5GB 的元凶之一） |
| `_eq()` | 零相位 FFT RBJ peaking EQ：`280Hz -3.5dB Q0.9` + `2800Hz +3.5dB Q0.7` | 去浑浊 + 补临场 |
| `_limit()` | 分块峰值限制器，包络用**膨胀（±2 块取最大）**而非均值 | 防限幅后的增益回弹（均值平滑曾让花火峰值冲到 1.000） |
| `_normalize()` | 归一到 `TARGET_RMS_DBFS=-18`，天花板 `-1 dBFS` | 统一响度 |
| `_fades()` | 15ms 淡入 / 40ms 淡出 | 去头尾爆音 |

### 修复前后对比（实测）

| 素材 | 200–300Hz | 600–1500Hz | |
|---|---|---|---|
| 卡芙卡 | 35.4% → **24.3%** | 16.5% → **23.3%** | EQ 生效 |
| 长文 204 字 | 42.7% → **32.1%** | 10.1% → **14.8%** | EQ 生效 |
| 花火 | 17.1% → **9.2%** | 22.4% → **27.8%** | EQ 生效 |

响度一致性：三个音色的 RMS 离散度 **5.5 dB → 0.62 dB**（卡芙卡 −18.06 / 流萤 −18.00 / 花火 −18.62 dBFS），**全部 0% 削波**。

> 环境变量开关：`POST_ENABLE`、`EQ_BANDS="280:-3.5:0.9,2800:+3.5:0.7"`、`TARGET_RMS_DBFS`、`PEAK_CEILING_DBFS`、`NUM_STEPS`。
> `/health` 会回显 `{ok, steps, post, eq}`，便于确认线上真的生效。

## 4. 引擎矩阵（本机实测 / 硬约束筛选）

硬约束：**① 必须中文；② 必须能拿到角色音色；③ 4C/3.9G 上 RTF < 1 且有余量。**

| 引擎 | 中文 | 角色音色 | 本机实测 RTF | 判定 |
|---|---|---|---|---|
| **sherpa-onnx VITS（`vits-zh-ll`）** | ✓ | 固定 5 说话人，**但可微调** | **0.398–0.431** | ✓ **选它** |
| ZipVoice（现用） | ✓ 中英 | 零样本克隆 ✓ | 0.834 (steps=3) | ✗ 余量只剩 1.2× |
| `vits-melo-tts-zh_en` | ✓ 中英 | 固定 1 说话人 | （未测） | 同族备选 |
| Kokoro / Matcha / Supertonic 3 | 部分 | 固定音色 ✗ | — | ✗ 无角色音色 |
| PocketTTS | **✗ 无中文** | 零样本克隆 ✓ | — | ✗ 语言不支持 |
| Bert-VITS2 | ✓ | 可训练 | — | ✗ 需 1.3B BERT 前端，4C/4G 不可能 |
| **GPT-SoVITS** | ✓ | **最好，且已有成品模型** | 未测 | ✗ 需要 torch + 自回归 GPT 解码，4C/4G 上 RTF 大概率 ≫1，**与"必须 RTF<1"直接冲突** |

**关键洞察**：市面上给原神/崩铁角色配音色的成品权重几乎都是 **GPT-SoVITS / Bert-VITS2 格式**（`.ckpt`/`.pth`）—— 音色最好，但推理栈太重。而 **VITS 是唯一"轻到能在 4C 上跑进 RTF 0.4"且"可以微调成任意音色"的架构**。真正的取舍不是"哪个引擎音色好"，而是**"愿不愿意为音色花一次微调"**。

### VITS 样本已生成供试听

`vits-zh-ll` 自带 5 个说话人，同一句话、统一归一到 −18 dBFS 的试听样本（RTF 0.359–0.419）：

```
~/Desktop/tts-abtest/
  vits_spk0.wav … vits_spk4.wav      # VITS 5 个说话人
  zipvoice_流萤_现用.wav              # 现用 ZipVoice 流萤，同句同响度对照
```

## 5. 推荐路线：微调 VITS → 导出 sherpa-onnx

前提已全部落实：

| 前提 | 状态 |
|---|---|
| 运行时够快 | ✓ 实测 RTF 0.40，余量 2.5× |
| 有导出链路 | ✓ sherpa-onnx 作者在 [Plachtaa/VITS-fast-fine-tuning#518](https://github.com/Plachtaa/VITS-fast-fine-tuning/issues/518) 明确提供 VFFT 模型的 ONNX 导出脚本 |
| 有一键工具 | ✓ [`ANONEKO777/sherpa-onnx-vits-fine-tuning-webui`](https://github.com/ANONEKO777/sherpa-onnx-vits-fine-tuning-webui)：WebUI 训练 + `export_vits_fast_fine_tuning_onnx.py` 导出 |
| 不用去 HF 下底模 | ✓ 该仓库自带 `pretrained_models/{C,CJ,CJE}/{G_0,D_0}.pth` 底模 + 1236 条辅助音频（HF 在本机与 VPS 均不可达） |
| 有训练语料 | ✓ 游戏解包语音（每角色需 100+ 条带文本短音频；现有参考包只有 4–6 条，**不够**） |
| 目标格式已验证 | ✓ 导出物 `model.onnx` + `lexicon.txt` + `tokens.txt` + `dict/` 与现用 `vits-zh-ll` 目录结构**完全一致** |

### 产出的目标目录（与现用模型同构）

```
model.onnx  /  model.int8.onnx        lexicon.txt  tokens.txt
dict/{hmm_model,idf,jieba.dict,stop_words,user.dict}.utf8
date.fst  number.fst  phone.fst  new_heteronym.fst
```

### 已知前提与坑

- **训练算力是最大不确定性**：本机 Mac 为 Intel Core i5-1038NG7（4C/2GHz/16GB），**无 CUDA、无 MPS → 纯 CPU 训练**；VFFT 官方称 GPU 上 20 分钟–2 小时，CPU 上会慢一个量级。建议先跑通"数据准备 + 导出"全链路（用小步数验证导出物能被 sherpa-onnx 加载），再投入长训练。
- 工具链要求 **Python 3.8** + **ffmpeg** + 编译 `monotonic_align`。
- VITS-fast-fine-tuning 上游已于 **2025-11-21 归档**（代码可用、不再维护）。
- 底模自带原神数据集的二次元声线，中/日/英三语，冷启动样本效率高。
- 语料切分要点：单条 3–10s、单说话人、带文本标注；参考包的文件名已是 `【情绪】…台词。.wav` 形式，可**自动生成标注**。

## 6. 残余风险（与文件位置）

| 风险 | 证据 | 处置 |
|---|---|---|
| **客户端 60s 超时会在播放中换音色** | `RemoteTtsClient.ets` `readTimeout=60000`；204 字段落 ≈29s；`AHEAD_REMOTE=3`（`Const.ets:58`）+ 服务端 `_lock` 串行 → 第 3 个排队请求最坏 ≈87s > 60s → 触发 `fallbackToSystem()` 中途切成系统 TTS | 建议把 `readTimeout` 提到 ≥120000。**设备离线，未改 ArkTS** —— 换引擎后 RTF 降到 0.4，此项风险自然大幅缓解 |
| 段落未按长度切分 | `BookContent.ets:20` 仅按 `\n` 切行 | 若换引擎后仍有长段落，再考虑按标点切段 |
| 花火参考音频过长 | 6.77s（流萤 3.38s / 卡芙卡 3.42s）→ prompt mel 成本近 2×，RTF 1.06–1.18 | 微调路线下此问题消失（VITS 推理不用参考音频） |
| 显存/内存 | VITS RSS 仅 184–294MB（ZipVoice ~790MB） | 换引擎后 `MemoryMax=1600M` 余量充足 |

## 7. 内存与稳定性

- **swap**：已加 2G `/swapfile` + `vm.swappiness=10` + `vm.vfs_cache_pressure=50`（原 3.9G 无 swap，曾导致 `rustc` 构建被 OOM 杀掉）。
- **长期增长**：老版本运行 6 天后 RSS 达 **2513MB**（新起 + 8 请求为 766MB）。老版本**每请求**都新建一个 44.1k→24k 重采样器，是主要元凶；v1.1.0 改为加载时一次性重采样。
- **增量斜率仍未完全归因**：150 次同文本 soak 为 ~1.5 MB/次，修掉 `_profile()` 的 FFT 长度缓存（np.pocketfft 按变换长度永久缓存 twiddle 表）后斜率变化不大 → **主因更可能是 ONNX Runtime arena 高水位爬坡与 glibc 内存滞留**，而非逐请求真泄漏。`_profile()` 的修复本身仍然正确（把 FFT 长度量化到 2 的幂，分带**百分比不受零填充影响**）。
- **systemd 加固**：`MemoryHigh=1200M` / `MemoryMax=1600M` / `RuntimeMaxSec=86400`（每日重启）+ `MALLOC_ARENA_MAX=4` / `MALLOC_TRIM_THRESHOLD_=65536`。目标是"万一回归就把 `tts` 自己重启掉"，而不是让内核 OOM 去杀别的进程。
- 换到 VITS 后内存占用降到 ~250MB，上述加固会变得非常宽松。

## 8. 参考

- sherpa-onnx TTS 文档：<https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/vits.html>
- VFFT → sherpa-onnx 导出说明：<https://github.com/Plachtaa/VITS-fast-fine-tuning/issues/518>
- 一键微调 + 导出 WebUI：<https://github.com/ANONEKO777/sherpa-onnx-vits-fine-tuning-webui>
- VITS-fast-fine-tuning：<https://github.com/Plachtaa/VITS-fast-fine-tuning>
- 早期 GPT-SoVITS 调研：[`TTS-PLAN.md`](./TTS-PLAN.md)
