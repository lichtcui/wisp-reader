# tools/tts — TTS 音色素材工具

TTS 端侧原型（见 [`TTS-PLAN.md`](../docs/TTS-PLAN-LOCAL-ONNX.md)）的素材处理脚本。零第三方依赖（只用标准库），
`/usr/bin/python3` 即可运行。

```bash
S=tools/tts/tts_assets.py
```

## 解决的三个已知坑

| 坑 | 现象 | 脚本行为 |
|---|---|---|
| zip 条目名乱码 | 包内文件名是 GBK 字节流被当作 cp437，`unzip` 解出乱码路径 | `extract` 做 `cp437 → gbk` 转码 |
| `.pth` 幻数被改写 | 重下得到的 `.pth` 首 2 字节是 `30 36` 而非 `PK`，`torch.load` 直接失败 | `extract` 自动改回 `PK` |
| 参考音频带长静音 | 如流萤【难过】前 1.75s 全静音，运行时不做裁剪会污染 SSL 特征 | `trim` 裁掉首尾静音 |

## 用法

```bash
# 1) 解压角色包（自动修 .pth 幻数），并校验内层 zip 完整性
$S extract --zip ~/Downloads/流萤.zip --out /tmp/probe --verify

# 2) 检查某个音色的参考音频静音分布
$S analyze --dir ~/Documents/playground/tts/models/v2ProPlus/流萤

# 3) 裁静音并 staging 给 P2 用（--stage 会写成 <dir>/ref.wav，即 demo 读取的路径）
$S trim \
  --src "~/.../中文/emotions/【难过】抱歉，我不得不这么做…….wav" \
  --out ~/Documents/playground/tts/models/v2ProPlus/流萤/ref.wav \
  --stage ~/Documents/playground/tts/gpt-sovits-onnx-rs/gpt-sovits-upstream/models/export/v2ProPlus
```

`trim` 输出时若裁剪后短于 3s 会告警（上游建议参考音频 3–10s）。

## 参数

`analyze` / `trim` 共用：

| 参数 | 默认 | 说明 |
|---|---|---|
| `--threshold` | `0.02` | 判静音的幅度阈值（相对满量程） |
| `--window` | `0.02` | 包络窗口（秒） |

`trim` 另有：`--pre`（保留前导余量 0.03s）、`--post`（尾部余量 0.10s）、`--min-sec`（告警阈值 3.0s）。

## 已验证

- `extract`：对 `流萤/花火/卡芙卡` 三个包解压，`.pth` 修幻数后 `testzip=None`。
- `trim`：输出与人工裁剪结果 **sha256 完全一致**（`b287aefa…`）。

## 注意

- **只读素材、只写输出路径**：不修改 `~/Downloads` 里的原 zip，也不覆盖 `中文/emotions/` 下的原始 wav。
- 换主用音色（如改用【开心】）时重跑 `trim` + `--stage` 即可，无需手工处理。
