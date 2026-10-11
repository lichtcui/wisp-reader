# TTS 服务器（远端合声）可行性调研

日期：2026-10-02
分支：`tts/mac-p0`（worktree `/Users/lichtcui/Documents/playground/source-reader-tts`）
前序（勿返工）：[`progress.md`](../../../progress.md) §「端侧自建 TTS（Route C / ZipVoice）调研结论」、
[`ZIPVOICE-ONNXRUNTIME-DYNAMIC-SHAPE.md`](ZIPVOICE-ONNXRUNTIME-DYNAMIC-SHAPE.md)、
[`TTS-FOLLOWUP-ORT-AND-EXIT-PATHS.md`](./TTS-FOLLOWUP-ORT-AND-EXIT-PATHS.md)（重点 §3/§6/§6.1）、
[`TTS-PLAN.md`](TTS-PLAN-LOCAL-ONNX.md) §4.3/§9（Route C 上下文）
范围：**只调研 + 给方案，不改代码、不 commit**。回答「连接远端服务器听书」是否可行、怎么落、代价多大。

---

## 0. 一句话结论（速览）

端侧自建音色两条路（GPT-SoVITS 端侧 RTF≥1.483、ZipVoice 端侧 ORT 动态 shape 乱码）都已判死（见前序）。
「服务器合成 + App 拉 PCM」在**单机自用（你本人一台小 VPS / 常驻 Mac）**场景下**技术上零阻塞**：App 端改造是
「在 `TtsController` 里加第 3 个 `engineKind=REMOTE`」，下游 `fill`/`ReqBuffer`/`AudioRenderer`/`AVSession` 全复用，
按我实测与官方数据的 CPU RTF，**轻量 CPU 服务器上 RTF≈0.5～0.8，逐段合成 + 预取 2 句能盖住延迟**。
但它改变的是产品性质（**全书文本出端 + 断网不可用**），且**违反 AGENTS.md 第 40 行「v1 不做在线 TTS」**，
是「拍板改决策」问题，不是「能不能做」问题——**技术上随时可上，建议当独立决策单，别和端侧封存混在一起**。

| 方案 | 可行性 | 新增工作量 | 风险/不确定性 |
|---|---|---|---|
| ① sherpa-onnx 薄壳（ZipVoice 零样本克隆 / VITS 现成音色） | 高 | 服务端 ≤0.5 人天 + App 1.5–2.5 人天 | 克隆音色质量 vs 训练音色差距要耳朵验；轻量 CPU 无官方 RTF 表 |
| ② GPT-SoVITS 官方 `api_v2.py`（1:1 复用 3 音色） | **中高**（音色最好，内存最重） | 服务端 ≤0.5–1 人天 + App 同上 | PyTorch CPU 常驻 ~1.5–2.3GB（int8）/ 3.9GB（fp32）；2GB 内存 VPS 跑不动 fp32 |
| ③ 常驻 Mac + tailscale（不买 VPS） | 高（零额外成本） | 服务端 0 + App 同上 | 依赖 Mac 常开；公网无端口暴露 |
| ④ 第三方 TTS API | 低 | App 同上（无服务端） | 成本/隐私最差，一笔带过 |

---

## 1. 服务端选型对比（都要归结为同一 App 侧改动，见 §3）

三候选产出同为 **PCM**（或可选的压缩码流），采样率可切（24k/32k），喂回现有 `AudioRenderer`（`STREAM_USAGE_AUDIOBOOK`）即可。

### 1.1 sherpa-onnx 薄壳（~100 行 FastAPI/WebSocket）

**形态**：`pip install sherpa-onnx` → 用其 `offline-tts` Python API（`python-api-examples/zipvoice-tts.py` 已存在）
包一层 FastAPI：`POST /tts {text, voice}` → 合成 → 回 PCM（或 websocket 逐句）。约 100 行、无新算法。

**两个模型选项，必须二选一**：

| 选项 | 模型/体积 | 音色 | 质量与风险 |
|---|---|---|---|
| **ZipVoice 零样本克隆** | `zipvoice-distill-int8-zh-en-emilia` **109.2MB** + `vocos_24khz.onnx` **54.2MB**（官方 release 体积） | 用你手上流萤/花火/卡芙卡的**参考音频**克隆 | 官方明确：`--reference-text` 必须是参考音频**逐字稿**，不匹配则质量显著下降；零样本克隆的**音色贴合度/稳定性 < 训练音色**，且 ZipVoice 是 flow-matching 迭代（`num-steps`），是 sherpa 系里**偏慢**的一档 |
| **VITS / Matcha 现成音色** | `vits-zh-hf-{bronya,echo,abyssinvoker,keqing,doom}` 各 ~120MB；`vits-icefall-zh-aishell3` 31MB（release asset 实测体积） | 现成动漫/通用女声，**没有**星穹铁道三位角色 | VITS 是**单次前向**（内嵌 decoder），RTF 必然最低；Matcha 是少数步 flow，居中。但**没有你要的角色音色** |

**CPU RTF / 内存可查证数据（诚实口径）**：

- **本机实测（真机 麒麟 9010 / 16GB）**：ZipVoice `numSteps=2 / numThreads=4` RTF **0.490–0.536**（progress.md §Route C 结论、`tts-p6-report.md` §5）。注意这是**旗舰手机 CPU**，≈ 当下主流 PC/家用机单核性能量级，可作「个人服务器不慢于它」的下界参考。
- **本机实测（Mac，同模型同代码，ORT 1.28.2 正常）**：ZipVoice 一段中文 3.44s @24k（103168 采样）**稳定正确**（FOLLOWUP §6）——证明**服务器侧（标准 onnxruntime）无端侧那个动态 shape bug**，可正常出声。
- **无官方 CPU RTF 表**：sherpa-onnx 文档 `tts/zipvoice.html` / `tts/matcha-tts.html` / `tts/vits.html` 只有下载与 CLI 用法，**没有 RTF/RAM benchmark 页**（`offline-tts/benchmark.html` 404）。所以轻量 VPS 上 sherpa 的 RTF 只能自己做一次 CPU 冒烟实测，不能用别人数字。
- 内存：ZipVoice 模型 109+54MB，推理时常驻**大概率 < 400MB**（模型 int8 + 短句），对 2–4GB 内存 VPS 无压力——这是它相对 GPT-SoVITS 的**唯一硬优势**。

**可行性**：高。**工作量**：服务端 ≤0.5 人天（薄壳 + 下模型 + `curl` 冒烟一段中文听声）。**风险**：克隆音色「像不像你要的三位角色」与「听书长稳不漂」要耳朵判，无客观保证。

### 1.2 GPT-SoVITS 官方 `api_v2.py`（1:1 复用现有 3 个 v2ProPlus 音色）

**形态**：官方仓库自带 FastAPI 服务，**零新建服务端代码**，直接 `python api_v2.py -a 0.0.0.0 -p 9880 -c GPT_SoVITS/configs/tts_infer.yaml`。

**端点/能力（本次拉取官方 `api_v2.py` 全文核实）**：

- `GET/POST /tts`（参数 `text / text_lang=zh / ref_audio_path / prompt_lang / prompt_text / text_split_method=cut5 / batch_size / media_type / streaming_mode`）。
- 管理端点：`/control?command=restart`、`/set_gpt_weights`、`/set_sovits_weights`、`/set_refer_aduio`——即可**热切换 3 个音色权重 + 参考音频**，无需重启进程。
- **媒体格式原生支持 `wav / raw / ogg / aac`**；`wave_header_chunk(sample_rate=32000, channels=1, sample_width=2)` → 默认 **32kHz S16LE mono PCM**；`pack_ogg` 走 av/ffmpeg 直接出 **ogg（opus）**。
- `uvicorn.run(workers=1)` → 单 worker，天然串行（单用户听书场景就是串行，无需排队）。

**CPU RTF / 内存（可查证）**：

| 来源 | 环境 | RTF | 内存 |
|---|---|---|---|
| 官方 README（v2 ProPlus） | 4060Ti / 4090 / **M4 CPU** | 0.028 / 0.014 / **0.526** | — |
| **本机实测**（TTS-PLAN §9 P2，int8 bundle） | Intel i5-1038NG7 4C/8T / 16GB | **0.74–0.78** | peak RSS **1.94–2.28 GiB**（phys 1.42–1.81 GiB） |
| 本机实测（fp32 bundle） | 同上 | 0.88–0.98 | peak RSS **3.86–4.19 GiB** |

- bundle 体积：int8 **1.2GB** / fp32 **3.2GB**（`ssl/bert` 不量化、必须常驻，见 TTS-PLAN §5）。
- 本机**端侧**（麒麟 9010）RTF 下限 **1.483** → **端侧不可行**，但那是「跑在手机里」；服务器上用同 int8 bundle 在 4 核 i5 上是 0.74–0.78（**服务器可行性成立**）。

**可行性 vs 轻量约束的关键判定**：

- **2GB 内存 VPS 跑不动**（int8 峰值 RSS ~2.3GiB 已顶格；fp32 直接 OOM）。**4GB 内存**跑 int8 是门槛（RSS ~2GiB + Python/系统头寸将将够，建议 4GB 且开 `is_half`/量化）。**1–2 核**能跑但 RTF 会从 0.75 往 1.0 方向恶化——单段合成墙钟 ≈ 音频时长 × RTF，RTF 1.0 时预取 2 句仍能勉强续上，但翻章 + 突刺会卡。
- 官方另给「CPU 优化推理版」`baicai-1145/GPT-SoVITS-CPUFast`（README 链接），可作 CPU 加速备选，但属社区 fork、音质一致性未验证，仅备注。
- **音色是三者里唯一的「1:1 复用」**：流萤/花火/卡芙卡权重 + 参考音频原样加载，出来就是训练音色（客观克隆度 0.86–0.91、长段有复读风险需 `cut5` + 非固定 seed 控制，见 TTS-PLAN §9 P2/P3）。

**可行性**：中高（音色最好、部署现成；成本 = 内存门槛 + PyTorch CPU 依赖）。**工作量**：服务端 ≤0.5–1 人天（conda 装 torch CPU + 指权重路径 + `curl` 冒烟三音色各一段）。**风险**：内存常驻高、轻量 CPU 上 RTF 最不宽裕；PyTorch/cpuonly 安装偶有坑；复读/漂移需沿用 P3 的 `cut5+非固定 seed` 约束。

### 1.3 （可选）常驻 Mac + tailscale（不买 VPS，组网变体）

把 §1.1/§1.2 的薄壳 **不部署在 VPS，而跑在本机常驻 Mac**，App 通过 tailscale 内网 IP 直连。

- **可行性与成本**：最高——**0 服务器成本、0 端口暴露**（tailscale 是 mesh VPN，无需公网）。本机就是 TTS-PLAN P2/P3 那台 i5/16GB（或换成任意常驻 Mac），int8 GPT-SoVITS 已实测 0.74–0.78。
- **代价**：要求该 Mac **常开**、登录 tailscale；家庭宽带上行通常 ≥20Mbps，远大于 PCM 48KB/s，不是瓶颈。
- 这是**在「不推翻决策、先自己体验」阶段的最佳最小闭环**：不用为服务器折腾，先在常驻 Mac + tailscale 上把 §2/§3 的链路跑通，真觉得音色值得，再考虑上 VPS 或干脆维持 Mac 常驻。
- **Colab 不适合**：免费/Pro 实例有空闲回收（~90min 无活动断连）、无固定内网 IP、GPU 分配不定，当「常驻听书引擎」不可靠；作为 demo 冒烟可以，不做常驻方案。

### 1.4 （一笔带过）第三方 TTS API（阿里/火山/MiniMax 等）

- 音色好、延迟低、免运维，但**全书文本出端到第三方**、按字/时长计费、接口/音色随时可能改，隐私+成本+供应链三重最差。**不建议**，仅作对照。

---

## 2. 协议与流式

### 2.1 整段合成 vs WebSocket 流式 chunk

| 方式 | 结论 |
|---|---|
| **整段合成（推荐 v1）** | 每次请求返回**一整段（一句话）**的 PCM 或 ogg。App 已有「逐段」节奏：`TtsController` 按 `paragraphs[]` 逐段合成（`AHEAD=2`）。**整段正契合现有 ReqBuffer/`enqueueParagraph` 管线**，无任何新编解码逻辑。 |
| WebSocket 流式 chunk | 首字延迟更低、可边收边播，但 **App 侧要新增「流式收 chunk → 边接收边填 render queue」**这一层，且竞态/断流重连比整段复杂一个量级。**v1 听书不是聊天 TTS，不值得**。 |

`ponytail:` v1 用整段 HTTP 拉取（对齐「简听」`HttpTtsPlayer` 事实标准）；真到「首段延迟不可接受 + 长文朗读」再上 WS 流式。

### 2.2 逐段预取能否盖住延迟（参考「简听」HttpTtsPlayer 的「当前句 + 后 2 句」）

延迟构成 = **RTT + 单段合成墙钟 + 下行**。量级：

- 单段音频 2–4s；服务器 RTF 0.52（GPT-SoVITS M4）/ 0.75（int8 i5）/ 0.5（sherpa ZipVoice 手机）→ **单段合成墙钟 ≈ 1–3s**。
- RTT：tailscale 内网 ~1–5ms、家庭宽带 ~10–30ms、VPS ~30–80ms（相对合成墙钟可忽略）。
- 现有 `AHEAD=2`（TtsController `ensureSynthesized` / `ensureZipSynthesized` 里 `issuedIndex - flushIndex < AHEAD`）默认只预取 2 **段**，对本地合成（RTF 0.5、无 RTT）够了；对远端应把 `AHEAD` 提到 **3**（当前句 + 后 2 句，正是 `end-web/HarmonyOS-book` 的 `HttpTtsPlayer` 实测做法，FOLLOWUP §6.1），并让每段「文本上行 + 合成 + PCM 下行」全程异步。

**能否盖住**：单用户串行播放 1 段 ≈ 2–4s，而并行预取 3 段的合成墙钟各 1–3s，**只要 `服务器合成吞吐 ≥ 播放吞吐` 就能盖住**（即有效 RTF < 1 即可；RTF 0.5-0.8 都成立）。2GB 内存 VPS 跑 int8 GPT-SoVITS 若 RTF 退化到 ~1.0 会是灰区：能播但翻章/突刺会露底。

### 2.3 跨章追尾怎么处理

现有 M5 跨章已是「整章 `paragraphs[]` 播完 → `nextReadable` 取下一章 → 再取正文合成」（`TtsController` 尾部），存在短暂停顿。
远端化后追尾被「取下一章正文」放大：**第一句 PCM 还没下行，正文都还没到 App**。

- **最小解法（0 新依赖）**：复用 M4 已有的**正文缓存 + 预取下一章**（`ChapterCache` / `BookContent` 已缓存相邻章），
  在 `TtsController` 播到「本章最后 `AHEAD` 段」时**提前 fetch 下一章段落**，把「取正文」从关键路径移出；合成仍是逐段远端拉。
  `ponytail:` v1 只做「提前取下一章正文」，**不做整章预合成**——整章预合成要在服务器侧排队 5–10 分钟音频，内存/磁盘无必要。
- 段落切分沿用系统 TTS 现有 `ChapterUtil` 的分段粒度即可，远端只是换了「谁在合成」，切分/高亮/进度逻辑不动。

---

## 3. App 侧改造量（复用 TtsController 管线，新增 `engineKind=REMOTE`）

现状（已读完 `model/TtsController.ets`）：PCM 来源 = 系统 TTS `onData` / ZipVoice worker `f32ToS16`；
下游 `ReqBuffer{chunks,bytes,doneAt}` → `tryFlush()`（`FLUSH_GRACE_MS`）→ `enqueueParagraph()`（按 sequence 拼段推 `RenderItem`）→
`fill(buffer)` 喂 `AudioRenderer`（`STREAM_USAGE_AUDIOBOOK`）→ AVSession/后台/定时/进度。**远端引擎只需要换「PCM 来源」这一步**。

### 3.1 最小改动边界（新增/改哪些文件）

| 文件 | 动作 | 内容 |
|---|---|---|
| `model/RemoteTtsClient.ets` | **新增** | `fetch(synthesis-server/{text,voiceId}) → ArrayBuffer`（S16LE PCM 或 ogg→PCM 二选一，见下）；超时/重试；`AbortController` 挂起取消 |
| `model/TtsController.ets` | **改** | ① `engineKind` 加 `TTS_ENGINE_REMOTE` 常量 + `@Trace serverUrl/remoteVoice`；② 仿 `ensureZipSynthesized()` 加 `ensureRemoteSynthesized()`（`AHEAD=3`，逐段 async fetch，回来 `rb.chunks.set(0, pcm)` + `rb.doneAt=Date.now()`，走**同一个** `tryFlush/enqueueParagraph`）；③ `fill` 前一帧判空/失败 → `fallbackToSystem()` 回退系统 TTS；④ `AudioRenderer` 采样率三元：系统 16k / ZipVoice 24k / **Remote 24k 或 32k**（取服务器返回的采样率，或写死 32k 对应 GPT-SoVITS） |
| `common/Const.ets` | **改** | `TTS_ENGINE_REMOTE`、默认服务器地址/`AHEAD_REMOTE=3` |
| `common/Prefs.ets` | **改** | 服务器地址 / 远端音色持久化（现有 `get/putString` 直接复用，0 新代码） |
| `pages/ListeningSettings.ets` | **改** | 引擎三选一（系统/远端；ZipVoice 隐藏开关保留）+ 服务器地址输入 + 音色选择 |
| `entry/obfuscation-rules.txt` | **改** | 新增远端 JSON 字段名 `-keep-property-name`（`serverUrl/voiceId/pcm/error` 等，release 混淆用） |
| `module.json5` | **改（若 HTTPS 自签）** | 走公网 HTTPS 无需动；**tailscale 内网 http:// 明文**需确认明文 HTTP 未被拦截（M0 已证明文 http 可用），或上 https 自签证书 + 白名单 |

**不动的**：`AudioRenderer` 链路、`AVSession`/锁屏/媒体键、后台长时任务、定时关闭、段落高亮/进度回写、书架 FAB、目录逻辑——全部 0 改动（它们只认 `queue` 里的 `RenderItem`，不认 PCM 是谁产的）。

### 3.2 编解码取舍（带宽 vs App 复杂度）

- **v1 直接拉 PCM（S16LE）**：0 编解码，但 24k=48KB/s、32k=64KB/s（见 §4）。
- **拉 ogg/opus**：GPT-SoVITS `api_v2` 原生 `media_type=ogg`（服务端零成本），但 **App 要新增 opus 解码**（HarmonyOS 有 `@ohos.multimedia.media` / AVCodec 能力可解 opus，但这是一块新集成 + 真机验证），**v1 不做**。
- 结论：**v1 拉 PCM**（你单机自用，带宽不是瓶颈）；真到移动流量或多人再切 ogg。`ponytail:` 边界注释写清楚升级路径即可。

### 3.3 工作量估算（人天）

| 层 | 人天 | 说明 |
|---|---|---|
| `RemoteTtsClient` 网络取流（超时/重试/取消） | 0.5 | 无新算法，`@ohos.net.http` 直用 |
| `TtsController` 加 `REMOTE` 分支 + 回退系统 TTS | 0.5–1 | 仿 `ensureZipSynthesized` 照抄改 3 处 |
| 设置页 + Const/Prefs + obfuscation | 0.5 | 模板化 |
| **App 合计** | **1.5–2.5** | 与 FOLLOWUP §3.2 的「App 1–2 人天」一致，多加回退/联调 0.5 |
| 服务端（§1.1 sherpa 薄壳 或 §1.2 api_v2 起服务） | 0.5–1 | 薄壳或 api_v2 均现成，无新算法 |
| **总计（含真机联调往返 hdc）** | **~2–3.5 人天** | 前提：不回头碰端侧 ORT/训练 |

---

## 4. 代价清单

| 代价 | 量化/判断 |
|---|---|
| **延迟** | 逐段 = RTT(1–80ms, 可忽略) + 服务器合成墙钟（RTF×音频时长 ≈ **1–3s/段**）。`AHEAD=3` 预取可盖住；翻章若未提前取正文会卡一下（§2.3，可取正文提前到后台）。 |
| **隐私** | **全书文本逐句出端**到你的服务器；这是「是否上远端 TTS」的**本质代价**，不是工程代价。单机自用（自己的 VPS/常驻 Mac）可接受，第三方 API 不可接受。 |
| **带宽** | PCM 24k S16 = **48KB/s ≈ 172.8MB/h**；32k = **64KB/s ≈ 230MB/h**。家用上行 ≥20Mbps、VPS 月流量 1TB 均绰绰有余。切 ogg/opus 可降到 **~1/10–1/16**（3–4KB/s），但 App 新增 opus 解码，v1 不做。 |
| **断网不可用** | 无网完全不能合成（系统 TTS 是离线的）。**必须保留 `fallbackToSystem()`**：网络失败/超时 → 自动回落系统 TTS，UX 上「远端是增强、系统是兜底」。 |
| **服务器成本** | §1.1 sherpa 薄壳：小 VPS（2C/4GB）可跑，模型 <400MB，**最低档 VPS 即可**；§1.2 GPT-SoVITS int8：**≥4GB 内存**、常驻 ~2GiB，1–2 核 RTF 贴近 1.0 灰区，建议 4C/8GB。§1.3 常驻 Mac + tailscale：**0 成本**。 |
| **本地缓存已合成段（v1 要不要）** | **不做**。同书顺序流式播放 + 预取 2–3 段，缓存命中率极低（章顺序不返头）；且每段 PCM 2–4s≈100–250KB，落盘反而增 I/O。`ponytail:` v1 不缓存；若未来「同一本书反复听 + 离线可用」成为真实需求，再按 `hash(bookId+paragraphIndex+velocity+voice)→PCM 文件` 加，落 `filesDir`，才是它该出现的时候。 |

---

## 5. 对照决策（二选一，供拍板）

> 现行决策文本（**唯一权威在 `AGENTS.md`**，`plan.md` 只是设计）：`AGENTS.md` 第 40 行
> `| v1 不做 | JS 运行时、登录型源、换源、发现(explore)、真分页、在线 TTS |`——「在线 TTS」与多项**共处一行**，不是独立行。

### 结论 A（不上，维持系统 TTS）——推荐作为**默认**，除非你明确想要三音色

- 动作 = **零改动**。听书继续 M5 系统 TTS（已真机验证，锁屏/后台/定时/高亮齐全）。
- 端侧三条自建路线维持「封存」结论（待 ORT 上游修 OHOS 动态 shape）。
- 适用判据：**系统 TTS 音质可接受**（多数鸿蒙看书 app 的「离线听书」就是系统 TTS，见 FOLLOWUP §6.1 对「简听」的实证）→ 没必要为音色付「文本出端 + 断网 + 运维」三重代价。

### 结论 B（上远端 TTS），最小改动边界 + 要改的决策文本

**步骤顺序（先决策后代码）**：
1. **改决策**：`AGENTS.md` 第 40 行删去「、在线 TTS」（即整行变为 `| v1 不做 | JS 运行时、登录型源、换源、发现(explore)、真分页 |`）；同步 `plan.md:26` 的「/ 在线 TTS」删除。**不需要改** `plan.md:321` 与 `progress.md:17`——那里本就是「v2 将做在线 TTS」，删掉第 40 行后它自动从「v1 不做」归位到「v2 做」。
2. **先跑 §1.3「常驻 Mac + tailscale」当最小闭环拿听感数据**（0 服务器成本），而不是直接买 VPS。
3. App 端按 §3.1 加 `engineKind=REMOTE` + 回退系统 TTS；服务端按 §1.1 或 §1.2 起一个（首推 §1.2 复用三音色）。

**上线前必须明确的边界**（写进决策，不要口头）：
- 远端 = **可选增强**，系统 TTS 仍是默认 + 兜底（失败/无网/未配置服务器地址 → 一律系统 TTS）。
- **单机自用**：服务器/常驻 Mac 只服务你自己；不承诺多人并发（api_v2 `workers=1` 天然串行）。
- v1 拉 PCM、不缓存、不做 ogg/opus 解码（分别留 `ponytail:` 升级路径）。

### 建议清单（按「投入 / 成功率」排序，供拍板）

| # | 方案 | 投入 | 成功率 | 建议 |
|---|---|---|---|---|
| **1** | **结论 A：维持系统 TTS** | **0** | 100%（已真机验证） | **默认建议**。只有当你明确「就是要流萤/花火/卡芙卡听书」才往下走 |
| **2** | **§1.3 常驻 Mac + tailscale 最小闭环**（+ §1.2 GPT-SoVITS 三音色，App `REMOTE` 引擎） | 服务端 0.5–1 + App 1.5–2.5 人天 | 高（音色 1:1、零服务器成本、链路风险全在 App 取流） | **想上远端时的首选第一步**：先在自己 Mac 上靠 tailscale 跑通拿听感，再决定是否 VPS 化 |
| **3** | **§1.1 sherpa 薄壳（ZipVoice 克隆 / VITS 现成音色）** | 服务端 ≤0.5 + App 1.5–2.5 人天 | 高（内存 <400MB 可跑最低档 VPS），但**音色贴合度 < 训练音色** | 若「轻量 VPS 长期对外」且愿接受克隆音色再选；否则只作对照 |
| **4** | **§1.2 GPT-SoVITS 直接上 VPS（≥4GB 内存）** | 服务端 ≤0.5–1 + App 1.5–2.5 人天 | 中高（音色最好），约束 = 4GB+ 内存 / 1–2 核 RTF 贴近 1.0 灰区 | 在方案 2 验证有打动你的音质后，若嫌 Mac 常开麻烦再迁移 |
| **5（否掉）** | 第三方 TTS API | — | 低（隐私/成本/供应链最差） | 一笔带过，不做 |

**拍板问题就一个**：「系统 TTS 音色是否可接受？」——可接受 → 选 1（0 投入）；不可接受 → 选 2（Mac+tailscale 拿听感），再据听感决定停还是 3/4 上 VPS。

---

## 6. 证据来源索引

**本机实测（可复核）**
- GPT-SoVITS int8/fp32 RTF 与内存：`TTS-PLAN.md` §9 P2（Intel i5-1038NG7 4C/8T/16GB；int8 RTF 0.74–0.78 / peak RSS 1.94–2.28GiB；fp32 0.88–0.98 / 3.86–4.19GiB；bundle int8 1.2GB / fp32 3.2GB）。
- GPT-SoVITS 端侧 RTF 下限 1.483（麒麟 9010，判死端侧）：`TTS-PLAN.md` §7「2026-09-29 拍板」块 + §9 P4 ⑨。
- 三音色权重/参考音频路径：`~/Documents/playground/tts/models/v2ProPlus/{流萤,花火,卡芙卡}/`（本报告 `ls` 复核）。
- ZipVoice 端侧 RTF 0.490–0.536（numSteps=2/numThreads=4）：`docs/tts-p6-report.md` §5、`docs/progress.md` §Route C。
- ZipVoice 服务端（Mac ORT 1.28.2）正确帧数 103168=3.44s@24k：`TTS-FOLLOWUP-ORT-AND-EXIT-PATHS.md` §6。
- App 现有 PCM 管线（`ReqBuffer`/`fill`/`enqueueParagraph`/`ensureZipSynthesized`/`AHEAD`/采样率三元）：`entry/src/main/ets/model/TtsController.ets`（本报告逐行读）。

**官方文档 / GitHub（本次拉取，走 127.0.0.1:7897 代理）**
- GPT-SoVITS v2 ProPlus RTF（0.028/4060Ti、0.014/4090、**0.526/M4 CPU**）与「CPU 优化版 GPT-SoVITS-CPUFast」链接：`RVC-Boss/GPT-SoVITS` README（L36–51）。
- `api_v2.py` 端点与能力（FastAPI；`/tts`、`/control`、`/set_gpt_weights`、`/set_sovits_weights`、`/set_refer_aduio`；`media_type=wav/raw/ogg/aac`；`sample_rate=32000, channels=1, sample_width=2`；`streaming_mode`；`text_split_method=cut5`；`workers=1`）：`RVC-Boss/GPT-SoVITS` `api_v2.py` 全文。
- sherpa-onnx ZipVoice 模型体积 109.2MB + vocab 说明 + `--reference-text` 必须逐字稿的精度警告：`k2-fsa.github.io/sherpa/onnx/tts/zipvoice.html`；sherpa Python API 例程 `python-api-examples/zipvoice-tts.py` 同页链接。
- sherpa-onnx VITS 现成中文音色体积：`k2-fsa/sherpa-onnx` release `tts-models` assets（`vits-zh-hf-{bronya,echo,abyssinvoker,keqing,doom}` ~120MB、`vits-icefall-zh-aishell3` 31MB，API 实测体积）。
- 无官方 CPU RTF/RAM 表：`k2-fsa.github.io/sherpa/onnx/offline-tts/benchmark.html` → 404（本报告探测）。

**同类 app 实证（既定事实，勿返工）**
- 「简听」`end-web/HarmonyOS-book`：离线朗读 = 系统 TTS（CoreSpeechKit，`online:1` 偏好在线无网回退）；自定义音色 = `CustomTtsConfig` + `HttpTtsPlayer`「当前句+后续两句」HTTP 逐句预取：`TTS-FOLLOWUP-ORT-AND-EXIT-PATHS.md` §6.1。

**决策文本定位（本报告 grep 复核）**
- `AGENTS.md` 第 40 行：`| v1 不做 | JS 运行时、登录型源、换源、发现(explore)、真分页、在线 TTS |`（「在线 TTS」与多项共处一行）。
- `plan.md:26`（`- 真分页（左右滑动翻页）/ 在线 TTS`）、`plan.md:257`（预留扩展点）、`plan.md:321` 与 `progress.md:17`（v2 范围已含在线 TTS）。

---

## 7. 决策记录（2026-10-02，已拍板）

- **系统 TTS = 默认 + 断网/失败兜底**（音质可接受）；**网络可用时用 GPT-SoVITS `api_v2.py` 提供流萤/花火/卡芙卡音色**。
- **最小闭环 = 常驻 Mac + tailscale**（§1.3 + §1.2），0 服务器成本，先拿听感；验证音质后再决定是否迁 VPS（≥4GB）。
- v1 边界：拉 32k S16LE PCM、不缓存、不做 ogg/opus、单机串行（`api_v2` 单 worker）。
- **实施不在本轮**（本轮只调研）；后续新 session 按 [`HANDOFF-S12.md`](HANDOFF-S12.md) 执行（含启动 prompt + 服务端缺口「base 预训练模型未落盘」+ App 改造清单 + 真机验收）。