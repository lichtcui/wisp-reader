# HANDOFF-S10 — ZipVoice 端侧 TTS 打通后，接入听书页的接力提示

日期：2026-09-30
分支：`tts/mac-p0`（worktree `/Users/lichtcui/Documents/playground/source-reader-tts`）
交接面：**P6 已完成并真机验证**；下一步是把它接进 M5 听书链路。本文件是给下一个（新 session）agent 的自包含开工提示。

> 新 session 接手顺序：读本文件 → 读 [`docs/tts-p6-report.md`](tts-p6-report.md)（P6 结果/坑）→
> 读 [`TTS-PLAN.md`](TTS-PLAN-LOCAL-ONNX.md) §4.3/§9（Route C 背景）→ 读 [`AGENTS.md`](../../../../AGENTS.md)（环境/命令）。

---

## 1. 我们停在哪（可直接确认）

- **P6 目标已达成**：sherpa-onnx **ZipVoice**（distill-int8 zh-en-emilia）+ 流萤参考音频，在真机端侧零样本
  合成出声。真机 RTF **0.49–0.54**（numSteps=2 / numThreads=4），< 1.0 即快于实时、可「点开即听」。
- 产物是**独立最小验证页**，**未接听书页、未动 M5 TtsController**：
  - 入口：`设置 → 「ZipVoice 离线听书测试」`
  - worker：`entry/src/main/ets/workers/ZipVoiceTtsWorker.ets`（`init-tts` / `tts-generate` 协议）
  - 页面：`entry/src/main/ets/pages/ZipVoiceTest.ets`（worker + 24000Hz S16LE AudioRenderer 播放 + RTF 显示）
- 全部改动**未 commit**。`git status` 里既有 P6 新文件，也有上一轮（codex）的 TTS-PLAN.md/tts-p0-report.md 改动。

## 2. 建议的下一步（按优先级，先做 1

**① 流式 chunk 化（最高优先）**。当前是 `generateAsyncWithConfig` 整句出 PCM——长句「首包延迟」太大，
接听书必须换成 sherpa 官方流式接口（`StreamingTtsWorker.ets`，`generateAsyncWithCallback`，逐 chunk 经
`postMessage` 回传 → 主线程逐块写 AudioRenderer）。这是接听书页的前置。

**② 接 M5 听书页，做成可选引擎**。`model/TtsController.ets` 是 M5 系统 TTS 单例；`pages/Listening.ets` 是全屏听书页。
最小改法：在 `ListeningSettings.ets` 加「引擎：系统 TTS / ZipVoice」开关（默认仍系统 TTS），
选 ZipVoice 时走 `ZipVoiceTtsWorker` 的流式 PCM，其余（AVSession/进度/段落高亮）复用 M5 现有逻辑。

**③ 多参考音频注入**。当前 `ref.f32` 写死「流萤/ref_zhongli.wav」。若要多音色，把多个 ref 转 f32 打 rawfile，
worker 的 `tts-generate` 消息带上 `refId` 选对应 Float32Array（参考音频不变则不用重 init 模型）。

**④ release 混淆**（收尾）。debug 无混淆；release 需在 `entry/obfuscation-rules.txt` 加
`-keep-property-name`（sherpa_onnx 属性名 + 新增 JSON 字段），否则 NAPI 读不到属性。

## 3. 本任务已验证的关键事实（勿再返工确认）

- `.har` 依赖：registry（`ohpm.openharmony.cn`）最高 **1.13.3 无 ZipVoice**，只能本地
  `"sherpa_onnx": "file:./libs/sherpa_onnx-v1.13.8.har"`。该 .har 是 gzip-tar 但 `ohpm install` 正常识别。
- 底层 C++ **已确认编了 ZipVoice**（v1.13.8 `.so`）；`createOfflineTts(config, mgr)` 非空 mgr 跳过 Validate，
  model 走 rawfile、`data_dir`(espeak-ng-data) 走沙箱。
- **API 用法（可直接照抄）**：
  ```ts
  const config = new OfflineTtsConfig();
  config.model.zipvoice.tokens = 'zipvoice/tokens.txt';      // rawfile 相对路径
  config.model.zipvoice.encoder = 'zipvoice/encoder.int8.onnx';
  config.model.zipvoice.decoder = 'zipvoice/decoder.int8.onnx';
  config.model.zipvoice.vocoder = 'zipvoice/vocoder/vocos_24khz.onnx';
  config.model.zipvoice.lexicon = 'zipvoice/lexicon.txt';
  config.model.zipvoice.dataDir = sandboxPath + '/zipvoice/espeak-ng-data'; // 沙箱绝对路径
  config.model.numThreads = 4; config.model.debug = true;
  const tts = new OfflineTts(config, context.resourceManager);
  // 合成：
  const input = new TtsInputWithConfig(); input.text = text;
  const gen = new TtsGenerationConfig();
  gen.referenceAudio = refFloat32Array; gen.referenceSampleRate = 24000;
  gen.referenceText = '…我应该会选择请求猎犬家系停止追捕。'; gen.numSteps = 2;
  input.generationConfig = gen;
  tts.generateAsyncWithConfig(input).then((out) => out.samples /* Float32Array-ish */);
  ```
- **ArkTS 严格模式坑**：`postMessage({...})` 无类型字面量会报 `arkts-no-untyped-obj-literals`，
  必须 `const m: Record<string, Object> = {...}; postMessage(m)`。
- **espeak-ng-data 是 355 个文件且含嵌套 `lang/`、`voices/`**，用 `listRawfileDir` 递归 + `copyRawFileDirToSandbox` 拷贝。
- **ref.f32**（流萤参考音频）已预转 24kHz mono f32le（324384B = 81096 采样），`getRawFileContentSync` 后要
  `bytes.buffer.slice(byteOffset, byteOffset+byteLength)` 再 `new Float32Array`（避免 padding）。

## 4. 环境速查（本机已就绪，勿改动）

```bash
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:$PATH"
cd /Users/lichtcui/Documents/playground/source-reader-tts
# 编译（只改 ArkTS 走这条；本任务不碰 Rust native）
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
$HDC install -r entry/build/default/outputs/default/entry-default-signed.hap
$HDC shell aa force-stop com.lichtcui.sourcereader
$HDC shell aa start -a EntryAbility -b com.lichtcui.sourcereader
$HDC shell hilog -x | grep ZipVoiceTts     # 观察日志
```
- 真机 UDID `33Z0224424136564`；`hdc list targets` 有输出即已连接。
- UI 自动化：`$HDC shell uitest dumpLayout -p /data/local/tmp/l.json -a && $HDC file recv ...`；
  点击 `$HDC shell "uitest uiInput click <x> <y>"`。dump bounds 是物理像素（本机宽 1260）。
- 模型/参考音频源文件在 `~/Documents/playground/tts/p5-zipvoice/...` 与 `~/Documents/playground/tts/models/v2ProPlus/流萤/`。

## 5. 约束（务必遵守）

- **不 commit**（除非明确要求）；主 App 在 `/Users/lichtcui/Documents/playground/source-reader`（**已复原，勿碰**）。
- 本项目根目录只允许文档 + 代码；新增文档落 `docs/`。
- ArkTS 严格模式不用 `any`；新增点语法 JSON 字段同步 `entry/obfuscation-rules.txt`。
- **只改 ArkTS 就跳过 Rust native 重编**；本任务不碰 `rust/`。