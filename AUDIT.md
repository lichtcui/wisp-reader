# AUDIT.md — 跨模块 Bug 修复服务审计

> 范围：只读审计（Gate A），**未修改任何代码/配置**。
> 目标项目：`source-reader`（HarmonyOS NEXT / ArkTS + ArkUI，兼容 Legado 书源）。
> 审计时点：HEAD `b02e223` (`feat: M5 listening...`)，分支 `master`，工作区干净（0 dirty）。
> 证据以文件、命令输出、用户提供结果为准；构建成功 ≠ 运行时验证。

---

## 1. Current state（现状）

### 1.1 仓库 / 构建清单

| 项 | 值 |
|---|---|
| Git root | `source-reader/`（与目标一致） |
| 分支 / HEAD | `master` / `b02e223` |
| 变更状态 | `git status --short` 为空（0 staged / 0 dirty / 0 untracked） |
| 最近提交 | `b02e223` M5 → `64af768` 阅读页整改 → `2f233e1` init → `0879734` init |
| 模块 | 单 `entry` 模块（`entry/src/main/module.json5`），`AppScope` + `rust/{legado-engine,legado-core}` |
| 权限 | `INTERNET`、`KEEP_BACKGROUND_RUNNING`；`backgroundModes: ["audioPlayback"]` |
| signingConfigs | 存在 1 组（含凭据，**未打印/未检查敏感字段**） |
| bundle | `com.lichtcui.sourcereader`（仓库内公开，非凭据） |
| 构建入口 | `hvigorw assembleHap --mode module -p product=default -p buildMode=debug` |

### 1.2 里程碑（来自 `docs/progress.md`）

M0–M5 均标注「✅ 真机验证」；**M6（调试器 + 缓存清理 + 备份恢复）⏳ 未开始**。v1 明确不做 JS 运行时/换源/发现/真分页/在线 TTS。

### 1.3 项目结构扫描 → 模块目录对照

| 模块 | 主要文件 | 备注 |
|---|---|---|
| **书架** | `pages/Shelf.ets`、`model/ShelfRepository.ets`、`model/LocalBook.ets`（导入）、`common/Format.ets`、`components/BookCover.ets` | 宫格/列表双视图、进度三态、本地 TXT、听书 FAB |
| **搜索** | `pages/Search.ets`、`pages/SearchResult.ets`、`engine/BookEngineNapi.ets`、`model/SourceRepository.ets` | 逐源并发渐进聚合 + 同名同作者跨源合并 + `bookInfo` 补全 |
| **阅读** | `pages/Reader.ets`、`common/ChapterDataSource.ets`、`common/ChapterUtil.ets`、`model/ChapterCache.ets`、`model/BookContent.ets` | 竖向滚动、目录浮层、段落高亮/跟随、进度/预取 |
| **听书** | `model/TtsController.ets`（单例）、`pages/Listening.ets`、`pages/ListeningSettings.ets`、`model/BookContent.ets`、`common/ChapterUtil.ets` | TTS PCM → AudioRenderer → AVSession + 后台任务 |
| **书源管理** | `pages/BookSourceManage.ets`、`model/SourceRepository.ets`、`rust/legado-engine/src/gate.rs` | 导入（文件/剪贴板/URL）、启停删、恢复内置、检测 |
| **数据管理** | `model/ShelfRepository.ets`（RDB）、`model/SourceRepository.ets`（prefs）、`model/ChapterCache.ets`、`model/LocalBook.ets`、`pages/Settings.ets` | **清理缓存 / 备份恢复 仍为占位（M6）** |
| 引擎边界 | `engine/IBookEngine.ets`、`engine/types.ets`、`engine/BookEngineNapi.ets`、`rust/legado-core/src/lib.rs` | JSON 字符串进出；`downloadCover` 由 Rust 落盘 |
| 路由/生命周期 | `pages/Index.ets`（`NavPathStack` + `pageMap`）、`entryability/EntryAbility.ets` | 所有 `ROUTE_*` 汇聚点 |

> `docs/bug.md`（progress.md 引用）在 `docs/` 下**不存在**（仅有 architecture/development/engine/progress）。

---

## 2. 缓存层定位

| 缓存 | 位置 | 键 / 失效 | 现状与缺口 |
|---|---|---|---|
| **图片缓存** | `components/BookCover.ets:33` 调 `bookEngine.downloadCover` → Rust `rust/legado-engine/src/runtime.rs:638-659` 写 `ctx.cacheDir/cover_{hash(coverUrl)}.img` | 文件名 = `coverUrl` 的 `DefaultHasher`（确定性） | 落盘确定性命中，但 **ArkTS 侧无读穿**：每次组件 `aboutToAppear` 都重新发起网络下载；同 URL 多组件并发重复下载；**无 PixelMap 内存缓存**；**无占用统计/清理**；`ctx.cacheDir` 可被系统回收 |
| **章节内容缓存** | `model/ChapterCache.ets`：内存 `Map` + `filesDir/chapters/{bookId}_{index}.json` | 键 `bookId#index`，**以 `chapter.url` 校验失效**（`getCachedChapter:51`） | 读路径 `Reader.fetchContent:168`、`BookContent.loadChapterParagraphs:58`；写路径 `putCachedChapter` + 预取 `Reader.prefetch:245-255`。**内存 Map 无上限**（plan §7 要求 LRU ~200MB，未实现）；`hasCachedChapter:92` 无调用方（死代码） |
| **TTS 音频缓存** | `model/TtsController.ets`：`ReqBuffer`（45-55）+ `queue: RenderItem[]`（108-109），`AHEAD=2` 预合成 | 仅内存、随播放消费即弃 | **无任何持久化音频缓存**；每段重新合成；`setVoice` 会关闭并重建引擎（840-877）；`seek` 按字数估算（809-823，非真实时间轴） |
| **本地书缓存** | `model/LocalBook.ets`：`filesDir/local/{bookId}/{book.txt,toc.json}` + `tocCache`(max4)/`textCache`(max2)（29-30、61-69） | 按 `bookId` | 导入后永久驻留；**删除书架书籍不会清理这些文件** |
| **清理缓存统计** | `pages/Settings.ets:82-86` | — | **硬编码 `value: '0 B'`**；点击 `onNavigate('清理缓存')` → `Index.pushPlaceholder`（占位「将在后续里程碑实现」）。`common/Format.ets:48 formatBytes` **已定义但全项目无调用**。**全项目无任何缓存删除/统计实现**（无 `rmdir`/`unlink`/`clearCache`） |

---

## 3. TTS 封装位置与生命周期调用点

**唯一封装**：`model/TtsController.ets` — `@ObservedV2` 单例（`static instance()`，68-75），聚合 TTS 引擎 + PCM 队列 + `AudioRenderer` + `AVSession` + `backgroundTaskManager` + 定时/倍速/音色/进度。

| 生命周期 | 调用点 | 行为 |
|---|---|---|
| 进入听书页 | `pages/Listening.ets:37-50` `aboutToAppear` → `tts.start(...)`（同书已激活则跳过） | 初始化 engine/session/renderer，`beginFrom` |
| 播放推进 | `TtsController.beginFrom:494` → `startBackground:512`；`fill:665` 更新 `paragraphIndex` 并 `persistProgress` | 段落边界即高亮/进度检查点 |
| 暂停/恢复 | `Listening` 播放键 `toggle()`；`pause:725` / `resume:746`；音频焦点中断 `audioInterrupt:270` → `pause` | — |
| 停止 | `Listening.stopAndClose:60` → `stop()`；**`entryability/EntryAbility.ets:18` `onDestroy` → `stop()`** | 释放 renderer/session、停后台任务 |
| 跨章 | `onParagraphEnd:705` → `loadChapter(next)` | 末章结束仅置 `playing=false` + renderer.pause |
| 阅读页集成 | `pages/Reader.ets:330-346` `openListening`；`:551` 底栏入口；`:53-66` `@Monitor('tts.paragraphIndex','tts.chapterIndex')`；`:348-352` `isSpeaking` | 段落高亮 + 跟随滚动 + 跨章同步 |
| 书架集成 | `pages/Shelf.ets:95-120` FAB（`tts.active` 驱动）→ `onOpenListening()`（无参，恢复既有会话） | — |
| 路由 | `pages/Index.ets:187-195` `ROUTE_LISTENING` / `:181-186` `ROUTE_LISTENING_SETTINGS` | — |
| 设置项 | `pages/ListeningSettings.ets` 读写 `KEY_TTS_SPEED` / `KEY_TTS_VOICE`（`common/Const.ets:29-35`） | — |

**生命周期缺口（详见 §4 R2/R6）**：`stopBackground()` 只在 `stop():203` 调用；自然播完（`onParagraphEnd:705-721`）与 `pause():725-744` 均不停后台任务；单例 `shared` 在 UIAbility 销毁后不重置，`ctx`/`book`/`engine` 残留。

---

## 4. Risks（按影响排序，均有证据）

| # | 级别 | 跨模块 | 问题 | 证据 |
|---|---|---|---|---|
| **R1** | 高 | 阅读 ↔ 听书 | **跨书串扰 / 进度污染**：`Reader.onTtsProgress` 与 `isSpeaking` 只比较 `chapterIndex/paragraphIndex`，**不校验 `bookId`**。听书 A 时打开书籍 B 的阅读页，会把 B 的章节跳到 A 的 `chapterIndex`，并把 B 的进度写成 A 的章节号。 | `Reader.ets:53-66`、`:348-352`、`:257-271`（`persistProgress`） |
| **R2** | 高 | 听书 ↔ 后台任务 | **长时任务泄漏**：自然播完（末章）或 `pause()` 后 `playing=false` 但 `backgroundTaskManager` 的 `AUDIO_PLAYBACK` 任务未停止（`stopBackground` 仅在 `stop()` 调用），后台任务/通知常驻。 | `TtsController.ets:203` vs `:705-721`、`:725-744`、`:429-437` |
| **R3** | 中 | 阅读 ↔ 听书 ↔ 数据 | **进度写竞争**：阅读页滚动停（`onScrollStop`）与 TTS 段落切换都会写同一 `progress` 行，无归属/`updatedAt` 守卫，互相覆盖。 | `Reader.ets:762-764`+`:257`、`TtsController.ets:973-987`、`ShelfRepository.ets:130-145` |
| **R4** | 中 | 阅读/书架/搜索 ↔ 图片缓存 | **封面无读穿/无去重/无统计**：`BookCover.load` 每次都网络下载（磁盘文件已存在也不用），同 URL 多组件并发重复下载；无 PixelMap 缓存；无占用统计。 | `BookCover.ets:22-39`、`runtime.rs:653-658` |
| **R5** | 中 | 数据管理 ↔ 书架/阅读 | **数据管理未实现致缓存不可控**：清理缓存写死 `'0 B'` 且路由到占位页；**无任何清缓存 API**；`removeBook` 只删 DB，遗留 `filesDir/chapters` 与 `filesDir/local` 孤儿文件；plan §7 的 LRU/200MB 未落地。 | `Settings.ets:82-86`、`Index.ets:62-64`+`:233-247`、`ShelfRepository.ets:80-87`、`plan.md:270-271` |
| **R6** | 中 | 听书 ↔ Ability 生命周期 | **单例不重置 / 引擎不释放**：`onDestroy` 调 `stop()` 但不清 `TtsController.shared`，也不 `engine.shutdown()`；UIAbility 重建后可能复用已失效 `ctx`。 | `EntryAbility.ets:17-20`、`TtsController.ets:68-75`、`:190-212` |
| **R7** | 低 | 阅读 ↔ 听书 | **段落切分重复实现**：`BookContent.sanitize`（TTS 用）与 `Reader.sanitize` 为两份相同逻辑；若一方改动，段落索引错位 → 高亮/进度错位。 | `BookContent.ets:12-37`、`Reader.ets:185-210` |
| **R8** | 低 | 数据/阅读 | **章节内存缓存无上限**（`ChapterCache` 内存 `Map` 只增不减）；`hasCachedChapter` 死代码。 | `ChapterCache.ets:18,92-94` |
| **R9** | 低 | 搜索 ↔ 引擎边界 | `BookEngineNapi.search` 丢弃 `opts.concurrency`，只传 `timeoutMs`。 | `BookEngineNapi.ets:19-24`、`IBookEngine.ets` |
| **R10** | 低 | 数据 ↔ 书架/阅读 | `ShelfRepository` 无懒初始化：`initShelf` 仅书架页调用；若在书架 Tab 初始化前触发 `saveProgress`/`getProgress`，`store===undefined` 时**静默丢写**。 | `ShelfRepository.ets:20-32,130-134`、`Shelf.ets:42` |

---

## 5. 构建验证

命令（按 `AGENTS.md` §4）：

```
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:$PATH"
hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

结果：**✅ BUILD SUCCESSFUL in 3 s 7 ms**（33 tasks：14 executed / 19 up-to-date）；**0 error / 0 warn**；退出码 0；
产物 `entry/build/default/outputs/default/entry-default-signed.hap` 存在，5,796,434 bytes（≈5.5 MB）。

> 限制：为**增量构建**（19 up-to-date），非 clean build；native `.so` 未重编（本次为 ArkTS 产物）；**构建通过不代表运行时/真机验证**。

---

## 6. Unknowns（未确立事实及原因）

1. **未做 clean 构建**：本次复用增量缓存，未验证冷构建可复现。
2. **Rust/`.so` 未重编、未跑 `cargo test`**：本次审计未触碰 Rust，引擎行为以既有 54 项主机测试记录为准，未复验。
3. **运行时未验证**：`AUDIT.md` 的所有「缺口」为静态代码证据，未在真机复现（R1/R2/R3 建议真机复现后再修）。
4. **签名配置未检查**：按审计规范仅确认存在 1 组 `signingConfigs`，未读取/未打印凭据。
5. **`nextTocUrl` 多页目录 / `isVolume` 卷**：progress.md 标注真机未覆盖，未知。
6. **release 混淆**：`entry/obfuscation-rules.txt` 已包含 TTS/缓存相关字段的 `-keep-property-name`，但未在 release 包运行时验证。
7. **`docs/bug.md` 缺失**：progress.md 引用但文件不存在，历史 bug 清单无法核对。

---

## 7. Proposed minimal next action（单一最小动作）

**只修 R1（高影响、边界清晰）**：在 `pages/Reader.ets` 的 `@Monitor('tts.paragraphIndex','tts.chapterIndex')`（`:53`）与 `isSpeaking`（`:348`）中加入**书籍身份守卫**——仅当 `this.tts.isActiveFor(this.book.bookId)`（或 `tts.currentBook()?.bookId === this.book.bookId`）时才滚动/高亮，避免听 A 读 B 时串章与进度污染。

- **需要授权**：进入 Gate B（修改授权）。本审计**未改任何代码**。
- **验证边界**：ArkTS 改动 → 走 `AGENTS.md` §4 ②③（编译 → 安装 → 重启 → 观察），真机复现「听 A 时打开 B，B 不跳章、B 进度不被改写」。
- **不要**在同一改动里顺手修 R2/R3 或重构（保持最小范围）。
- 若需环境/构建失败处置 → 转 **Build Doctor**；若做发布前候选验证 → 转 **Release Check**。