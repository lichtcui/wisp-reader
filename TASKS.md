# TASKS.md — 跨模块 Bug 修复任务清单

> 由 [`AUDIT.md`](./AUDIT.md) 审计派生；按模块分组。
> 状态：`[ ]` 未开始 · `[~]` 进行中 · `[x]` 完成。修复须另获授权（Gate B），审计阶段不改代码。
> 优先级：P0（阻断/高影响）→ P1 → P2。每项给出证据位置与验证方式。

---

## 跨模块 / 高优先（P0）

- [ ] **T-CROSS-1（R1）阅读 ↔ 听书跨书串扰**：`Reader.onTtsProgress` 与 `isSpeaking` 增加 `bookId` 守卫，仅同书才滚动/高亮。
  - 证据：`entry/src/main/ets/pages/Reader.ets:53-66`、`:348-352`
  - 验证：真机「听书 A 时打开 B」→ B 不跳章、B 进度不被写成 A 的章节号。
- [ ] **T-CROSS-2（R2）听书后台任务泄漏**：`pause()` 与自然播完（`onParagraphEnd` 末章）时调用 `stopBackground()`；恢复播放再 `startBackground()`。
  - 证据：`entry/src/main/ets/model/TtsController.ets:203`（仅 stop 调）、`:705-721`、`:725-744`、`:429-437`
  - 验证：播完/暂停后 `hidumper` 或任务列表确认 `AUDIO_PLAYBACK` 长时任务已结束。
- [ ] **T-CROSS-3（R3）进度写竞争**：为 `progress` 写入加归属/`updatedAt` 防覆盖（如仅当前活动模块可写，或写入前比较 `updatedAt`）。
  - 证据：`Reader.ets:762-764`+`:257-271`、`TtsController.ets:973-987`、`model/ShelfRepository.ets:130-145`
  - 验证：阅读与听书交替操作同一本书，重启后进度不跳变。

---

## 书架（Shelf）

- [ ] **T-SHELF-1（R5）删除书籍清理关联缓存**：`removeBook` 后一并删除 `filesDir/chapters/{bookId}_*` 与 `filesDir/local/{bookId}`（本地书）。
  - 证据：`model/ShelfRepository.ets:80-87`、`model/ChapterCache.ets:24-30`、`model/LocalBook.ets:49-59`
- [ ] **T-SHELF-2（R10）数据层懒初始化**：`ShelfRepository` 在 `store===undefined` 时补初始化，避免书架 Tab 初始化前进度丢写。
  - 证据：`model/ShelfRepository.ets:20-36,130-145`、`pages/Shelf.ets:42`
- [ ] **T-SHELF-3 进度三态**：核对 `progressText` 的 `total` 反推在 `percent` 为 0/极小值时是否正确。
  - 证据：`pages/Shelf.ets:225-232`

## 搜索（Search）

- [ ] **T-SEARCH-1（R9）引擎边界参数透传**：确认 `opts.concurrency` 是否需要传给 native（当前被丢弃）。
  - 证据：`entry/src/main/ets/engine/BookEngineNapi.ets:19-24`
- [ ] **T-SEARCH-2 搜索代次 guard 回归**：核对连续重搜/返回时的 `searchGen` 与 `pending` 计数无残影。
  - 证据：`pages/SearchResult.ets:64-135`

## 阅读（Reader）

- [ ] **T-READ-1（R7）统一正文清洗**：`Reader.sanitize` 与 `BookContent.sanitize` 合并为单一实现，保证 TTS 段落索引与阅读页一致。
  - 证据：`pages/Reader.ets:185-210`、`model/BookContent.ets:12-37`
- [ ] **T-READ-2（R8）章节缓存内存上限**：为 `ChapterCache` 内存层加 LRU/上限；清理死代码 `hasCachedChapter`。
  - 证据：`model/ChapterCache.ets:18,92-94`、`plan.md:270`
- [ ] **T-READ-3 预取去重**：频繁切章时避免对同一 `bookId#index` 重复预取/重复写盘。
  - 证据：`pages/Reader.ets:245-255`、`:212-243`

## 听书（Listening / TTS）

- [ ] **T-TTS-1（R6）单例与引擎释放**：`stop()` 释放 `engine`（`shutdown`）并考虑重置单例；`onDestroy` 后不复用失效 `ctx`。
  - 证据：`model/TtsController.ets:68-75,190-212`、`entryability/EntryAbility.ets:17-20`
- [ ] **T-TTS-2 定时器与自然结束**：自然播完时 `clearTimer()`，避免定时器空转。
  - 证据：`model/TtsController.ets:705-721`、`:880-907`
- [ ] **T-TTS-3 错误态恢复**：`onError` 后 `playing=false`，确认 UI 与 `AVSession` 状态一致、可重试。
  - 证据：`model/TtsController.ets:585-590`、`pages/Listening.ets:359-374`

## 书源管理（BookSourceManage）

- [ ] **T-SRC-1 导入持久化回归**：核对「启停/删除/恢复内置」后的 `preferences` 落盘与列表 key 稳定性。
  - 证据：`pages/BookSourceManage.ets:65-70,175-198,343-386`、`model/SourceRepository.ets:39-47`
- [ ] **T-SRC-2 检测并发/超时**：确认 `detect`（并发 4）无源级串扰，`busy` 态防重入。
  - 证据：`pages/BookSourceManage.ets:200-222`

## 数据管理（缓存 / 备份，M6）

- [ ] **T-DATA-1（R4/R5）封面缓存读穿**：`BookCover.load` 先查 `ctx.cacheDir/cover_{hash}` 是否已存在（或加内存 PixelMap 缓存），避免重复下载。
  - 证据：`components/BookCover.ets:22-39`、`rust/legado-engine/src/runtime.rs:653-658`
- [ ] **T-DATA-2（R5）清理缓存页实现**：统计并清理 `filesDir/chapters`、`filesDir/local`（可选）、`ctx.cacheDir/cover_*`；设置页用 `formatBytes` 展示真实占用。
  - 证据：`pages/Settings.ets:82-86`、`common/Format.ets:48-61`、`pages/Index.ets:62-64`
- [ ] **T-DATA-3（R5）备份/恢复**：导出 JSON（书源 + 书架 + 进度，带 `schemaVersion`）并支持导入恢复。
  - 证据：`plan.md:272`、`pages/Settings.ets:88-93`
- [ ] **T-DATA-4 缓存上限策略**：落实 plan §7「已读永久保留、未读超 N 天清理 / LRU ~200MB」。
  - 证据：`plan.md:270-271`

---

## 验证 / 构建（横切）

- [ ] **T-VER-1 clean 构建复验**：执行一次非增量的 `hvigorw assembleHap ... --no-daemon`，确认冷构建可复现。
- [ ] **T-VER-2 Rust 回归**：若改动引擎，`cd rust/legado-engine && cargo test`（当前记录 54 passed）并重出 `.so`。
- [ ] **T-VER-3 真机闭环**：每个修复按 `AGENTS.md` §4 走「编译 → 安装 → `aa force-stop` → 重启 → hilog `SourceReaderTts`/`SourceReaderPoC` 观察」。
- [ ] **T-VER-4 混淆确认**：新增 JSON 字段时同步 `entry/obfuscation-rules.txt` 的 `-keep-property-name`。
- [ ] **T-VER-5 文档补齐**：补 `docs/bug.md`（progress.md 引用但缺失）或在 progress.md 去除引用。

---

## 回归验收状态（S10 回归 / 发布，2026-09-27）

> 逐项核对源码 + 构建复核。图例：`✅ 已修复/已核验` · `➖ 缓解` · `⏭ 顺延/范围外` · `🚫 受阻（设备离线）`。
> 修复均已通过 **clean debug 构建** 与 **release 构建**（`BUILD SUCCESSFUL`）。

| 任务 | 状态 | 处置 / 证据 |
|---|---|---|
| T-CROSS-1 阅读↔听书串扰 | ✅ | `Reader.onTtsProgress` / `isSpeaking` 增加 `tts.isActiveFor(bookId)` 守卫（`Reader.ets:65-77`、`:450-457`） |
| T-CROSS-2 后台任务泄漏 | ✅ | `pause()` 与自然播完末章分支调用 `stopBackground()`，恢复播放再 `startBackground()`（`TtsController.ets:855`、`:825-838`） |
| T-CROSS-3 进度写竞争 | ➖ | `saveProgress` 加 `lastWriteAt` 时间戳防旧写覆盖；叠加 T-CROSS-1 消除跨书污染（`ShelfRepository.ets:132-152`） |
| T-SHELF-1 删除书籍清缓存 | ⏭ | `removeBook` 全仓**无调用点**（无删除 UI），无可触发路径；加删除入口时一并落清理 |
| T-SHELF-2 数据层懒初始化 | ✅ | `EntryAbility.onCreate` 预调 `initShelf`，搜索直达阅读也能落进度（`EntryAbility.ets:14-19`） |
| T-SHELF-3 进度三态 | ⏭ | `percent` 极小值反推 `total` 的理论边界未在真机复现（设备离线）；低风险，顺延复验 |
| T-SEARCH-1 concurrency 透传 | ✅ | `BookEngineNapi.search` 现传 `concurrency`（`BookEngineNapi.ets:23-26`） |
| T-SEARCH-2 搜索代次 guard | ✅ | S6 实现并真机验证；本轮静态复核无残影 |
| T-READ-1 统一正文清洗 | ⏭ | 两处 `sanitize` 当前**逐字节一致**（非功能缺陷）；合并为纯重构，顺延 |
| T-READ-2 缓存内存上限 + 死码 | ✅ | `ChapterCache` 加 24 条 LRU（`touchMemory`）；删除死码 `hasCachedChapter`；`BookCover` 加 64 条 PixelMap LRU |
| T-READ-3 预取去重 | ⏭ | `ChapterCache` 内存 LRU 后重复写盘概率降低；in-flight 去重顺延 |
| T-TTS-1 引擎释放 | ✅ | `stop()` 增 `engine.shutdown()` 并置空、复位日志位（`TtsController.ets:226-243`） |
| T-TTS-2 定时器自然结束 | ✅ | 末章播完 `clearTimer()`，避免 1s 定时器空转（`TtsController.ets:825-830`） |
| T-TTS-3 错误态恢复 | ✅ | `onError` 清 in-flight、停 flush/progress 定时器、停后台；新增 `queueExhausted()`，播完后 `resume()` 可从章首重播 |
| T-SRC-1 导入持久化回归 | ✅ | 列表 key 改为 `bookSourceUrl#enabled`（去 index），启停/一键清理即时刷新（`BookSourceManage.ets:644`） |
| T-SRC-2 检测并发/超时 | ✅ | `runDetect` 加 `busy` 重入守卫并复位 `statusVisible`（`BookSourceManage.ets:292-308`）；引擎每源独立 Client（复核） |
| T-DATA-1 封面读穿 | ✅ | S3 已实现：`pathCache` + `accessSync` 校验，命中不重下（`BookCover.ets:58-62`） |
| T-DATA-2 清理缓存页 | ✅ | S9 已实现并真机核对（`CacheManage.ets`、`CacheRepository.ets`）；本轮增 `cover_*.img` 后缀精确匹配 |
| T-DATA-3 备份/恢复 | ⏭ | M6 范围，未开始 |
| T-DATA-4 缓存上限策略 | ⏭ | M6 范围，未开始 |
| T-VER-1 clean 构建 | ✅ | `hvigorw clean` + `assembleHap debug --no-daemon` → `BUILD SUCCESSFUL`（全量任务） |
| T-VER-2 Rust 回归 | ✅ | `cargo test` → `54 passed; 0 failed`（无 Rust 改动，未重出 `.so`） |
| T-VER-3 真机闭环 | ✅ | 设备已连接（`33Z0224424136564`）：release + debug 安装/启动、书架→阅读→目录→听书全链路冒烟通过，无 `JSCRASH`/`CPPCRASH`。详见 `RELEASE-NOTES.md` §5；跨书串扰因设备仅一本本地书可读未覆盖 |
| T-VER-4 混淆确认 | ✅ | 本轮未新增 JSON 字段，`obfuscation-rules.txt` 无需变更 |
| T-VER-5 文档补齐 | ✅ | 移除 `docs/progress.md` 对不存在的 `docs/bug.md` 的引用 |