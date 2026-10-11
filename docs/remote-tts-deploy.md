# 远端 TTS 部署与运维（VPS + sherpa-onnx VITS）

服务端代码：仓库 `server/`（`app.py` / `requirements.txt` / `tts.service` / `deploy.sh`）。
VPS：`ssh -p 40860 root@103.236.96.53`（Ubuntu 22.04 / 4C Xeon 8173M / 3925 MB + **2 GB swap**）。

> **引擎选型、三个已修 bug（词典 / `rule_fsts` / 停顿）与全部实测数据见
> [`research/TTS-ENGINE-COMPARISON.md`](./research/TTS-ENGINE-COMPARISON.md)。**
> 本文件只记录**现状部署与运维**。

## 0. App 侧接入（`feat/remote-tts` 分支）

远端是**可选增强，默认关闭**：默认仍是系统 TTS，断网/失败自动回退系统 TTS。

- 入口：`我的 → 设置 → 听书设置 → 朗读引擎`，选「远端」后填 `服务器地址` + `API Key`。
- 建议值：`http://103.236.96.53:39680`，Key 取 VPS 上 `tts.service` 的 `X_API_KEY`。
- 相关代码：`entry/src/main/ets/model/RemoteTtsClient.ets`（`POST /tts` + 剥 RIFF）、
  `model/TtsController.ets`（引擎分派 / `ensureRemoteSynthesized` / `fallbackToSystem`）、
  `common/Const.ets`（`TTS_ENGINE_*` / `KEY_TTS_SERVER` / `KEY_TTS_API_KEY`）。
- **采样率差异**：系统 TTS 是 16 kHz，远端返回 24 kHz；`TtsController` 的 `sampleRate` 按引擎取值，
  渲染器用 `SAMPLE_RATE_24000`、时长换算用 `24000 * 2` 字节/秒。改这块时别写死 16 kHz。
- 预取：远端 `AHEAD_REMOTE = 3` 段（系统 TTS 为 2），整段 HTTP、无 SSE/WS、无本地缓存。
  服务端 `app.py` 用一把 `_lock` **把推理串行化**，所以预取深度买到的是「CPU 不空转」而不是并行度；
  `num_threads=4` 只影响单次推理的核数，**请求之间不会互相抢核**。
- 超时：`RemoteTtsClient.ets` `connectTimeout=5000` / `readTimeout=120000`（2026-10-11 由 60000 提到 120000）。
  3 段预取 + 服务端串行，实测最坏单请求 wall ≈ 46 s（279 字 / 5 句 / effective 1.5），120 s 有余量。
  仍然失败时会走 `fallbackToSystem` **并把 `tts_engine` 写成系统 TTS**（见 §5 的注意项）。
- **客户端 `speed` 已真的下发**（2026-10-11）：`remoteSynthesize(..., speed)` 带 `this.speed`，
  服务端有效语速 = `min(2.0, max(0.5, client_speed)) * SPEED_SCALE`。
  例：App 1.0x → 0.75（默认），App 2.0x → clamp 后的 1.5。实测日志 `speed=0.750/1.500` 对得上。
- ⚠️ **语速越高越可能断续**：本机（4C）实测每字合成成本 ≈ 0.13–0.16 s，而播放速度 = 有效语速下
  的 ~0.19 s/字（0.75）/ 0.136 s/字（1.5）⇒ **有效语速 ≈ 1.0 是可持续上限**。
  即 App 的 1.0x/1.2x 稳，**1.5x/2.0x 有概率出现段间空档**（预取 3 段缓冲会被吃光）。
  想再快只能换更快的机器（或改服务端批合成），暂无计划；调 `AHEAD_REMOTE` 不解决问题。
- ⚠️ 状态：这条远端链路**已知会整体重做**，本文件只按现状记录，不代表最终方案。

## 1. 现场（勿动）

| 用途 | 路径 |
|---|---|
| **线上模型（VITS）** | `/root/tts/genshin-vits/vits-hf-zh-jp-zomehwh.onnx` |
| **线上词典** | `/root/tts/genshin-vits/lexicon_final.txt`（自制纯中文 66,790 条） |
| 分词词典（jieba） | `/root/tts/vits-zh-ll/sherpa-onnx-vits-zh-ll/dict/` |
| 文本正规化 FST | `/root/tts/vits-zh-ll/sherpa-onnx-vits-zh-ll/{date,number,phone}.fst` |
| 回滚用（ZipVoice） | `/root/tts/zipvoice/sherpa-onnx-zipvoice-distill-int8-zh-en-emilia/` + `vocos_24khz.onnx` |
| 回滚用参考音频 | `/root/tts/refs/{流萤,花火,卡芙卡}/中文/emotions/*.wav`（排除 `._*`，只有 ZipVoice 用） |
| 同族备选模型 | `/root/tts/vits-zh-ll/sherpa-onnx-vits-zh-ll/`（16kHz / 5 说话人 / RTF 0.40） |
| 已弃用 | `genshin-vits/theresa.onnx` —— **坏文件**，男声 F0 落在 190–220 Hz，勿再启用 |
| 服务目录 / unit / 日志 | `/root/tts/server/` / `tts` / `journalctl -u tts -f` |

- API Key（服务端当前值）：见 `/etc/systemd/system/tts.service` 的 `X_API_KEY` 行。
- 词典生成与诊断脚本、各轮试听样本目录清单见
  [`research/TTS-ENGINE-COMPARISON.md`](./research/TTS-ENGINE-COMPARISON.md) §9。

## 2. 音色

VITS 用 **speaker id**，不再需要参考音频：

| voice | sid | F0 |
|---|---|---|
| 胡桃 | 119 | 312 Hz |
| 甘雨 | 111 | 273 Hz |
| 刻晴 | 115 | 255 Hz |
| 雷电将军 | 125 | 208 Hz |
| 钟离 | 104 | 122 Hz |

**旧名别名**（App 端已同步，服务端仍兜底）：
`流萤 → 甘雨`、`花火 → 胡桃`、`卡芙卡 → 雷电将军`。
2026-10-11 起 App 的 `TTS_REMOTE_VOICE_OPTIONS` 就是上表这 5 个名字，默认 **钟离**；
设备上残留的旧值（如 `流萤`）由 `common/Const.ets::normalizeRemoteVoice()` 在读取时归一，
**用户不需要手动重选**（已真机确认 `tts_remote_voice=流萤` → 界面显示「远端音色 · 甘雨」）。
改名只需动 `Const.ets` 与 `app.py` 的 `VITS_VOICES` / `VITS_VOICE_ALIASES`，两边别只改一边。
注意：**这 5 个 sid 在公开的 804 说话人表里是空位**，所以「名字 ↔ 角色音色」的对应关系
只能靠听感判断（F0 表是实测的，可信）。

## 3. 安装 / 启动 / 重启

```bash
# 首次（在 VPS，/root/tts 下已有 app.py 等）：pip 走清华源
cd /root/tts
pip3 install -i https://pypi.tuna.tsinghua.edu.cn/simple --upgrade fastapi uvicorn
X_API_KEY=<你的密钥> bash deploy.sh          # 装 unit + 起服务

# 改代码后（改完先本地 py_compile，别把语法错误推上去）
cd <repo> && python3 -m py_compile server/app.py
scp -P 40860 server/app.py root@103.236.96.53:/root/tts/server/
scp -P 40860 server/tts.service root@103.236.96.53:/etc/systemd/system/
ssh -p 40860 root@103.236.96.53 'systemctl daemon-reload && systemctl restart tts && journalctl -u tts -f'
```

启动约 **3s**（含 warmup），日志应出现：

```
vits ready (warmed) in 2.9s sr=22050 speakers=804 model=vits-hf-zh-jp-zomehwh.onnx lexicon=lexicon_final.txt rule_fsts=date.fst,number.fst,phone.fst
voices=['刻晴','甘雨','胡桃','钟离','雷电将军'] aliases={...} speed_scale=0.75 sentence_pause=320ms
engine=vits post: enabled=True eq=(off) target=-18.0dBFS ceiling=-1.0dBFS
```

### 环境变量（`server/tts.service`）

| 变量 | 默认 | 说明 |
|---|---|---|
| `ENGINE` | `vits` | `vits` \| `zipvoice`（回滚用） |
| `VITS_DIR` | `/root/tts/genshin-vits` | 模型目录 |
| `VITS_DICT_DIR` | `/root/tts/vits-zh-ll/sherpa-onnx-vits-zh-ll/dict` | jieba 分词词典（**必须传字符串**，传 `None` 会 `TypeError`） |
| `RULE_FST_DIR` / `RULE_FSTS` | 见 service | `date.fst,number.fst,phone.fst`。**不加载数字会被静默丢弃**；`new_heteronym.fst` 无效果，别加 |
| `SPEED_SCALE` | `0.75` | 乘在**客户端 `speed`**（现由 App 下发）上的基准语速；映射到 sherpa 的 `length_scale = 1/speed`。0.75 是 2026-10-11 的听感起点值，按 §0 的可持续上限，**不建议再往上调**（>1.0 会断续），要调小（更慢）随时可以 |
| `SENTENCE_PAUSE_MS` | `320` | 句间自插静音（sherpa 自带只有 ~80ms）；`0` 关闭 = 恢复模型原生停顿 |
| `POST_ENABLE` | `1` | `0` = 输出裸模型音频（A/B 用） |
| `EQ_BANDS` | **VITS 下为空** | 去浑浊 EQ 是 ZipVoice 专用补丁；填 `280:-3.5:0.9,2800:+3.5:0.7` 可手动开 |
| `TARGET_RMS_DBFS` / `PEAK_CEILING_DBFS` | `-18` / `-1` | 响度目标 / 限幅天花板 |
| `NUM_STEPS` | `3` | **仅 ZipVoice** |

- **后处理链**（纯 numpy，VPS 上无 scipy/soundfile/ffmpeg/sox）：去均值 → 重采样到 24k →
  响度归一 → 分块峰值限幅 → 淡入淡出。约 0.2% CPU。
- 输出固定 **24kHz S16LE mono**（VITS 原生 22050，服务端 `_resample_fft()` 升采样；
  纯音验证 `1000 Hz → 1000.0 Hz`，无移调）。
- **文本必须保留标点**：sherpa 靠标点分句，去掉标点后内部停顿直接变 0（实测）。
- **RTF 是单请求口径且服务端串行**：`_lock` 保证同时只有一个推理在跑，
  早期文档记录的并发期 RTF 1.655–6.428 **包含排队等待**，不是抢核。现用 VITS 实测 **0.576**。

## 4. 端点与鉴权

- `GET /health` → `{"ok","engine","version","sample_rate","voices","speed_scale","post","eq"}`。
  **改完 env 一定要看一眼**，这是确认配置真生效的最快方式。
- `POST /tts` body `{"text","voice","speed"}` → `audio/wav`（24kHz S16LE mono，RIFF 头）。
- `X-API-Key` 头：`app.py` 读环境变量 `X_API_KEY`，非空则必须匹配，否则 401；留空则免鉴权。

## 5. 故障排查

| 现象 | 排查 |
|---|---|
| `403/401` | App 的 API Key 与服务端 `X_API_KEY` 不一致 |
| 服务起不来 / 端口占用 | `systemctl status tts`；`ss -tlnp \| grep 9880` |
| **某些词读得像日文** | 词典被换回了 `zome_lexicon.txt`（自带词典含日文词表）。确认 `/health` 后查启动日志的 `lexicon=`，应为 `lexicon_final.txt` |
| **数字不念 / 莫名跳过** | `rule_fsts` 没生效。日志里会出现 `Ignore OOV '2024'` 之类 |
| **句间没有停顿** | `SENTENCE_PAUSE_MS=0`？或客户端把标点删了（标点丢了 sherpa 就不分句） |
| **男声变女声 / 音高全错** | 模型被换成了 `theresa.onnx`（**坏文件**）。用 `f0.py` 量钟离，应为 ~122 Hz |
| RTF 变慢 / 内存爆 | `journalctl -u tts` 看 `ENGINE` / `NUM_STEPS` 是否被改（ZipVoice 每加一步约 ×1.2–1.8）；VITS 稳态 RSS ≈ **441 MB**，`MemoryHigh=1200M`/`MemoryMax=1600M` 会在回归时主动重启服务 |
| 输出无声/杂音 | 确认模型在 `VITS_DIR`；`POST_ENABLE=0` 时输出是裸模型音频（正常但更浑浊） |
| **播到带引号/破折号的段落就中断，App 弹「远端合成失败，已切换回系统 TTS」** | 2026-10-11 已修：纯标点分段（`：“”`、`——`）sherpa 返回 `sample_rate=0` 的空音频，旧代码在 `_resample_fft` **除零 → HTTP 500**。现在跳过该分段（日志 `drop unspeakable segment`），整段无字时返回 320ms 静音。**这条极常见**：`他说：“你来了。”` 会分出一个独立的 `”` 段，即每个对白段都曾 500。查 `journalctl -u tts \| grep "drop unspeakable"` |

> ⚠️ **注意（App 侧未改）**：`fallbackToSystem()` 会把 `tts_engine` **写入 preferences**，
> 一次瞬时失败 = 用户选的「远端」被永久改回系统 TTS（需手动再切）。当前保留该行为（属产品决策，
> 见 `docs/bugfix/TASKS.md` §T-TTS-5 的待定项）。

## 6. 网络（已落定：公网映射 39680）

VPS 是**端口映射型 NAT**（内网 `172.16.0.38`，公网 `103.236.96.53`）。公网只暴露有限端口，
服务端内网 `9880` 已映射到**公网 `39680`**：

```
设备直连：http://103.236.96.53:39680
鉴权：X-API-Key（与 /etc/systemd/system/tts.service 的 X_API_KEY 一致）
```

> tailscale 路线不可用（login/controlplane/derp.tailscale.com 均被墙）。
> 开发期也可用 SSH 本地转发替代：`ssh -p 40860 -f -N -L 9880:127.0.0.1:9880 root@...`，设备填 `http://<Mac-LAN-IP>:9880`。

## 7. 内存与稳定性

- **已加 2G swap**：`/swapfile` + `/etc/fstab` + `vm.swappiness=10`、`vm.vfs_cache_pressure=50`
  （原 3.9G 无 swap，曾导致 `rustc` 构建被内核 OOM 杀掉）。
- **systemd 加固**（`server/tts.service`）：`MemoryHigh=1200M` / `MemoryMax=1600M` /
  `RuntimeMaxSec=86400`（每日重启，**VITS 重启只花 ~3s**）+ `OMP_NUM_THREADS=4` /
  `OPENBLAS_NUM_THREADS=4` / `MALLOC_ARENA_MAX=4` / `MALLOC_TRIM_THRESHOLD_=65536`。
  目标：万一内存回归就把 `tts` 自己重启掉，而不是让内核去杀别的进程。
- **增长已归因完毕，无逐请求泄漏**：干净 100 次 soak —— 354MB → 首次 warmup 后 441MB →
  **此后 60 次请求零增长**、静置 60s 零增长。441MB 是 ONNX Runtime arena 的一次性高水位。
  老版本「6 天涨到 2513MB」的元凶是**每请求**新建 44.1k→24k 重采样器（已修）。

## 8. VPS 下载通道

VPS 网络受限，实测：**清华 PyPI 可用**（`-i https://pypi.tuna.tsinghua.edu.cn/simple`）、
**ModelScope 可达**；**HuggingFace / github.com / ghproxy / hf-mirror 全部超时**。
因此任何新模型/新代码都要先在 Mac 下好再 `scp -P 40860` 上去。

> 注意：**Mac 侧的 `hf-mirror.com` 是通的**（`https://hf-mirror.com/<repo>/resolve/main/<file>`），
> 这就是拿到 804 说话人模型的通道 —— 「VPS 下不了 HF」不再是阻塞项。
