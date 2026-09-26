# HANDOFF-S5 — 听书模块逐项修复（A–E）

日期：2026-09-26
范围：**仅听书模块**（`model/TtsController.ets` 为主线，含 `pages/Listening.ets`、书架 / 阅读页浮动入口）。
基线：`0eb1e1c`（S4 收尾）。HEAD：`1131008`。
约束履行：A、B 各自单独 commit；D 吸附动画复用 `UI-SPEC.md` 的 `260ms / Curve.FastOutSlowIn`；E 只改听书传输控制，未联动阅读模块 E 项。

> 构建：`assembleHap` 通过（7 个 commit 均编译绿灯）。
> **真机验证已完成**（设备 `33Z0224424136564`，先遇锁屏 `10106102`，解锁后跑通），逐项结果见 §5。
> 验证期发现浮动按钮「容器未挂载」缺陷，已追加 commit `ad136e7` 修正。

---

## 0. 调查来源

- A 项根因来自 `ROOT-CAUSE.md` §3-A（只读调查，未改码）。
- B 项由 `@general` 只读复核报告独立给出（复核确认 ROOT-CAUSE §3-B 成立，并补全三处可执行细节）。
  其关键 API 结论：`person` 只能在 `createEngine` 时确定（无法运行时切音色，重建不可避免）；
  `speed` 是每次 `speak()` 的 `extraParams`（改速**不需要**重建/重合成）；`flush()` 会重置播放位置。

---

## 1. 变更清单（按项）

### A. 进度条跳跃（commit `1fa17cd`）

**根因**（ROOT-CAUSE §3-A）：进度取「写入渲染器」位置而非「实际播放帧」。`fill()`（`writeData` 回调）
一写入就设 `paragraphIndex`，而 AudioRenderer 预缓冲使写入领先可听播放一个缓冲区 → 进度/高亮跳到还没听到的段；
时间估算纯按字数（`chars / (5.0 * speed)`），段内不推进、跨段突跳；AVSession 位置同源且只在段边界刷新。

**实现**：
- `TtsController.ets`：新增 `ParagraphTiming` 时间轴。每段在 `enqueueParagraph` 时按**合成 PCM 字节长度**
  （`bytes / 32000 = ms`，与 M5 实测「段落字节/32000 ≈ 实测时长」一致）登记 `[startMs, endMs)`。
- 新增 200ms `tickProgress()`：用 `renderer.getAudioTimestampInfoSync().framePos`（失败回退墙钟）换算已播毫秒，
  再由时间轴解析**当前真正在播的段落**，写回 `paragraphIndex` / `currentIndex` 与新增 `@Trace elapsedMs`。
- `fill()` 回调**只搬 PCM 字节**，删除了写进度的代码（回调不再碰 DB / AVSession）。
- AVSession `elapsedTime` 改用 `elapsedMs`，并在 tick 内节流到 **1s** 刷新一次；`persistProgress` 同样节流。
- `pages/Listening.ets`：时间读数改用 `tts.elapsedMs`（播放时钟，200ms 插值）。

**验证**：静态 + 编译；真机未完成（见 §5）。段落滑块仍为整段粒度（离散推进），
时间读数连续推进；总时长仍是字数估算（见 §6 遗留）。

### B. 暂停恢复 / 改语速 / 换音色卡顿（commit `54a37d2`，加固 `1131008`）

**根因**（`@general` 复核）：
1. `pause()` 用 `resetQueues()` 清掉已合成 PCM（真正的卡顿主因）；`resume()` 走 `beginFrom` →
   停引擎 + 重清队列 + 整段重合成 + `startRenderer` 的 `pause→flush→start`（制造 underrun）。
2. `setSpeed()` 调 `beginFrom(currentIndex)` 整段重合成——但 `speed` 只是 `speak()` 参数，毫无必要。
3. `setVoice()` 先 `pause()` → `shutdown()` → **固定 120ms 死等** → 串行 `createEngine` → `resume()` 重合成；
   且 `async` 未 await + `creating` 守卫导致连点静默失败。

**实现**（均在 `TtsController.ets`）：
- 新增 `clearInflight()`：只丢弃未 flush 的在途请求，**保留** `queue` / `timeline` / `queueOffset`。
- `pause()`：`clearInflight()` 取代 `resetQueues()`；保留已缓冲音频与时间轴。
- `resume()`：快路径——`playing=true` + 续发合成 + `renderer.start()`（**不** pause/flush），
  从停顿处续播；渲染器缺失才回退 `beginFrom`。`1131008` 再补 `start()` 失败重试（防与未完成的 pause 竞争）。
- `setSpeed()`：删除 `beginFrom`；只 `engine.stop()` + `clearInflight()` + `ensureSynthesized()`，
  新语速作用于后续段，已缓冲音频不中断。
- `setVoice()`：去掉固定 120ms；**先建新引擎、后关旧引擎**，全程不停播；新增 `voiceSwitching` 串行化。

**验证**：静态 + 编译；真机未完成（见 §5）。

### C. 听书目录改 `BottomDrawer`（commit `acd3947`）

**实现**：`pages/Listening.ets` 删除一次性 `bindSheet` 目录，改用与阅读模块同一组件
`ui/common/BottomDrawer.ets`（`mode:'overlay'`、`sheetSize:'large'`、`title:'目录'`），
内容用**尾随 builder** `BottomDrawer({...}) { this.tocContent() }`（沿用 S4 的 V2 `@BuilderParam` 防崩溃写法）；
页面根由 `Column` 改为 `Stack` 以承载 overlay。章节点击 → 关闭抽屉 + `jumpChapter`。

### D. 浮动按钮（commit `c6fb27d`）

**实现**：新增 `ui/common/FloatingListenButton.ets`（`@ComponentV2`）：
- 悬浮右侧，`PanGesture` 跟随手指拖动，位置钳制在父容器内；
- 拖动结束后**空闲 2500ms** 用 `animateTo({ duration: 260, curve: Curve.FastOutSlowIn })` 向右吸附
  （时长/曲线复用 `UI-SPEC.md` §1.3「overlay 抽屉打开」参数）；
- 根 `Stack` 满尺寸但 `hitTestBehavior(HitTestMode.None)`，空白区不拦截下层触控，仅气泡消费触摸；
- 首帧位置 = 右缘、纵向约 55%。

接入：
- `pages/Shelf.ets`：替换原静态 `listenFab()`，`tts.active` 时显示；可拖动 + 吸附。
- `pages/Reader.ets`：`tts.active` 时显示（位于抽屉之下，抽屉遮罩可覆盖）；点击经新增
  `@Event onOpenListening` → `Index.openListening()`（**无参** push，保留当前 TTS 会话与书目，避免跨书误重启）。

### E. 上一章 / 下一章改真正章节跳转（commit `af1cf49`）

**现状**：传输按钮与 AVSession `playNext/playPrevious` 调 `next()/prev()`，原实现只 `beginFrom(currentIndex±1)`
（约 5 秒一个段落），仅到章末才换章。

**实现**：`TtsController.next()/prev()` 改为 `nextReadable/prevReadable(chapters, chapterIndex)` 直接
`loadChapter(..., false, this.playing)`（保留播放/暂停态，跳到相邻可读章开首）。UI 与锁屏媒体键同步生效；
`prev` 不再落到上一章末尾。与阅读模块 E 项（正倒序）无关。

---

## 2. 每项 commit 对照

| 项 | commit | 说明 |
|---|---|---|
| A | `1fa17cd` | 音频时钟驱动进度；回调只搬 PCM；AVSession/DB 节流 |
| B | `54a37d2` + **`1131008`** | 暂停续播、改速不重合成、换音色先建后关；**加固 resume 重试** |
| C | `acd3947` | 听书目录 → `BottomDrawer` overlay |
| D | `c6fb27d` + **`ad136e7`** | 浮动听书按钮（拖动/吸附/书架+阅读页）；**修正：先挂载容器再测量** |
| E | `af1cf49` | 上一章/下一章真章节跳转 |

## 3. 关键文件

- `entry/src/main/ets/model/TtsController.ets`（A/B/E）
- `entry/src/main/ets/pages/Listening.ets`（A/C，prev/next 绑定复用 E）
- `entry/src/main/ets/ui/common/FloatingListenButton.ets`（D，新增）
- `entry/src/main/ets/pages/Shelf.ets`、`pages/Reader.ets`、`pages/Index.ets`（D）

## 4. 构建命令

```bash
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:$PATH"
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
# 结果：BUILD SUCCESSFUL（仅既有 ArkTS 警告：音频 API 的 syscap 提示、函数可能抛异常提示）
```

## 5. 真机验证结果

测试书《测试书》（本地 3 章，章节时长 ≈3s），`hilog` tag `SourceReaderTts`。

| 项 | 结果 | 依据 |
|---|---|---|
| A 进度 | ✅ | `begin para=0` → `play para=1`（+2.2s）→ `play para=2`（+5.2s），与 PCM 时长一致，**无写入侧提前跳段**；时间读数 `00:05`→`00:06` 连续递增 |
| B 卡顿 | ✅ | 暂停/恢复只在日志出现 `pause` / `resume`，**无 `begin para=`**（未重合成/未从段首重播）；语速 1.2x→2.0x 无 pause/begin；音色 13→21→13 仅 `engine ready voice=21/13`，全程不停播 |
| C 抽屉 | ✅ | 点列表图标：全屏遮罩 `#52000000` + 标题 `目录` + 章节 `第一章/第二章/第三章`，与阅读页同一 `BottomDrawer` overlay |
| D 浮动按钮 | ✅ | 阅读页气泡 `[1031,1570]`→拖动到 `[366,1570]`→空闲约 2.5s 吸附回 `[1030,1570]`；点击回到听书页。书架气泡 `[1031,1650]`→拖动 `[216,1649]`→吸附 `[1030,1649]` |
| E 章节跳转 | ✅ | 听书页「上一章」`第三章 归途`→`第二章 相遇`，「下一章」→`第三章 归途` |

恢复现场：语速已还原 `1.0x`、音色已还原 `聆小珊（女声）`；验证后 `aa force-stop` 结束听书后台任务。

（过程记录：首次 `aa start` 因锁屏报 `10106102 ... cannot be unlocked automatically`，解锁后重试成功。）

## 6. 遗留问题 / 已知风险

1. **`getAudioTimestampInfoSync` 为 API 19**：`compatibleSdkVersion 5.0.0(12)`，API 12–18 设备上该方法不存在，
   已用 `try/catch` 回退到墙钟估算，不会崩溃；但**低版本设备进度精度退化为墙钟**。目标机 API 24 无此问题。
2. **总时长仍是字数估算**（`CHARS_PER_SECOND=5.0`），未随 PCM 时间轴校正；段落滑块为整段粒度。
   `elapsedMs`（音频时钟）与 `estimateDurationMs`（字数）口径不同，极端文本下滑块到头/总时长可能略有偏差。
3. **暂停续播的音频时钟**：若 pause 与 resume 之间渲染器被系统路由变化重置，`framePos` 会从 0 重新计，
   而时间轴未重置 → 段落映射可能短暂偏差；目前未做路由变化监听（`audioInterrupt` 只处理 pause/stop）。
4. **`onParagraphEnd` 仍是写入侧触发**：章末切章由 end 标记（写入领先）驱动，最多提前一个缓冲区；
   进度/高亮本身已由音频时钟驱动，两者在章末可能有亚秒级不一致。
5. **跨书串扰（T-CROSS-1）未处理**：`Reader.onTtsProgress` / `isSpeaking` 仍无 `bookId` 守卫；
   阅读页浮动按钮已用**无参** `openListening()` 规避「点一下把 TTS 切到当前书」，但监听中的跨书滚动仍是原缺陷。
6. **后台任务泄漏（T-CROSS-2）未处理**：`pause()` 仍未 `stopBackground()`；本轮未纳入。
7. **文档未提交**：`AUDIT.md` / `ROOT-CAUSE.md` / `TASKS.md` / `UI-SPEC.md` / `HANDOFF-S3.md` / `HANDOFF-S4.md`
   及本文件仍 untracked；`AGENTS.md` / `docs/progress.md` 的改动来自并行 TTS 调研工作流，本轮未纳入。