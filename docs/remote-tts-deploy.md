# 远端 TTS 部署与运维（VPS + sherpa-onnx ZipVoice）

服务端代码：仓库 `server/`（`app.py` / `requirements.txt` / `tts.service` / `deploy.sh`）。
VPS：`ssh -p 40860 root@103.236.96.53`（Ubuntu 22.04 / 4C Xeon 8173M / 3.8G 无 swap）。

## 0. App 侧接入（`feat/remote-tts` 分支）

远端是**可选增强，默认关闭**：默认仍是系统 TTS，断网/失败自动回退系统 TTS。

- 入口：`我的 → 设置 → 听书设置 → 朗读引擎`，选「远端」后填 `服务器地址` + `API Key`。
- 建议值：`http://103.236.96.53:39680`，Key 取 VPS 上 `tts.service` 的 `X_API_KEY`。
- 相关代码：`entry/src/main/ets/model/RemoteTtsClient.ets`（`POST /tts` + 剥 RIFF）、
  `model/TtsController.ets`（引擎分派 / `ensureRemoteSynthesized` / `fallbackToSystem`）、
  `common/Const.ets`（`TTS_ENGINE_*` / `KEY_TTS_SERVER` / `KEY_TTS_API_KEY`）。
- **采样率差异**：系统 TTS 是 16 kHz，远端返回 24 kHz；`TtsController` 的 `sampleRate` 按引擎取值，
  渲染器用 `SAMPLE_RATE_24000`、时长换算用 `24000 * 2` 字节/秒。改这块时别写死 16 kHz。
- 预取：远端 `AHEAD_REMOTE = 3` 段（系统 TTS 为 2），整段 HTTP、无 SSE/WS、无本地缓存、无并发限制。
  服务端固定 `num_threads=4`，所以 3 路预取会互相抢核：**RTF 只在单请求下 <1**（详见 §3 注）。
- ⚠️ 状态：这条远端链路（含并发预取）**已知会整体重做**，本文件只按现状记录，不代表最终方案。

## 1. 现场（勿动）

- 模型：`/root/tts/zipvoice/sherpa-onnx-zipvoice-distill-int8-zh-en-emilia/` + `vocos_24khz.onnx`。
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

- `num_steps` 默认 2，可经环境变量 `NUM_STEPS` 覆盖（现用 **3**，句首更干净、RTF≈0.92 仍 <1）；`num_threads=4`。
  每句合成后加 12ms 淡入压句首瞬态。
  **注（并发场景）**：上面这个 RTF 是**单请求**口径。`num_threads=4` 是固定的，而 App 侧 `AHEAD_REMOTE = 3` 会同时发 3 个请求，
  三者互相抢核 → 实测 RTF 由 0.767 / 0.784 涨到 **1.655 / 1.753 / 2.580 / 6.428**（2026-10-07 真机对比并发期与停 App 后的单请求），
  即**并发下已不能保证 <1**。当前仍能实时不断流（靠 3 段预取缓冲），但余量很薄。
- 输出固定 24kHz S16LE mono；RTF（num_steps=2）流萤/花火/卡芙卡约 0.56–0.71（VPS 4C）。

## 4. 端点与鉴权

- `GET /health` → `{"ok": true}`。
- `POST /tts` body `{"text","voice","speed"}` → `audio/wav`（24kHz S16LE mono，RIFF 头）。
- `X-API-Key` 头：`app.py` 读环境变量 `X_API_KEY`，非空则必须匹配，否则 401；留空则免鉴权。

## 5. 故障排查

| 现象 | 排查 |
|---|---|
| `403/401` | App 的 API Key 与服务端 `X_API_KEY` 不一致 |
| 服务起不来 / 端口占用 | `systemctl status tts`；`ss -tlnp \| grep 9880` |
| RTF 变慢 / 内存爆 | `journalctl -u tts` 看是否 `num_steps` 被改；峰值 RSS 约 831 MiB；**多条 `remote-tts synth` 并发在跑也是原因**（App 侧预取 3 路 → RTF >1，见 §3 注） |
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