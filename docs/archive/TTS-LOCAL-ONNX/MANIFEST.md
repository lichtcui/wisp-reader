# MANIFEST — 已删除的 `~/Documents/playground/tts/`（40G 实验台）

删除时间：2026-10-12。删除理由：端侧自建音色路线已封存（见 [`README.md`](./README.md)），
该目录不属于任何仓库、不被 source-reader(master) 任何代码或文档引用，唯一引用方是已删的
`source-reader-tts` worktree。删除前已把**文本产物 / 测量证据 / 唯一未推送代码**复制进本目录。

- 删除前总体积：**40G**（`du -sh`）
- 本目录归档后体积：**146 个文件 / 1,548,754 B ≈ 1.5MiB**（`du -sh` 报 1.7M，含 4KB 块对齐开销）

## 1. 删除清单

| 路径 | 体积 | 内容 | 可恢复性 |
|---|---|---|---|
| `gpt-sovits-onnx-rs/` | 30G | Rust ONNX 导出器（`bailu-obj/gpt-sovits-onnx-rs` 的 clone）+ 27G 上游 vendor clone + 2.7G `target/` | **可重克隆**（GitHub）；3 个未推送提交与未提交改动见本目录 `gpt-sovits-onnx-rs/` |
| `models/v2ProPlus/` | 945M | `{流萤,花火,卡芙卡}/`，各 315M（`gpt.ckpt` 155MB + `sovits.pth` 173MB + 参考音频） | 可重下（ModelScope 直链），**逐文件 sha256 见 [`docs/tts-p0-report.md`](./docs/tts-p0-report.md) §6** |
| `p2/` | 1.3G | Mac 侧 ONNX 基准：`onnx-int8/` 1.2G、`audio/` 56M、`bundles/` | 音频/模型可重导；**测量结果已归档到 [`evidence/p2-results/`](./evidence/p2-results)** |
| `p3/` | 2.3G | 分段 / 复读检测 / ASR 扫描：`audio/` 1.5G、`whisper-models/`、`asr-venv/` | 同上；**结果与语义 dump 已归档到 [`evidence/p3-results/`](./evidence/p3-results)** |
| `p4/` | 5.2G | OHOS 端侧工程：`gpt-sovits-tts-ohos` 1.4G、`tts-bench` 1.3G、`src/onnxruntime-1.24.4` 1.0G、`build/` 1.0G、`ohos-tts-test` 246M、`out/` 93M、`logs/` 20M | **ORT 源码树与 build 可重编**（脚本已归档到 [`harness/p4/`](./harness/p4)）；`reader-data-backup/` 为空 |
| `p5-zipvoice/` | 392M | sherpa-onnx v1.13.8 macOS shared 69M、ZipVoice distill-int8 模型 145M、`vocos_24khz.onnx` 52M、两个 tar.bz2 126M | 可重下；**VPS 上已有线上副本**（见 `../../remote-tts-deploy.md` §1） |

## 2. 已归档（可从本目录取回的东西）

| 类别 | 归档位置 | 说明 |
|---|---|---|
| 9 份该分支独有文档 | [`docs/`](./docs) | P0/P6 报告、exit-paths、S11–S13、ZipVoice 动态 shape、远端方案、91KB TTS-PLAN |
| 端侧 App 代码 | [`app/`](./app) | `ZipVoiceTest.ets`、`ZipVoiceTtsWorker.ets` |
| 资产脚本 | [`tools-tts/`](./tools-tts) | `tts_assets.py` + README |
| 实验脚手架 | [`harness/`](./harness) | p2/p3 Python harness（含 `chunker.py` / `loopdetect.py`）、p4 OHOS 构建脚本与文档 |
| 测量证据 | [`evidence/`](./evidence) | p2/p3 结果 JSON、语义 token dump（报告里数字的原始出处） |
| 未推送代码 | [`gpt-sovits-onnx-rs/`](./gpt-sovits-onnx-rs) | 3 个 `.patch` + `worktree-uncommitted.diff` + 原文件 + `STATE.md` |

## 3. 关键产物指纹（用于日后核对重编/重下的东西是否同一份）

| 产物 | 大小 (B) | sha256 |
|---|---|---|
| `p4/build/ort-ohos-arm64/Release/libonnxruntime.so.1.24.4` | 28,176,512 | `a1c139ee7389dcd17c49fd6b21235594115327999c246d4c273bf7a641f85bd3` |
| `models/v2ProPlus/<角色>/gpt.ckpt`（3 角色） | 155,313,312 | 见 [`docs/tts-p0-report.md`](./docs/tts-p0-report.md) §6 |
| `models/v2ProPlus/<角色>/sovits.pth`（3 角色） | 172,765,299 | 同上 |

## 4. 明确未归档（已随目录删除）

- 原始日志：`p4/archive/full-buffer-*.log`（17.8M + 1.1M）、`p2/logs/` 444K、`p3/logs/` 2.0M、
  `p4/logs/` 20M、`p4/build_ort*.log`。**结论文本与结果 JSON 均已归档**，日志本身只是原始输出。
- 音频中间产物：`p3/audio/` 1.5G、`p2/audio/` 56M、`p3/asm/_audio_tmp.npy` 7.3M。
- 环境与构建产物：`asr-venv/`、`whisper-models/`、`target/`、`build/`、`ohos-tts-test/`、`tts-bench/`、
  `gpt-sovits-upstream/`（27G vendor clone）。

## 5. 恢复路径

1. **ORT for OHOS**：`harness/p4/build_ort_ohos.sh` + `harness/p4/patches_ort_ohos.sh`（幂等）+
   `harness/p4/ORT-OHOS-BUILD.md`；源码树按文档拉 `onnxruntime-1.24.4` 后打 4 处 patch。
2. **GPT-SoVITS 权重**：ModelScope 直链重下后按 `docs/tts-p0-report.md` §6 的 sha256 校验
   （注意该报告记录过一批**损坏的 zip**，别用旧本地副本）。
3. **ZipVoice / VITS 模型**：VPS `/root/tts/...` 已有线上副本，见
   [`../../remote-tts-deploy.md`](../../remote-tts-deploy.md) §1。

> 端侧路线的**重启前提**（ORT 上游修掉 OHOS 交叉编译下的动态 shape bug）见
> [`README.md`](./README.md) §2 末。在此之前不要按本清单恢复端侧环境。
