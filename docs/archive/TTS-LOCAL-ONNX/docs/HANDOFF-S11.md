# HANDOFF-S11 — ZipVoice 接入听书页（②③）完成；① 流式结论修正

日期：2026-10-01
分支：`tts/mac-p0`（worktree `/Users/lichtcui/Documents/playground/source-reader-tts`）
前序：见 [`HANDOFF-S10.md`](HANDOFF-S10-tts-branch.md)（P6 打通）与 [`tts-p6-report.md`](tts-p6-report.md)

## 1. 结论速览

| 优先级 | 状态 | 结果 |
|---|---|---|
| ① 流式 chunk 化 | ❌ **不成立（路线修正）** | `generateAsyncWithCallback` 在本 NAPI 绑定里不存在；`TtsInputWithConfig.callback` 是单发 + 缓冲长度错误 |
| ② 接听书可选引擎 | ✅ 真机验证 | ZipVoice 端到端：合成→播放→AVSession→段落高亮→进度回写→参考音色显示 |
| ③ 多 ref 音色 | ✅ 真机验证 | 流萤/花火/卡芙卡 3 个 ref.f32，`tts-generate` 带 `refId` |

## 2. ① 的关键修正（勿再返工）

交接面（S10）写的「用 `generateAsyncWithCallback` 逐 chunk」**前提是错的**：

- 本 NAPI `libsherpa_onnx.so` 只导出 `offlineTtsGenerate(WithConfig)` 四个函数，**没有** callback 版本。
- 真正暴露的是 `TtsInputWithConfig.callback`（`(data:{samples:Float32Array, progress:number})=>number`），
  底层走 `SherpaOnnxOfflineTtsGenerateWithConfig(..., progress_cb, ...)`。
- **实测两点致命**：
  1. ZipVoice（flow-matching + vocos）**一次回调就是整段音频**，`chunk#1` 后再无 chunk——无首包延迟收益。
  2. 回调的 `data.samples.length` 是**固定缓冲长度 412928**（与 P6 的「412928 采样」巧合一致），
     而真实输出 `out.samples.length` 本跑是 254608——`length` 不可信，`Float32Array.from` 会带上尾部垃圾。
- **结论**：已回退为整句 `generateAsyncWithConfig`（可靠 `out.samples`）。听书页的首包延迟由
  **按段落合成**（每段一个独立 `tts-generate`，段落天然短）兜住——这正是 ② 的实现方式。

## 3. 改动清单（本分支未 commit）

```
entry/src/main/ets/workers/ZipVoiceTtsWorker.ets     + refId 注册表(REFS/RefSpec) + 初始化预载 3 ref + tts-generate/tts-generate-done 带 requestId+samples
entry/src/main/ets/pages/ZipVoiceTest.ets            测试页（整句合成+queue 播放；不改动生产路径）
entry/src/main/ets/model/TtsController.ets           + engineKind/refId(@Trace) + ensureZipEngine/onZipMessage/onZipComplete/f32ToS16/ensureZipSynthesized/setRef
entry/src/main/ets/pages/ListeningSettings.ets       + 引擎开关(系统TTS/ZipVoice) + ZipVoice 参考音色选择
entry/src/main/ets/pages/Listening.ets               voiceRow/voiceMenuItems 按引擎切换（参考音色 vs 系统音色）
entry/src/main/ets/common/Const.ets                  + KEY_TTS_ENGINE / TTS_ENGINE_* / KEY_TTS_REF / TTS_REF_OPTIONS
entry/src/main/resources/rawfile/zipvoice/refs/       ref.f32 → refs/{liuying,huahuo,kafuka}.f32（花火/卡芙卡用 ffmpeg 转 24k mono f32le）
```

## 4. 关键坑（继承 S10 + 新增）

- （继承）`.har` 本地 file 依赖、espeak-ng-data 递归拷、ref.f32 slice 去 padding、`Record<string,Object>` postMessage——见 S10。
- **新增①**：`TtsController` 的 `fill`/`ReqBuffer`/`enqueueParagraph` 管线是「字节队列」，ZipVoice 走
  `f32ToS16(Float32Array)` 转 S16LE 后复用同一管线（渲染器采样率按引擎 24000/16000 切，`usage` 仍 `STREAM_USAGE_AUDIOBOOK` 保锁屏卡）。
- **新增②（真机风险，非代码 bug）**：偶发 native **SIGSEGV(signal 11)** 在 worker 的 `generateAsyncWithConfig`，
  以及更早的 **SIGKILL(signal 9, RSS_THRESHOLD_KILLER/OOM)**。两者都指向 sherpa-onnx(196MB distill 模型)+onnxruntime 在
  本机（麒麟 9010，后台 App 多、内存吃紧时的长时间 thrash）上的稳定性边界。**闭环比对**：同一代码 00:02 `play para=1`
  成功、00:08/00:10 sigsegv、00:11 `begin para=6` 恢复——非常规复现。若后续要稳，方向：换更小模型/vocoder、numSteps 降到 1、
  `debug=false` 减日志压力、或保底回系统 TTS；再不行在生成前清后台/重试。

## 5. 构建 / 验证（复现）

```bash
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:$PATH"
cd /Users/lichtcui/Documents/playground/source-reader-tts
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
$HDC install -r entry/build/default/outputs/default/entry-default-signed.hap
$HDC shell aa force-stop com.lichtcui.sourcereader && $HDC shell aa start -a EntryAbility -b com.lichtcui.sourcereader
# 设置→听书设置：引擎选「ZipVoice 离线」+ 参考音色；书架→书→阅读页底栏「听书」→ 观察 hilog grep SourceReaderTts / ZipVoiceTts
```

## 6. 遗留（下一步可选）

- release 混淆（S10 §4 ④ 仍未做）：`entry/obfuscation-rules.txt` 加 sherpa_onnx 属性名 + 新增 JSON 字段的 `-keep-property-name`。
- ZipVoice 语速倍速：当前 `speed=1.0`（`setSpeed` 只对系统 TTS 生效；听书设置已注明）。
- 偶发 native SIGSEGV/SIGKILL：见 §4 新增②。