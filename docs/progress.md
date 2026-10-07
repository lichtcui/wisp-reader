# 进度 / 下一步

> **本文件只记「当前状态 / 未决风险 / 交接」，是常读文件（勿通读，按下方目录取段）。**
> - 权威设计 → [`plan.md`](./plan.md)　决策与理由 → [`decisions.md`](./decisions.md)　踩坑按症状查 → [`PITFALLS.md`](./PITFALLS.md)
> - 当前任务与文档路由 → [`../AGENTS.md`](../AGENTS.md)
> - **历史流水（M0–M4 结果 / 各页整改 / 抽屉两次真机返修 / 书架编辑五轮审计轨迹）已移出**到
>   [`archive/PROGRESS-HISTORY.md`](./archive/PROGRESS-HISTORY.md)（**默认不要读**，需要时查它的目录）。

## 目录（行号定位，只读需要的段）

> 本目录由 `make docs-toc` 自动生成，**勿手改**（行号是生成时快照）。

<!-- TOC:BEGIN -->
- 里程碑状态 — L23
- M5 结果（2026-09-25，真机验证） — L37
- 书架编辑模式（多选删除）（2026-10-07，已真机验证 D1–D21） — L77
- 未决 / 风险 — L111
- 交接备忘 — L156
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
| v2 | QuickJS/Boa JS 引擎、换源、在线 TTS、真分页 | ⏳ |


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
  `pages/ListeningSettings.ets`（默认语速/音色），`common/ChapterUtil.ets`、`model/BookContent.ets`（正文加载/清洗复用）。
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

## 未决 / 风险

> **要动手修的清单在 [`bugfix/TASKS.md`](./bugfix/TASKS.md)**（P0→P2，每项带证据位置与验证方式）；
> 本节只记「还没想清楚 / 待复验」的风险，不重复任务项。

**近期已关闭**（详细信息看指针，不在本文件重复）

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
- **书架编辑模式（多选删除）**：已实施并真机验证（2026-10-07，D1–D21）—— 见上文同名节；
  计划 / 逐步代码 / DoD 逐条证据见 [`archive/SHELF-EDIT-PLAN.md`](./archive/SHELF-EDIT-PLAN.md)（§7 / §8 / §10 / §12.3），
  五轮审计轨迹原文见 [`archive/PROGRESS-HISTORY.md`](./archive/PROGRESS-HISTORY.md) §附。

**未决**

- （当前无阻塞性未决项；待做清单与状态以 [`bugfix/TASKS.md`](./bugfix/TASKS.md) 头部摘要为准。）

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
- 端侧自建 TTS（本地 GPT-SoVITS 音色）调研与原型计划见 [`research/TTS-PLAN.md`](./research/TTS-PLAN.md)
  （与 M5 系统 TTS 并行、未立项；下一步 = TTS-PLAN §9 P0）。
