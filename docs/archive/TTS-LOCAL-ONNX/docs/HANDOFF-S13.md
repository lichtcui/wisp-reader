# HANDOFF-S13 — 远端 TTS 落定：VPS + sherpa-onnx ZipVoice（num_steps=2），系统 TTS 兜底

日期：2026-10-02（接 S12）
分支：`tts/mac-p0`（worktree `/Users/lichtcui/Documents/playground/source-reader-tts`）
前序：`HANDOFF-S12.md`（Mac+api_v2 最小闭环，已听感验证）、`research/TTS-SERVER-REMOTE-SYNTH.md`。

## 1. 结论速览（本轮已实测拍板）

| 项 | 决定 |
|---|---|
| 服务端引擎 | **sherpa-onnx `OfflineTts` + ZipVoice（int8 distill）**，`num_steps=2`，`num_threads=4`，CPU |
| 为什么不是 GPT-SoVITS | 其 int8 单音色仍 ~1.2G 模型 / ~2.2G peak RSS，4G 无 swap 贴线；ZipVoice 峰值 **831 MiB**，余量 4.5× |
| VPS 实测 | RTF（num_steps=2）流萤 0.650 / 花火 0.709 / 卡芙卡 0.558；num_steps=4 全部 >1 不可用 |
| 音色 | ZipVoice **零样本克隆**（参考音频即时模仿），用户已确认接受；非 GPT-SoVITS 训练音色，**不要比 1:1** |
| 采样率 | 输出 **24kHz**（非 32k）；参考音频 44.1kHz 内部自动重采样 |
| 决策文本 | 系统 TTS=默认+兜底；远端=可选增强；单用户；整段 HTTP 逐句（非 SSE/WS）；不做 ogg/opus、不缓存 |
| v1 不做 | ogg/opus 解码、合成段本地缓存、多人并发、真 token 级流式 |

## 2. VPS 现状（新 session 直接接手的现场，勿重装）

- 连接：`ssh -p 40860 root@103.236.96.53`（Ubuntu 22.04，4C Xeon 8173M @2.0GHz，3.8G 无 swap，20M，月 1000G）。
- **网络**：GitHub/HF/pypi.org/crates.io 全部超时；**可达**：`pypi.tuna.tsinghua.edu.cn`（pip 用 `-i` 指它）、gitee、rsproxy.cn。**所有下载必须走清华源或 scp，别直连官方源**。
- 已装（本 session 留的，别删）：`python3-pip`、`sherpa-onnx==1.13.8`、`numpy`。
- 已有文件：
  - `/root/tts/zipvoice/sherpa-onnx-zipvoice-distill-int8-zh-en-emilia/`（encoder.int8.onnx / decoder.int8.onnx / tokens.txt / lexicon.txt / espeak-ng-data/）
  - `/root/tts/zipvoice/vocos_24khz.onnx`
  - `/root/tts/refs/{流萤,花火,卡芙卡}/中文/emotions/*.wav`（**夹带 `._*` 苹果元数据文件，匹配时排除**）
  - `/root/tts/bench.py`（可复用的 benchmark，含正确 API 与参考文本剥离逻辑）
- **不需要 swap**（ZipVoice 峰值 831 MiB，4G 余量充足）。
- `/data/media/超级宝贝jojo` 是既有数据，**勿动**。

## 3. sherpa-onnx 1.13.8 API 关键签名（已探明，勿再探）

```python
import sherpa_onnx as so
zip_cfg = so.OfflineTtsZipvoiceModelConfig(
    tokens=f"{M}/tokens.txt", encoder=f"{M}/encoder.int8.onnx",
    decoder=f"{M}/decoder.int8.onnx", vocoder=VOC,   # vocoder 直接放这里，无独立 Vocos 类
    data_dir=f"{M}/espeak-ng-data", lexicon=f"{M}/lexicon.txt",
)
model_cfg = so.OfflineTtsModelConfig(zipvoice=zip_cfg, num_threads=4, provider="cpu")
tts = so.OfflineTts(so.OfflineTtsConfig(model=model_cfg, max_num_sentences=1))
audio = tts.generate(text, prompt_text=ref_text, prompt_samples=ref_samples,
                     sample_rate=ref_sr, num_steps=2)   # GeneratedAudio: .samples(float32), .sample_rate
```

- **参考文本 = 文件名去 `.wav` 再去头部 `【...】`**（例：`【中立】…….wav` → `……`）。
- 参考加载：`wave` 读 16/32bit → `np.int16/32 → float32 / 32768(或2^31)`，多声道取均值。
- `tts` 单例常驻，逐句 generate；切音色=换 `prompt_samples`+`prompt_text` 重调 generate。

## 4. 服务层规格（Task 1）

- 语言：**Python FastAPI + uvicorn**（允许 Python 的理由：Rust 走 sherpa-onnx 需要 Linux 版 libsherpa-onnx C 库，GitHub 被墙拿不到；Python 走清华 PyPI 的 sherpa-onnx wheel 一条命令，且任务明示「Rust 难则允许 Python 并说明原因」）。
- 端点（单 worker、串行、够单用户）：
  - `POST /tts`  body `{"text": str, "voice": "流萤|花火|卡芙卡", "speed": float=1.0}` → `audio/wav`（24kHz 16bit mono，RIFF 头）。
  - `GET /health` → `{"ok": true}`。
- 关键约束：**`num_steps=2` 写死**（=3 会掉 RTF，勿改）。`num_threads=4`。
- 音色映射（默认参考，保留可配置）：
  - 流萤 → `refs/流萤/中文/emotions/【中立】…我应该会选择请求猎犬家系停止追捕。.wav`
  - 花火 → `refs/花火/中文/emotions/【吃惊】…好吧，看你这个表情是不会相信我的…没事，我可以明天再来问你一遍！.wav`
  - 卡芙卡 → `refs/卡芙卡/中文/emotions/【中立】黑塔用这么简单的小玩意藏她的宝贝？.wav`
- 鉴权：`X-API-Key` 头比对环境变量（单用户，够用；tailscale 内网为第一道）。
- 日志：Python logging 打 stdout，交给 systemd journald（**不另配 logrotate**，journald 自带轮转）。
- 代码落位：仓库 `server/` 目录（`app.py` + `requirements.txt` + `tts.service` + `deploy.sh`），git 跟踪不落模型。

## 5. App 端清单（Task 2，复用 HANDOFF-S12 §4，唯一差别：24k 而非 32k）

| 文件 | 动作 |
|---|---|
| `entry/src/main/ets/model/RemoteTtsClient.ets` | 新增：`POST {server}/tts {text,voice}` → WAV `ArrayBuffer` → 剥 RIFF 头得 PCM S16LE；超时/重试/AbortController |
| `entry/src/main/ets/model/TtsController.ets` | `engineKind` 加 `TTS_ENGINE_REMOTE`；仿 `ensureZipSynthesized()` 加 `ensureRemoteSynthesized()`（`AHEAD=3`，WAV→PCM 进 `rb.chunks` 走同一 `tryFlush/enqueueParagraph`）；失败 `fallbackToSystem()`；AudioRenderer 采样率三元已有 24k 分支（ZipVoice 端侧遗留）直接复用 |
| `common/Const.ets` | `TTS_ENGINE_REMOTE`、默认服务器地址、`AHEAD_REMOTE=3` |
| `common/Prefs.ets` | 服务器地址/远端音色持久化（复用 get/putString） |
| `pages/ListeningSettings.ets` | 引擎三选一 + 服务器地址输入 + 音色选择 |
| `entry/obfuscation-rules.txt` | 新增远端 JSON 字段 `-keep-property-name`（serverUrl/voice/speed/error） |

**不动**：AudioRenderer/AVSession/锁屏、后台常驻、定时关闭、段落高亮/进度回写、目录/书架。明文 `http://` tailscale 内网请求 M0 已证可用。

## 6. 部署（Task 3）

- systemd：`tts.service`（`/root/tts/server` 工作目录，`uvicorn app:app --host 0.0.0.0 --port 9880 --workers 1`，`Restart=always`，`Environment=X_API_KEY=...`）。
- tailscale：VPS 装 tailscale → `tailscale up` 登录 → 拿 `100.x.y.z`；服务端口优先绑 tailscale IP（不绑则靠 X-API-Key + 公网端口，二选一）。
- 设备拿到可直连的 `http://100.x.y.z:9880`。

## 7. 真机验收（Task 4，命令见 AGENTS.md §4）

1. 书架→书→阅读页→听书，听书设置选「远端」+ 填 `http://100.x.y.z:9880` + 选流萤。
2. `hilog | grep SourceReaderPoC`：逐段 fetch 成功 → `play para=N` 持续推进；听感=流萤克隆音色。
3. 三音色各切一段，确认换参考音频生效。
4. 锁屏/媒体键/切后台/定时关闭仍正常（AVSession 链路不动）。
5. 断网/停服务 → 自动回退系统 TTS（不崩、提示）。
6. 章末追尾不卡（`AHEAD=3` + M4 正文预取盖住）。

## 8. 文档改动（Task 5）

- `AGENTS.md:40` 删「、在线 TTS」→ `| v1 不做 | JS 运行时、登录型源、换源、发现(explore)、真分页 |`；`plan.md:26` 同步删「/ 在线 TTS」。
- `docs/progress.md` M5 后新增「远端 TTS（VPS + ZipVoice ONNX 流式）」结果（含 RTF/峰值内存/真机记录）。
- 部署文档落 `docs/`（服务端安装/启动/切换音色/故障排查）。

## 9. 关键坑（继承 + 本轮新增）

- （本轮）`num_steps=2` 是 RTF 达标前提，`=3/=4` 会到 1.1–1.4，**勿改**。
- （本轮）参考音频 44.1kHz，sherpa 内部重采样 24k，无需预处理；参考文本必须逐字（文件名即稿，剥 `【...】`）。
- （本轮）`._*` 苹果元数据文件要排除；wav 里 `…` 等字符被标 OOV 忽略属正常，不影响出声。
- （继承 S12）后端单 worker 串行；整段返回一次即可 `rb.chunks.set(0,pcm)` + `doneAt` 走 `tryFlush`。
- （继承）明文 `http://` 内网请求可用；`tts/`、`p5-zipvoice/` 等 playground 目录非本仓库，勿 commit 模型/权重。

## 10. 新 session 启动 prompt

见下方（可直接粘贴，自包含）。