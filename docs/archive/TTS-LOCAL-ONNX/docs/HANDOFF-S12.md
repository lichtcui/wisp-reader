# HANDOFF-S12 — 服务器 TTS 拍板：GPT-SoVITS 三音色（Mac + tailscale），系统 TTS 兜底

日期：2026-10-02
分支：`tts/mac-p0`（worktree `/Users/lichtcui/Documents/playground/source-reader-tts`）
前序：见 [`HANDOFF-S11.md`](./HANDOFF-S11.md)（ZipVoice ②③ 完成）与
[`TTS-SERVER-REMOTE-SYNTH.md`](TTS-SERVER-REMOTE-SYNTH.md)（本次调研报告，未 committed）

## 1. 结论速览（已拍板）

| 项 | 决定 |
|---|---|
| 引擎策略 | **系统 TTS = 默认 + 断网/失败兜底**（音质可接受）；**网络可用时用 GPT-SoVITS `api_v2.py` 提供流萤/花火/卡芙卡音色** |
| 服务端最小闭环 | **常驻 Mac + tailscale**（0 服务器成本、0 公网端口）跑 `api_v2.py`；验证音质值得后再决定是否迁 VPS（≥4GB 内存） |
| 三音色 | `~/Documents/playground/tts/models/v2ProPlus/{流萤,花火,卡芙卡}/`（`gpt.ckpt` + `sovits.pth` + `中文/emotions/*.wav` 参考音频） |
| App 侧 | 新增 `engineKind=REMOTE`，复用 `TtsController` 的 `fill`/`ReqBuffer`/`AudioRenderer`/`AVSession` 管线，失败回退系统 TTS |
| v1 明确不做 | ogg/opus 解码（拉 32k S16LE PCM）、已合成段本地缓存、多人并发（`api_v2` 单 worker 串行） |
| 端侧自建音色 | 维持「封存」（ZipVoice ORT 动态 shape bug / GPT-SoVITS 端侧 RTF ≥1.483），**勿返工** |

## 2. 本轮调研成果落位（新 session 先读这个）

- 完整调研 + 证据来源：`docs/research/TTS-SERVER-REMOTE-SYNTH.md`（本分支已写，**未 commit**）。
  - §1 服务端选型（sherpa 薄壳 / GPT-SoVITS api_v2 / Mac+tailscale / 第三方 API）
  - §2 协议与流式（整段 vs WS；`AHEAD=3` 预取；跨章追尾）
  - §3 App 改造量（`engineKind=REMOTE` 最小改动边界 + 文件清单 + 人天）
  - §4 代价清单（延迟/隐私/带宽/断网/成本/缓存判断）
  - §5 对照决策 + 建议清单；§6 证据来源索引
- 关键数字（可查证）：GPT-SoVITS v2ProPlus 官方 **0.526/M4 CPU**；本机 int8 **RTF 0.74–0.78 / peak RSS ~2GiB**；ZipVoice 真机 RTF 0.49–0.54。

## 3. 服务端最小闭环（第一步，先在自己 Mac 上拿听感）

> ⚠️ **最大缺口（新 session 第一个待办）**：本地 `tts/` 只有 3 个角色的 **fine-tuned** `gpt.ckpt`/`sovits.pth`，
> **没有 GPT-SoVITS 的 base 预训练模型**（`s1v3.ckpt` 类 GPT base + `s2G*.pth` 类 SoVITS base + `cnhubert`/`chinese-roberta-wwm-ext-large`/`g2pw`）。
> `api_v2.py` 起服务前必须先按官方 README 下 `pretrained_models`；base GPT 确切文件名可从任意角色的 `gpt.ckpt` 内
> `data.pkl` 的 `pretrained_s1` 字段读出（提取脚本见 `TTS-PLAN.md` §10-E）。

1. **clone 一个干净的 GPT-SoVITS 用于服务端**（不要复用 ONNX 那条打过 patch 的）：`tts/gpt-sovits-server/`。
   - 注：`~/Documents/playground/tts/gpt-sovits-onnx-rs/gpt-sovits-upstream/api_v2.py` 已存在，但该 clone 打过 `t2s_model_onnx.py` patch，服务端建议 fresh clone 以免干扰。
2. **装 conda + torch（CPU 版）**：见 GPT-SoVITS 官方 README「Install」；若嫌慢走 `127.0.0.1:7897` 代理。
3. **下 pretrained_models**（base GPT + base SoVITS + cnhubert + bert + g2pw），放 `GPT_SoVITS/pretrained_models/` 对应路径。
4. **放三音色**：把 `~/Documents/playground/tts/models/v2ProPlus/{角色}/gpt.ckpt`、`sovits.pth` 拷到服务端工作目录（或启动后用 `/set_gpt_weights`+`/set_sovits_weights` 指过去，不必移动）。
5. **起服务**：`python api_v2.py -a 0.0.0.0 -p 9880`；先 `curl` 冒烟一段中文 + 一段参考音频（可用
   `~/Documents/playground/tts/models/v2ProPlus/流萤/中文/emotions/【中立】…*.wav`），`media_type=wav&text_split_method=cut5`，听声。
   - 参考音频是 44.1kHz、中文文件名，shell 注意转义；三音色各自 4–6 条见 `TTS-PLAN.md` §1 明细。
6. **tailscale 组网**：Mac 与手机（或同 tailnet 设备）各装 tailscale enroll 同一账号；之后 App 请求 `http://<mac-tailscale-ip>:9880/tts?...`。

## 4. App 端改造清单（人天 ≈ 1.5–2.5，详细边界见 research §3.1）

| 文件 | 动作 | 内容 |
|---|---|---|
| `entry/src/main/ets/model/RemoteTtsClient.ets` | **新增** | `fetch(server/{text,voiceId})→ArrayBuffer`（32k S16LE PCM）；超时/重试/`AbortController` |
| `entry/src/main/ets/model/TtsController.ets` | **改** | `engineKind` 加 `TTS_ENGINE_REMOTE`；仿 `ensureZipSynthesized()` 加 `ensureRemoteSynthesized()`（`AHEAD=3`，async fetch 回来填 `rb.chunks`/`rb.doneAt` 走同一 `tryFlush/enqueueParagraph`）；失败 → `fallbackToSystem()`；`AudioRenderer` 采样率三元加 32k |
| `entry/src/main/ets/common/Const.ets` | **改** | `TTS_ENGINE_REMOTE`、默认服务器地址、`AHEAD_REMOTE=3` |
| `entry/src/main/ets/common/Prefs.ets` | **改** | 服务器地址/远端音色持久化（`get/putString` 复用） |
| `entry/src/main/ets/pages/ListeningSettings.ets` | **改** | 引擎三选一 + 服务器地址输入 + 音色选择 |
| `entry/obfuscation-rules.txt` | **改** | 新增远端 JSON 字段 `-keep-property-name`（release 混淆） |
| `entry/src/main/module.json5` | 仅自签 HTTPS 才动 | tailscale 内网 `http://` 明文，M0 已证明文 http 可用 |

**不动**：`AudioRenderer`/`AVSession`/锁屏/媒体键、后台长时任务、定时关闭、段落高亮/进度回写、目录/书架——全复用。

## 5. 验收清单（真机，hdc 命令见 AGENTS.md §4）

1. 书架→书→阅读页→听书，听书设置引擎选「远端」+ 填 `http://<mac-tailscale-ip>:9880` + 选音色（流萤）。
2. `hilog | grep SourceReaderPoC`：观察逐段 `fetch` 成功 → `play para=N` 持续推进；听感 = 流萤音色（非系统 TTS）。
3. 三音色各切一段，确认 `set_gpt_weights`/`set_sovits_weights` 热切换生效（或重启 app 重选）。
4. 锁屏/媒体键/切后台/定时关闭仍正常（AVSession top session 链路不动，应天然通过）。
5. **断网回退**：关 tailscale / 停 `api_v2.py` → 自动回退系统 TTS（不崩、提示切换）。
6. 翻章追尾：听书到章末观察是否卡顿（`AHEAD=3` + M4 正文预取应盖住）。

## 6. 决策文本改动（上远端 TTS 所需，代码前先做）

- `AGENTS.md` 第 40 行删去「、在线 TTS」→ `| v1 不做 | JS 运行时、登录型源、换源、发现(explore)、真分页 |`。
- `plan.md:26` 同步删「/ 在线 TTS」；`plan.md:321` 与 `progress.md:17` 无需改（v2 范围本就含在线 TTS）。
- 同时把线上边界写进决策：**远端 = 可选增强，系统 TTS 始终默认 + 兜底**；单机自用；v1 拉 PCM / 不缓存 / 不做 opus。

## 7. 关键坑（继承 + 本轮新增）

- （继承 S11）`TtsController` 的 `fill/ReqBuffer/enqueueParagraph` 是「字节队列」，远端 PCM 直接 `Uint8Array` 进队列复用同管线；渲染器采样率按引擎三元切换（系统 16k / ZipVoice 24k / Remote 32k）。
- （继承）后端按 `requestId`/`idx` 对齐顺序；远端整段返回一次，`rb.chunks.set(0, pcm)` + `doneAt` 即可走 `tryFlush`，无需 sequence 分片。
- （本轮）`api_v2.py` 默认 `workers=1` 串行，单用户够用；`text_split_method=cut5` + 非固定 seed 沿用 P3 的复读控制结论。
- （本轮）明文 `http://` 内网请求：M0 已证 HarmonyOS 明文 http 可用；若上公网 VPS 再考虑 HTTPS/自签 + 白名单。
- （本轮）旁边 playground `tts/` 目录是**调研产物非本仓库**，勿把模型/权重 commit 进 App 仓库。

## 8. 下一 session 启动 prompt（可直接粘贴）

```
你接手 HarmonyOS 听书工程 /Users/lichtcui/Documents/playground/source-reader-tts（分支 tts/mac-p0），
继续「服务器 TTS（远端合声）」实施。先读（顺序）：AGENTS.md → docs/progress.md →
docs/research/TTS-SERVER-REMOTE-SYNTH.md → docs/handoff/HANDOFF-S12.md。

已拍板（当既定事实，勿返工）：
- 系统 TTS = 默认 + 断网/失败兜底；网络可用时用 GPT-SoVITS 官方 api_v2.py 提供流萤/花火/卡芙卡音色。
- 最小闭环 = 常驻 Mac + tailscale 跑 api_v2.py（0 服务器成本），先拿听感，再决定是否迁 VPS（≥4GB 内存）。
- 三音色权重在 ~/Documents/playground/tts/models/v2ProPlus/{流萤,花火,卡芙卡}/（gpt.ckpt + sovits.pth + 中文/emotions/*.wav 参考音频）。
- 端侧自建音色路线已封存（勿重验）：ZipVoice 端侧 ORT 动态 shape 乱码、GPT-SoVITS 端侧 RTF≥1.483。
- v1 不做：ogg/opus 解码、合成段落本地缓存、多人并发。

本轮目标（按序）：
1) 服务端：clone 干净 GPT-SoVITS 到 ~/Documents/playground/tts/gpt-sovits-server，装 conda+torch CPU，
   下官方 pretrained_models（base GPT=从 gpt.ckpt 的 data.pkl 读 pretrained_s1、base SoVITS、cnhubert/bert/g2pw），
   起 api_v2.py，curl 冒烟三音色各一段中文听声，确认音色 1:1。
2) tailscale 组网 Mac↔设备，拿到设备可直连的 http://<mac-tailscale-ip>:9880。
3) App：按 HANDOFF-S12 §4 加 engineKind=REMOTE（RemoteTtsClient + TtsController 三处 + Const/Prefs/ListeningSettings/obfuscation），
   复用 fill/ReqBuffer/AudioRenderer/AVSession 管线，失败回退系统 TTS，AHEAD=3，采样率 32k S16LE。
4) 改决策文本：AGENTS.md:40 删「、在线 TTS」+ plan.md:26 同步。
5) 真机按 HANDOFF-S12 §5 验收；编译→安装→重启→hilog 闭环（命令见 AGENTS.md §4）。
产出：代码改动 + 更新 docs/progress.md（M5 后新增「远端 TTS」结果）+ 真机验证记录。
```

## 9. 证据来源（详见 research §6）

- GPT-SoVITS v2 ProPlus RTF（0.526/M4 CPU）与 api_v2 端点：`RVC-Boss/GPT-SoVITS` README / `api_v2.py`。
- 本机 int8 RTF 0.74–0.78 / RSS ~2GiB：`TTS-PLAN.md` §9 P2。
- 三音色路径/参考音频：本报告 §3（`ls`/`find` 复核）。
- 「简听」HttpTtsPlayer 预取模式 / 系统 TTS 离线朗读：`TTS-FOLLOWUP-ORT-AND-EXIT-PATHS.md` §6.1。