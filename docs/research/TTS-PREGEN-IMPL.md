# TTS 预生成 · 实现方案（阶段一=服务端 / 阶段二=App 入口与设置）

> 上游：[`TTS-PREGEN-PLAN.md`](./TTS-PREGEN-PLAN.md)（判据改写 + ZipVoice/GPT-SoVITS 实测 + 坑清单）、决策 [`../decisions.md`](../decisions.md) **D15**、
> 任务 [`../bugfix/TASKS.md`](../bugfix/TASKS.md) **T-TTS-7**；引擎细节 [`TTS-ENGINE-COMPARISON.md`](./TTS-ENGINE-COMPARISON.md)、音色 [`TTS-VOICE-SOURCES.md`](./TTS-VOICE-SOURCES.md)。
> **状态（2026-10-14）**：**阶段一（服务端）已上 VPS 并 7/7 验收（§4.1.1）；阶段二（App 侧）真机验收 6 项中 5 项已拍到（§4.2：缓存章 24 kHz 命中 / 跨章 16k↔24k 双向重建 / 未算完退实时不混声线 / 听完即删 + 自动续章），剩拖动·变速的逐项拍照、锁屏、`expired` 分支**；同轮修三个真 bug（本地书键存 sidecar / hilog 不支持 `%f` / `notfound` 不再作废缓存键，最后一个真机待验）。
> **as-built 偏差以 §3.6 为准**（整章先落盘再播、块级段落下标、入口在听书页等）。
> **用户已拍板三件事**：① 默认引擎 = **GPT-SoVITS v2ProPlus（流萤微调）**；② 缓存 **WAV 直出（24 kHz mono）** + 严格淘汰；
> ③ 素材来源 = **先手动喂（curl）**，客户端入口后置（阶段二）。本文 §6 是给**下一个 session** 的启动 prompt。

<!-- TOC:BEGIN -->
- 0. 一页速览 — L43
- 1. 数据契约（先定这个，阶段一/二都依赖） — L70
  - 1.1 缓存键（服务端算，客户端只存） — L72
  - 1.2 `POST /job` 的 item（= 客户端能直接产出的东西） — L84
  - 1.3 落盘布局 — L96
  - 1.4 HTTP 接口表（除 `/health` 外都要 `X-API-Key`，与 `POST /tts` 同一把） — L121
- 2. 服务端实现（阶段一，客户端零改动） — L134
  - 2.1 进程架构 — L136
  - 2.2 合成流程（worker） — L148
  - 2.3 引擎与内存（`gsv_v2proplus`） — L162
  - 2.4 让出 CPU / 内存（唯一会伤到线上的地方） — L173
  - 2.5 磁盘预算（**先做这一步**，否则一跑就满） — L181
  - 2.6 淘汰策略（**别把用户马上要听的那章挤掉**） — L198
  - 2.7 QC 与失败处理 — L205
  - 2.8 部署（as-built） — L211
  - 2.9 实现期与本文档的偏差（as-built，实现时改的，均已入库） — L238
- 3. 客户端设计（阶段二，含「填写方式」） — L259
  - 3.1 现有设置照旧 + 「两套音色」的取舍 — L261
  - 3.2 新增设置项表（「填写方式」= 用户在设置页怎么填） — L271
  - 3.3 入口与交互 — L289
  - 3.4 播放路径改造（章级原子切换 + 变速 + 进度锚点） — L298
  - 3.5 字段与 obfuscation 三处同步清单（**漏一个就是 release 读到 undefined**） — L314
  - 3.6 实现偏差（as-built，2026-10-13） — L329
- 4. 验证 — L345
  - 4.1 阶段一（主机侧 curl + 线上回归，**不上设备**） — L347
  - 4.1.1 实测结果（2026-10-13，VPS `103.236.96.53`，worker `tts-job`） — L361
  - 4.2 阶段二（真机） — L386
- 5. 风险 / 未决 — L423
- 6. 附录：阶段一（服务端）的启动 prompt（**已完成，留作历史**） — L434
- 7. 附录：阶段二（客户端接入）的启动 prompt — L476
<!-- TOC:END -->

## 0. 一页速览

| 项 | 内容 |
|---|---|
| **目标** | VPS 空闲时把「用户正在听的这本书」接下来 N 章的音频预先合成好；App 播放时**整章命中缓存就用缓存音频**，未命中照旧走实时 VITS / 系统 TTS |
| **非目标（本轮）** | 服务端自爬书源（选项 B）、客户端 UI、在线/实时 GPT-SoVITS、变速音频多份缓存、多用户/多租户 |
| **阶段一（本轮要做的）** | 服务端：`POST /job` 入队 + 文件队列 worker（GPT-SoVITS v2ProPlus 合成）+ `GET /audio/{key}` + 淘汰/QC。**客户端一行不改**，用 curl 验收 |
| **阶段二（后续 session）** | App：听书设置里新增「预生成」分组 + 书级「预生成后续 N 章」入口 + 播放路径改「章级原子切换」 |
| **默认引擎** | `gsv_v2proplus` + `voice=流萤`（微调权重 `/root/tts/gsv/models/v2ProPlus/流萤/`）；备选 `zipvoice_s12`（已在线上代码里，内存小、快 1.7×） |
| **硬约束** | 内存：worker 常驻 **3.3 GB**（机器 3.9 GB + 6 GB swap）⇒ **单 worker、串行、跑批时线上 VITS 会被换出**；磁盘：`/` 只剩 **1.2 GB** ⇒ 必须先回收（§2.5） |

**关键数字（实测，明细见 [`TTS-PREGEN-PLAN.md`](./TTS-PREGEN-PLAN.md) §2/§3）**

| | 音频 | 合成 | RTF | 常驻 |
|---|---|---|---|---|
| 整章 8741 字（《剑来》，6 块 × 1500 字，cut5） | **1802.5 s（30.0 min）** | **9992.4 s（2.78 h）** | **5.57** | 3.29 GB（HWM 3.65） |
| 285 字切片 | 64.8 s | 350.1 s | 5.42 | 同上 |

⇒ **1.14 s 合成 / 字**，一章 3000 字 ≈ **57 min 算力 / 31 MB 磁盘 / 9.8 min 音频**；100 章 ≈ **95 h + 3.1 GB**。

**五个设计要点（一句话）**
1. **整章一个文件**（客户端按章播），缓存键由**服务端算**并把 key 回给客户端存（避免两端各写一套 hash）。
2. **job item = 客户端已有的段落数组**（不是一整块文本）——章节文本的切分口径由客户端决定，服务端只负责把段落用 320 ms 接起来。
3. **队列用文件系统**（`new/run/done` 原子 rename），**worker 是独立进程**：`app.py` 永不加载 torch，worker 崩了不伤线上 VITS。
4. **淘汰保护未播放项**：预生成 20 章却把第 1 章挤掉是最坏的 bug（见 §2.6）。
5. **速度只存 1.0**，变速交给 `AudioRenderer.setSpeed()`；且**不要**套用 VITS 的 `SPEED_SCALE=0.75`（§3.4）。

## 1. 数据契约（先定这个，阶段一/二都依赖）

### 1.1 缓存键（服务端算，客户端只存）

```
canonical = "\n".join(p.strip() for p in paragraphs if p.strip())     # 去空段、逐段 trim
key       = sha256(canonical + "|" + voice + "|1.0|" + engine + "|v1").hexdigest()[:16]
```

- `engine` = `gsv_v2proplus` | `zipvoice_s12`；`v1` 是**后处理口径版本**（24 kHz / −18 dBFS / −1 dBFS / 15+40 ms 淡入淡出 / 320 ms 接缝）——
  改口径就升 `v1`，旧缓存自然失效，不用写迁移。
- **`speed` 固定 `1.0`**：变速在客户端做（§3.4）。
- key 是**不透明字符串**，客户端把它存在章节缓存记录里（阶段二；§3.5 的三处同步清单）。

### 1.2 `POST /job` 的 item（= 客户端能直接产出的东西）

```json
{ "bookId": "5b4fad87", "chapterIndex": 12, "title": "第12章 今日无事",
  "voice": "流萤", "engine": "gsv_v2proplus",
  "paragraphs": ["第一段正文……", "第二段正文……"] }
```

- **为什么要段落数组**：章节文本切分口径必须与客户端一致，否则段↔时间无法对应（进度锚点，§3.4）；
  服务端把段落用 **320 ms 静音**接起来（与线上 `SENTENCE_PAUSE_MS` 同值），段内由引擎自己按标点切（cut5 + `fragment_interval=0.3`）。
- 服务端**不做**段内再切分决策，也不接受整章单块文本（否则失去段落边界）。

### 1.3 落盘布局

```
/root/tts/cache/
  audio/<key>.wav           # 24 kHz mono S16LE（48 KB/s），原子落盘（先写 .part 再 os.replace）
  meta/<key>.json           # 见下
  queue/new/<key>.json      # 待生成（写入即入队；内容 = item + key + attempts）
  queue/run/<key>.json      # 已被 worker claim（rename 原子抢占）
  queue/done/<key>.json     # 完成
  queue/fail/<key>.json     # 失败（含 err）
```

`meta/<key>.json`（**服务端内部 + 将来给客户端读**，字段名要与 App 侧类型一致）：

```json
{ "key": "…", "engine": "gsv_v2proplus", "voice": "流萤", "speed": 1.0, "ver": 1,
  "bookId": "…", "chapterIndex": 12, "title": "…",
  "chars": 3012, "audioMs": 588000, "synthMs": 3429000, "createdAt": 1760300000000, "lastPlayedAt": 0,
  "chunks": [ { "i":0, "t0Ms":0, "t1Ms":301000, "chars":1450, "p0":0, "p1":17 } ] }
```

- `chunks[]` 给**精确的块级时间锚点**（每块一次 `run()` 调用，边界 = 320 ms 接缝，实测可对账）；
  段级锚点现阶段**由客户端按字数在块内插值**（§3.4），不额外付 RTF 代价。
- `lastPlayedAt` 由 `GET /audio/{key}` 更新（淘汰用，§2.6）。

### 1.4 HTTP 接口表（除 `/health` 外都要 `X-API-Key`，与 `POST /tts` 同一把）

| 接口 | 请求 | 响应 | 备注 |
|---|---|---|---|
| `POST /job` | `{"items":[item,…]}` | `{"jobId":"…","items":[{"key","state","title"}]}` | `state ∈ queued/ready/running`；**幂等**：已 ready 直接回 `ready` 不重排。⚠️ **响应顺序 ≠ 提交顺序**（已 ready/queued 的在循环内 append、新条目循环外 append）⇒ 客户端**必须按 `title` 配对，不能按下标**；2026-10-14 真机踩过：按下标 ⇒ 键张冠李戴（缓存章读出别章正文）。2026-10-16 加固：只有标题**两侧都唯一**时才配对（同名/无标题章留空退实时），并用 `/job/status` 的 `bookId`+`chapterIndex`（服务端存的就是提交 meta）**按章号纠偏**（`healPregKeys`） |
| `GET /job/status` | `?jobId=` 或 `?key=` | `{"queued":n,"running":n,"done":n,"failed":n,"items":[…]}` | 客户端轮询用（阶段二每 5 s）。**判「算好了没」只信这里**：提交→开跑实测可能排 ~14 min、单章合成 ~3.7 min（2026-10-16 实测）⇒ 别用 `/audio` 的 404 计时 |
| `GET /audio/<key>` | `Range: bytes=…` | `200/206` WAV；`404` | **必须支持 Range**（`AudioRenderer` 流式 + 拖动进度）；命中即 `utime` + 写 `lastPlayedAt` |
| `DELETE /cache/<key>` | — | `204` | 客户端听完整章后调（阶段二；阶段一手动 curl）。**同路径没有 GET**（取音频走 `/audio/{key}`）⇒ 用 GET 探存在性会回 **405**，别据此判「文件没了」；被删的章 meta 仍在，重提交会重新合成 |
| `GET /cache/stats` | — | `{"files","bytes","maxBytes","freeBytes","protected"}` | 运维/验收用 |
| `POST /cache/probe` | `{paragraphs,voice,engine}` | `{"key","state"}` | **阶段二可选**：客户端没存 key 时（换设备/重装）先探一次 |
| `POST /tts` | 现状不变 | 现状不变 | **不加缓存查找**：章级命中由客户端用 `/audio` 走（少一次全文上传） |
| `GET /health` | — | 现状 + `lastTtsAgeMs`、`cacheBytes`、`queue` | `lastTtsAgeMs` 给 worker 做让位门闸（§2.4） |

## 2. 服务端实现（阶段一，客户端零改动）

### 2.1 进程架构

```
tts.service（线上，已有）  app.py（FastAPI/uvicorn） —— 只做 HTTP：/tts /health /job /audio /cache
                                        │  读写 /root/tts/cache/{audio,meta,queue}
tts-job.service（新，默认 disabled）   job_worker.py —— 独立进程，常驻 torch + GPT-SoVITS
```

- **`app.py` 永不 import torch**（保持 441 MB 常驻与 100% 可用性）；它只做入队、状态、发文件、淘汰。
- **worker 崩溃不影响线上**；重启后从 `queue/` 续跑。
- 队列只靠文件系统（无 redis/sqlite）：`new → run` 用 `os.rename`（同一文件系统内原子）抢占，天然防重复。

### 2.2 合成流程（worker）

1. 取 `queue/new/` 最早的一项 → `os.rename` 到 `queue/run/`（抢占）。若 `run/` 里有 `mtime` 超过 **45 min** 的项（进程被杀），移回 `new/` 并把 `attempts+1`；`attempts ≥ 3` → `fail/`。
2. **分块**：按段落累加到 **≥1500 字**切一块（整段边界，绝不切断段）——实测整章 8741 字 → 6 块；**不分块会在单次 `run()` 里长到 13.5 GB VA 被 OOM 杀掉且中途无任何落盘**（已踩两次，见 PLAN §5.11）。
3. 每块一次 `tts.run({text: "\n".join(块内段落), text_lang:"zh", ref_audio_path: 微调包自带参考, prompt_text: 真值, prompt_lang:"zh",
   text_split_method:"cut5", fragment_interval:0.3, speed_factor:1.0, seed: …})` → 取回音频 → 复刻线上后处理
   （`24k FFT 重采样 / EQ(不启用) / −18 dBFS 归一 / −1 dBFS 限幅 / 15+40 ms fade`）。
4. 块间**插入 320 ms 静音**；逐块 `gc.collect()` + `ctypes.CDLL("libc.so.6").malloc_trim(0)`（实测 RSS 每块回落 ~100 MB，HWM 稳定）。
5. 全部块完成后：拼接 → 写 `<key>.part` → `os.replace` 成 `audio/<key>.wav` → 写 `meta/<key>.json` → item 移到 `queue/done/`。
6. **段偏移**：`meta.chunks[]` 用实测块时长（精确）；块内段落按字数插值（客户端做）。
   *可选实验（30 min，不影响验收）*：`return_fragment=True` 能否在**一次调用**内吐句子级片段 + 时长 —— 若成立则段级锚点免费。
   **不要**为段级锚点改成「逐段调用」：实测每次 `run()` 有 ~12 s 固定开销（285 字 1 次 350 s vs 30 次 718 s），逐段会让 RTF 翻倍到 ~11。
7. `seed` 写进 meta；同一 key 重复生成时用同一 seed 以便对账（首次 `seed=-1` 随机，记下来）。

### 2.3 引擎与内存（`gsv_v2proplus`）

- 环境：`/root/tts/gsv/venv` + `/root/tts/gsv/GPT-SoVITS`（gitcode 镜像）+ `pretrained_models/`（3.9 G）+ `models/v2ProPlus/流萤/`。
  启动脚本 = 现有 `/root/tts/gsv/gsv_batch.py` 里的 `_build()` 复用文件（worker 直接 import 它，**不要复制第二份口径**）。
- 必备 env：`CUDA_VISIBLE_DEVICES=""`、`OMP_NUM_THREADS=3` 且脚本内 `torch.set_num_threads(3)`、`OPEN_JTALK_DICT_DIR=/root/tts/gsv/open_jtalk_dic_utf_8-1.11`、
  `sys.path` 同时含仓库根 + `GPT_SoVITS/`。
- **单 worker、串行**：3.3 GB 常驻 + 线上 VITS 441 MB 已经贴机器上限；**禁止并发两个 worker**（v4 那次就是无 swap 被 OOM）。
  内存下限保护：`/swap2`（4 G）**必须保留**，worker 起来前检查 `SwapTotal ≥ 4 G`，不满足就拒绝启动并在日志里说清。
- 备选引擎 `zipvoice_s12`：走线上 `app.py` 的 `ENGINE=zipvoice` + `NUM_STEPS=12`（峰值 1.0 GB，可与 VITS 共存，~55 h/100 章）。
  实现上**照抄 worker 骨架**、只换 `synth()` 后端；两者写同一份缓存目录与同一份 meta 口径（`engine` 字段区分）。

### 2.4 让出 CPU / 内存（唯一会伤到线上的地方）

- 门闸：worker 每块开始前 `GET http://127.0.0.1:9880/health`，若 `lastTtsAgeMs < 60000` → `sleep 15` 再查（用户正在实时听书 ⇒ 批任务让路）。
  `app.py` 侧只需一个模块级 `_last_tts_at`（`/tts` 入口更新）+ `/health` 暴露 `lastTtsAgeMs`。
- systemd：`Nice=19`、`CPUWeight=20`、`IOSchedulingClass=idle`、`Restart=on-failure`、`RestartSec=30`。
- 预期副作用（实测）：批任务运行时 `Mem available → 100–190 MB`、swap 用掉 4.9 GB、线上 `/health` 仍 ~0.5 s 返回，
  但**第一个 `/tts` 请求要等引擎页换入**（可能 +1–3 s）。⇒ 阶段一验收要把这条测出来（§4.1 第 3 项）。

### 2.5 磁盘预算（**先做这一步**，否则一跑就满）

`/` 现状：`29G 用 28G，剩 1.2G`。回收清单（按收益排序，前 4 项**无风险**）：

| 动作 | 回收 | 风险 |
|---|---|---|
| `rm -rf /root/.cache/pip` | **1.0 G** | 无（装包会重新下） |
| `apt-get clean` | **225 M** | 无 |
| `rm -rf /root/tts/gsv/out /root/tts/gsv/{x3,x6,pp3,pp6,zs3,zs6,zl,zipout,batchab}` | **~240 M** | 无（都是本轮实测产物，试听包已在本机） |
| `/var/log` 清理（`journalctl --vacuum-size=200M`） | 视情况 | 低 |
| 删 base 里 **v2ProPlus 用不到** 的子集：`gsv-v4-pretrained/`(789 M)、`hifigan_do_03357000/`(784 M)、`models--nvidia--bigvgan…`(430 M)、`sv/`(103 M)、`s1bert25hz-2kh-longer…`(148 M)、`gsv-v2final-pretrained/`(149 M) | **~2.4 G** | **中**：删完必须跑一次 v2ProPlus 冒烟（加载 + 285 字合成，日志无 `missing`/`No such file`），失败就退回 ModelScope 重下（VPS 可访问 ModelScope） |
| `/root/tts/gsv/refs`（266 角色 157 M）只留 流萤/花火/卡芙卡 | ~150 M | 低（其余角色暂不用） |

**不要动**：`/swap2`（4 G，v2ProPlus 必需）、`/root/tts/genshin-vits`（线上 VITS）、`/root/tts/zipvoice`（备选引擎）、
`venv`(2.5 G) / `GPT-SoVITS`(653 M) / `models`(536 M) / `pretrained_models` 的**必需子集**。
目标：**回收后 free ≥ 4 G**；配置 `CACHE_MAX_BYTES=2G`、`RESERVE_FREE=1.5G`（低于就拒新 job，§2.6）。

### 2.6 淘汰策略（**别把用户马上要听的那章挤掉**）

- 每次写入前跑一次淘汰；先删 `lastPlayedAt > 0` 中**最旧**的，直到 `bytes + newSize ≤ CACHE_MAX_BYTES` 且 `free ≥ RESERVE_FREE`。
- **未播放的项不参与淘汰**；若全是被保护的未播放项且仍超限 ⇒ `POST /job` 回 `409 {"reason":"cache_full_wait_playback"}`（客户端提示"先听几章"）。
- 客户端听完整章后调 `DELETE /cache/<key>`（阶段二）——**串行追更场景主要靠这个**，LRU 只是兜底。
- `GET /cache/stats` 暴露 `protected`（未播放项数），便于验收与运维判断。

### 2.7 QC 与失败处理

- 逐块检查：`audioMs > 0`、`3.5 ≤ chars/秒 ≤ 6.5`（实测 4.8–5.1）、峰值 `-1 ≥ peak ≥ -25 dBFS`、无整段静音（RMS 不低于 -45 dBFS）。
- 失败 → 该块重试 1 次（重试用同 seed）→ 仍失败 ⇒ 整章进 `queue/fail/`（含 `err`），**不留半章缓存**（章级原子性从生成端就守住）。
- 阶段一不做 ASR 回比；复读检测可后续复用 `/root/tts/genshin-vits/loopdetect.py`。

### 2.8 部署（as-built）

仓库里就是最终版：`server/deploy.sh` 会把 `tts_cache.py` / `pregen_test.py` / `job_worker.py` 拷到位并装两个 unit
（worker 装完会 `disable` 掉）；运维细节见 [`../remote-tts-deploy.md`](../remote-tts-deploy.md) §9。unit 关键项：

```ini
# /etc/systemd/system/tts-job.service（仓库 server/tts-job.service 为唯一实现）
[Service]
WorkingDirectory=/root/tts/gsv
Environment=OMP_NUM_THREADS=3 CUDA_VISIBLE_DEVICES= CACHE_DIR=/root/tts/cache
Environment=CACHE_MAX_BYTES=2G RESERVE_FREE=1.5G
Environment=OPEN_JTALK_DICT_DIR=/root/tts/gsv/GPT_SoVITS/text/G2PWModel
Environment=MALLOC_ARENA_MAX=4
ExecStart=…/job_worker.py --engine gsv_v2proplus --voice 流萤 --api-base http://127.0.0.1:9880 --chunk-chars 1500
Nice=19          # 线上优先
CPUWeight=20
IOSchedulingClass=idle
MemoryMax=3800M  # 故意在实测 HWM 3638 MB 之上：真出事杀 worker 而不是杀线上
Restart=on-failure
RestartSec=30
```

- 默认 **disabled**（`Restart=on-failure` + `systemctl stop` 不会拉回；`kill -9` 会）：`systemctl start tts-job` 才开跑。
- worker 启动自检 `SwapTotal ≥ 4096 MB`（当前 6.1 GB），否则直接拒绝启动 —— 不让内核去挑受害者。
- `app.py` 的改动（小）：`/job`、`/job/status`、`/audio/{key}`、`DELETE /cache/{key}`、`/cache/stats`、`/cache/probe`、`/health` 增字段、`_last_tts_at`。
  这些**不改 `/tts` 行为**（实测见 §4.1.1 #3/#7）：45 次并发探针全成功、`/health` <0.5 s、无 5xx。

### 2.9 实现期与本文档的偏差（as-built，实现时改的，均已入库）

1. **`gsv_batch.py` 加了 `if __name__ == "__main__":`**——它原来导入即跑 `main()`（自己重跑基准），不包住就没法被 worker `import`。
   `python3 gsv_batch.py` 的手工行为不变。
2. **seed 用推导而不是解析库 stdout**：`gsv_batch.synth_native()` 写死 `seed=-1`（调用方无参可传），而 GPT-SoVITS 的
   `TTS.py` 在 `seed==-1` 时用 `random.randint()` 自选种子 ⇒ worker 在每个块前 `random.seed(int(key[:8],16)+i)`，
   并用 `random.Random(同值).randint(0,2**32-1)` **预测**实际种子写进 meta。实测两次都吻合库自报的 `Set seed to …`。
3. **引擎/音色不匹配的条目判失败**（而不是按 item 里的引擎/音色合）：worker 只服务一个 `(engine, voice)`（常驻一份 3.3 GB 权重），
   串音色的错误音频是最坏的失败模式。
4. **`stats()` 先 `ensure_dirs()`**：没跑过任何 job 时 `/cache/stats` 不能 500。
5. **`unknown → expired`**：条目在 45 min 内被彻底删除后，轮询的客户端要能拿到终态。
6. **`run/<key>.json` mtime 心跳**：worker 每块结束 `utime` 一次，所以 stale = **无进展** N 分钟，
   而不是「开跑 N 分钟」——否则一个 1500 字块（~30 min）会被自己的回收器在跑批中途搬走。
7. **超长段安全阀**：`chunk_paragraphs` 保持「绝不切断段」，但**单段 > `--chunk-chars`**（例如整章被当成一行发来）时
   在**句末**切开（拿不到句末标点时才硬切），并在 meta 里标 `chunks[].split` / `splitBlocks` + 打 WARNING。
   不做这个的话一张单行章节会变成一次 8741 字的 `run()` —— 就是 `cut3` 整章 OOM 的那个形状。
8. **预告字节小偏差**：`est_bytes()` 按 4.4 字/秒估，实测 4.90 字/秒 ⇒ 8709 字章预告 81.4 MB、实落 85.3 MB（−5%）；
   只用于容量门闸，不会写进文件。
9. **块数由段边界决定**：逐段 greedy fill 到 ≤`--chunk-chars` ⇒ 每块丢掉半段填充余量，同一章按真实段数组切是 **7 块**、
   按原始行切是 **6 块**。**块数不是契约**，只有「每块 ≤ `--chunk-chars`」是。

## 3. 客户端设计（阶段二，含「填写方式」）

### 3.1 现有设置照旧 + 「两套音色」的取舍

现有 [`ListeningSettings.ets`](../../entry/src/main/ets/pages/ListeningSettings.ets) 的四组设置（朗读引擎 / 默认语速 / 服务器地址 / API Key / 远端音色）
**全部保留不动**（实时链路的地址与 Key 正好也是预生成要用的，用户**只需填一次**）。

⚠️ **踩点**：实时链路是 VITS 的 5 个标签音色（刻晴/甘雨/胡桃/钟离/雷电将军），预生成是 GPT-SoVITS 的 3 个（流萤/花火/卡芙卡）。
两套音色不同 ⇒ **同一本书会在「缓存章」与「未缓存章」之间换声线**（章级原子切换内是干净的，跨章会切换）。
- 默认建议：**实时音色 = 甘雨**（其旧别名正是 `流萤`，用户心智一致），预生成音色 = **流萤**，这样跨章切换至少保持在女声同一区。
- 更彻底的解法（不在本轮）：实时链路也换 GPT-SoVITS —— RTF 5.6 不可能实时；或给 VITS 微调一个"流萤"（另开条目）。

### 3.2 新增设置项表（「填写方式」= 用户在设置页怎么填）

写在 `common/Const.ets`（常量）+ `pages/ListeningSettings.ets`（控件，**D17 起与朗读引擎无关，常显**；服务器地址 / API Key 也归到这组）。存储走 `common/Prefs.ts`。
`chips()` / `TextInput` / `Toggle` 全部复用该页现有写法与 `color.json` 令牌（**不要**引入新配色）。

| 设置项 | Prefs key | 控件 | 默认 | 校验 / 生效 |
|---|---|---|---|---|
| 预生成音色 | `tts_pregen_voice` | chips：`['流萤','花火','卡芙卡']` | `流萤` | 读时用 `normalizePregenVoice()` 收敛到列表内（照抄 `normalizeRemoteVoice()` 的写法） |
| 提前生成章数 | `tts_pregen_ahead` | chips：`[5,10,20,30]` | `10` | 整数；上限只做 UI 约束（真实上限在服务端磁盘，见 §2.6） |
| 仅 Wi-Fi 时生成 | `tts_pregen_wifi_only` | `Toggle` | `true` | 立即生效；`network.on('netAvailable')` 判 `NetBearType.BEARER_WIFI` |
| 缓存优先播放 | `tts_pregen_prefer` | `Toggle` | `true` | 关掉则总是走实时 VITS（排查用） |
| （复用）服务器地址 | `tts_server` | 现有 `TextInput` | `TTS_SERVER_DEFAULT` | 不变 |
| （复用）API Key | `tts_api_key` | 现有 `TextInput` | `TTS_API_KEY_DEFAULT` | 不变 |

**该分组的说明文字要写实数**（用户拍板的就是这个代价）：
> 「预生成由电脑端（VPS）在你听书时后台合成：**每章约 1 小时**算力、单章约 **31 MB** 空间。
> 缓存就绪的章节用 `流萤` 声音，未就绪的章节仍用上面选的实时音色+系统兜底（**同一章内不会换声线**）。」

### 3.3 入口与交互

- **书级入口**：`BookDetail` 或 `Reader` 的长按菜单增加「预生成后续 N 章」（N = `tts_pregen_ahead`）。
  点击 → 取该书目录 → 从当前进度往后 N 章 → **逐章**取正文（走现有内容缓存，不额外打网络）→ `POST /job` **一次提交多章**（服务端串行排队）。
- **进度**：提交后弹一个只读进度条（`@Local` 状态，5 s 轮询 `GET /job/status?jobId=`），显示 `done/total` + 当前章标题；可「停止」（阶段一只停客户端轮询，服务端队列继续）。
- **失败可见**：`failed > 0` 时列失败章（`title` + `err` 摘要）并给「重试」；**不静默**。
- **自动续播预生成（可选，阶段二后置）**：播放到第 K 章时，若剩余缓存 < `ahead` 则自动补交 job（Wi-Fi + `prefer` 打开时）。
- 段落上传口径：用**内容缓存里已有的段落数组**（`ChapterCache` 的段落结构），不要重新切分——保证与服务端 meta 的 `p0/p1` 对得上。

### 3.4 播放路径改造（章级原子切换 + 变速 + 进度锚点）

在 `model/TtsController.ets` 的 `ensureRemoteSynthesized()` **之前**插一层（沿用现有 `ensureEngine / fallbackToSystem` 的兜底结构）：

1. 取本章 `pregKey`（存在章节缓存记录里，§3.5）→ `GET /audio/<key>`（带 `Range`）。
2. **200/206** → 「缓存章模式」：`AudioRenderer` 直接喂 WAV（`samplingRate=24000`，与 `SAMPLE_RATE_REMOTE` 一致），
   **`setSpeed(playbackRate)`**，不分段、不再发 `/tts`。
   - `playbackRate = clamp(pref × TTS_PREGEN_SPEED_SCALE, 0.5, 2.0)`，**新增常量 `TTS_PREGEN_SPEED_SCALE = 1.0`**。
   - **不要**套 `SPEED_SCALE=0.75`（那是为 VITS 的 0.85 语速标定的）：GPT-SoVITS speed=1.0 实测 **4.85 字/秒**，
     正好等于现在"0.75 档"的听感（VITS 5.2 字/秒 × 0.75）。这个 1.0 是**听感标定项**，真机验收时可能微调成 0.95/1.05。
3. **404** → 走**现状逻辑**（逐段 `POST /tts` 实时 VITS；失败 → 系统 TTS）。**整章**都走同一条路径（章级原子切换）。
4. **进度锚点**：用 `meta.chunks[].t0Ms/t1Ms` 拿到当前块，再用 `chars` 在块内**按字数插值**成 `paragraphIndex`。
   误差 ≤ 块内 ~±20%（块只有 5 min 音频，最坏 ±1 min）；**够用**，且不额外付 RTF 代价（§2.2 第 6 条）。
   读完一章后：`DELETE /cache/<key>`（腾磁盘）+ 清 `pregKey`。
5. 章节缓存失效（书源更新正文）时 `pregKey` 一并作废（沿用 `ChapterCache` 现有的 hash 失效机制）。

### 3.5 字段与 obfuscation 三处同步清单（**漏一个就是 release 读到 undefined**）

新增/改动字段必须**同时**改：Rust struct（若走 NAPI）/ `engine/types.ets` / `entry/obfuscation-rules.txt`，`make check` 会核对。

| 字段 | 出现位置 | 是否要进 keep 列表 |
|---|---|---|
| `pregKey` | `ChapterCache`（落盘章节缓存 JSON） | **要** |
| `key` `state` `jobId` `items` `queued` `running` `done` `failed` `err` | `RemoteTtsClient` ↔ 服务端 JSON | **要**（`text`/`voice`/`speed` 已在列表里） |
| `chars` `audioMs` `synthMs` `chunks` `t0Ms` `t1Ms` `p0` `p1` `lastPlayedAt` `createdAt` | 仅阶段二若落盘/缓存 meta；若只内存解析可不进 | 落盘则**要** |
| `maxBytes` `freeBytes` `bytes` `files` `protected` `reason` | 接口响应（内存解析） | 建议一并加，成本为零 |

**实际做法（2026-10-13）**：`TtsPregen.ets` 里所有 `interface` 字段**一律进 keep**（包括纯客户端字段）——`check-keep-props.sh` 是机械判定，
「哪些字段真的跨 JSON」靠人判一定会判错；实际新增 **27** 个名字（`pregKey` / `jobId` / `key` / `p0` `p1` / `t0Ms` `t1Ms` / `chunks` / `state`…），
现共 **172** 个 keep 名，`make check` 绿。

### 3.6 实现偏差（as-built，2026-10-13）

| # | 计划（§） | 实际实现与理由 |
|---|---|---|
| 1 | `GET /audio/<key>` 带 `Range` **边下边播**（§3.4-1） | **整章先落盘再播**：`TtsPregen.loadPregAudio` 下到 `filesDir/preg/<key>.wav.part` → `rename`（同卷原子）→ `PregAudioSource` 只读文件。理由：① 拖动进度只能靠 `seek`；② 进度锚点用 `AudioRenderer` 的 `framePos` 增量（真实出声时间）比「下了多少字节」准；③ 预取下一章复用同一份文件，重听不再打网络。代价：**进章要等下完**（局域网 1–3 s，移动网 10–60 s）——期间日志/文案是「正在下载预生成音频」，失败或 `no-ctx`/`no-renderer` 才退实时 |
| 2 | 块内按 `chars` 插值求段落（§3.4-4） | 服务端 meta 的 **`chunks[].p0/p1` 给了块级段落下标**（合成时就知道这块吃了哪些段）→ 客户端只在块内按段长插值（`pregTimeline`）：高亮误差从「块内 ±20%（≈±1 min）」降到「段内 ±1 段」；段落数与音频不同源时只在日志里报 `preg timeline covers=x/y`，不错乱 |
| 3 | 入口在 `BookDetail` / `Reader` 长按菜单（§3.3） | 实现在**听书页**（`pages/Listening.ets` 预生成行）：「后续 N 章」只有在听的书上有意义，且与播放器同页；长按菜单留给 v2 |
| 4 | 设置页新增「预生成」分组（§3.2） | `pages/ListeningSettings.ets`，**仅远端引擎下可见**（系统引擎没有服务端，显示了只会误导）：音色 chip 3 档 / 提前章数 `5·10·20·30` / 仅 Wi-Fi / **缓存优先播放** |
| 5 | 「仅 Wi-Fi 时生成」（§3.2） | 语义收窄为**只拦后台行为**：拦预取下一章（`prefetchNextPreg`）与预提交（`TtsPregenRunner.startPregen`），**不拦进章时下载**——那是用户当下要听的 |
| 6 | 章级原子切换的判据（§3.4-3） | `chapterAudioRoute(preferCache, pregKey)` **两条件**全中才走缓存（D17 起不再看引擎）；**第一条 PCM 进渲染器那一刻锁死路线**（`pregPlaying`），此后到章尾不再换；只有**出声前**的失败（404 / 下载失败 / 打不开）才退实时（`preg fallback=realtime why=`）。**`notfound` 不再作废缓存键**（`preg key kept key=… why=notfound`）：键是**内容寻址**的，留着它「算好了 / 重新提交」就能命中，作废反而会把刚付了算力的缓存**永久丢掉**（真机 2026-10-14 实测：提交后立刻进章 = job 还没算完 = 404，旧逻辑把刚提交的两个键全抹了）；job 还在 `queued`/`running` 时**不跳过、照旧试一次**：同一个 job 里可能已经有章算好了（重新提交 / 别处提交过），跳过反而白走一遭 16 kHz 实时（还多一次采样率重建）；没算好的那几章多付一次 404 很便宜。「已提交没算完」的登记用 `markPregKeyPending` / `isPregKeyPending`（`model/TtsPregen.ets` 进程内 `Set`），由 `TtsPregenRunner` 在 job 到终态（无 queued/running）时撤销，**只喂日志**（`preg key kept … pending=1/0` 区分两种 `notfound`），不改变行为 |
| 7 | **D17：实时不再走 VPS**（2026-10-13） | 实时朗读恒为系统 TTS（16 kHz）；缓存章 24 kHz。采样率由 `renderRate` 记录、`ensureRenderRate(rate)` 在**进章时**比对并重建渲染器（`beginFrom` / `abandonCachePath` 改异步等它就位，用 `seq` 守卫防换章竞态）；`sampleRate` getter 改成「按路线」而不是「按引擎」。存量 `KEY_TTS_ENGINE=2` 在 `loadPrefs` 迁回 0；REMOTE 分支代码保留但不可达 |
| 7 | 读完一章 `DELETE /cache/<key>` + 清 `pregKey`（§3.4-4） | 再加**本地文件一起删**（键都没了，留着只能占盘）；`onPregEnded` 一气做完三件事。**代价（接受）**：重听刚听完的章要重新生成或退回实时——磁盘只剩 ~2 G 换来的取舍 |
| 8 | `TTS_PREGEN_SPEED_SCALE = 1.0`（§3.4-2） | 按计划；`pregPlaybackRate` = `clamp(pref × 1.0, 0.5, 2.0)` 交给 `renderer.setSpeed()`，**不**套 VITS 的 `0.75` |
| 9 | 「自动续播预生成（后置）」 | 先做了一半：**下一章预取**（开播後台落地音频，`prefPregenPrefer` + 仅 Wi-Fi 双门）；「剩余不足自动补交 job」仍未做 |
| 10 | 缓存键存在章节条目里（§3.4-3） | **本地书的键存不进条目**：本地书正文不进 `ChapterCache`（直接读导入文件），而 `setChapterPregKey` 要求条目已在缓存里 ⇒ 键被静默丢弃、进章永远退实时（首轮真机「拿不到缓存章」的真因）。修法 = **sidecar** `filesDir/pregkeys/<bookId>_<index>.json`（`{url, pregKey}`，`url` 对不上即视为无 → 换源/目录重排自动失效）。权威顺序：**正文条目在 ⇒ 只信条目**（不吃旁路，免得正文换了键还活者）；没有条目（本地书）⇒ 才读旁路；正文条目回来时顺手删残留 sidecar。`clearChapterPregKey` / `deleteBookChapters`（现扫 `chapters` + `pregkeys` 两目录）同步清理。`setChapterPregKey` 改**返回 `boolean`**，提交计数按它算（不再数「尝试次数」——首轮日志的 `stored=2` 是「尝试了 2 次」，易误读成「已落盘 2 章」） |

## 4. 验证

### 4.1 阶段一（主机侧 curl + 线上回归，**不上设备**）

| # | 场景 | 判据（实测口径） |
|---|---|---|
| 1 | 小样本端到端：285 字切片 `POST /job` → 轮询 → `GET /audio/<key>` | `state=ready`；WAV = 24 kHz mono；时长 64.8 s ±5%；峰值 ≤ −1 dBFS；**0% 削顶** |
| 2 | 幂等 | 同一 item 再 `POST /job` → 立刻 `state=ready`，`queue/` 不新增文件，`createdAt` 不变 |
| 3 | **让位** | 生成中并发 `POST /tts`（285 字）→ worker 在 60 s 内不再 claim 新块（看 `journalctl -u tts-job` 时间戳）；`/tts` 耗时 ≤ 现基线 + 3 s |
| 4 | 整章 | 8741 字真实章节 → `audio ≈ 1802 s`、`synth ≈ 2.8 h`、`RTF ≈ 5.6`；`meta.chunks` 6 块且 `t1Ms` 与音频总长对得上（±2%） |
| 5 | 磁盘/淘汰 | `CACHE_MAX_BYTES=40M` 跑两章 → 第 1 章被淘汰，`/cache/stats` 与 `ls audio/` 对账；`protected` 计数正确（**未播放项不被淘汰**） |
| 6 | Range / 恢复 | `curl -r 1000000-1000099` → `206` + 100 B；`kill -9` worker 中途 → 45 min 后（或缩短阈值）该项回到 `new/` 并最终完成 |
| 7 | 线上回归 | `tts.service` 未重启的前提下，真机听书 1 章（`§harmony-device-run`）+ `GET /health` 仍 0.5 s 内；`journalctl -u tts` 无 5xx |

> 所有生成类验收都写明**墙钟预期**（RTF 5.6 ⇒ 1 h/章），不要用「等它跑完」当验收条件；`#1`/`#5`/`#6` 用 285 字样本即可。

### 4.1.1 实测结果（2026-10-13，VPS `103.236.96.53`，worker `tts-job`）

7 项 **全部执行并留证**（日志：`journalctl -u tts-job`、`/root/tts/r1_s*.log`、`/root/tts/yield_probe*.log`）。

| # | 结论 | 实测证据 |
|---|---|---|
| 1 | **PASS** | 285 字（`/tmp/ab_text.txt`）→ `key=cb120d78078d6e34`，1 块，seed `127634260`（与库自报 `Set seed to 127634260` 一致）；`synth=320.7 s`、`RTF=5.03`；WAV `[24000,1,2]`、`sec=63.76`（在 64.8 ±5%）、`peak=-2.0 dBFS`、`rms=-18.0`、`clip=0.0%`、`3060524 B`；`meta.audioMs` 与实测时长差 **0.00%** |
| 2 | **PASS** | 同一 item 再 `POST /job` → `200 ready`，同 key，`createdAt=1791851306388` 不变，`queue {new:0,run:0}` 不新增 |
| 3 | **PASS** | worker 生成期间并发 `POST /tts`：共 45 次探针全部成功（1.2–13.8 s，基线 +0，无 5xx）；**门闸共打 25 次让位**，其中连续一段 **09:14:04 → 09:20:05（6 min）不 claim 任何新块**，最后两次 `lastTtsAgeMs=34518ms` / `49531ms` 仍在窗口内继续睡，直到 60 s 窗口过期才在 **09:20:20** 开工（`block 1/1 attempt=1 chars=299`）；反向也正确：探针已停 85 s 时**正常放行**（不打假让位）。让位不会丢任务：被压 6 min 的那项（`1f0f…`）最终 `done` + `VERDICT OK` |
| 4 | **PASS（块数 7，见偏差 9）** | 8709 字 / 41 段 → **7 块**（1346/1456/1466/1329/1371/1392/343，均 ≤1500）；`audio=1777.5 s`、`synth=12025.4 s（3.34 h）`、`RTF=6.76`；`sum(chunks[].t1Ms)==audioMs`；钉的 `audioMs` 与实测文件差 **0.00%**；`peak=-1.51 dBFS`、`clip=0.0%`、`chars/sec of audio=4.90`；`VmHWM=3638 MB`；**VERDICT OK** |
| 5 | **PASS** | `CACHE_MAX_BYTES=4M`：第 2 章完成时 `evicted 1 played item(s) freeing 2.9MB: ['cb12…']`（正是已播放的那份），新写的**未播放**项存活；`GET /audio/cb12…` → `404`；`stats files=1 bytes=3170924 protected=1`；新 item 再来 → `409 {"reason":"cache_full_wait_playback","neededBytes":2989800,"protected":1}`；同一请求打到生产 2G 实例 → `200 queued`（无假 409） |
| 6 | **PASS** | `Range: bytes=0-63` → `206` + `content-range: bytes 0-63/3060524`；`bytes=1000-2000` → `206` len 1001；`kill -9` 中途 → 重启后 `reaped stale key=6941163fb8120842 age=14424s attempts=1 -> new/` → 重跑 `done`；`SIGTERM` → `finishing the current block, then releasing the item` + `interrupted after 1/1 blocks; releasing to new/`（`audio/` 无半成品） |
| 7 | **PASS（主机侧）** | `tts.service` 未重启（`systemctl restart tts` 只发生过一次，在验收前）；`/health` 全程 <0.5 s；`journalctl -u tts` 无 5xx；验收 #3 的 45 次主机探针（与真机同一条 `POST /tts` 路线）全成功。**真机听书那一半未做**（阶段一是服务端，App 未接入预生成；该回归归入 §4.2 阶段二） |

**与判据的偏差（都要当作「契约不是块数」的证据）**

- #4 期望「6 块」，实测 **7 块**：块数只由 `--chunk-chars` 上限与**段边界**决定（§2.2 绝不切断段），而基准里的 6 块是
  `gsv_batch._chunk_text` 按**原始行**切的。同一章节的正文按 ~250 字/段（真实客户端的段数组形状）切 → 每块丢掉半段的填充余量 → 7 块。
  音频总量与基准一致（1777.5 s vs 1802.5 s，−1.4%，差在切缝数/切点）。
- #3 的真机 `POST /tts` 耗时基线是 3–4 s（命中已加载的 VITS），并发探针**没有变慢**；但 worker 自己的块会被拖慢
  （302 字块从 ~7 min 拉到 ~10 min，`RTF 5.03 → 10.04`）——这是设计取舍：**线上优先**。
- #4 的 `RTF` 实测 6.76（判据 5.6）：本章 7 块的 `RTF` 在 6.7–9.5 之间波动（块间差 >40%），与基准
  5.54 的差主要是机器噪声/swap 压力，不是口径变化——同一 `synth_native()`、同一 seed 推导、同一 `cut5`+`fragment_interval=0.3`。
  工程结论请用 **3.3 h / 8709 字**，不要用 2.8 h。

### 4.2 阶段二（真机）

按 skill `harmony-device-run` 的闭环：`make run` → `uitest dumpLayout` 确认设置项渲染 → 点「预生成 10 章」→ 看 `job/status` 轮询进度 →
**断网/未就绪章**走系统 TTS 且**不半章换声线**（抓 `hilog` 的 `TtsController` 分支日志）→ 缓存章播放 + 拖动进度 + 章节进度锚点（对比段落高亮）→ 听完一章后 `audio/` 文件被删。

**已完成（2026-10-13，静态）**：代码全部落地；`make hap` 成功（ArkTS 严格模式，含新增 `Progress` 组件与 chip/`Toggle` 行）；
`scripts/check-keep-props.sh` ✓ 172 keep 名覆盖全部 JSON 字段；**`make test-pregen`（`scripts/tts-pregen-sim.py`）87/87 通过**
（第二十七次同步时是 88 条；D17 把路由真值表由 5 条收到 2 参 4 条，并新增一条 Python 侧回归门：`chapterAudioRoute` 源码里出现 `engine`/`TTS_ENGINE` 即 fail）——
从真源码机械切片（`Const.ets` + `TtsPregen.ets` 去 `import` 全文）编到 JS 跑断言，覆盖本文 §3.4 的路由/时间轴/倍速/文案。
**真机进度（首轮 2026-10-13 夜 · `33Z0224424136564` · debug · `make run` 闭环）**：① 设置页渲染 ✓、② 系统 TTS 实时 16 kHz 播放 ✓（`tts engine migrated remote->system (D17)` → `renderer ready rate=16000` → `begin para=0 route=realtime`；跨章自然续播恒 `route=realtime`、同路线不重建渲染器）；
③ 提交被「仅 Wi-Fi 时预生成」拦下（`wlan0` 已有 192.168.10.110 ⇒ 默认网络疑似仍为蜂窝，**待 `ip route` 取证**）；④～⑥ 未跑——当时以为是「拿不到 key 对得上的缓存章」，真因见次轮。

**真机进度（次轮 2026-10-14 · 自造短章 TXT 本地书《短章测试》4 章 120/272/391/150 字，bookId `c9af6cb1`）**：
**先修一个真 bug**（§3.6-10）：本地书的正文不进 `ChapterCache`，`setChapterPregKey` 于是把键静默丢掉 ⇒ 每章都退实时；改成 sidecar 落盘，并把提交计数从「尝试次数」改成「真落盘数」。

| # | 结果 | 真机证据（`make log`，按 bundle 名筛；设备时间戳） |
|---|---|---|
| 1 | ✓ | 预生成 4 行常显；D17 后无「朗读引擎」chip（02:0x 截图式 dump） |
| 2 | ✓ | `18:09:04 preg submit jobId=6acf54abc6c6f1 items=2 stored=2 evicted=0` → `preg job done total=2 done=2 failed=0 expired=0`；服务端 `queue/run` 出现**与首轮完全相同的 key**（`ec27bbff1308dcb4` / `e059f05aa885e9c4` ⇒ 内容寻址 ✓） |
| 3 | ✓ | `preg chapter end key=ec27bbff1308dcb4` → `begin para=0 route=cache` → `preg play para=0 base=0 rate=1.00`（修完 `%f` 后；修复前实测是 `rate=}f`）→ `preg playing key=e059f05aa885e9c4` → `play para=1..6`（每 ~5.6 s）⇒ 缓存章 24 kHz 真的在放 |
| 4 | 未跑 | 拖动 / 变速 / 段落高亮跟随（`rate=` 的可读性已由本次修好） |
| 5 | ✓ | 音频未算完时进章：`render rate 16000 -> 24000` → `renderer ready rate=24000` → `begin para=0 route=cache` → `preg audio failed kind=notfound msg=服务器上找不到这一章（可能已被清理）` → `preg fallback=realtime why=notfound para=0` → `render rate 24000 -> 16000` → `renderer ready rate=16000` ⇒ **退实时前把渲染器换回 16 kHz，同一章内只有一种声线/一种采样率** |
| 6 | ✓ | `preg chapter end key=ec27bbff1308dcb4` → `preg cache delete key=… code=204`；第二章听完同理（`e059f05a…`）；设备 `filesDir/pregkeys/` 清空（`total 0`）、`cache/pregen/` 空 ⇒ 两章都真的删干净；第三章末 → 第四章**自动接着播**（无人干预） |

**顺带修掉的日志缺陷**：`preg play … rate=%{public}f` 在真机上打成 `rate=}f`（**hilog 不支持 `%f`**，不报错、值直接丢）⇒ 改 `pregPlaybackRate(this.speed).toFixed(2)` + `%{public}s`，并新增 `scripts/check-hilog-format.sh` 接进 `make check` 防复发（已记入 `docs/PITFALLS.md`）。
**第三个真 bug（同轮发现，代码已改、真机待验）**：提交后立刻进章时 `GET /audio/<key>` 必然是 404（worker 还没算完），旧逻辑把这种 `notfound` 当成「音频已失效」**把键抹了** ⇒ 刚付了算力的缓存永久丢掉。现改为：`notfound` **一律保留键**（内容寻址 ⇒ 算好了或重新提交还是同一条 key；**不跳过下载**，同 job 里已算好的章照样命中）；登记面 `markPregKeyPending` / `isPregKeyPending`（`TtsPregenRunner` 在 job 终态撤销）**只用来区分日志**（`preg key kept … pending=1/0`），仿真 +4 条断言 = **91/91**。**真机验证待设备重连**（要看的日志：提交后马上进章 → `preg key kept … pending=1` → 实时；算完再进章 → `route=cache` + `preg playing`）。
**仍未跑**：拖动/变速的逐项拍照、锁屏媒体卡、`expired`（服务端清理）分支的真机形态、Wi-Fi 门禁取证（本轮未触发）。

| # | 场景 | 判据（真机上要看的东西） |
|---|---|---|
| 1 | 设置页渲染 | 预生成 4 行（音色 chip / 提前章数 chip / 仅 Wi-Fi / 缓存优先）**常显**（D17 起与引擎无关，无「朗读引擎」chip）；服务器地址 / API Key 同组 |
| 2 | 提交与轮询 | 听书页点「开始」→ `hilog` 见 `preg submit jobId=… items=N stored=N`；进度行 `done/total` 与当前章标题每 5 s 动；点「停止查看」只停客户端轮询（服务端继续）；只有 `expired` 时「重试失败」必须真的能重提（仿真覆盖了清单，真机只看按钮行为） |
| 3 | 缓存章播放 | 进已就绪的章：`preg play para=0 base=0 rate=1.00` → `preg playing key=…`（**必须是同一条 key**）；听感与 `curl` 下的成品一致 |
| 4 | 拖动 / 变速 | 拖进度条：`preg play para=K base=<ms>`，段落高亮跟着跳、不错位；改语速后**不重下**、`rate=` 改变、`elapsedMs/总长` 按源时间走 |
| 5 | 退实时不换声线 | 未就绪章（键无效 / 服务端被删）：`preg fallback=realtime why=notfound` 或直接走实时；退实时前渲染器要从 24 kHz 换回 16 kHz（`renderRate` 重建）；**同一章内不得出现两种声线，也不得两种采样率**（日志里没有先 `preg playing` 再走系统 TTS） |
| 6 | 听完即删 | 章末：`preg chapter end key=…` → 服务端 `GET /audio/<key>` 变 404、`/cache/stats files` 减 1、设备 `filesDir/preg/` 为空；下一章自动接着播 |

## 5. 风险 / 未决

1. **内存是最脆的一环**：3.3 GB worker + 441 MB VITS 在 3.9 GB 机器上靠 6 GB swap 撑。若哪天 OOM 杀掉的是**线上 VITS**（而不是 worker），听书会中断。
   缓解：`tts-job.service` 加 `MemoryMax=3400M`（让它先死），并把「批任务只在夜间/充电时段跑」做成默认（阶段二）。
2. **跨章换声线**（§3.1）——接受，但要在设置页写清楚；默认配置选同区女声。
3. **段级进度锚点是插值**（§2.2/§3.4）——若真机上体验不可接受，再评估 `return_fragment=True` 或「逐段调用 + RTF ×2」。
4. **磁盘**：即使回收后也只够 ~60 章（2 GB）；**"预生成 100 章"在当前 VPS 上装不下**，必须靠「听完即删」+ 窗口。
5. **`cut5` + `fragment_interval=0.3` 是听感最优（用户 2026-10-12 判定）**，不要自作主张换成 `cut3`（实测更慢 9.48）或 `fragment_interval=0`（只减静音不减算力，听感未被用户接受）。
6. v2ProPlus 的参考音频（微调包自带 3.38 s）**很短**，长文批量时若出现不稳定/漂移，备选 = 用 `refs/流萤/ref00.wav` 零样本。
7. **法律/礼貌性**：阶段一是用户手动喂已抓取的正文，不新增爬取；选项 B（服务端自爬）仍需单独评估。

## 6. 附录：阶段一（服务端）的启动 prompt（**已完成，留作历史**）

> 复制下面整段作为新 session 的第一条消息（**新 session 请用 `/new`**，别续旧会话）。
> 阶段二（客户端接入）的 prompt 见 **§7**。

```
【任务】实现 TTS 预生成阶段一（服务端缓存 + job worker），客户端一行不改。

先读（按顺序，别通读全仓）：
1. AGENTS.md（约定：文档落位 / make 入口 / 一轮多工具 / 上下文卫生）
2. docs/research/TTS-PREGEN-IMPL.md（★ 本次的唯一施工图，§1 契约 / §2 服务端 / §2.5 磁盘 / §4.1 验收）
3. docs/research/TTS-PREGEN-PLAN.md §2.2/§5（实测数字与坑，短路用）
4. docs/bugfix/TASKS.md 的 T-TTS-7 条目；docs/remote-tts-deploy.md（线上部署现状）
5. server/app.py（只读你需要的段：路由 + _lock + 后处理函数）与 VPS /root/tts/gsv/gsv_batch.py（口径单一来源，worker 直接 import）

已定决策（不要再问、不要改）：
- 默认引擎 gsv_v2proplus + voice=流萤（微调权重 /root/tts/gsv/models/v2ProPlus/流萤/）
- 缓存 WAV 直出（24 kHz mono S16LE），键 = sha256(段落逐段 trim 后拼接 | voice | 1.0 | engine | v1)[:16]，speed 只存 1.0
- 队列用文件系统（/root/tts/cache/queue/{new,run,done,fail}，原子 rename 抢占）；worker 独立进程，app.py 不 import torch
- 素材：先手动喂（curl / 小脚本），**不做**客户端 UI、**不做**服务端自爬
- 淘汰：已播放优先删，未播放受保护；CACHE_MAX_BYTES=2G、RESERVE_FREE=1.5G
- 语速：缓存音频 speed=1.0，变速交客户端；禁止把 VITS 的 SPEED_SCALE=0.75 套到缓存路径

第一步（先做、别跳）：
a) 按 IMPL §2.5 回收磁盘（pip/apt/gsv out/测试目录，无风险项 ~1.5 G），把 df/du 前后数字记下来
b) 实现 app.py 的 /job /job/status /audio/{key} /cache/stats /health.lastTtsAgeMs（不改 /tts 行为）
c) 写 job_worker.py（分块 1500 字、每块一次 run()、320 ms 接缝、原子落盘、让位门闸、QC）
d) 部署 tts-job.service（disabled）→ 用 285 字样本跑 IMPL §4.1 的 1/2/5/6 项
e) 整章 8741 字跑一次，对账 audio/synth/RTF 与 meta.chunks
f) 真机听书一章做线上回归（skill harmony-device-run）

VPS：ssh -n -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=10 -p 40860 -o BatchMode=yes root@103.236.93.55
（4C / 3.9 G RAM + 6 G swap / 磁盘紧；线上 tts.service 端口 9880，对外 39680，X_API_KEY 在 /etc/systemd/system/tts.service）
注意：ssh 易挂——后台任务要 setsid nohup 且完整重定向（< /dev/null > /dev/null 2>&1），轮询用短命令；
VPS 只装了 grep（无 rg）；日志用 grep -a 过滤，别 tail（有上万字符的 missing_keys）。
实测参考：整章 8741 字 = 6 块 / 音频 1802.5 s / 合成 9992.4 s / RTF 5.57 / 常驻 3.29 GB（HWM 3.65）。

收尾：文档同步（TTS-PREGEN-IMPL 状态、remote-tts-deploy 增节点、TASKS T-TTS-7 进度、progress.md）→
make docs-toc && make check → 提交（docs/代码分开两个 commit，风格照 git log）。
遇到与 IMPL 冲突的现实（比如某个 API 名字/字段不同），改 IMPL 并说明，别默默偏离。
```

## 7. 附录：阶段二（客户端接入）的启动 prompt

> 复制下面整段作为新 session 的第一条消息（**新 session 请用 `/new`**）。

```
【任务】实现 TTS 预生成「阶段二」：App 侧接入章级缓存播放（**阶段一服务端已上线并 7/7 验收，别重复做**）。

先读（按顺序，别通读全仓）：
1. AGENTS.md（文档落位 / make 入口 / 一轮多工具 / 上下文卫生）
2. docs/research/TTS-PREGEN-IMPL.md —— **§3 客户端设计（★ 本次施工图）**、§1 数据契约、§4.2 阶段二验收、§5 风险
3. docs/remote-tts-deploy.md §9（服务端现状与运维命令：起 worker、看 stats、验收客户端）
4. docs/bugfix/TASKS.md 的 T-TTS-7 条目（阶段一证据 + 阶段二待办）
5. 代码（大文件先看顶部成员索引再 grep 取段）：model/TtsController.ets、model/RemoteTtsClient.ets、
   model/ChapterCache.ets、model/BookContent.ets（段落数组的唯一来源）、pages/ListeningSettings.ets、
   common/Const.ets、common/Prefs.ets

已定决策（**不要重新论证**）：
- 章级原子切换：缓存命中 → 整章只走缓存（不再发 /tts）；未命中 → 走现状实时 VITS；失败 → 系统 TTS。**同一章内绝不换声线。**
- 预生成音色固定 '流萤'；POST /job 的 voice/engine 必须与 worker 配置一致（worker 只加载这一个，不匹配会被判失败）。
  **key 用服务端返回的，不要自己拼**（拼错就是另一种缓存键 = 重新合成）。
- 变速：缓存路径用新增常量 TTS_PREGEN_SPEED_SCALE = 1.0（GPT-SoVITS speed=1.0 实测 4.9 字/秒 ≈ 现在 0.75 档听感）；
  **不要把 SPEED_SCALE=0.75 套到缓存路径**（那是给 VITS 0.85 语速标定的）。
- 进度锚点：用 meta.chunks[].t0Ms/t1Ms 定位当前块，再按 chars 在块内按字数插值成段落号（块内 ±20% 可接受，不要为此改逐段合成）。
- 听完一章 → DELETE /cache/<key>（服务端把 GET /audio 记为「已播放」，只有已播放项才会被淘汰；未播放项受保护）。
- 服务端是**单 worker 单音色**、常驻 3.3 GB / 3.9 GB 机器：提交要克制（一次几章到几十章），不要并发轰炸。
- 服务端 409 {"reason":"cache_full_wait_playback"} = 缓存满且剩余项都没播放 → UI 要给出「听完已缓存章节再继续」而不是报错失败。

第 0 步（**先定这个，别直接写播放代码**）：整章音频怎么喂给 AudioRenderer。
一章 WAV 是 25–90 MB，**不能整块读进 ArkTS 堆**（也不要用整块 ArrayBuffer）。
建议：先 GET /audio/<key> 流式落到应用 cacheDir 临时文件，播放时按 ~几秒的 PCM 滑窗读盘喂渲染器，
用完（换章/停止/听完）删临时文件；写完把选定方案与「为什么不用 AVPlayer 或整块内存」补进 IMPL §3.4。

第一步：
a) ChapterCache 增加 pregKey（**落盘字段 → 必须进 obfuscation keep 列表**，§3.5 三处同步，make check 会核对）
b) ListeningSettings 加「预生成」分组 4 项（§3.2 的表：音色 / 提前章数 / 仅 Wi-Fi / 缓存优先；说明文案写实数
   「每章约 1 小时算力、约 31 MB」+「未就绪章仍用实时音色，同章内不换声线」；只读令牌，别引入新配色）
c) 书级入口「预生成后续 N 章」：逐章取**已有内容缓存里的段落数组**（不要重新切分，否则和 meta 的 p0/p1 对不上）
   → 一次 POST /job 多章 → 5 s 轮询 GET /job/status?jobId= 的只读进度条 + 失败可见（title + err + 重试）
d) TtsController 在 ensureRemoteSynthesized() 之前插缓存层（§3.4 四条分支）+ 变速 + 进度锚点 + 听完 DELETE
e) **主机侧先跑仿真**（照 scripts/shelf-updater-sim.py 的路子：tsc + node + 打桩远端音频，
   断言四条分支、章节锚点插值、404/409/失败兜底），再上真机

真机验收（§4.2，走 skill harmony-device-run；设备当前未连接 → 先 hdc list targets -v，USB Offline 时 hdc kill -r）：
make run → uitest dumpLayout 确认设置项渲染 → 点「预生成 N 章」看 job/status 轮询 →
未就绪章走实时 VITS、就绪章整章缓存播放（抓 hilog 的 TtsController 分支日志，确认**同章内不换声线**）→
拖动进度（Range）→ 段落高亮与音频位置对得上（±1 段内）→ 变速 → 听完一章后 VPS 上 cache/audio/<key> 消失。

服务端：systemctl start tts-job（**默认 disabled**，跑完 systemctl stop；重启用前先 systemctl reset-failed）。
验收客户端：python3 /root/tts/server/pregen_test.py stats|item|verify|delete（stdout 是给人看的，别改契约字段）。

VPS：ssh -n -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=10 -p 40860 -o BatchMode=yes root@103.236.93.55
（4C / 3.9 G RAM + 6 G swap；线上 tts.service 端口 9880 / 对外 39680，缓存 /root/tts/cache/）
注意：ssh 易挂 —— 后台任务要 setsid nohup 且完整重定向，轮询用短命令；VPS 只装了 grep（无 rg），日志用 grep -a（有上万字符的单行）。

实测参考（**不要重新测基线**）：3000 字 ≈ 57 min 算力 / 9.8 min 音频 / 31 MB；8709 字 = 7 块 / 音频 1777.5 s / 合成 3.34 h / RTF 6.76；
**块数由段边界决定、不是契约**（同章切 6 块或 7 块都正常，只保证 ≤1500 字/块）；并发听书时 worker 的块会被拖慢（线上优先，这是设计取舍）。

收尾：文档同步（IMPL §3.4 定案 + 状态、TASKS T-TTS-7 阶段二进度、progress.md、PITFALLS 新坑）→
make docs-toc && make check → 提交（代码/文档分开两个 commit，风格照 git log）。
遇到与 IMPL 冲突的现实（API 字段 / AudioRenderer 能力），改 IMPL 并说明，别默默偏离。
```
