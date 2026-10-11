# TTS-P6 报告 — ZipVoice 端侧离线听书最小打通（真机）

日期：2026-09-30
分支：`tts/mac-p0`（worktree `/Users/lichtcui/Documents/playground/source-reader-tts`）
对应计划：[`TTS-PLAN.md`](TTS-PLAN-LOCAL-ONNX.md) §4.3 / §9（Route C：sherpa-onnx ZipVoice）
结论：**P6 全部验收通过**。用 sherpa-onnx ZipVoice（distill-int8 zh-en-emilia）+ 流萤参考音频，
在鸿蒙真机上端侧零样本合成出声，端侧 RTF ≈ 0.49–0.54（num-steps=2 / numThreads=4）。

> 本文件的定位：**最小打通交付证据**。目标是「证明 Route C 在真机可跑、可出声、RTF 达标」，
> **不接听书页、不动 M5 完整链路**。接 M5 听书页是下一步（见 `docs/handoff/HANDOFF-S10.md`）。

---

## 1. 验收结果（HBN-AL80 / 麒麟 9010 / API 24 / arm64-v8a）

| 验收项 | 结果 |
|---|---|
| 合成不崩 | ✅ 连续 2 次无崩溃 |
| samples 非空 | ✅ 412928 采样（17.21s @ 24kHz，两次一致） |
| 采样率 | ✅ 24000 |
| 端侧 RTF | ✅ 第 1 次 **0.536**（9.22s，含预热）/ 第 2 次 **0.490**（8.43s） |
| 出声 | ✅ `AudioRenderer` 24000Hz S16LE 起播（状态「合成完成，开始播放」） |
| 参考音频 | ✅ ref 81096 采样（324384B f32le，3.379s @ 24kHz） |

对照 Mac 同档基准（`TTS-PLAN.md` §4.5/§9）：ns2+t4 → 0.354、ns4+t4 → 0.616。真机 0.49–0.54
落在两者之间且 **< 1.0（快于实时）**，满足「端侧离线点开即听」。

**最关键不确定点已消除**：`liblegado_core` 无关，本任务依赖的 `sherpa-onnx v1.13.8` `.har`
底层 C++ **确实编了 ZipVoice**——`init-tts-done` 正常返回，encoder/decoder/vocoder（vocos 24kHz）
全部从 rawfile 加载成功，espeak-ng-data 从沙箱加载成功。

---

## 2. 关键决策（本轮拍板，可继承）

| 项 | 决策 |
|---|---|
| 引擎 | sherpa-onnx **v1.13.8** `.har`（registry 最高只到 1.13.3，故走**本地 file 依赖**） |
| 模型路径 | encoder/decoder/vocoder/tokens/lexicon → **rawfile**（经 `resourceManager` 读）；`espeak-ng-data`（需目录遍历）→ **拷沙箱**，`dataDir` 填沙箱绝对路径 |
| 参考音频 | `ref_zhongli.wav`(44.1k) 预转 `ref.f32`(24k mono f32le) 打 rawfile，规避 ArkTS 侧 WAV 解析 |
| 参数 | numSteps=2、numThreads=4、debug=true；`generateAsyncWithConfig` **整句非流式** |
| 入口 | 独立测试页 `ZipVoiceTest.ets`，设置 →「ZipVoice 离线听书测试」，**不复用 M5 TtsController** |
| 播放 | `audio.AudioRenderer` 24000Hz mono S16LE（Float32→Int16 转换） |

`OfflineTtsZipvoiceModelConfig` 字段：`tokens` / `encoder` / `decoder` / `vocoder` / `lexicon` /
`dataDir`（其余 featScale/tShift/targetRms/guidanceScale 走默认）。`TtsGenerationConfig` 设
`referenceAudio`(Float32Array) / `referenceSampleRate=24000` / `referenceText` / `numSteps=2`。

## 3. 关键坑（照抄可复现，勿再踩）

1. **`.har` 是 gzip 压缩的 tar**（非标准 zip）——但 `ohpm install file:./libs/sherpa_onnx-v1.13.8.har`
   正常识别，已装好。**registry `ohpm.openharmony.cn` 只有 1.13.3，无 ZipVoice**，必须走本地 file 依赖。
2. **ArkTS 严格模式 `arkts-no-untyped-obj-literals`**：`postMessage({...})` 直接传无类型字面量会编译失败；
   统一改成 `const msg: Record<string, Object> = {...}; postMessage(msg)`。
3. **espeak-ng-data 实际 355 个文件**（非 122），且含嵌套 `lang/`、`voices/` 子目录——需用官方
   `listRawfileDir` **递归**处理（`copyRawFileDirToSandbox` 里按 `/` 拆 `src` 递归 `mkdir`）。
4. **`getRawFileContentSync` 返回的 `Uint8Array.buffer` 可能带 padding**——`readRefAudio` 里
   用 `bytes.buffer.slice(byteOffset, byteOffset + byteLength)` 精确切出再 `new Float32Array`。
5. **OHOS C++ 路径已确认**：`SherpaOnnxCreateOfflineTtsOHOS(config, mgr)` 非空 `mgr` 时跳过 `Validate()`；
   model 文件走 `ReadFile(mgr, ...)`（rawfile），`data_dir` 走文件系统——所以「model 塞 rawfile、
   espeak-ng-data 拷沙箱」方案成立（这也是 init 能成功的前提）。

## 4. 改动清单（本分支未 commit）

```
entry/oh-package.json5                             + sherpa_onnx 本地 file: 依赖
entry/src/main/resources/rawfile/zipvoice/          模型(encoder/decoder/tokens/lexicon/vocoder/
                                                    espeak-ng-data 355 文件) + ref.f32，共约 196M
entry/src/main/ets/workers/ZipVoiceTtsWorker.ets    新建（init-tts / tts-generate 两消息协议）
entry/src/main/ets/pages/ZipVoiceTest.ets           新建（worker + AudioRenderer 播放 + RTF 显示）
entry/src/main/ets/common/Const.ets                 + ROUTE_ZIPVOICE_TEST
entry/src/main/ets/pages/Index.ets                  + NavDestination 分支 + onSettingsNavigate 路由
entry/src/main/ets/pages/Settings.ets               设置 →「ZipVoice 离线听书测试」入口
```

模型本地源目录：`~/Documents/playground/tts/p5-zipvoice/sherpa-onnx-zipvoice-distill-int8-zh-en-emilia/`；
vocoder 在其上一级 `p5-zipvoice/vocos_24khz.onnx`；参考音频原文件
`~/Documents/playground/tts/models/v2ProPlus/流萤/ref_zhongli.wav`。

## 5. 构建 / 安装 / 验证命令（复现用）

```bash
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:$PATH"
cd /Users/lichtcui/Documents/playground/source-reader-tts
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon

HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
$HDC install -r entry/build/default/outputs/default/entry-default-signed.hap
$HDC shell aa force-stop com.lichtcui.sourcereader
$HDC shell aa start -a EntryAbility -b com.lichtcui.sourcereader
$HDC shell hilog -x | grep ZipVoiceTts
# 进 设置 → 「ZipVoice 离线听书测试」→ 点「生成并播放」；观察 init-tts-done / tts-generate-done
```

## 6. 遗留 / 下一步（本轮明确不做）

- **流式 chunk**：当前 `generateAsyncWithConfig` 整句出 PCM，接听书页时再切流式（官方有 `StreamingTtsWorker`）。
- **多音色 ref 注入**：当前只写死 `流萤/ref_zhongli.wav` 一个参考音频。
- **release 混淆**：debug 构建无混淆；release 需在 `entry/obfuscation-rules.txt` 加
  `-keep-property-name`（sherpa_onnx 属性名 `encoder`/`decoder`/… + 新增 JSON 字段）。
- 接 M5 听书页的完整方案见 `docs/handoff/HANDOFF-S10.md`。