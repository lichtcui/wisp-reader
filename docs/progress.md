# 进度 / 下一步

> **本文件只记「当前状态 / 未决风险 / 交接」，是常读文件（勿通读，按下方目录取段）。**
> - 权威设计 → [`plan.md`](./plan.md)　决策与理由 → [`decisions.md`](./decisions.md)　踩坑按症状查 → [`PITFALLS.md`](./PITFALLS.md)
> - 当前任务与文档路由 → [`../AGENTS.md`](../AGENTS.md)
> - **历史流水（M0–M4 结果 / 各页整改 / 抽屉两次真机返修 / 书架编辑五轮审计轨迹）已移出**到
>   [`archive/PROGRESS-HISTORY.md`](./archive/PROGRESS-HISTORY.md)（**默认不要读**，需要时查它的目录）。

## 目录（行号定位，只读需要的段）

> 本目录由 `make docs-toc` 自动生成，**勿手改**（行号是生成时快照）。

<!-- TOC:BEGIN -->
- 里程碑状态 — L24
- M5 结果（2026-09-25，真机验证） — L41
- 书架编辑模式（多选删除）（2026-10-07，已真机验证 D1–D21） — L81
- 在办：书源管理改造（3000 条） — L115
- 未决 / 风险 — L171
- 交接备忘 — L287
<!-- TOC:END -->

---

## 里程碑状态

| 阶段 | 内容 | 状态 |
|---|---|---|
| **M0** | 引擎 PoC：交叉编译 + 解析 + 网络 + 体积 + 冷启动 | ✅ 已完成（真机验证） |
| M1 | 项目骨架 + Design Token（红白）+ 路由 + 三 Tab | ✅ 已完成（真机验证，浅色切换待复验） |
| M2 | 引擎接口（search/bookInfo/toc/content）+ JS/登录门禁 + 书源导入 | ✅ 已完成（真机验证：detect 8/13 可用） |
| M3 | 搜索聚合 + 详情 + 加入书架 + 持久化 | ✅ 已完成（真机验证：加入书架重启仍在） |
| M4 | 阅读页（横向分页翻页）+ 目录（含分页）+ 进度 + 阅读设置 | ✅ 已完成（真机验证：目录/跳转/字号/进度重启恢复；修 bindSheet + 正文清洗；**收尾项已补**）|
| M5 | 听书 + 系统 TTS + 后台播放 + AVSession | ✅ 已完成（真机验证：PCM→AudioRenderer→AVSession 成为 top session，锁屏控件/媒体键可控，切后台不断，定时关闭，段落高亮/进度同步）|
| M6 | 规则调试器 + 缓存清理 + 备份恢复 | ✅ 功能全部落地：规则调试器 UI（`pages/RuleDebugger.ets`，真机验收未做）、备份/恢复（`pages/BackupManage.ets`，含 2026-10-07 修的真「全量覆盖」）、目录缓存统计/清理、**缓存上限策略（`model/CacheTrim.ets`，2026-10-07 实现并真机六项压测通过）**。仅余规则调试器页真机验收 → [`research/CACHE-LIMIT-PLAN.md`](./research/CACHE-LIMIT-PLAN.md) |
| v1.1 | **换源**（阅读页顶栏入口 / 书名 + 作者严格匹配 / 进度按章节序号迁移） | ✅ 已完成（真机验证往返切换 + 缓存清理，见上文同名节）；**2026-10-13 又修「候选被静默丢掉 + 每轮白等 13 源」并加预热，真机复验通过（候选 2→7 行、切换 ≤1s）**|
| v1.2 | **书架「更新」**（手动批量查新章，只查详情不爬目录） | ✅ 已完成（**2026-10-13 真机验收 12 项**：进度文案 / 两个 toast 分支 / 本地书排除 / 零误写 / 防重入 / 幂等 / 编辑态隐藏；「有新章」分支真机不可造，见指针）→ [`bugfix/TASKS.md`](./bugfix/TASKS.md) §T-SHELF-7 |
| v1.3 | **TTS 预生成（服务端章级缓存 + job worker）** | 🔶 **阶段一（服务端）2026-10-13 完成并 7/7 验收**（VPS，App 零改动）；阶段二（App 侧整章播缓存/变速/听完删）未开工 → [`bugfix/TASKS.md`](./bugfix/TASKS.md) §T-TTS-7、[`research/TTS-PREGEN-IMPL.md`](./research/TTS-PREGEN-IMPL.md) §4.1.1 |
| v2 | QuickJS/Boa JS 引擎、在线 TTS、真分页 | ⏳ |


## M5 结果（2026-09-25，真机验证）

设备 `33Z0224424136564`（HarmonyOS NEXT，API 24）：

| 验证项 | 结果 |
|---|---|
| 系统 TTS 引擎（`textToSpeech`，离线 `zh-CN` 聆小珊）创建/播报 | ✅ 引擎创建、逐段 PCM 合成 |
| **PCM → `AudioRenderer`**（16kHz/16-bit/mono，`STREAM_USAGE_AUDIOBOOK`）播放 | ✅ 时序实测：段落字节/32000 ≈ 实测时长（para1 3.41s vs 理论 3.42s） |
| **AVSession 成为 top session**（App 持有音频焦点） | ✅ `hidumper AVSessionService -show_session_info` → `is the topsession: true` |
| **锁屏媒体卡片**（封面位/章节名/书名·作者/进度条） | ✅ 锁屏 dump 显示「第三章 归途 / 测试书 · 测试作者」+ 进度条 |
| **媒体键控制**（`play/pause/next/prev` 路由到 AVSession） | ✅ keyCode 10→pause/resume、12→下一段、13→上一段 |
| 切后台不断（Home 后继续播报） | ✅ 后台期间 `play para` 持续推进 |
| 后台长时任务（`backgroundModes: ["audioPlayback"]`） | ✅ `startBackgroundRunning` 成功（缺该配置时报 9800005） |
| 定时关闭 | ✅ 定时到点 `timer fired, pausing` 自动暂停 |
| 段落高亮 + 阅读页跟随滚动 | ✅ `@Monitor('tts.paragraphIndex','tts.chapterIndex')` 驱动；跨章自动加载 |
| 进度回写（`paragraphIndex`） | ✅ 复用 `ShelfRepository.saveProgress`，书架返回刷新 |
| 书架 FAB（听书任务进行中显示） | ✅ 代码就绪（`TtsController.active` 驱动） |
| 编译（`hvigorw assembleHap` debug） | ✅ BUILD SUCCESSFUL |

**路线修正（重要）**：最初按「系统 TTS 直连播报（`playType:1`）+ AVSession」实现，实测 AVSession
`is the topsession: false`、锁屏无控件——系统 TTS 内部自己持有音频焦点，App 的会话不会被提升为 top。
改为 `plan.md` 原定链路：TTS `playType:0` 返回 PCM → App `AudioRenderer` 播放 → 持有音频焦点 → AVSession 成为
top session，锁屏/媒体键可控。两者 App 内 UI/控制器/后台/定时逻辑一致，仅替换音频输出层。

**M5 新增/改动文件**：
- 新增 `model/TtsController.ets`（`@ObservedV2` 单例：TTS 引擎 + PCM 队列 + `AudioRenderer` + `AVSession` +
  `backgroundTaskManager` + 定时/倍速/音色/进度）。
- 新增 `pages/Listening.ets`（全屏听书页，附录 7 结构：封面/章节/进度/语速/上下段/播放/定时/音色 + 目录 sheet）、
  `pages/ListeningSettings.ets`（默认语速/音色），`common/ChapterUtil.ets`、`model/BookContent.ets`（正文加载 + **清洗唯一实现** `sanitizeText`，阅读页与听书共用，见 `TASKS.md` T-READ-1）。
- 改动 `pages/Reader.ets`（底栏「听书」入口 + 段落高亮 + 跟随滚动 + 跨章同步）、`pages/Index.ets`（
  `ROUTE_LISTENING` / `ROUTE_LISTENING_SETTINGS`）、`pages/Shelf.ets`（听书 FAB）、`pages/Settings.ets`（听书设置路由）、
  `common/Const.ets`、`entryability/EntryAbility.ets`（退出释放）、`module.json5`（`backgroundModes`）、
  `resources/*/element/color.json`（`listen_*` 令牌）、`entry/obfuscation-rules.txt`（TTS/AVSession/Audio 字段名保留）。

**已知限制（v1 / 可优化）**：
- 段落间偶有合成延迟（一次性预合成 2 段，`AHEAD=2`）；跨章需先取正文再合成，存在短暂停顿。
- 播放位置/时长按字数估算（`CHARS_PER_SECOND=5`），非精确音频时间轴；锁屏 `seek` 按估算定位到段。
- 音色 21（男声）需系统已下载，未下载时 `createEngine` 失败并回退并提示。


## 书架编辑模式（多选删除）（2026-10-07，已真机验证 D1–D21）

按 [`archive/SHELF-EDIT-PLAN.md`](./archive/SHELF-EDIT-PLAN.md) §8 逐步实施（未改交互设计、未改 `UI-SPEC.md`）。

| 阶段 | 内容 | 状态 |
|---|---|---|
| S1 | 新增 `model/ShelfEditState.ets`（`@ObservedV2` + `@Trace`）；`Index` 顶/底栏分支 + `deleteAction()` + `onBackPress` + `.scrollable`；`Shelf` 长按/点按分流 + 三态 `entryKey` + 角标 + FAB 隐；`BookCover` 加 `@Param dimmed` | ✅ 编译通过 |
| S2 | `removeBook`→`removeBooks`（含 `lastWriteAt.delete` + 替换过时 TODO 注释）；`ChapterCache.deleteBookChapters` / `TocCache.deleteBookToc` / `LocalBook.deleteLocalBookData`；新增 `model/BookRemoval.ets`；`Index` 二次确认弹窗 + `doDelete` | ✅ 编译通过 |
| S3 | `Shelf.reload()` 加 `reloadGen` 代次守卫（慢刷新不覆盖新结果） | ✅ 编译通过 |
| S4 | `CacheStats.toc` 分类 + `isChapterFile`→`isJsonFile` 改名 + `clearCache()` 清 `tocs` + `CacheManage`「目录缓存」行 | ✅ 编译通过 |

**验证证据（本轮）**

| 项 | 结果 |
|---|---|
| debug `assembleHap` | ✅ `BUILD SUCCESSFUL` |
| release `assembleHap`（含 SignHap） | ✅ `BUILD SUCCESSFUL`（D21 只要求跑到混淆阶段） |
| 混淆产物 | ✅ `entry/build/.../release/obfuscation/{nameCache,fileWhiteLists,projectWhiteList}.json` 已刷新 |
| K15/§5.5 静态自查 | ✅ 无 `@Monitor('edit.x')`、无 `this.edit['x']`、无 `ShelfEditState` JSON 往返 |
| 混淆面实证（新增） | ✅ `PropertyCache`: `editing→c12`、`bookIds→d12`（类成员**确实**被改名，印证 K15）；`Shelf.ets`/`Index.ets`/`CacheManage.ets` 的 struct 成员整列自动保留（含 `edit`/`deleting`/`selectBadge`/`tocCount` 等新增项） |
| 真机 D1–D21 | ✅ **已验**（设备 `33Z0224424136564`）：D1–D9 / D11 / D13 / D15–D17 / D19 / D21 全通过；D10/D12/D14/D18 按用户决定跳过；D20 部分通过（书架书量不足，见下）。逐条证据见 [`archive/SHELF-EDIT-PLAN.md`](./archive/SHELF-EDIT-PLAN.md) §12.3 |

**计划的 3 处修正（实施/真机中发现，已回写计划 §1.5、§1.6）**
1. `selectBadge` 不能像计划 §8 S1-3e 那样写 `.justifyContent/.alignItems` —— `StackAttribute` 在本 SDK 无此二属性，改用构造参数 `Stack({ alignContent: Alignment.Center })`（居中效果等价）。
2. S1 里作为占位 Toast 的 `confirmDelete()` 在 S2 已被真实二次确认弹窗替换（同一函数，非新增）。
3. **（真机专属缺陷）** 计划 §8 S1-3e 的长按写法（helper 返回 `GestureType` + `.gesture(this.longPressToEdit(entry))`）在真机上**永不触发**：转译产物实证它被编译成**空手势**（`Gesture.create(GesturePriority.Parallel); Gesture.pop();`）—— `.gesture()/.parallelGesture()` 只接受**内联手势字面量**。且 `.gesture()` = `GesturePriority.Low`，会输给祖先识别器。→ 统一改为 `.parallelGesture(LongPressGesture({repeat:false,duration:500}).onAction(...))`，helper 改名 `onLongPress(entry): void` 只留业务逻辑。

**真机验证要点（设备 `33Z0224424136564`）**
- **三个真机疑点全部关闭**：**R6** 长按在 +498ms 触发（`duration:500` 手感符合预期）；**R10** `Index.onBackPress` **生效**（系统 Back 键正确退出编辑态并留在书架，`EntryAbility.ets` 无需回退方案）；**R12** 长按后**不补送 click**（`longPressFired` 兜底未被依赖，`GestureGroup` 回退未启用），且 3s 慢滑（手指持续移动 ≥500ms）**不误进编辑态**、编辑态内跨书慢滑选中数不变 → `.parallelGesture` + `.onTouch(被动回调)` 不阻断 `Grid`/`List` 滚动。
- **删除链路端到端**（删「夜的命名术」，播放 TTS 中）：书架 4→3、重启仍 3、DB `books` 4→3 行 / `progress` 7→6 行；`chapters/` 13→6、`tocs/` 4→3；「清理缓存」页章节 125.2→28.6KB、**目录 235.5→73.8KB**（= 235.5 − 161.7，逐字节对上）；点「清理全部缓存」后四类缓存全部归零。**播放中删除 → 之后无任何 `play para=` 日志（TTS 已停）+ 听书 FAB 消失**。双击「删除」验证防重入：只删一次。
- **异常面**：`hilog` 全量扫描 **0 条** JS/ArkTS 错误 + **0 条**本应用 error 级日志。
- **唯一没验全的 D20**（编辑态滚动）：本机书架只有 3–4 本书（grid 2 行 / list 4 行 ≤ 一屏），**内容不足以滚动**；三条加书路径均不可自动化（硬件键盘态下 `TextInput.onSubmit` 无法注入；`DocumentViewPicker` 内无 `.txt` 且 shell 不可写共享存储；`aa start` 不支持 `--wh/--ww` → `10106107`）。改以「慢滑不误触 + 编辑态慢滑不改选 + 代码层不阻断滚动」三项替代证据（详计划 §12.3）。
- **临时诊断已清理**：真机排查用的 3 条 `hilog('ShelfDiag')`（+ import）已移除，重新构建/安装并复验 D1–D4/D6 通过。

## 在办：书源管理改造（3000 条）

**状态：specs + plan + 任务清单已批准；`T0.2` / `T0.1` 门禁已完成；`T1.1`–`T1.6`
均已真机通过（2026-10-17）。Phase 1 存储地基的技术验收已完成。Phase 3 的 `T3.1` 页面骨架已完成
（2026-10-18，debug 真机）：两段共用一份 `SourceRow` 投影，列表改用 `LazyForEach`，
导入/调试/导出/恢复内置收进页内 `＋` / `⋯`；两段查询、筛选与滚动状态均保留，3000 条滚动首帧未验证。**

- 设计（索引）：[`specs/SPEC-BOOKSOURCE-REVAMP.md`](./specs/SPEC-BOOKSOURCE-REVAMP.md)（capability map + 共享契约）
  + 五份模块 spec（`source-store` / `source-list` / `detect-engine` / `detect-job` / `detect-ui`）
  + [`specs/SPEC-BOOKSOURCE-LAYOUT.md`](./specs/SPEC-BOOKSOURCE-LAYOUT.md)（布局 2 两段式）
- 计划：[`research/BOOKSOURCE-REVAMP-PLAN.md`](./research/BOOKSOURCE-REVAMP-PLAN.md)（A1–A12 架构决定 / 依赖图 / 风险表）
- 任务：[`research/BOOKSOURCE-REVAMP-TODO.md`](./research/BOOKSOURCE-REVAMP-TODO.md)（20 任务 / 6 检查点 / 两会话并行分工）
- **`T0.2` 并发 / 超时实测已完成（2026-10-15，Ask first 已确认）**：并发 **16**、L1 超时 **8 s**
  （L2 保持 45 s），3000 源 L1 单轮 ≈4.4 min（判据 ≤20 min 留 ~4.5× 余量）；32/64 数据已备，
  真机若 >15 min 改一个常量上调到 32。实测台 `scripts/detect-bench.py`（主机 probe；
  3180 条真实混合源抽 400 × 2 轮 × 并发 8/16/32/64）；`runtime.rs` 的 `clamp(1, 8)` 临时放宽到 64 测完
  **已回退**，转正归 `T2.2`。结论 → [`specs/SPEC-DETECT-ENGINE.md`](./specs/SPEC-DETECT-ENGINE.md) §3.3/§3.5、
  plan A2、[`research/BOOKSOURCE-REVAMP-TODO.md`](./research/BOOKSOURCE-REVAMP-TODO.md) §T0.2
- **`T0.1` 长时任务真机验证已完成（2026-10-15）**：A1 已定 —— `DATA_TRANSFER` **可用**（息屏 **606 s 零丢 tick**）、
  **一个 Ability 只能一个长时任务**（`9800005`；并存须「一个任务多类型」）、受 SDK 硬约束
  「**>10 分钟不更新进度即取消**（进度通知须为实况窗）」；降级路径**未触发**，Phase 4 范围不变。证据 →
  [`research/T0.1-LONG-TASK-EVIDENCE.md`](./research/T0.1-LONG-TASK-EVIDENCE.md)、`specs/SPEC-DETECT-JOB.md` §3.6
- **T1.1 已完成（2026-10-17 真机）**：`SourceStore.ets` 建表、投影、自然键、启停隔离、检测/置信度写、
  筛选、导出与删除一次性自检全绿（`add=2 upd=1 dupid=1 idstable=1 grp=1 proj=1 iso=1 patch=1 flt=1 exp=2 rm=1`）；
  临时自检探针已移除。
- **T1.2 已完成（2026-10-17 真机）**：`SourceStoreMigration.ets` 将 13 条书源迁入 `sources.db`，
  原文备份到 `filesDir/book-sources-v1.pre-migration.json`（23068 B，与迁移前 preferences 逐字节一致）；
  第二次启动 `already-migrated count=0`，旧 `book_sources_v1` 键保留。失败路径已验证事务回滚、无半表残留。
- **T1.3 已完成（2026-10-17 真机）**：`sources.confidence` 成为唯一权威；搜索结束只按变化的自然键
  `patchConfidences()` 单事务更新列，启动与换源面板用投影覆盖 `BookSource` 里的旧副本。
  实测 👍玄幻阁 `90→100`、黑炎小说 `40→50`、云中书库 `35→45`，force-stop 重启后值保持不变。
- **T1.4 已完成（2026-10-17 真机）**：备份导入/导出改走 `replaceAll()` / `exportAll()`；导出的
  `schemaVersion=1`，与改动前备份的全部字段路径一致。旧备份成功导入（计数 `13 / 3 / 7`），
  最新备份回导后恢复 `13 / 4 / 8`；换源面板当时已去掉全量 parse，实测显示 3 个候选、检索进度 `8/12`。
  `make check` 通过。
- **T1.5 已完成（2026-10-17 真机）**：`Index.ets` / `Shelf.ets` / `SearchResult.ets` 改为
  `ensureSourceStore()` + `listRows()` 投影读取；书架按实际书籍 URL、搜索与换源按稳定行 `id` 懒加载完整规则。
  `SourceSwitchPanel.ets` 与 `BookSourceManage.ets` 共用同一 SQLite 启用/换源状态；完整规则不再在进入页面时全量解析。
  `rg -n "loadSources" entry/src/main/ets` 只剩 `model/SourceRepository.ets:22`（定义）；正常启动无全量
  `JSON.parse`，仅 T1.2 的一次性旧 preferences 迁移保留该例外。`make run` 编译、安装、force-stop、启动通过；
  启动日志 `source migration status=already-migrated count=0`，书架《剑来》进入阅读并换源成功。
  启用一致性实测：管理页 `13/13 → 12/13`，搜索 `源 8/11 成功`、换源 `已检索 10/11 个书源`；重启后仍为
  `12/13`，恢复后 `13/13`、搜索 `源 10/12 成功`。`SearchResult.ets` 每次 `searchToken` 变化重读启用投影。
  新增 `scripts/check-source-consumers.sh` 防止阅读链路回退，并随 `make check` 执行。
- **T1.6 已完成（2026-10-17 真机）**：debug-only「T1.6 性能造数（3000）」入口完成临时 JSON 校验、
  原书源备份、单事务造数与恢复；3000 条为 1000 个 URL × 3 个不同名称、12 组、2000/1000 启用状态。
  最新轮 `upsertMany=477 ms`、冷就绪 `init+list=44 ms`（首帧 `18 ms`）、首次 toggle `10 ms` /
  中位 `1 ms`、remove `1 ms`、`jsonSerialize=0`；测后恢复原 13 条，`exact=1`。前一轮首次 toggle
  `20 ms` 作为调度抖动风险保留。路径、哈希、hilog 与复跑说明 →
  [`research/T1.6-SOURCE-STORE-BENCH.md`](./research/T1.6-SOURCE-STORE-BENCH.md)。
  新增 `scripts/check-t16-bench.sh`，随 `make check` 执行；`make check` 通过。
- **下一步**：先与人对齐「恢复内置」是替换还是合并；确认后再做 `T3.2`，本轮不实现其确认动作。
  手机端 3000 源列表滚动与性能验收仍待后续真机验证。
  T1.6 残留风险是 16 ms 阈值对首次写调度较敏感（前一轮首样本 `20 ms`，稳态中位 `1–2 ms`）。
- 动手前待答：恢复内置「替换 vs 合并」（`T3.2`）、预检/完整结果的展示粒度（`T5.1`）

## 未决 / 风险

> **要动手修的清单在 [`bugfix/TASKS.md`](./bugfix/TASKS.md)**（P0→P2，每项带证据位置与验证方式）；
> 本节只记「还没想清楚 / 待复验」的风险，不重复任务项。

**近期已关闭**（详细信息看指针，不在本文件重复）

- **T-TTS-7 TTS 预生成「阶段一」（服务端）2026-10-13 完成并 7/7 验收通过**（**App 侧一行未改**，不在设备上）：VPS 新增 `server/tts_cache.py`（内容寻址键 + 落盘布局 + 淘汰/保护 + 文件系统队列）、`server/job_worker.py`（**独立进程**，`import gsv_batch.synth_native` 作唯一合成口径，单 worker 单音色 `流萤`）、`tts-job.service`（**默认 disabled**，`MemoryMax=3800M`，启动自检 swap ≥4 G）、`server/pregen_test.py`（验收客户端）、`server/deploy.sh`；`app.py` 新增 6 个端点（`/job` `/job/status` `/audio/{key}` `DELETE /cache/{key}` `/cache/stats` `/cache/probe`）。
  实测：整章 8709 字 / 41 段 = **7 块**（≤1500 字/块）/ 音频 **1777.5 s** / **合成 3.34 h（RTF 6.76；记账请用 3.3 h / 8709 字，立项基准 2.78 h 是主机噪声更好的结果）** / HWM **3638 MB**；并发 `/tts` 45 次全部成功且**门闸连打 16 次让位**（09:14:04→09:17:49）；小样本 285 字（RTF 5.03 / 峰值 −2.0 dBFS / 0% 削顶）、幂等、淘汰与保护（含 `409 cache_full_wait_playback`）、Range 206、`kill -9` 重排恢复、SIGTERM 退条不留半章全通过。磁盘先回收 3.6 G（删 GSV 用不到的三个子模型）。
  **未做**：阶段二（App 侧 `流萤` 音色 + `/audio` 整章播放/变速/听完 `DELETE`）与「批任务运行期间真机听书」的真机回归（主机侧同源探针已覆盖）；AI 生成音频只有 `curl` 能听。→ [`bugfix/TASKS.md`](./bugfix/TASKS.md) §T-TTS-7、[`research/TTS-PREGEN-IMPL.md`](./research/TTS-PREGEN-IMPL.md) §4.1.1、[`remote-tts-deploy.md`](./remote-tts-deploy.md) §9

- **T-SHELF-7 书架「更新」：2026-10-13 真机验收通过（设备 `33Z0224424136564` · debug · `make run`）**：进度 `检查中 0/2` → `1/2`、**`total = 2`（本地书正确排除）**、toast `没有发现新章节，1 本未检查` 与（停用两个同 URL 孪生源后）`检查失败，请检查网络或书源`、
  失败书不建基线且不影响其余书、**全程 `shelf.db` 逐列零写入**（反复点击/注入/复跑均如此）、连点两次只跑一轮、幂等、编辑态顶栏无入口 —— 共 12 项。
  **「有新章」分支真机不可造**：沙箱 DB 对 shell 只读（`touch` / `file send` 均 `Permission denied`），且 App 内写基线的两处（换源 / 加入书架）写的正是本功能要比对的**同一个源详情页值** ⇒ 只有主机仿真覆盖，证据与理由见 [`bugfix/TASKS.md`](./bugfix/TASKS.md) §T-SHELF-7「验证」③④。
  顺带产出两条可复用技法（**toast 读法 = `uitest screenCap` + 主机 `tesseract -l chi_sim`**，因为 `dumpLayout` 不导出 toast 窗口；**同 URL 孪生源让「停用书源」失效**）→ [`PITFALLS.md`](./PITFALLS.md) 与 skill `harmony-device-run` §4。
  **同日收尾小迭代（2026-10-13）**：进行中进度行改为 `shelfProgressText(done,total,failed)` —— 无失败 `检查中 1/2`、有失败 `检查中 1/2 · 1 本未检查`（失败数不必等结束 toast）；主机仿真 **25 → 30 断言 `ALL PASS`** + `make hap` 通过；**真机 2026-10-13 已验证**：两种形态都拍到（无失败 `检查中 1/2` dump 实测 `[658,190][869,241]`；有失败 `检查中 1/2 · 1 本未检查`，靠停用 `bbiquge8` + 孪生 `笔趣阁8` 注入），顶栏不截断（按实测字宽外推最长形态 ≈550px vs 可用 ≈710px，余量 ~80vp；该最长形态本身未真机出现）；同日**「有新章」分支也由一次性调试版真机走通**（`[T-MARK]` → 真写库 → 还原后 toast `1 本有新章节` → 再点幂等），详见 TASKS §T-SHELF-7「验证」④⑤。

- **release 包首次真机冒烟（T-VER-6，2026-10-07）**：搜索 / 详情 / 阅读 / 听书 / 备份导出→清库→导入 / 重启复读 / 书源列表全通过，**0 条 JS 错误 + 0 崩溃，未发现混淆类缺陷**。
  逐项证据 → [`bugfix/TASKS.md`](./bugfix/TASKS.md) §「release 冒烟结果（T-VER-6）」、[`bugfix/RELEASE-NOTES.md`](./bugfix/RELEASE-NOTES.md) §9；
  **顺带更正**：`f898a23`（2026-10-02）已实现规则调试器 UI 与备份/恢复，M6 因此从「未开始」改为「大部分已落地」，
  并新登记 T-DATA-7（导入并非全量覆盖）+ 三条坑进 [`PITFALLS.md`](./PITFALLS.md)。
- **T-DATA-7 备份导入改为真「全量覆盖」（2026-10-07）**：`replaceShelf` 先清 `books` / `progress` 再写 + `lastWriteAt.clear()`；真机实测 3 本 / 7 条 → 导入 1 书 1 进度的 fixture → 1 本 / 1 条，重启不复现。证据 → [`bugfix/TASKS.md`](./bugfix/TASKS.md) §T-DATA-7。
- **T-CROSS-3 进度写竞争完整修复（2026-10-07）**：口径从「时间戳缓解」改为「**播放中音频独占，阅读页只读**」——
  新增 `model/ProgressOwner.ets` 归属仲裁（`saveProgress(p, writer)` 检查先于 `lastWriteAt` 守卫；`TtsController.setPlaying` 为 `playing` 唯一写入口，
  起播 claim / 停播先落盘再 release），并顺带修 `Reader.onTtsProgress` 跨章跟随缺段落锚点（原来会落到章首并写库）。
  真机四场景 + **修复前对照**（含反向取证：修复前同一操作库确实被覆盖）→ [`bugfix/RELEASE-NOTES.md`](./bugfix/RELEASE-NOTES.md) §11、
  [`bugfix/TASKS.md`](./bugfix/TASKS.md) §T-CROSS-3。
- **T-SHELF-6 TOC 缓存新鲜期 + 后台重爬（2026-10-07）**：登记的「文档↔实现口径分歧」逐路径核对后是**更大的产品缺陷** ——
  TOC 缓存只比 `tocUrl`（`CachedToc.fetchedAt` 写了没人读）→ 缓存事实上的**永久**，`tocUrl` 不变的连载书**新章永不出现**（目录少章 + 书架永远「已读到最新章」），
  只有清缓存 / 配额驱逐 / 换源才重爬。修法：`TOC_REFRESH_AFTER_MS = 6h` 新鲜期 + 打开书时**后台异步重爬**（先渲染缓存；失败静默回退；章数变化则采新目录
  并用新分母重写 `percent` 让书架自愈），顺带把 `buildTocItems` 改用 `setItems()`（**LazyForEach 只在创建时读一次数据源**，换实例不刷新已挂载列表）；
  书架三态文档口径同步改为「快照」。真机 8 项证据（含插桩伪造新章 → 目录 29 章 + 书架 `28章/29章`；TTL = 0 / 2000ms / 6h 三档）→
  [`bugfix/RELEASE-NOTES.md`](./bugfix/RELEASE-NOTES.md) §13、[`bugfix/TASKS.md`](./bugfix/TASKS.md) §T-SHELF-6。
- **T-SHELF-5 封面解码失败日志（2026-10-08）**：定性从「待确认的日志噪音」纠正为**真 bug（日志噪音 + 用户可见永久空封面）**——
  根因不在解码器也不在 `BookCover` 取用路径，而是 **Rust `download_cover` 不校验正文是不是图片**（详情页 / 防盗链 HTML 照样写进 `cover_*.img`）**且缓存命中即早退**（中毒后永不复检/永不重下，
  每次渲染重试解码 → `ImageSource` / `62980118` 刷屏）。修法：写盘前嗅探图片签名（非图片不落盘，返回 `not_image`）+ 缓存命中先验头 64 B（旧毒文件删除重下 = 自愈）+ ArkTS 解不开就删文件并负缓存（每 URL 每会话只试一次）。
  真机：启动 8s 内该组错误 **15 行 → 0 行**，沙箱 38 个封面缓存**全为合法 JPEG**、中毒文件已消失，封面渲染布局与修复前逐行一致（无回归）→
  [`bugfix/RELEASE-NOTES.md`](./bugfix/RELEASE-NOTES.md) §14、[`bugfix/TASKS.md`](./bugfix/TASKS.md) §T-SHELF-5。
- **T-TTS-6（中文原神角色音色）→ 用户决定不做（2026-10-11）**：当前 VPS 上无解 —— **A** 声纹匹配已证伪（`fanchen-C` 的 187 声线非原神角色，含真阳性对照）、
  **B** ZipVoice + 官方中配参考音频（音色 7/7 命中、RTF<1，但 `num_steps=3` 的 few-step 毛刺不接受）、**C/D** 需租 GPU（换机器）。
  任务条目已从 [`bugfix/TASKS.md`](./bugfix/TASKS.md) 移除，决定固化在 [`decisions.md`](./decisions.md) D14；调研全文留在 [`research/TTS-VOICE-SOURCES.md`](./research/TTS-VOICE-SOURCES.md)（纯参考、不再跟进）。
  **→ 2026-10-11 晚更新：D14 已部分重开**（离线批量预生成这个新前提下，ZipVoice `steps=12` 过了用户听感）→ [`research/TTS-PREGEN-PLAN.md`](./research/TTS-PREGEN-PLAN.md)、[`decisions.md`](./decisions.md) **D15**。
- **T-READ-4 引擎不支持 Legado `text.` 前缀 → 目录/正文只取第一页（2026-10-11 已修；2026-10-12 设备侧复验）**：DSL 只认 `class.` / `id.` / `tag.`，`text.下一页@href` 被当 CSS 选择器 →
  **0 结果且无诊断** → 翻页循环第一页后 break；内置源 **9 条规则 / 8 个源**命中（《剑来》目录 **50 条 vs 实际 1308 章**，真机书架的 `3章/50章` 即此）。
  修法：新增 `RuleToken::TextContains` + `html_extractor::apply_text_filter`（自身文本包含关键字、大小写不敏感）；`make test` **56 → 58 项全过**、`probe search 剑来` 零回归、`make rust` 成功。
  **设备侧已于 2026-10-12 复验**（换源时旧缓存被清、重爬得 1308 章，见上文「换源」条）；同批定性的「《大唐》目录加载失败」在主机侧无法复现（`probe toc` 正常 1449 条）⇒ 非引擎缺陷。
  证据 → [`bugfix/RELEASE-NOTES.md`](./bugfix/RELEASE-NOTES.md) §17、[`bugfix/TASKS.md`](./bugfix/TASKS.md) §T-READ-4、[`PITFALLS.md`](./PITFALLS.md)。
- **书架编辑模式（多选删除）**：已实施并真机验证（2026-10-07，D1–D21）—— 见上文同名节；
  计划 / 逐步代码 / DoD 逐条证据见 [`archive/SHELF-EDIT-PLAN.md`](./archive/SHELF-EDIT-PLAN.md)（§7 / §8 / §10 / §12.3），
  五轮审计轨迹原文见 [`archive/PROGRESS-HISTORY.md`](./archive/PROGRESS-HISTORY.md) §附。
- **换源（v1.1）实现 + 真机验证（2026-10-12）**：阅读页顶栏 `...` **左侧**新增「换源」入口 → 抽屉内**渐进**检索候选（一源一次 `search`，6 并发）→ 确认框 → 切换。
  候选判定 = 书名 + 作者严格匹配（`model/SourceSwitch.ets::isSameBook`）；切换 = **换 `bookId`**（删旧 `books`/`progress` 行 + 清旧源章节/目录缓存 + 插新行，保留 `addedAt`），
  进度按章节序号迁移（先按章节名对齐，落空按 `percent` 折算，`locateChapter`）；听书进行中先停播（`TtsController.stop`，否则新行的进度写会被 `ProgressOwner` 丢弃）。
  **零 Rust 改动**（不依赖 `bookUrlPattern`）→ 决策 [`decisions.md`](./decisions.md) **D16**（D11 据此修订）。
  **真机证据**（`33Z0224424136564`，《剑来》 bbiquge8 ⇄ 🎉云中书库 **往返**切换，`uitest dumpLayout` + 沙箱 `ls`）：
  ① 抽屉头部 `· 当前 <源名>` 随切换更新，进度文案 `已检索 5/6 个书源` → `共 2 个候选`（渐进上屏可见）；
  ② 严格匹配只出 1 个其它源、无同名异书；《天堂向左 深圳往右》无候选 → 空态文案正常；
  ③ 确认框可取消；落点为迁移章且正文来自新源（`第四卷/第四章 黄鸟` → `第一百零四章 坐地分赃`，即 `percent` 对齐 4/50 → 104/1308）；
  ④ 书架仍 3 本、无旧行残留，`aa force-stop` 重启后不变；**换回原源**同样成功（双向可逆）；
  ⑤ **旧源缓存真被删**：换回后沙箱 `files/tocs/` + `files/chapters/` 里云中书库的 `ee8114a5*`（3 章 + 188 KB 目录）消失，只剩 `5b4fad87*`；
  ⑥ 顺带复验 **T-READ-4 设备侧**（见 [`bugfix/TASKS.md`](./bugfix/TASKS.md)）：旧目录缓存（修复前 50 条）被换源清掉后重爬得 bbiquge8 **1308 章**。
  **未验**：本地 TXT 书点「换源」→ toast（设备书架无本地书，只做了代码审查）、听书**播放中**换源（未起播）。
  另记一条观察：旧目录残缺时（50 条 vs 实际 1308）`percent` 对齐会大幅漂移（4 章 → 104 章）—— 属 T-READ-4 的历史数据后果，不是换源缺陷。
- **换源：候选漏判 + 检索等待 + 两处 UI 刷新（2026-10-13，真机已验证）**：用户报「《剑来》换源只有 1 个候选」并抱怨每轮要等 13 源全跑完。
  主机侧 `probe search 剑来 --json`（13 内置源 / 560 条）把症状拆开：**同名 8 条**里 `小说` / `黑炎小说` 的作者字段是 `作者：烽火戏诸侯`，
  而 `isSameBook` 用的 `normalizeKey` 只删空白、不认标签 → **2 条被当「另一本书」静默丢掉**（命中 6/8 → 修后 **8/8**）；
  另有 `m.bbiquge8.net` 两条书源（`bbiquge8` / `笔趣阁8`，`bookSourceUrl` 一字不差）造成同站重复行（**5 行 → 7 行**）。
  四处改动：① `作者：` / `最新章节：` 前缀清洗收敛到 `common/Format.ets` 单点（`SearchResult` 私有副本删除），`isSameBook` 比作者前先削；
  ② 同域去重（域名 + 搜索模板，见 `SourceSwitchPanel.dedupeBySite`，行级也按域名）；
  ③ 检索预算：单源超时 10s→**6s**、全局派发预算 **10s**、候选够 **3 条**即收尾（进度行写原因 + 「继续检索」），候选结果**会话缓存 30 分钟**（重开抽屉直接上屏 + 「重新检索」）；
  ④ 新 `model/SourcePrefetch.ets`：行一上屏就预热最靠前 **2** 个候选的 `bookInfo` + `toc`（点「切换」时宿主直接命中，原链路 `bookInfo` 1.1s + 目录 5.9s = 7s），
  其余候选串行补一次 `bookInfo` 把行内占位换成「最新：xxx」；**只放内存**（不写 `TocCache`，没选中的候选不留垃圾）。
  **真机复验又逮到两处（改完这两处才算闭环）**：⑤ 候选行 `ForEach` 的 key 只含「URL + 序号」，预热回填只换文案 → key 不变 → **子树不重建**，
  「最新：xxx」拿得到却不上屏（修法：列表 key 追加 `chapter`）；⑥ 「重新检索」点了没反应 —— `startSearch()` 无条件先试 `restoreCache()`，
  刚打开时的缓存还新鲜 → 重搜被缓存原样命中（修法：`startSearch(forceFresh)`）。
  **真机结果**：候选 **2 行 → 7 行**（12 源参与）、3s 上屏 6 行、`已检索 12/12 个书源 · 候选已够用`、预热命中切换 **≤1s**（原 7s）、
  重开抽屉「上次检索到的 7 个候选」秒上屏、`bbiquge8 ↔ 小说` 往返后书架进度 `104章/1308章` 未丢。
  留一条未解释的观测：曾有一次换源后重开抽屉 7 行全无「当前」标记（随后三次复现均正常）。
  证据 → [`bugfix/TASKS.md`](./bugfix/TASKS.md) §T-SWITCH-1、[`bugfix/RELEASE-NOTES.md`](./bugfix/RELEASE-NOTES.md) §18。

**未决**

- **TTS 离线批量预生成（2026-10-12 已立项，阶段一未开工、仓库与线上零改动）**：用户提「VPS 空闲时批量预生成 50–100 章，听书优先读缓存音频」。
  评估结论：**约束搬家** —— `RTF<1` 只属于实时流式，批量改用 `RTF ≤ 24 ÷ 每日收听小时数`（听 2 h/天 → ≤12）。
  **用户拍板（同日）**：① 默认引擎 = **GPT-SoVITS v2ProPlus（流萤微调）**（试听后「`cut5` + `fragment_interval=0.3` 这个听着效果比较好」）；
  ② 缓存 **WAV 直出（24 kHz mono）+ 严格淘汰**（已播放优先删、**未播放项保护**）；③ 素材**先手动喂**（curl），客户端入口后置。
  实测（同机同文本）：整章 8741 字 = 6 块 / 音频 **1802.5 s（30.0 min）** / 合成 **9992.4 s（2.78 h）** / **RTF 5.57** / 常驻 **3.29 GB**（HWM 3.65）
  ⇒ 一章 3000 字 ≈ **57 min 算力 / 9.8 min 音频 / 31 MB**，100 章 ≈ **95 h + 3.1 GB**；v4（钟离）RTF **115.3** ⇒ CPU 出局；零样本底座（花火/卡芙卡）5.86–7.17 可用。
  两个反直觉实测：**`cut3` 比 `cut5` 慢 1.75×**（长段让 AR 单段吐 612 token，也正是整章 `cut3` 被 OOM 的直接原因）、**`fragment_interval=0` 与 `0.3 s` 算力完全相同**（只少 14% 段间静音）；
  另一条硬结论：**逐句调用比原生慢 2×**（每次 `run()` 有 ~12 s 固定开销）⇒ 离线批量必须「一次调用 + 合批」，段级时间锚点只能按字数插值。
  硬约束：**磁盘**（`/` 剩 **1.2 G**，需先回收 ~1.5 G；100 章装不下 ⇒ 听完即删 + 窗口）与**内存**（3.3 GB 与线上 VITS 抢：跑批时 `Mem available` 100–190 MB、swap 4.9 G，首个 `/tts` 要等引擎页换入）。
  施工图（数据契约 / 服务端 / 磁盘回收 / App 侧「填写方式」/ 验收 / 下个 session 的 prompt）→ [`research/TTS-PREGEN-IMPL.md`](./research/TTS-PREGEN-IMPL.md)、
  实测明细 [`research/TTS-PREGEN-PLAN.md`](./research/TTS-PREGEN-PLAN.md)、决策 [`decisions.md`](./decisions.md) **D15**（**D14 部分重开**，实时链路不变）、任务 [`bugfix/TASKS.md`](./bugfix/TASKS.md) **T-TTS-7**；
  试听包 `~/Desktop/tts-gpt-sovits/`（含 `整章/` 30 min 成品与 6 分块）与 `~/Desktop/tts-zipvoice-batch/`。

- （当前无阻塞性未决项；待做清单与状态以 [`bugfix/TASKS.md`](./bugfix/TASKS.md) 头部摘要为准。
  **T-TTS-5 的客户端四项已于 2026-10-11 落地**（`readTimeout` 120s / 5 音色改名 + 旧名归一 / 语速客户端下发 / `SPEED_SCALE` 起点 0.75），
  真机端到端已跑通（同一章连播 5 段 0 回退，服务端 `speed=0.750/1.500` 与 UI 档位对得上），并顺带修掉服务端「纯标点分段除零 500」
  ——但**设备在验收中途再次掉线**（`hdc list targets` 为空），**5 音色的真机逐个切换**与**听感终值**仍待用户/设备：
  服务端侧 5 音色已逐个 200 验证，试听包 `~/Desktop/tts-abtest-tts5/`（5 音色 + 3 档 `SPEED_SCALE`）→ [`bugfix/TASKS.md`](./bugfix/TASKS.md) §T-TTS-5、[`bugfix/RELEASE-NOTES.md`](./bugfix/RELEASE-NOTES.md) §16。
  另两个小项已按用户决定改掉：远端语速上限 `TTS_REMOTE_SPEED_MAX=1.2`（1.5x/2.0x 档置灰，本机有效语速上限 ≈1.0）、
  `fallbackToSystem()` 改为**不落盘**（本次会话回退系统 TTS，下次听书自动重试远端）。）

- **T-READ-3（预取去重）已关闭（2026-10-08 实现 + 2026-10-11 真机复验）**：`Reader.fetchContent` 加 `bookId#index` 单飞表，并发切章时同一章只请求一次、只写一次盘。
  真机正/反对照（设备 `33Z0224424136564`，插桩已还原）：修复后 key `#11` = miss×2 + **join×1 + engine×1**；修复前对照（旁路 `inflight.set`）key `#39`/`#45` = miss×2 + **engine×2**、join 0 次。
  顺带删死代码 `prefetch` → [`bugfix/TASKS.md`](./bugfix/TASKS.md) §T-READ-3、[`bugfix/RELEASE-NOTES.md`](./bugfix/RELEASE-NOTES.md) §15。

- 目录分页 `nextTocUrl` / 卷 `isVolume` 已在引擎实现（真机 detect 覆盖当页路径），多页目录待复验。
- 书源持久化仍用 `preferences` JSON（书籍/进度已用 `relationalStore`）；后续可迁移统一。
- 规则「静默失败」诊断：`parseWithDiagnostics` 已可返回 regex/CSS/JS 诊断，调试器 UI 也已存在（`pages/RuleDebugger.ets`，随 `f898a23` 落地）——该页尚未真机验收，仅在 release 冒烟中确认入口可达。
- 文件导入/剪贴板导入：URL 导入已真机复验（成功 1 / 排除 2：需 JS 1、需登录 1）；文件/剪贴板走同一门禁函数。
- 搜索排序已改为 Legado 分桶 + 同名同作者跨源合并 + 源 `weight`（见 [`archive/PROGRESS-HISTORY.md`](./archive/PROGRESS-HISTORY.md) §搜索结果页整改）；
  另加**书源置信度**（失败扣分/成功回分/持久化）决定**搜索调度顺序**（同文件 §书源置信度 + 搜索滑动窗口调度）。
- **同 URL 重复书源**（用户库内确有两例：`bbiquge8` / `笔趣阁8` → `http://m.bbiquge8.net`）是「URL 当主键」
  这一类缺陷的共同诱因。搜索侧已修两处：源状态抽屉 key 改序号（[`archive/PROGRESS-HISTORY.md`](./archive/PROGRESS-HISTORY.md) §源状态抽屉内容整改）+ 搜索前 `dedupeByUrl`（同文件 §选择来源抽屉整改）；书源管理列表 key 也已改为 `url#index#enabled`（见 [`bugfix/TASKS.md`](./bugfix/TASKS.md) T-SRC-1，已 release 真机复验通过）。

## 交接备忘

- 构建/安装/调试命令：**首选 `make`（`make help` 看全部；`make run` = 编译→安装→force-stop→启动）**，
  环境变量与签名的完整说明见 [`development.md`](./development.md)（流程清单见 skill `harmony-device-run`）。
- 踩坑按症状查 [`PITFALLS.md`](./PITFALLS.md)；技术决策与理由见 [`decisions.md`](./decisions.md)。
- **底部抽屉规范见 [`specs/UI-SPEC.md`](./specs/UI-SPEC.md)**（唯一权威；改动抽屉必须全项目同步）。
- 引擎复用清单与门禁见 [`engine.md`](./engine.md)。
- 架构与 NAPI 边界见 [`architecture.md`](./architecture.md)。
- 端侧自建 TTS（本地 GPT-SoVITS 音色）**已于 2026-10-12 封存**（不再推进）：原型真机跑通但 OHOS ORT 动态
  shape 根因无解，记 D12；证据、脚本、测量结果与未推送代码见 [`archive/TTS-LOCAL-ONNX/`](./archive/TTS-LOCAL-ONNX/README.md)
  （原计划 [`research/TTS-PLAN.md`](./research/TTS-PLAN.md)）。
