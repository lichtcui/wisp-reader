# 远端 TTS 部署与运维（VPS + sherpa-onnx ZipVoice）

服务端代码：仓库 `server/`（`app.py` / `requirements.txt` / `tts.service` / `deploy.sh`）。
VPS：`ssh -p 40860 root@103.236.96.53`（Ubuntu 22.04 / 4C Xeon 8173M / 3925 MB + **2 GB swap**）。

> **引擎选型与「杂音」根因的实测数据见 [`research/TTS-ENGINE-COMPARISON.md`](./research/TTS-ENGINE-COMPARISON.md)**
> （结论：ZipVoice 在本机没有任何一档 `num_steps` 能同时做到实时与不浑浊；实测 `sherpa-onnx-vits-zh-ll` RTF 0.40、RSS ~250MB，
> 是唯一能兼顾「中文 + 可微调成角色音色 + RTF<1」的架构）。本文件只记录**现状部署与运维**。

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
- ⚠️ **单请求超时会中断播放并换音色**：`RemoteTtsClient.ets` 的 `readTimeout=60000`，204 字段落约 29s；
  3 段预取 + 服务端串行 → 第 3 个排队请求最坏 ≈87s > 60s，会触发 `fallbackToSystem()` 把音色换成系统 TTS。
  建议把 `readTimeout` 提到 **≥120000**（设备离线，尚未改）。换 VITS（RTF 0.40）后此风险大幅缓解。
- ⚠️ 状态：这条远端链路**已知会整体重做**，本文件只按现状记录，不代表最终方案。

## 1. 现场（勿动）

- 模型：`/root/tts/zipvoice/sherpa-onnx-zipvoice-distill-int8-zh-en-emilia/` + `vocos_24khz.onnx`。
- **备选模型（已下载、已实测）**：`/root/tts/vits-zh-ll/sherpa-onnx-vits-zh-ll/`（16kHz / 5 说话人 / RTF 0.40 / RSS ~250MB），
  试听样本生成脚本见 `/tmp/abtest/gen.py`。
- 参考音频：`/root/tts/refs/{流萤,花火,卡芙卡}/中文/emotions/*.wav`（排除 `._*`）。
- 服务目录：`/root/tts/server/`；systemd unit：`tts`；日志：`journalctl -u tts -f`。
- API Key（服务端当前值）：见 `/etc/systemd/system/tts.service` 的 `X_API_KEY`。

## 2. 音色映射（默认参考，`app.py` 的 `VOICE_REFS` 可改）

| voice | 参考音频 |
|---|---|
| 流萤 | `【中立】…我应该会选择请求猎犬家系停止追捕。.wav` |
| 花火 | `【吃惊】…好吧，看你这个表情是不会相信我的…没事，我可以明天再来问你一遍！.wav` |
| 卡芙卡 | `【中立】黑塔用这么简单的小玩意藏她的宝贝？.wav` |

参考文本 = 文件名去 `.wav` 再剥头部 `【...】`；参考 wav 用 `wave` 读成 float32，x 声道取均值。

## 3. 安装 / 启动 / 重启

```bash
# 首次（在 VPS，/root/tts 下已有 app.py 等）：pip 走清华源
cd /root/tts
pip3 install -i https://pypi.tuna.tsinghua.edu.cn/simple --upgrade fastapi uvicorn
X_API_KEY=<你的密钥> bash deploy.sh          # 装 unit + 起服务

# 改代码后
scp -P 40860 server/app.py root@103.236.96.53:/root/tts/server/
ssh -p 40860 root@103.236.96.53 'systemctl restart tts && journalctl -u tts -f'
```

- `num_steps` 经环境变量 `NUM_STEPS` 覆盖，**现用 3**（实测 RTF 0.834）；`num_threads=4`。
  单请求内不会再建重采样器（参考音频在加载时一次性重采样到 24kHz）。
- **RTF 是单请求口径且服务端串行**：早期文档记录的并发期 RTF 1.655 / 1.753 / 2.580 / 6.428
  **包含排队等待时间**，不是抢核导致的算力下降 —— `app.py` 的 `_lock` 保证同时只有一个推理在跑。
  真正的问题是**余量薄**：`steps=3` 的 0.834 只剩 1.2× 吞吐余量，一旦抖动就耗尽 3 段预取缓冲。
- **v1.1.0 后处理链**（纯 numpy，VPS 上无 scipy/soundfile/ffmpeg/sox）：
  `_eq()` 零相位 RBJ peaking EQ + `_limit()` 分块峰值限制器 + `_normalize()` 响度归一 + `_fades()` 淡入淡出。
  环境变量：`POST_ENABLE`（默认开）、`EQ_BANDS="280:-3.5:0.9,2800:+3.5:0.7"`、
  `TARGET_RMS_DBFS=-18`、`PEAK_CEILING_DBFS=-1`。
  效果：200–300Hz 占比 47.8%→24–32%，600–1500Hz 8–12%→15–23%；三音色响度离散 5.5dB→0.62dB，全部 0% 削波。
- 输出固定 24kHz S16LE mono。`/health` 回显 `{ok, steps, post, eq}`，用来确认线上真的生效（改完 env 一定要看一眼）。

## 4. 端点与鉴权

- `GET /health` → `{"ok": true, "steps": 3, "post": true, "eq": "280:-3.5:0.9,2800:+3.5:0.7"}`。
- `POST /tts` body `{"text","voice","speed"}` → `audio/wav`（24kHz S16LE mono，RIFF 头）。
- `X-API-Key` 头：`app.py` 读环境变量 `X_API_KEY`，非空则必须匹配，否则 401；留空则免鉴权。

## 5. 故障排查

| 现象 | 排查 |
|---|---|
| `403/401` | App 的 API Key 与服务端 `X_API_KEY` 不一致 |
| 服务起不来 / 端口占用 | `systemctl status tts`；`ss -tlnp \| grep 9880` |
| RTF 变慢 / 内存爆 | `journalctl -u tts` 看是否 `num_steps` 被改（每加一步 RTF 约 ×1.2–1.8）；新起稳态 RSS 约 **790 MB**，但**老版本连续跑 6 天后涨到 2513 MB**（元凶是每请求新建 44.1k→24k 重采样器，v1.1.0 已修）。`MemoryHigh=1200M`/`MemoryMax=1600M` 会在回归时主动重启服务 |
| 输出无声/杂音 | 确认 `vocos_24khz.onnx` 在 `${VOCODER}`；参考音频未被删 |

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
  `RuntimeMaxSec=86400`（每日重启）+ `OMP_NUM_THREADS=4` / `OPENBLAS_NUM_THREADS=4` / `MALLOC_ARENA_MAX=4` /
  `MALLOC_TRIM_THRESHOLD_=65536`。目标：万一内存回归就把 `tts` 自己重启掉，而不是让内核去杀别的进程。
- **增长归因现状**：修掉 `_profile()` 的 FFT 长度缓存（量化到 2 的幂）后斜率变化不大，
  说明主因更可能是 ONNX Runtime arena 高水位爬坡 + glibc 内存滞留，而非逐请求真泄漏。
  换 VITS（RSS ~250MB）后这些加固都非常宽松。细节见 [`research/TTS-ENGINE-COMPARISON.md`](./research/TTS-ENGINE-COMPARISON.md) §7。

## 8. VPS 下载通道

VPS 网络受限，实测：**清华 PyPI 可用**（`-i https://pypi.tuna.tsinghua.edu.cn/simple`）、
**ModelScope 可达**；**HuggingFace / github.com / ghproxy / hf-mirror 全部超时**。
因此任何新模型/新代码都要先在 Mac 下好再 `scp -P 40860` 上去。