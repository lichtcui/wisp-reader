# ROOT-CAUSE.md

只读并行调查汇总（未修改任何源码）。日期：2026-09-25。
格式：每条 = 根因 / 证据（文件:行）/ 最小修复建议 / 风险等级。

---

## 1. 封面延迟（书架 + 阅读目录）— 同一根因

两个现象走同一组件、同一函数：`BookCover`（普通 `@ComponentV2`，无 `@Reusable`，`pixmap` 为实例级 `@Local`）
→ `BookEngineNapi.downloadCover` → Rust `runtime::download_cover`。

- **根因**：`BookCover.load()` 每次无条件走网络，Rust `download_cover` 只写盘、从不读盘判断已存在，
  ArkTS 侧无内存缓存、无磁盘命中检查；TOC 封面随面板销毁/重建，书架 DB 只存 `cover_url` 未存本地路径。
  书架另有放大器：`reload()` 串行 `await getProgress` 阻塞首帧赋值 `entries`。
- **证据**：`entry/src/main/ets/components/BookCover.ets:22-39`（核心 `:33`）、
  `entry/src/main/ets/engine/BookEngineNapi.ets:70-72`、
  `rust/legado-engine/src/runtime.rs:638-660,643-657`、
  `entry/src/main/ets/pages/Shelf.ets:50-58`（fanout `:128,:173`）、
  `entry/src/main/ets/pages/Reader.ets:568-578,803`、
  `entry/src/main/ets/model/ShelfRepository.ets:10,44,68`。
- **最小修复建议**：Rust 在 `fetch` 前用 URL 哈希算出文件名并 `Path::exists` 短路返回；
  `BookCover.load` 加模块级 `Map<coverUrl,PixelMap>` 内存缓存 + `fileIo.accessSync` 磁盘命中；
  TOC 面板改常驻挂载或让 `BookCover` 变 `@Reusable`；`getProgress` 改批量查询。
- **风险等级**：低（纯缓存读取，不改数据语义）。
- **影响面**：`BookDetail.ets:111`、`SearchResult.ets:405`、`Listening.ets:167` 复用同组件，同缺陷会复现。

**结论：A 与 B 同一根因**，修复应落在 `BookCover` / Rust `download_cover` 单点。

---

## 2. 目录二次渲染 + 章节缓存命中判断

### A. 目录二次渲染

- **根因**：不是数据源被二次 `setItems`（`setItems` 仅在 `Reader.load()` 与 `toggleTocOrder()` 调用，
  `@Monitor` 从不写 `chapters`）。真正原因是挂载后再定位：目录 `List` 无 `initialIndex`，首帧渲染顶部项，
  `openPanel` 用 `setTimeout(...,80)` 调 `locateCurrentToc()` 滚到当前章，LazyForEach 随即在目标位置重建一批 item。
- **证据**：`entry/src/main/ets/pages/Reader.ets:320`（`setTimeout(() => this.locateCurrentToc(), 80)`）、
  `:390-401`（`locateCurrentToc`）、`:631-664`（`List`/`LazyForEach`，无 `initialIndex`）、`:99-100`、`:403-412`；
  `entry/src/main/ets/common/ChapterDataSource.ets:29-34`（`setItems → onDataReloaded` 全量重载）。
- **最小修复建议**：给目录 `List` 传 `initialIndex`（正序 `chapterIndex`，倒序 `chapters.length-1-chapterIndex`）使首帧直达；
  或在 `List.onAppear` 同步定位并删掉 80ms 延时。
- **风险等级**：低（只改渲染时机，不动数据/缓存；需真机确认长目录首帧定位）。

### B. 章节缓存命中判断

- **根因**：命中判断在内存层被绕过。缓存键为 `bookId#index`，内存 `Map` 只存 `content` 不存 `url`，
  `getCachedChapter` 命中内存即返回，仅磁盘分支才比对 `entry.url`；TOC 重拉导致 index↔url 映射变化时，
  内存按旧 index 返回**错章内容**（假命中）。`prefetch` 不被 await，与 `loadChapter` 可并发，
  落盘前双方都判 miss → 重复网络请求 + 重复写盘。`''` 被当作命中属隐患（Rust 空正文会 reject，未实际写入）。
- **证据**：`entry/src/main/ets/model/ChapterCache.ets:20-22`（key）、`:39-43`（内存命中不校验 url）、
  `:51`（仅磁盘校验）、`:69,83-85`（无条件 set/TRUNC 写盘）；
  `entry/src/main/ets/pages/Reader.ets:168-175`、`:212-243`、`:237`、`:245-255`；
  `entry/src/main/ets/model/BookContent.ets:58-65`（TTS 路径同样绕过内存 url 校验）。
- **最小修复建议**：内存改存 `{url, content}`，命中前比对 `url`，不一致即删除返回 `undefined`（与磁盘层对齐）；
  为 `fetchContent` 增加 `bookId#index` 的 in-flight `Map` 做请求合并。
- **风险等级**：中（内存校验修复会短暂增加一次重取；in-flight 合并需清理失败/异常以防永久 pending）。

---

## 3. 听书进度跳跃 + 暂停/语速/音色卡顿（TTS 生命周期）

核心文件：`model/TtsController.ets`、`pages/Listening.ets`、`pages/Reader.ets`。

### A. 进度条跳跃

- **根因 1（主）**：进度取「写入渲染器」位置而非「实际播放帧」。`fill()` 由 `writeData` 驱动，
  段落切换直接把 `paragraphIndex` 设为正在写入的 item.index；全仓库无 `getAudioTime`/`timestamp`。
  AudioRenderer 预缓冲使写入领先可听播放一个缓冲区，进度跳到「还没听到」的段。
- **根因 2**：进度完全按字数估算（`chars / (5.0 * speed)`），非音频时间轴；整段内不推进、跨段突跳。
- **根因 3**：AVSession `position.elapsedTime` 同源且仅段边界 `setAVPlaybackState`，锁屏进度静止后跳变。
- **根因 4**：段落高亮/跟随由跳跃的 `paragraphIndex` 驱动。
- **证据**：`entry/src/main/ets/model/TtsController.ets:665`（`fill`）、`:267-269`（`writeData`）、
  `:677-679`（写 `paragraphIndex`）、`:962-969`（`estimateElapsedMs`，`CHARS_PER_SECOND=5.0` 见 `:25`）、
  `:939-944`、`:682,743`；`Listening.ets:208-213,228`；`Reader.ets:53-66,348-352`。
- **最小修复建议**：用 `renderer.getAudioTime()`/timestamp 换算实际播放帧，写入回调只记录不回写 UI 进度；
  slider 改用播放时间；AVSession 进度定期（如 1s）刷新。
- **风险等级**：中。

### B. 暂停 / 改语速 / 改音色卡顿

- **根因 1**：改语速从当前段「整段重合成」，丢缓冲。`setSpeed()` → `beginFrom(currentIndex)`；
  `beginFrom` 先 `engine.stop()`+`resetQueues()` 再重新 speak，首段合成延迟期间无数据。
- **根因 2（最明显）**：改音色销毁并重建引擎 + 固定 120ms 等待 + 重合成。
  `engine.shutdown()` → `engine=undefined` → `await setTimeout 120` → `ensureEngine()` → `resume()`。
- **根因 3**：`resume`/切段时 `startRenderer` 强制 `pause→flush→start`，每次 `beginFrom` 都 flush 渲染器缓冲，
  队列已被清空 → underrun → 填空静音。
- **根因 4**：暂停会丢掉当前段已播部分，恢复从段首重播（停顿 + 重复）。
- **根因 5**：音频回调内做 `persistProgress()`（DB insert）与 `updatePlaybackState()`，实时回调线程分配 Promise，段边界易抖。
- **证据**：`TtsController.ets:827-838`（`setSpeed`）、`:850-875`（`setVoice`，`:856/859/860-862/864/874`）、
  `:500-506`（`beginFrom`）、`:516`、`:285-306`（`startRenderer`）、`:518`、`:695-696`、
  `:725-744`（`pause`）、`:752`（`resume`）、`:679`、`:681-682`。
- **最小修复建议**：音色切换优先复用引擎（若 API 支持 person 切换），否则旧引擎播完当前段再无缝切换；
  改语速先预合成首段再切；仅在必要时 flush；记录段内字节偏移恢复续播；持久化移出音频回调。
- **风险等级**：高（音色切换 `setVoice` 重建引擎，改动面最大）；其余为中/低。
- **未发现**：回调重复注册/泄漏（`ensureRenderer` 只注册一次 `:267-275`；`startFlushTimer` 有守卫 `:592-599`），
  无忙等，UI 线程无阻塞式 sleep。

---

## 4. 书源检测误报 + no result 判定 + 清理缓存恒 0B

### A. 书源检测误报

- **根因**：`detect` 跑完整链路（搜索→详情→目录→首章→正文），但可用判定过宽：各阶段只要求
  「HTTP<400 且 body 非空」，正文仅 ≥50 字即通过；书名一致性校验可被跳过；`checkKeyWord`/`bookUrlPattern`
  从未生效；detect 没有源级超时（最坏 4×15s）。
- **证据**：`rust/legado-engine/src/runtime.rs:433`（`detect_one`）、`:459`（`out.ok = chain.0`）、
  `:469`（`verify_chain`）、`:477-487`（详情）、`:527-537`（目录）、`:563-573`（章节）、
  `:589-598`（正文阈值 50）、`:491-511`（一致性可跳过）、`:421-431`（无 timeout）；
  `rust/legado-engine/src/types.rs:139`（`checkKeyWord` 定义）、`:30`（`bookUrlPattern`）；
  `entry/src/main/ets/pages/BookSourceManage.ets:209-216`；`common/Const.ets:38`。
- **最小修复建议**：`detect_one` 加 `tokio::time::timeout`；校验 `checkKeyWord`/`bookUrlPattern`；
  提高正文阈值并识别登录/错误页；把导入摘要 gate 文案改为「规则通过」以免误认「可用」。
- **风险等级**：中。

### B. "no result" 判定

- **根因**：判定发生在 ArkTS，非 Rust。`groups.length===0 && pending===0` 时无条件显示「没有找到结果」，
  未区分「全部源失败/超时」与「源成功但零结果」；无启用源时也落入同一分支。
- **证据**：`entry/src/main/ets/pages/SearchResult.ets:501-514`（空态分支）、`:64-74`（`pending=sources.length`）、
  `:98-135`（逐源仅写 `status.ok=false`）、`:591-599`（`sourceSummary` 只报成功数）；
  Rust `runtime.rs:135-138`、`types.rs:269-274`、`status.rs:35,54`。
- **最小修复建议**：`pending===0 && groups` 为空时，若 `statuses.every(s=>!s.ok)` 显示「全部书源请求失败/超时」，
  否则显示「未搜索到结果」；`sourceSummary` 增加失败计数。
- **风险等级**：低。

### C. 清理缓存恒 0B

- **根因**：并非算错目录，而是功能完全未实现：设置项写死 `'0 B'`，「清理缓存」路由落入占位页，
  全项目无缓存统计/删除代码；`formatBytes` 已定义但零调用。真实缓存分散在 `filesDir/chapters` 与 `cacheDir/cover_*`。
- **证据**：`entry/src/main/ets/pages/Settings.ets:81-86`；`entry/src/main/ets/pages/Index.ets:45-47,53-64,234-247`；
  `entry/src/main/ets/model/ChapterCache.ets:24-30`；`entry/src/main/ets/components/BookCover.ets:33`；
  `rust/legado-engine/src/runtime.rs:653-658`；`entry/src/main/ets/common/Format.ets:48-61`。
- **最小修复建议**：新增缓存工具遍历 `ctx.cacheDir`（`cover_*`）与 `ctx.filesDir/chapters`，
  用 `fileIo.statSync(fd).size` 求和，Settings 用 `formatBytes` 展示；清理删除同路径。
- **风险等级**：低。

**备注**：`BookSourceManage.ets:414` 检测结果列表 key 用 `result.sourceUrl`，源 URL 重复时摘要计数会多于实际渲染行，次要显示问题。

---

## 优先级建议

1. 高：`setVoice` 音色切换重建引擎（3-B-2）。
2. 中：听书进度改用音频时钟 + 减少 flush（3-A-1 / 3-B-3），同时缓解进度跳跃与暂停/倍速卡顿。
3. 中：内存缓存 url 校验（2-B）；detect 超时与校验（4-A）。
4. 低：封面缓存短路（1）、目录 `initialIndex`（2-A）、no result 文案（4-B）、清理缓存实现（4-C）。