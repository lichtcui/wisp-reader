# 已封存：端侧自建音色 TTS（Route C，分支 `tts/mac-p0`）

> **状态：已废弃封存（2026-10-12 清理）。当前方案是「远端 VPS TTS + 系统 TTS 兜底」，
> 见 [`../../research/TTS-PLAN.md`](../../research/TTS-PLAN.md)、
> [`../../research/TTS-ENGINE-COMPARISON.md`](../../research/TTS-ENGINE-COMPARISON.md)、
> [`../../remote-tts-deploy.md`](../../remote-tts-deploy.md)。**
>
> 本目录只是**历史证据**，不是可执行方案。除「重启端侧路线」外，日常开发不需要读。

## 1. 为什么封存（一句话）

端侧跑神经声码器在鸿蒙上是**死路**：`sherpa-onnx ZipVoice` 已在真机出声且 RTF 0.49–0.54（快于实时），
但**通过 OHOS 交叉编译的 ORT 对一切动态 shape 输出的 `GetShape()` 返回 ~4× 虚高帧数**
（mel 1614 帧 vs 正确 400 帧）⇒ 波形全 NaN / 电流声。升级 ORT（1.16.3 与 1.24.4 同病）、降级、
换 vocoder、换模型四条路全部被同一根因堵死，与 ORT 版本无关。

## 2. 演进链（P0 → P6 → 转远端）

| 阶段 | 做什么 | 结果 |
|---|---|---|
| P0–P3 | GPT-SoVITS → ONNX 导出，Mac 侧量化 / 分段 / 复读检测 | 端侧 RTF **1.483**，慢于实时，不可用 |
| P4 | **自建 ORT 1.24.4 for OHOS arm64** + 真机长稳 60.15 min / 0 崩溃 | ✅ 纯工程成果，非 TTS 结论 |
| P5–P6 | 转 `sherpa-onnx ZipVoice`（distill-int8）+ 参考音频零样本克隆 | ✅ 真机出声，RTF **0.49–0.54** |
| P6+ | 打 `.har` 换自建 ORT 后回归 | ❌ 仍电流声 → 定位到动态 shape 根因 |
| → | 结论「端侧封存」，改走 **VPS 远端合成** | S13 落定 ZipVoice；master 后来换成 **VITS**（v2.0.0） |

根因链的完整证据（含 `VOCOS-FIX` / `ZvDiag` 日志与 Mac 地面真值对照）见
[`docs/TTS-FOLLOWUP-ORT-AND-EXIT-PATHS.md`](./docs/TTS-FOLLOWUP-ORT-AND-EXIT-PATHS.md) §6。

**重启端侧路线的前提**：ORT 上游/社区修掉 OHOS 交叉编译路径下的动态 shape bug（当前无时间表），
或改用不经 `GetShape()` 的第三方运行时。届时应先读上表 P4 的 ORT 构建件（本目录已留脚本）。

## 3. 目录

| 路径 | 内容 | 来源 |
|---|---|---|
| [`docs/TTS-PLAN-LOCAL-ONNX.md`](./docs/TTS-PLAN-LOCAL-ONNX.md) | 该分支的 91KB 权威计划（P0–P6 全量方案） | `source-reader-tts/TTS-PLAN.md` |
| [`docs/tts-p0-report.md`](./docs/tts-p0-report.md) | P0 报告：权重修复、sha256 台账、Mac 基准 | `source-reader-tts/docs/` |
| [`docs/tts-p6-report.md`](./docs/tts-p6-report.md) | P6 报告：ZipVoice 真机最小打通验收 | 同上 |
| [`docs/TTS-FOLLOWUP-ORT-AND-EXIT-PATHS.md`](./docs/TTS-FOLLOWUP-ORT-AND-EXIT-PATHS.md) | ORT 升级/降级/服务器三条出路调研 + **§6 回归推翻结论** | 同上 |
| [`docs/ZIPVOICE-ONNXRUNTIME-DYNAMIC-SHAPE.md`](./docs/ZIPVOICE-ONNXRUNTIME-DYNAMIC-SHAPE.md) | 动态 shape 症状的第一份记录 | 同上 |
| [`docs/TTS-SERVER-REMOTE-SYNTH.md`](./docs/TTS-SERVER-REMOTE-SYNTH.md) | 转远端的第一份方案（ZipVoice on VPS） | 同上 |
| [`docs/HANDOFF-S11.md`](./docs/HANDOFF-S11.md) · [`S12`](./docs/HANDOFF-S12.md) · [`S13`](./docs/HANDOFF-S13.md) | 三个 session 交接（S13 = 远端落定） | 同上 |
| [`app/`](./app) | 端侧 ZipVoice 的 App 侧实现：`ZipVoiceTest.ets`（测试页）+ `ZipVoiceTtsWorker.ets`（worker 协议） | `source-reader-tts/entry/src/main/ets/` |
| [`tools-tts/`](./tools-tts) | `tts_assets.py`：权重 zip 解压校验 / 参考音频裁剪与 staging | `source-reader-tts/tools/tts/` |
| [`harness/`](./harness) | 实验脚手架：`p2`/`p3` Python harness（分段、复读检测、ASR、RTF 测）、`p4` OHOS ORT 构建脚本、`apps/P5-SESSION-PROMPT.md` | `~/Documents/playground/tts/` |
| [`evidence/`](./evidence) | `p2-results` / `p3-results`：测量 JSON 与语义 token dump（报告里的数字出处） | 同上 |
| [`gpt-sovits-onnx-rs/`](./gpt-sovits-onnx-rs) | 上游 Rust ONNX 导出器的 **3 个未推送提交（补丁）+ 未提交改动（diff + 原文件）** | 见其内 `STATE.md` |
| [`MANIFEST.md`](./MANIFEST.md) | 已删除的 40G 实验台清单、关键产物 sha256、恢复路径 | 本次清理生成 |

## 4. 代码历史仍完整（不必从本目录找实现）

分支 **`tts/mac-p0` 保留在 `source-reader.git` 里**（worktree 目录已删）。整棵该分支的代码用：

```bash
cd ~/Documents/playground/source-reader
git log --oneline master..tts/mac-p0        # 10 个提交（worktree 独有）
git show tts/mac-p0:entry/src/main/ets/workers/ZipVoiceTtsWorker.ets
git diff master..tts/mac-p0 -- entry/src/main/ets/model/TtsController.ets
```

注意该分支与 master 已**双向分叉**（master 后来独立把远端 TTS 做完了），**不要 merge**，
只做资料查阅。

## 5. 本次清理删了什么

- `~/Documents/playground/source-reader-tts/`（990MB，git worktree）——已删；分支保留。
- `~/Documents/playground/tts/`（**40G**，无 git 的实验台）——已整体删除；清单与可恢复性见
  [`MANIFEST.md`](./MANIFEST.md)。
