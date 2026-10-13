# TTS 离线批量预生成（VPS 空闲时批量出音频 + 客户端优先读缓存）

> 起因：用户提出「VPS 上没跑别的任务，能不能空闲时批量预生成 50–100（或更多）章的书本音频；听书优先读缓存音频，读不到才用默认 TTS」，
> 并追问「**这样能用 GPT-SoVITS 的模型了吗？**」
> 本文 = ① 该前提如何改写 TTS 选型判据　② 用线上同一份代码实测 ZipVoice steps 6/12/24 的证据（含**用户听感结论**）　③ 方案草图与已知坑。
> 相关：引擎/管线细节 → [`TTS-ENGINE-COMPARISON.md`](./TTS-ENGINE-COMPARISON.md)；音色调研 → [`TTS-VOICE-SOURCES.md`](./TTS-VOICE-SOURCES.md)；
> 决策 → [`../decisions.md`](../decisions.md) **D15**（D14 部分重开）；部署运维 → [`../remote-tts-deploy.md`](../remote-tts-deploy.md)。
> **状态（2026-10-12）**：**已立项**（用户拍板）；本文 = 评估 + 实测 + 坑，**实现方案**见 [`TTS-PREGEN-IMPL.md`](./TTS-PREGEN-IMPL.md)，任务条目 [`../bugfix/TASKS.md`](../bugfix/TASKS.md) **T-TTS-7**。仓库代码与线上行为**仍未改一行**（阶段一待开工）。
> **追加（2026-10-12，GPT-SoVITS 实测）**：用户要求「看 GPT-SoVITS 的效果」→ 在 VPS 上把 v2ProPlus（流萤微调）/ v4（钟离_ZH 微调）**真跑通**并测得 RTF/RSS。
> 结论：**v2ProPlus 整章 RTF 5.57（可用）、v4 RTF 115（CPU 上不可用）**；硬件门槛是**内存**（单进程 3.3 GB，本机 3.9 GB + 4 GB swap）；**用户选了 v2ProPlus 作预生成默认引擎**（听感最优），代价 = 100 章约 4 天。详见 §2.2 / §5。

<!-- TOC:BEGIN -->
- 0. 结论先行 — L30
- 1. 约束搬家：流式 vs 批量 — L50
- 2. 本轮实测（VPS 4C Xeon 8173M @2.00GHz / 3.9 G + 2 G swap） — L62
  - 2.1 ZipVoice（2026-10-11） — L64
  - 2.2 GPT-SoVITS（2026-10-12，同机 / 同文本） — L86
- 3. 换算到「预生成 100 章」 — L124
- 4. 方案草图（**已细化为 [`TTS-PREGEN-IMPL.md`](./TTS-PREGEN-IMPL.md)，本节只留结论**） — L145
  - 4.1 服务端：内容寻址缓存 + job worker — L147
  - 4.2 批处理必须让出 CPU（这是唯一会伤到线上的地方） — L156
  - 4.3 客户端：**章级原子切换**（关键体验约束） — L162
  - 4.4 素材从哪来（两个选项，建议 A 起步） — L169
  - 4.5 批量 QC（离线才有的新问题） — L178
- 5. 本轮新发现的坑 — L183
- 6. 复现入口 — L211
- 7. 未决 / 下一步 — L224
<!-- TOC:END -->

## 0. 结论先行

1. **前提确实被改写，但改的不是"能不能"，而是"值不值"** —— 当初判死 GPT-SoVITS 的**唯一硬理由**是 `RTF < 1`（实时流式要跟上朗读）。
   批量离线生成把这条约束整个拿掉，换成三条新的：**追上收听速度**、**峰值内存**、**批量 QC**。
   新判据：**RTF ≤ 24 ÷ 每日收听小时数**（听 2 h/天 → RTF ≤ 12；4 h/天 → RTF ≤ 6），峰值 RSS ≤ 机器余量。
2. **用户听感已过（2026-10-11，用户试听后确认）：ZipVoice `num_steps=12` 可以接受** ——
   路线 B 当初的否决理由（`num_steps=3` 的 few-step 毛刺）在新步数档位**不再成立**，而 `steps=12` 在实时流式下是绝对不可能用的（RTF ~3.5）。
   这是本轮**唯一真正的新信息**：不是"找到更好的引擎"，而是"**批量让我们能用得起更慢的好引擎**"。
3. **推荐分工：质量引擎离线批量 + VITS 实时兜底**，两者在同一份 `server/app.py` 里已经是两个分支（`ENGINE=vits|zipvoice`），
   `NUM_STEPS` / `VOICE_REFS` 都是环境变量与常量，**零新依赖、零新硬件**。
4. **内存才是门槛，ZipVoice 不占内存**：ZipVoice int8 实测峰值 **0.81–1.00 GB**，与常驻 VITS（441 MB）共存毫无压力。
   但 **GPT-SoVITS 单进程就要 3.29–3.43 GB**（实测；文献里 ~2.2 GB 偏乐观）——本机 3925 MB 总内存下，v4 **无 swap 时直接被 OOM killer 杀掉**（`anon-rss 3.73 GB`），加 4 GB swapfile 才跑完（§2.2）。
5. **GPT-SoVITS 实测结论：CPU 上只有 v2ProPlus 勉强能用，v4 直接出局**（§2.2）：
   - `v2ProPlus`（流萤微调）RTF **5.42**（speed=1.5 → 5.96，speed=0.75 → 4.95）⇒ 100 章 **~103 h / 4.3 天**，比 `steps=12`（~55 h）**慢一个数量级以内但确实更贵**，且内存 3.6 GB 与线上 VITS 抢得厉害。
   - `v4`（钟离_ZH 微调）RTF **115.3**（59 s 音频跑了 **1.9 h**）⇒ 100 章 ~2200 h，**CPU 上不可行**；v3/v4 的 BigVGAN vocoder 是主因（且 v3/v4 **不允许空 prompt_text**）。
   - 逐句调用（复刻 `app.py` 口径）比引擎原生切句**慢 2×**（11.22 vs 5.42）——每句都会重算参考音频的 hubert/BERT 特征。**离线批量必须走原生 `run()` + 内部切句**。
   - 零样本底座（无微调权重，用 `refs/*/ref00.wav` + `names.json` 里的真值文本）也能量产：花火 RTF 7.17 / 卡芙卡 RTF 5.86 ⇒ 花火/卡芙卡没有微调权重**不再是阻塞项**（只是保真度低于微调）。
6. **用户决策（2026-10-12，立项）**：① 默认引擎 = **GPT-SoVITS v2ProPlus（流萤）**——试听后判定「`cut5` + `fragment_interval=0.3` 这个听着效果比较好」，明知 100 章 ≈ 4 天也要；
   ② 缓存 **WAV 直出（24 kHz mono）+ 严格淘汰**；③ 素材**先手动喂**（curl），客户端入口后置。施工图：[`TTS-PREGEN-IMPL.md`](./TTS-PREGEN-IMPL.md)（§1 数据契约 / §2 服务端 / §3 App 侧「填写方式」/ §6 下个 session 的 prompt）。

## 1. 约束搬家：流式 vs 批量

| 维度 | 实时流式（现状 v2.0.0） | 离线批量预生成 |
|---|---|---|
| **RTF** | **< 1**（否则合成追不上播放） | **≤ 24 ÷ 每日收听小时数**（听 2 h/天 → ≤ 12） |
| 内存 | 常驻 RSS 要和 VITS/系统共存 | 峰值 RSS ≤ 机器余量（可突发，可 swap） |
| 音质上限 | 被 RTF 锁死在 few-step（`steps=3`） | **步数自由**（12 / 24 都可行） |
| 主要代价 | 无（即时出音） | **首次 N 章的生成时间** + 批量 QC + 磁盘 |
| 失败模式 | 卡顿 → 回退系统 TTS | 生成的音频难听/复读/漏字，**事后要能发现** |

**真正的新成本是"首次缓冲"**：缓存还没铺开时，用户听书只能走 VITS（音色是标签名）或系统 TTS —— 预生成不是"替代"，是"**逐步替换**"。

## 2. 本轮实测（VPS 4C Xeon 8173M @2.00GHz / 3.9 G + 2 G swap）

### 2.1 ZipVoice（2026-10-11）

**素材刻意选得比上一轮苛刻**：285 字**真实小说章节**（《剑来》@ 黑炎小说，`probe content` 抓取，原正文 8741 字），
满篇**对白 + 引号 + 省略号**。上一轮路线 B 判听感用的是**无对白的单句** —— 那是最容易过的样本。

**方法（保证数字就是线上口径）**：`/root/tts/genshin-vits/batch_ab.py` 直接 `import app`（线上 `server/app.py`），
因此走的是**同一份**切句 + 320 ms 停顿 + 24 kHz 重采样 + 后处理（−18 dBFS 归一 / −1 dBFS 限幅 / 淡入淡出）代码；`num_steps` 每轮改 `app.NUM_STEPS` 再调 `_synth_zipvoice`。

| 引擎 | steps | 音频 | wall | **RTF** | 峰值 RSS |
|---|---|---|---|---|---|
| VITS（现线上）甘雨 / 胡桃 / 钟离 | — | 51.97 / 54.30 / 56.63 s | 29.0 / 29.0 / 30.6 s | **0.557 / 0.533 / 0.541** | 441 MB（常驻） |
| ZipVoice 流萤 / 花火 / 卡芙卡 | 6 | 43.36 / 48.48 / 45.89 s | 72.2 / 101.2 / 70.6 s | **1.665 / 2.087 / 1.539** | ~0.8–1.0 GB |
| ZipVoice 流萤 / 花火 / 卡芙卡 | **12** | 42.75 / 48.75 / 45.00 s | 139.6 / 200.4 / 138.0 s | **3.266 / 4.110 / 3.066** | 1.0 GB (`VmHWM`) |
| ZipVoice 流萤 | 24 | 42.22 s | 266.2 s | **6.304** | 0.81 GB (`VmHWM`) |

- 测量时 `nice -n 19`，**线上 VITS 服务同时在跑**（对拍时也确认 `GET /health` = `engine:vits`，5 音色 200）。
- 三个角色的音频时长差 ~13% 说明**VITS 的时长由 sid 决定**（同文本 52–57 s），ZipVoice 更稳（42–49 s）。
- 所有产物 0% 削顶、峰值 0.89。

**试听包（本机）**：`~/Desktop/tts-zipvoice-batch/`（42 MB）—— `参考原声/`（3 角色官方中配 `ref00`）+ `zipvoice/`（3 角色 × steps 6/12 + 流萤 24，各含 `_eq` / `_noeq` 后处理对照）+ `vits当前线上/`（3 音色）+ `text.txt` + `readme.md`。
判定：`_eq` 与 `_noeq` 只差 EQ（`280:-3.5:0.9, 2800:+3.5:0.7`，`ENGINE=zipvoice` 下的服务端默认）。

### 2.2 GPT-SoVITS（2026-10-12，同机 / 同文本）

**为什么能跑了**：代码从 `gitcode.com/gh_mirrors/gp/GPT-SoVITS` 镜像克隆（github 在 VPS 不可达），base 从 ModelScope 下（3.9 GB），
torch **2.6.0+cpu** 从 SJTU pytorch-wheels，运行期资产（G2PWModel / nltk_data / open_jtalk 词典）从 ModelScope `XXXXRT/GPT-SoVITS-Pretrained`。
环境完全隔离在 `/root/tts/gsv/venv`，**不动系统 python 与线上 `tts.service`**。

脚本 `/root/tts/gsv/gsv_batch.py`：复刻 `server/app.py` 的**全部**后处理口径（24 kHz FFT 重采样 / −18 dBFS 归一 / −1 dBFS 限幅 / 15+40 ms 淡入淡出），
并对比两条调用路径：**逐句**（`_split_sentences` + 320 ms 停顿，= `app.py` 口径）与**原生**（一次 `run()` + `text_split_method`，引擎自己切句）。

| 模型（权重） | 参考音频 | 路径 | 音频 | 合成 | **RTF** | 峰值 RSS |
|---|---|---|---|---|---|---|
| 流萤 = **v2ProPlus** e10 (`s250`) | 微调包自带 `【中立】…`（3.38 s）| 逐句 | 64.14 s | 718.0 s | **11.22** | 3.29 GB（HWM 3.61）|
| 流萤 v2ProPlus | 同上 | **原生 cut5** | 64.76 s | 350.1 s | **5.42** | 同上 |
| 流萤 v2ProPlus `speed=0.75` / `1.5` | 同上 | 原生 cut5 | 82.50 / 45.96 s | 407.2 / 273.7 s | 4.95 / **5.96** | 同上 |
| 钟离 = **v4** e10 (`s990_l32`) | 微调包自带 `【默认】…`（3.84 s）| 原生 cut5 | 59.12 s | **6816.7 s（1.9 h）** | **115.32** | 3.43 GB |
| 花火 = v2ProPlus **底座零样本** | `refs/花火/ref00.wav`（6.77 s）| 原生 cut5 | 64.24 s | 459.7 s | 7.17 | 3.28 GB |
| 卡芙卡 = v2ProPlus 底座零样本 | `refs/卡芙卡/ref00.wav`（3.42 s）| 原生 cut5 | 68.72 s | 401.4 s | 5.86 | 3.51 GB |

- 同文本线上 VITS = 54.94 s（voice=流萤→甘雨 sid，speed=1.0）⇒ **GPT-SoVITS speed=1.0 的语速比 VITS 慢 18%**，ZipVoice 快 22%。
- 逐句 → 原生同一模型同文本 RTF 11.22 → 5.42：**每句重算参考音频 hubert/BERT 特征**是那 2× 的出处。
- 零样本（底座 s2Gv2ProPlus + `refs/*/ref00.wav` + `names.json` 里的 `real_name` 作 prompt_text）**可用** ⇒ 花火/卡芙卡没有微调权重不是阻塞项。
- 全程 `nice -n 19` + `OMP_NUM_THREADS=3` + `torch.set_num_threads(3)`，线上 VITS 未停（对拍时 `GET /health` 正常）。

**内存（比 CPU 更早卡死的地方）**：加载完常驻 3.28–3.51 GB（机器 3925 MB）⇒ **v4 无 swap 时被 OOM killer 杀掉**
（`anon-rss 3728928 kB`、`total-vm 7168544 kB`），临时加 4 GB swapfile（`/swap2`）后才跑完；加完盘只剩 1.4 GB 空闲。

**整章 + 切句法对照（2026-10-12，同一份 8741 字真实章节）**

| 变体 | 音频 | 合成 | RTF | 备注 |
|---|---|---|---|---|
| `cut5 + fragment_interval=0.3`（分 6 块 × 1500 字） | **1802.5 s（30.0 min）** | **9992.4 s（2.78 h）** | **5.57** | ✅ **用户听感最优，定为预生成默认口径**；逐块 RTF 3.96 → 6.43（越跑越慢 = swap 压力累积）|
| `cut3`（按中文句号）+ 分块 | 失败 | 第 14 段被杀 | — | 长段让 AR 单段吐到 **612 token** ⇒ 缓冲尖峰 OOM |
| `cut3`（285 字） | 64.1 s | 607.3 s | **9.48** | 反直觉：**比 cut5 慢 1.75×** |
| `cut5 + fragment_interval=0`（285 字） | 55.5 s | 349.2 s | 6.30 | **算力与 0.3 s 版一字不差**（349.2 vs 350.1），音频短 14% |

- 整章口径 = **1.14 s 合成 / 字、4.85 字/秒音频** ⇒ 3000 字/章 ≈ **57 min 算力 / 31 MB / 9.8 min 音频**，100 章 ≈ **95 h + 3.1 GB**。
- **未经分块的整章单次 `run()` 会 OOM 且中途无任何落盘**（第一次白跑 2.5 h）⇒ 分块 + 逐块落盘是实现里的硬要求。

## 3. 换算到「预生成 100 章」

一章 3000 字 ≈ **9.35 min** 音频（VITS 实测 321 字/分 @ `SPEED_SCALE=0.75`）≈ **27 MB**（24 kHz S16LE mono = 48 KB/s）
⇒ **100 章 ≈ 15.6 h 音频 ≈ 2.7 GB 磁盘**。⚠️ **磁盘是硬约束**（2026-10-12 实测）：VPS `/` 只剩 **1.2 GB**（29 G 用了 28 G，其中 `/root/tts/gsv` 就占 8 G）
⇒ **「预生成 100 章」在当前 VPS 上装不下**，必须先回收 + 靠「听完即删」+ 窗口（[`TTS-PREGEN-IMPL.md`](./TTS-PREGEN-IMPL.md) §2.5/§2.6）。

| 引擎 | 生成 100 章 | 听 2 h/天所需日算力 | 结论 |
|---|---|---|---|
| VITS | **9 h** | 65 min/天 | 一晚跑完，余量巨大（维持现状即可） |
| ZipVoice steps=6 | ~28 h（1.2 天） | 3.6 h/天 | 可行，但**用户已否**（毛刺） |
| ZipVoice **steps=12** | **~55 h（2.3 天）** | **7.1 h/天** | **✓ 用户已接受，建议档** |
| ZipVoice steps=24 | ~98 h（4.1 天） | 12.6 h/天 | 贴线，只适合「慢慢生成」 |
| **GPT-SoVITS v2ProPlus**（整章实测 5.57） | **~95 h（4.0 天）** | 6.9 h/天 | **✅ 用户已选为预生成默认引擎**（听感最优）；代价 = 常驻 3.3 GB + 跨章换声线 |
| GPT-SoVITS v4（实测 115.3） | ~2200 h（92 天） | 157 h/天 | **CPU 上不可行**（v3/v4 的 BigVGAN vocoder 太重）|

- GPT-SoVITS 两行是**同机同文本实测**（§2.2），可直接与 ZipVoice 比；换算口径（整章实测）：v2ProPlus **4.85 字/秒音频 / 1.14 s 合成分**
  ⇒ 3000 字/章 = **1 章 ≈ 57 min 算力 / 9.8 min 音频 / 31 MB**（语速比 VITS 慢 18%）⇒ 100 章 ≈ 16 h 音频 ≈ 3.1 GB。
- **内存是硬约束**（比 CPU 更早到极限）：v2ProPlus / v4 单进程常驻 **3.28–3.51 GB**，本机 3925 MB 且线上 VITS 还占 441 MB
  ⇒ 预生成期间必须靠 swap（本轮临时加了 4 GB `/swap2`），而** swap 会让线上 VITS 首次请求明显变慢**（引擎页被换出）。
  ZipVoice 的 1.0 GB 峰值相比之下完全无压力 —— **这是选 ZipVoice 而不是 GPT-SoVITS 的主因**。

## 4. 方案草图（**已细化为 [`TTS-PREGEN-IMPL.md`](./TTS-PREGEN-IMPL.md)，本节只留结论**）

### 4.1 服务端：内容寻址缓存 + job worker

- **`POST /tts` 前挂缓存查找**：key = `sha256(正文 hash | voice | speed | engine | steps)`。命中即返回磁盘 WAV ⇒
  **客户端 happy path 零改动**（它本来只认 `POST /tts` 回 24 kHz WAV）。
- **新增**（名字待定）：`POST /job {items:[{key,text,voice}]}` 入队、`GET /job/status` 进度、`GET /audio/{key}` 取整章（要支持 `Range`，`AudioRenderer` 才会流式播）。
- 落盘建议：**整章一个文件**（客户端按章播，段级切分没有收益），顺带存一份自描述头（voice/steps/正文 hash）便于 QC 与失效。
- **只生成 `speed=1.0`**：变速交给客户端 `AudioRenderer.setSpeed()`（App 侧已有 `effectiveSpeed()`），否则缓存按语速爆炸。
- 磁盘 LRU + 上限：与 App 侧缓存策略同思路（[`CACHE-LIMIT-PLAN.md`](./CACHE-LIMIT-PLAN.md)），阈值按 §3 的 27 MB/章折算。

### 4.2 批处理必须让出 CPU（这是唯一会伤到线上的地方）

- systemd 侧：`Nice=19` + `CPUWeight=20`（本轮实测 nice 19 与线上 VITS 共存，对拍未受影响）。
- 服务端侧：**最近 60 s 内有 `/tts` 请求 → 暂停批处理**（否则用户点开新书时会和批任务抢 4 个核）。
- swap 现 2 GB：ZipVoice 峰值 1 GB + VITS 441 MB + 系统 ⇒ 建议加到 6–8 GB（本轮未加也不 OOM，因为峰值比预估低得多）。

### 4.3 客户端：**章级原子切换**（关键体验约束）

- 播放某章前探测「**本章是否就绪**」→ 就绪则**整章**用远端音频；未就绪则**整章**走系统 TTS。
  **绝不做半章换音色**（同一章内换声线比音色不贴角色更伤听感）。
- 兜底顺序沿用现有 `ensureEngine / ensureRemoteSynthesized / fallbackToSystem`（[`../engine.md`](../engine.md)），
  只是"远端"从"实时合成"变成"可能命中缓存"——**对客户端是同一个接口**，这也是先做缓存层的原因。

### 4.4 素材从哪来（两个选项，建议 A 起步）

| 选项 | 做法 | 代价 |
|---|---|---|
| **A. 客户端上传** | 用户在某本书上点「预生成 N 章」→ App 把经引擎抓好的正文按章 `POST /job` | 客户端要加一个入口；服务端不用碰书源规则 |
| B. 服务端自爬 | 把 `rust/legado-engine` 编 `x86_64-unknown-linux-musl` 传上 VPS，用**同一批书源**自己抓正文再生成 | 一份引擎的交叉编译产物；但能"整本书静默预生成"，不依赖 App |

> 选项 B 的合法性/礼貌性要单独想（服务端 24×7 爬小说站 vs 用户点一下爬几章），**这不是技术限制**。

### 4.5 批量 QC（离线才有的新问题）

- 已有可复用资产：VPS `/root/tts/genshin-vits/loopdetect.py`（复读检测）、`asr_region.py`（局部 ASR 回比）、`zip_gen.py` 尾部的**声纹回比**。
- 策略：**失败章重试 → 仍失败则降 `steps` 或退回 VITS 生成该章**（宁可音色不贴，不要复读/空音）。

## 5. 本轮新发现的坑

1. **ZipVoice 词典缺 `“ ” …`**：日志成片 `matcha-tts-lexicon.cc Ignore OOV '”'` / `'…'` —— 这些符号被**静默丢弃**，
   听感上就是"引号处该有的停顿没了"。批量路线要先做**文本侧替换或词典补丁**（VITS 侧无此问题）。
2. **参考音频越短克隆越不稳**：`流萤_ref00.wav` 只有 **3.38 s**（花火 6.77 / 卡芙卡 3.42），
   而路线 B 唯一失败例（可莉 3.36 s）正是最短的那个（[`TTS-VOICE-SOURCES.md`](./TTS-VOICE-SOURCES.md) §11.2）⇒ **流萤是三个里最该复听的**。
3. **线上 `VOICE_REFS` 只登记了 3 个音色**（流萤 / 花火 / 卡芙卡）⇒ 想加原神角色（钟离/甘雨/… 参考音频在 VPS `/root/tts/gsv/refs/` 下 266 个目录里）**只需往 `VOICE_REFS` 补条目**，不需要新模型。
4. 若新增的 job 接口字段要**跟 NAPI 或落盘**，字段名必须进 `obfuscation-rules.txt`（见 [`AGENTS.md`](../../AGENTS.md) 硬性约定 / [`../engine.md`](../engine.md) §JSON 契约）。**纯服务端 HTTP 接口不受此约束。**
5. **切句法别乱换：`cut5` 反而更快、`cut3` 更慢**（**推翻本节早先的推测**，2026-10-12 实测）：同文本 285 字
   `cut5 + 0.3 s` = 350.1 s / **RTF 5.42**（**用户判定听感最优** ⇒ 已定为预生成默认口径）；
   `cut3`（按中文句号）= 607.3 s / **RTF 9.48**（长段让 AR 单段吐到 612 token，也正是整章 `cut3` 在第 14 段被 OOM 的直接原因）；
   `cut5 + fragment_interval=0` = 349.2 s / RTF 6.30 —— **算力与 0.3 s 版一字不差**，只是音频短 14%（去掉 927×0.3 s 段间静音）。
   ⇒ 结论：**保持 `cut5` + `fragment_interval=0.3`**；`cut3` 不要用；`fragment_interval=0` 只作为「磁盘实在不够」时的备选（听感未过）。
6. **逐句调用比原生慢 2×**（§2.2）：离线批量必须走**一次 `run()` + 内部切句**，不要复刻实时链路的逐句调用。
7. **内存 3.3–3.4 GB ⇒ 和线上 VITS 抢内存**：批任务在跑时 `Mem available` 掉到 **~100–190 MB**、swap 用掉 **4.9 GB**；
   线上 `/health` 仍 0.5 s 返回，但**引擎页被换出 ⇒ 首个 `/tts` 请求要等换入**。批处理真上线前必须先解决内存（加内存 / 限并发 / 只在深夜跑）。
8. **GPT-SoVITS 环境搭建的三个硬坑**（复现用）：torch **必须 ≥ 2.6**（新 `transformers` 的 `check_torch_load_is_safe` 会因 CVE-2025-32434 直接拒掉更低版）；
   `fast_langdetect` 必须**预置模型**（把 `venv/.../fast_langdetect/resources/lid.176.ftz` 拷成 `GPT_SoVITS/pretrained_models/fast_langdetect/lid.176.{ftz,bin}`，
   否则 import 期就 `Cache directory not found`，而它想下的 `dl.fbaipublicfiles.com` 在 VPS 不可达）；`sys.path` 必须**同时**含仓库根和 `GPT_SoVITS/` 子目录（否则 `No module named 'AR'`）。
9. **github / huggingface 在 VPS 不可达**：代码走 `gitcode.com` 镜像（`gh_mirrors/gp/GPT-SoVITS`），base/运行期资产走 ModelScope。
   可用源只有：ModelScope / 清华 pypi / SJTU pytorch-wheels / gitee / gitcode。
10. **v3/v4 不允许空 `prompt_text`**（`NO_PROMPT_ERROR`，它们用 vocoder），所以 v4 的零样本/微调都**必须有参考音频的真值文本**；
    `refs/<角色>/names.json` 里的 `real_name`（形如 `【情绪】正文.wav`）就是现成的真值（`_ref_text_from` 只需剥 `【…】` 前缀）。
11. **整章必须分块（1500 字/块，按段落切）**：单次 8741 字 `run()` 会累积到 **13.5 GB VA** 被 OOM 杀掉，**且中途无任何落盘**（白跑 2.5 h）。
    分块后每块独立落盘、RSS 每块回落（HWM 稳定 3.65 GB）⇒ 整章实测 audio 1802.5 s / synth 9992.4 s / **RTF 5.57**（6 块）。
12. **每次 `run()` 有 ~12 s 固定开销**：285 字 **1 次**调用 350 s vs **30 次**（逐句）718 s ⇒ ① 批量必须「一次调用 + 合批」（§5.6 的另一半证据）；
    ② **段级时间锚点不能靠逐段调用换**（那会把 RTF 拉到 11）⇒ 预生成只能给精确的**块级**偏移 + 段级按字数插值（[`TTS-PREGEN-IMPL.md`](./TTS-PREGEN-IMPL.md) §2.2/§3.4）。

## 6. 复现入口

| 动作 | 位置 |
|---|---|
| 本轮批量 A/B 脚本 | VPS `/root/tts/genshin-vits/batch_ab.py`（`ENGINE=zipvoice ZOUT=… python3 batch_ab.py <文本> <角色,角色> <steps,steps>`，日志 `/tmp/batchab{12,24}.log`） |
| 试听包 | 本机 `~/Desktop/tts-zipvoice-batch/`（含 `readme.md` 与全部数字） |
| 真实章节文本 | 本机 `/tmp/chapter.txt`（《剑来》@ 黑炎小说 `bundled-sources.json` index 2，`probe content`，8741 字）；试听用 285 字切片 `/tmp/ab_text.txt` |
| 线上 VITS 对拍 | `POST /tts {text,voice,speed}` + `X-API-Key`（key 在 VPS `/etc/systemd/system/tts.service`） |
| 参考音频 | VPS `/root/tts/gsv/refs/<角色>/ref00.wav`（266 个官方中配角色目录，同目录 `names.json` 给真值文本） |
| GPT-SoVITS 批量脚本 | VPS `/root/tts/gsv/gsv_batch.py`（`<角色[,角色]> <native\|nchapter\|ab> [steps] [variants] [chunk_chars] [cut] [fragment_interval]`；venv `/root/tts/gsv/venv`；日志 `/tmp/gsv_*.log`） |
| GPT-SoVITS 试听包 | 本机 `~/Desktop/tts-gpt-sovits/`（`gsv/` 各变体 wav + `对比/` ZipVoice s12 与线上 VITS + **`整章/` 8741 字 30 min 成品 + 6 分块** + `readme.md`） |
| 预生成实现方案 | [`TTS-PREGEN-IMPL.md`](./TTS-PREGEN-IMPL.md)（数据契约 / 服务端 / App 侧设置 / 验收 / 下个 session 的 prompt） |

## 7. 未决 / 下一步

1. ~~是否立项~~ → **2026-10-12 已立项**（用户拍板）：默认引擎 v2ProPlus、WAV 直出 + 严格淘汰、先手动喂（客户端入口后置）。
   施工图 [`TTS-PREGEN-IMPL.md`](./TTS-PREGEN-IMPL.md)，条目 [`../bugfix/TASKS.md`](../bugfix/TASKS.md) **T-TTS-7**，阶段一未开工。
2. **GPT-SoVITS 已实测（2026-10-12）**：整章 `v2ProPlus` RTF 5.57 / `v4` RTF 115.3 / 零样本底座 5.86–7.17，内存 3.3 GB。
   v4 在 CPU 上出局；v2ProPlus 慢但**被用户按听感选为默认引擎**（100 章 ≈ 95 h，需要 worker 独占内存 —— 实现里用独立进程 + 让位门闸缓解）。
   ~~待办：`cut3` + 调小 `fragment_interval` 后的重测~~ → **已测完并推翻**（`cut3` 更慢，见 §5.5）。剩余待办：整章复读/漏字 QC（§4.5）、段级时间锚点（IMPL §2.2）。
3. **最小可用版本**（若不想一次做全）：先只做 §4.1 的缓存层 + `POST /job`，客户端入口后置（用户手动喂 20 章先听）。
4. **预生成的语种/文本预处理**（§5.1 的引号/省略号）要在批量脚本里先补，否则整本书都是"引号无停顿"。
