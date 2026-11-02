# RELEASE-NOTES — 回归与发布候选（S10）

日期：2026-09-27 · 基线：`2bedba6`（S9 收尾）· 本轮**未提交**（用户未要求）
范围：全模块回归审查 + TASKS 逐项验收 + 构建/签名复核 + 清理。
配套：任务状态见 [`TASKS.md`](./TASKS.md) §「回归验收状态」。

---

## 0. 发布版本建议

| 项 | 当前 | 建议 | 说明 |
|---|---|---|---|
| `versionName` | `0.1.0` | **`0.2.0`** | M0–M5 全部功能落地 + 一轮跨模块回归修复 + UI-SPEC 收口，已具备可演示的完整阅读/听书闭环 |
| `versionCode` | `1000000` | **`1000001`** | 当前版本号长期固定为 `1000000`，需建立递增规则（建议每次发布 +1；正式对外前再统一映射到 `x.y.z` 规范） |

> 版本字段位于 `AppScope/app.json5`。本轮未改动，避免与发布流程冲突。

---

## 1. 变更汇总

### 1.1 关键缺陷修复（跨模块）

| ID | 问题 | 修复 |
|---|---|---|
| R1 / T-CROSS-1 | 听 A 书时打开 B 书，B 会被 A 的 TTS 进度驱动跳章、且把 A 的章节号写进 B 进度 | `Reader.onTtsProgress` / `isSpeaking` 增加 `tts.isActiveFor(bookId)` 守卫（`Reader.ets:65-77`、`:450-457`） |
| R2 / T-CROSS-2 | 暂停 / 整本播完后 `AUDIO_PLAYBACK` 长时任务不结束（耗电、后台任务泄漏） | `pause()` 与末章自然结束分支调用 `stopBackground()`；恢复播放经 `startBackground()` 重启（`TtsController.ets:855`、`:825-838`） |
| R3 / T-CROSS-3 | 阅读与听书对同一本书的无条件进度写互相覆盖 | 首轮：`saveProgress` 加 `lastWriteAt` 时间戳防旧写覆盖；**2026-10-07 完整修复**：新增 `model/ProgressOwner.ets` 归属仲裁（播放中音频独占、阅读页只读），详见 §11 |
| R6 / T-TTS-1 | `stop()` 从不 `shutdown()` TTS 引擎、引擎单例资源不释放 | `stop()` 增 `engine.shutdown()` 并置 `engine=undefined`、复位日志位（`TtsController.ets:226-243`） |
| R7 | `onError` 后残留 in-flight 缓冲，`resume()` 可能永久卡在 flushIndex | `onError` 清 in-flight、停 flush/progress 定时器、停后台 |
| R8 | 整章播完后点「播放」无声（队列已排空） | 新增 `queueExhausted()`，`resume()` 检测到播完后从章首重播 |
| — | 快速切章时慢请求迟到会覆盖新章节（正文回退、进度写错） | `Reader.loadChapter` 增 `loadGen` 代次守卫（`Reader.ets:296-334`） |
| — | `paragraphIndex` 恢复时未夹取，越界值被回写 | `applyChapter` 内夹取到 `[0, len-1]` |

### 1.2 按模块

**阅读（Reader）**
- 目录正/倒序切换后**定位到当前章**（原来跳到列表顶部）。
- 顶栏返回 / 更多改用统一组件 `AppBackButton` / `MoreMenuButton`（spec 组件此前从未接线）。
- 目录浮层内容根去掉写死 `height('100%')`，交 `BottomDrawer` 布局。

**听书（Listening / TTS）**
- 生命周期闭环（见 §1.1）：后台任务配对、引擎释放、定时器自然结束清理、错误可恢复、播完可重播。
- 听书目录抽屉由 `overlay` 改为 `system` 模式（`large`），符合 UI-SPEC「目录走系统 sheet」。
  > ⚠️ **已被取代（2026-10-06）**：该条连同「目录走系统 sheet」规则已作废，现行为**全部抽屉统一 overlay**，
  > 见 [`docs/specs/UI-SPEC.md`](../specs/UI-SPEC.md)。请勿按本条回改。
- 浮动按钮（`FloatingListenButton`）复核：挂载后测量、拖动吸附定时器清理、`HitTestMode.None` 均正确。

**书源管理**
- 列表 `ForEach` key 改为 `bookSourceUrl#enabled`（去掉 `index`），「一键关闭不可用」开关即时刷新。
- `runDetect` 增加 `busy` 重入守卫并在开始时复位状态抽屉。

**数据管理 / 缓存**
- 章节缓存内存层加 **24 条 LRU**；封面 PixelMap 缓存加 **64 条 LRU**（长会话内存不再无界增长）。
- 封面统计/清理精确匹配 `cover_*.img`（避免误伤未来其它 `cover_` 前缀文件）。
- 数据库改为**应用启动即初始化**（`EntryAbility.onCreate`），从搜索直达阅读也能落进度（原仅进书架 Tab 才初始化）。

**引擎边界**
- `search` 现向 native 透传 `opts.concurrency`（此前被丢弃，当前单源无影响，修复契约）。

### 1.3 UI-SPEC 合规整改

| 项 | 处置 |
|---|---|
| 书架「…」功能键热区不足 44×44 | → `MoreMenuButton`（44×44 + 按压反馈） |
| 详情页 `Text('‹')` 返回 | → `AppBackButton(tone:'onBrand')` |
| 阅读页返回 / 更多为手搓实现 | → `AppBackButton` / `MoreMenuButton`（带 day/night 颜色覆盖） |
| 听书目录用 overlay 模式 | → `system` + `large`（⚠️ **已被取代**：2026-10-06 起统一 overlay，见 [`docs/specs/UI-SPEC.md`](../specs/UI-SPEC.md)） |
| 抽屉内容根写死高度 | → 移除（Reader / Listening） |
| 详情页面板圆角 16 | → 20（`sheetTopRadius`，可选项） |
| `mask` 色令牌 | 复核 base `#52000000` / dark `#80000000`，已正确 |
| 抽屉实现 | 复核：全项目**无裸 `bindSheet`**，均经 `BottomDrawer` |

### 1.4 清理

- 删除死代码：`ChapterCache.hasCachedChapter`、`Format.formatWordCount`、`ShelfRepository.getBook`。
- 接线此前**未被编译**的 `AppBackButton` / `MoreMenuButton`（因此暴露并修复其 `.scale(number)` 编译错误：改用 `ScaleOptions`）。
- `ShelfRepository.removeBook` 保留（删除书架功能的预留 API），补注释说明需同步清理章节/本地缓存。
- 移除工具临时目录 `.pi/`，并加入 `.gitignore`。
- 修复 `docs/progress.md` 对不存在的 `docs/bug.md` 的引用。

---

## 2. 构建与产物证据

| 步骤 | 命令 | 结果 |
|---|---|---|
| 环境 | `harmonyos-build-doctor`（Node / `DEVECO_SDK_HOME` / JBR / hap-sign-tool 均已定位） | OK |
| clean debug | `hvigorw clean` + `assembleHap --buildMode debug --no-daemon` | **BUILD SUCCESSFUL**（全量任务，0 error） |
| release HAP | `assembleHap --buildMode release` | **BUILD SUCCESSFUL**（`SignHap` 执行） |
| release APP | `assembleApp --buildMode release` | **BUILD SUCCESSFUL**（`SignHap` + `SignApp`） |
| Rust 回归 | `cd rust/legado-engine && cargo test` | **54 passed; 0 failed**（本轮无 Rust 改动，未重出 `.so`） |

**发布候选产物（最终、含清理后代码）**

| 项 | 值 |
|---|---|
| 文件 | `build/outputs/default/source-reader-default-signed.app` |
| 大小 | 2,736,684 B |
| SHA-256 | `e1691742790cae670fa313e1c6c7ba34a99a99156fb69b71f3cf6f1e8db99d45` |
| `verify-app` | success；`Digest verify result: true`（SHA-256） |
| `verify-profile` | success；`bundle-name = com.lichtcui.sourcereader` |

未签名 HAP：`entry/build/default/outputs/default/entry-default-signed.hap`（5.55 MB，release）。

---

## 3. 签名审计（2026-10-19 已外置）

| 字段 | 当前状态 |
|---|---|
| 仓库内 `build-profile.json5` | `signingConfigs: []`；产品不再绑定签名身份，不含路径或口令 |
| 仓库外身份文件 | `~/.ohos/source-reader/signing.json`，权限 `600`，格式 `{ debug, release }` |
| 构建模式注入 | `hvigorfile.ts` 按 `SOURCE_READER_SIGNING_MODE=debug|release` 选择身份 |
| Debug | 已配置，仅用于本地开发安装 |
| Release | `null`；`make app-release` / `make verify-*` 必须以 `PUBLICATION_BLOCKED` 阻断 |
| 历史审计 | 2026-09-27 的产物曾由 Debug Profile 签发，且 `build-profile.json5` 内含本机路径与 DevEco 密文口令；该快照已由 `scripts/migrate-signing.sh` 机制取代 |

**结论：`SIGNING_READY` 仍未达成。** 当前没有独立 Release 身份，不能构建或声称已有可公开发布产物；已生成的 Debug 包不得用于正式分发或 AppGallery 上架。

**发布前必做**
1. 申请 release 类型证书与 Profile（含 distribution-certificate），填入外部签名文件的 `release` 字段；不得复用 Debug 的 alias / 证书 / profile。
2. 运行 `make app-release`，再运行 `make verify-app` / `make verify-profile`，复核 profile 类型、bundle、有效期与 SHA-256。
3. 只有两道门禁全部通过后，才把发布状态提升为 `READY_FOR_PUBLICATION`。

---

## 4. 已知遗留 / 未完成

### 4.1 发布阻塞项

| 项 | 说明 |
|---|---|
| **Release 签名身份** | 见 §3，当前为 Debug Profile |
| **版本号** | `versionName`/`versionCode` 未提升 |

### 4.2 顺延的 TASKS（非本轮范围）

- `T-SHELF-1` 删除书籍清理缓存：`removeBook` 无调用点（无删除 UI），待删除入口一并实现。
- `T-SHELF-3` 进度三态在 `percent` 极小值时的反推边界：**2026-10-07 已修复并真机验证**（反推收敛到 `Format.deriveTotalChapters`，脏值降级「第N章」；见 §12）；当时登记的 `toc.length` ↔ `percent` 口径分歧已于同日修完（T-SHELF-6，见 §13）。
- `T-READ-1` `Reader.sanitize` 与 `BookContent.sanitizeText` 合并：**2026-10-08 已完成**（纯重构；两份当时逐字节一致，合并后阅读页与听书跨章共用 `BookContent.sanitizeText`，真机复核段落下标一致，详见 [`TASKS.md`](./TASKS.md) §阅读）。
- `T-READ-3` 章节预取 in-flight 去重（LRU 已降低重复写盘概率）。
- `T-DATA-4` 缓存 LRU/上限策略（未开始，**M6 最后一项**）；`T-DATA-3` 备份/恢复已于 2026-10-07 release 真机验证通过（§9），其「全量覆盖」语义缺陷 `T-DATA-7` 已于同日修复并真机复验（§10）。
- `T-VER-3` 真机闭环已完成（见 §5）；跨书串扰与后台任务结束的直接观测待条件复验。
- 规则调试器与备份/恢复**并非未开始**：随 `f898a23`（2026-10-02）落地（`pages/RuleDebugger.ets`、`pages/BackupManage.ets`），本轮记错。

### 4.3 保留的工作文档（未纳入版本控制）

`AUDIT.md`、`ROOT-CAUSE.md`、`TASKS.md`、`UI-SPEC.md`、`TTS-PLAN.md`、`HANDOFF-S3/4/5.md` 为未跟踪工作文档（`HANDOFF-S6..S9.md` 已跟踪）。
> 注：其中 `UI-SPEC.md` 已于 2026-10-06 重建为 [`docs/specs/UI-SPEC.md`](../specs/UI-SPEC.md)（底部抽屉统一规范，现行有效）。
建议择一：提交归档，或加入 `.gitignore`；**本轮未删除**这些审计轨迹。

---

## 5. 真机冒烟（2026-09-27，设备 `33Z0224424136564`）

设备接通后完成 `docs/development.md` 闭环（安装 → `aa force-stop` → `aa start` → `hilog`/`uitest` 观测）。
release 与 debug 两个包均验证；release 包**不输出 App 自身 `hilog`**（仅系统日志），故 TTS 链路证据取自 debug 包。

| 观测项 | 结果 |
|---|---|
| 安装（release / debug） | ✅ `install bundle successfully` |
| 启动、`hilog` 无 `JSCRASH`/`CPPCRASH` | ✅（仅一条既有 NAPI `AddCleanupHook` 警告，无害） |
| 书架渲染 4 本 + 进度三态 | ✅ |
| DB 启动即初始化 + 进度恢复（`initShelf`） | ✅ 打开本地书直接停在已存进度「第三章 归途」 |
| 阅读页正文渲染（本地书） | ✅ |
| 阅读菜单（顶栏/底栏） | ✅ |
| 目录浮层（overlay）+ 书籍卡片 + 「定位」 | ✅ |
| 目录 正序 ↔ 倒序 切换 | ✅ 标签变更、列表反转、当前章在顶 |
| 顶栏「更多」→ `MoreMenuButton` 菜单「书籍详情」 | ✅（新接线组件真机可用） |
| 听书入口 + `FloatingListenButton` | ✅ 收起听书页后阅读页右下出现 52vp 气泡 |
| TTS 全链路 | ✅ `engine ready` → `avsession ready` → `renderer ready` → `begin para=0` → **`background task started`** → `tts format rate=16000` → `play para=1` |
| 自然播完（末章） | ✅ 播到章末自动停止（时间冻结） |
| **播完后重播**（本轮修复） | ✅ 再点播放 → `begin para=0` + `background task started`（`queueExhausted()` 重播） |
| **暂停**（本轮修复） | ✅ 命中 `pause` 日志路径（含 `stopBackground()`） |

**未覆盖**：
- 跨书串扰守卫（`T-CROSS-1`）：设备上仅一本本地书可读，联网书源当次取目录失败，无法构造「听 A 读 B」。守卫为纯代码路径（`isActiveFor`），待联网真机复验。
- 后台长时任务**结束**的直接观测：本机 `hidumper` 的 `BackgroundTaskManager` 不提供任务明细 dump；由 `pause`/自然结束路径的代码 + `background task started` 日志间接佐证。

---

## 6. 回归审查发现（评审池，未全部修复）

由 4 路并行只读评审得出，以下为**未采纳/低优先级**项，供后续排期：

- 阅读正文 `ForEach` 未用 `LazyForEach`（长章节一次性实例化）。
- `Reader` 两个 `setTimeout`（滚动定位）未在 `aboutToDisappear` 清理。
- `TtsController` 迟到 `onData` 不修正时间轴时长；`releaseRenderer` 未 `off('audioInterrupt')`。
- `pause()/resume()` 渲染器 start/pause 未串行化（快速切换存在竞态）。
- `SourceRepository` 的 `preferences.flush()` 未 await（持久化窗口，未处理拒绝）。
- `BookSourceManage` 文件导入无大小上限；`detect` 异常时 `detail` 文案固定为「搜索未命中」。
- `CacheRepository.getCacheStats` 在 UI 线程同步遍历（万级文件需异步化）。

---

## 7. 验证矩阵

| 闸门 | 状态 |
|---|---|
| 代码评审（4 模块） | ✅ |
| TASKS 逐项验收 | ✅（见 `TASKS.md` 附录） |
| clean debug 构建 | ✅ |
| release 构建 + SignHap + SignApp | ✅ 历史结果（仅 Debug 身份；当前 Release 身份缺失） |
| Rust `cargo test` | ✅ 54/54 |
| `verify-app` / `verify-profile` | ✅ 历史结果（身份为 debug；当前门禁会阻断） |
| 签名就绪（公开发布） | ❌ 外部 `release = null` |
| 真机冒烟 | ✅ 已执行（见 §5） |
| 真机跨书串扰 + 后台任务结束直接观测 | ⏭ 待联网/工具条件复验 |
| Git 清理 | ✅ 签名材料已移出仓库；工作区 `build-profile.json5` 不再保存凭据 |

**最高发布状态：`SMOKE_TESTED`（仅限内部/开发渠道；公开发布仍受 Release 签名身份阻塞，未达 `READY_FOR_PUBLICATION`）。**
---

## 8. 增量（2026-10-07）：书架编辑模式（多选删除）+ 目录缓存统计

> 计划与逐行代码见 [`../archive/SHELF-EDIT-PLAN.md`](../archive/SHELF-EDIT-PLAN.md)（§8 S1–S4）。
> 本节为增量记录，§0–§7 仍描述 S10 快照。

### 8.1 新功能

- **书架长按多选删除**（用户确认交互 A–H）：
  - 长按书籍 → 进编辑态并选中该书；编辑态内点按加/减选（不打开阅读页）、长按忽略。
  - 顶栏改为「全选/取消全选 · 已选择 X 本书 · 完成」；底栏三 Tab 替换为「删除」（0 本时置灰）。
  - 编辑态锁 Tab 滑动（`.scrollable(!edit.editing)`）、系统返回键退出编辑态（`onBackPress`）、隐藏听书 FAB。
  - 删除走二次确认（`showAlertDialog`，红色「删除」）→ `BookRemoval.deleteBooks` → 退出编辑态 → 刷新书架 → Toast。
  - 角标：编辑态**所有**书都有角标（选中=实心红+白勾+封面 72% 透明；未选中=半透黑底+白环）；列表模式角标在行尾。
- **删除连带清理（T-SHELF-1）**：`books`/`progress` 行 → `chapters/{bookId}_*` → `tocs/{bookId}.json` → `local/{bookId}`（含内存层 evict）；删前 `tts.isActiveFor → stop()`。封面文件刻意不删（文件名是 Rust 侧 hash，ArkTS 无法定位）。

### 8.2 顺带修复

- **T-DATA-5**：`CacheStats` 增 `toc` 分类，「清理缓存」页新增「目录缓存」行（`isChapterFile` 改名为 `isJsonFile` 供 chapters/tocs 共用）。
- **T-DATA-6**：`clearCache()` 增 `removeDir(filesDir/tocs)`（此前目录缓存永不被清 = 磁盘泄漏）。

### 8.3 改动文件（9 改 + 2 新增）

`model/ShelfEditState.ets`（新）、`model/BookRemoval.ets`（新）、`pages/Index.ets`、`pages/Shelf.ets`、`components/BookCover.ets`、`model/ShelfRepository.ets`、`model/ChapterCache.ets`、`model/TocCache.ets`、`model/LocalBook.ets`、`model/CacheRepository.ets`、`pages/CacheManage.ets`。
`entry/obfuscation-rules.txt` **未改**（无新增 JSON 字段；且已按 §5.5 禁字符串式属性访问）。

### 8.4 构建与混淆证据

| 闸门 | 状态 |
|---|---|
| debug 构建（`assembleHap buildMode=debug`） | ✅ `BUILD SUCCESSFUL` |
| release 构建（`assembleHap buildMode=release`，含 SignHap） | ✅ `BUILD SUCCESSFUL`（比 D21 要求的「跑到混淆阶段」更强） |
| 混淆产物 | ✅ `.../release/obfuscation/{nameCache,fileWhiteLists,projectWhiteList}.json` 重新生成（2026-10-07） |
| 混淆面静态自查（K15/§5.5） | ✅ 全仓无 `@Monitor('edit.x')` / `this.edit['x']` / `ShelfEditState` JSON 往返 |
| 真机 DoD D1–D21 | ✅ **已验（2026-10-07，设备 `33Z0224424136564`）**：D1–D9 / D11 / D13 / D15–D17 / D19 / D21 全通过；D10 / D12 / D14 / D18 按用户决定跳过；D20 部分通过（书架书量不足）。逐条证据见 [`../archive/SHELF-EDIT-PLAN.md`](../archive/SHELF-EDIT-PLAN.md) §12.3 |

### 8.5 真机验证与真机专属修复（2026-10-07）

- **长按手势 bug（真机专属，计划外）**：计划 §8 的 `longPressToEdit(entry): GestureType` + `.gesture(...)` 写法在真机上**从不触发**——`.gesture()/.parallelGesture()` 只接受**内联手势字面量**，helper 返回的 gesture 被 ETS 编译器**静默丢弃**（转译产物退化为 `Gesture.create(GesturePriority.Parallel); Gesture.pop();`）；另 `.gesture()` 为 `GesturePriority.Low`，在 `Navigation` 下输掉竞争。
  **修复**：改为 `.parallelGesture(LongPressGesture({ repeat: false, duration: 500 }).onAction(() => this.onLongPress(entry)))`（grid/list 同形），helper 改名 `onLongPress(entry): void`（只留 `longPressFired` + `edit.enter`）。长按 +498ms 触发 ✅。已回写计划 §1.6 #42/#43、§5 K16/§5.2、`TASKS.md` `T-SHELF-4`。
- **三个真机疑点关闭**：**R6** 500ms 手感 ✅（+498ms）；**R10** `Index.onBackPress` 生效、`EntryAbility.ets` **未改** ✅；**R12** 长按后不补送 click（`longPressFired` 兜底未依赖）、3s 慢滑不误进编辑态、编辑态慢滑不改选 ✅。
- **删除链路端到端**：删「夜的命名术」（当时 TTS 在播）→ 书架 4→3 且重启仍 3；DB `books` 4→3 / `progress` 7→6；`chapters/` 13→6、`tocs/` 4→3；应用内章节缓存 125.2→28.6KB、目录缓存 235.5→**73.8KB**（与文件字节逐一对应）；点击「清理全部缓存」四类归零；TTS 停（无后续 `play para=`）+ 听书 FAB 消失；双击「删除」防重入只删一次。
- **异常面**：`hilog` 全量扫描 **0 条** JS/ArkTS 错误 + **0 条**本应用 error 级日志（仅框架内部既有 `ImageSource` 等封面噪音）。
- **未验完整项**：**D20**（编辑态滚动）—— 本机书架 3–4 本不足一屏、不可滚，且三条加书路径（搜索 onSubmit / 文件选择器 / 缩小窗口）均不可自动化 → 以「慢滑不误触 + 编辑态慢滑不改选 + 不阻断滚动」三项替代证据；**D10 / D12 / D14 / D18** 已跳过（用户决定：未授权删本地书 / 删空书架，并跳过深色模式与读屏项）。
- **临时诊断已清理**：排查用的 3 条 `hilog('ShelfDiag')`（+ import）已移除，重新构建安装后复验 D1–D4/D6 通过。

**已知限制**：本节（§8）只覆盖书架编辑模式本身；release 包的**全局**冒烟见 §9。

---

## 9. release 包首次真机冒烟（T-VER-6，2026-10-07）

目的：混淆（`-enable-property-obfuscation`）类问题**只在 release 现形**——本轮首次把 release 包完整跑一遍并逐段取证。
包：`entry/build/default/outputs/default/entry-default-signed.hap`（17:58 构建）；设备 `33Z0224424136564`；取证手段 = `uitest dumpLayout` + `hilog -x` + `hidumper`（无 GUI）。

**结论：全部通过，未发现混淆类缺陷。** 逐项证据表见 [`TASKS.md`](./TASKS.md) §「release 冒烟结果（T-VER-6）」；要点：

| 面 | 结论 |
|---|---|
| 搜索 / 详情 / 目录 / 正文（NAPI JSON） | ✅ `BookSearchItem` / `bookInfo` / `content` 字段全部正读（「剑来」57 条结果、详情含最新章节、正文分页 `第1/3页`） |
| 书架 / 进度（relationalStore 读写 + 跨进程） | ✅ 加书 2→3 本、删书 3→0、导入恢复回 3 本，force-stop 重启后进度文字不变 |
| 听书（TTS→PCM→`AudioRenderer`→AVSession） | ✅ `is the topsession: true`，进度 `00:12 / 03:39` 推进，删正在播的书即停（AVSession 让出 top） |
| **备份导出（JSON.stringify）** | ✅ 导出文件键名**全未混淆**：sources 23 / books 13 / progress 7 字段 + `schemaVersion`/`exportedAt` 全对（`keep` 列表有效） |
| **备份导入（JSON.parse）** | ✅ 同一文件导入成功：书源 13 / 书架 3 本 / 进度 7 条 |
| 书源列表 key（T-SRC-1） | ✅ 同 URL 两条（`bbiquge8` / `笔趣阁8` → `m.bbiquge8.net`）分别渲染，列表头 7/13 启用与备份 JSON 对账一致 |
| 书架编辑态长按（T-SHELF-4 修复） | ✅ release 同样 `已选择 1 本书` → 全选 3 → 确认弹窗 → 删除 |
| 异常面 | ✅ 0 条 JS/ArkTS 错误、0 崩溃；应用级 error 仅框架噪音 |

**新发现（已登记）**
1. **T-DATA-7**：导入并非文案所称「全量覆盖」——`doImport` 只 upsert，不删除备份外的行（实测删书残留的 4 条孤儿进度在导入后仍在）；`removeBooks` 也不 GC 历史孤儿进度行。
2. **release 下应用 hilog 被系统过滤**：`hilog -T SourceReaderTts` 恒为空（domain `0x0000` 不落 buffer）→ release 冒烟只能靠系统侧日志；已记入 [`../PITFALLS.md`](../PITFALLS.md)。
3. 启动即出现的 `ImageSource` / `62980118` 封面噪音在 release 同样复现（T-SHELF-5，仍未定位，暂按噪音对待）。

**未跑**：规则调试器页（不在冒烟范围；页面确实已存在，见 `pages/RuleDebugger.ets`）。

---

## 10. 增量（2026-10-07）：备份导入改为真「全量覆盖」（T-DATA-7）

**问题**：页面说明与确认弹窗都承诺「覆盖当前书源、书架与阅读进度」，但 `doImport` 只 `saveSources` + `upsertBook` / `saveProgress`（只增不减）——删书残留的孤儿进度行在导入后继续存活，落库数据与备份文件不一致。

**处理**（用户选「真覆盖」口径）

- `model/ShelfRepository.ets` 新增 `replaceShelf(books, progress)`：`DELETE FROM books` / `DELETE FROM progress` → `lastWriteAt.clear()` → 复用既有 `upsertBook` / `saveProgress` 写入。
  `lastWriteAt.clear()` 不是装饰：该单调守卫是**会话级**的，不清就会让备份里 `updatedAt` 更旧的进度被静默丢掉。
- `pages/BackupManage.ets`：`doImport` 改为 `saveSources` + `replaceShelf`（全部格式校验仍在清表之前）；确认弹窗与页面说明补明「备份中不存在的书源、书籍与进度不会被保留 / 将被删除」；恢复后 toast 显示实际计数（书源 / 书架 / 进度）。
- 书源无需改动：`saveSources` 走 `putString` 整体替换，本来就是覆盖语义。
- 不新增混淆 keep 字段（无新增 JSON 字段，`make check` 不受影响）。

**验证（debug 包，`make run`，设备 `33Z0224424136564`）**

| 步骤 | 结果 |
|---|---|
| 当前 13 源 / 3 本 / 7 条 → 导入「1 书 1 进度」fixture | ✅ 1 本 / 1 条（修复前会保持 3 本 / 7 条） |
| `aa force-stop` + 重启 | ✅ 仍 1 本 / 1 条（确认落盘，非内存态） |
| 同会话先导入 `updatedAt = now+1 天`（书架 6章/300章）再导入旧时间戳 fixture（1章） | ✅ 书架回到 1章/50章（证明 `lastWriteAt.clear()` 生效） |
| JS 错误 / 崩溃 | ✅ 0 条 |

验证后已导回全量备份（13 / 3 / 7），设备状态复原；测试 fixture 已从设备删除。

**附带更正**：「孤儿进度行」不能全局 GC——详情页「立即阅读」不要求已上架也能写进度（`BookDetail.ets:233`），「`progress` 有行而 `books` 无行」有合法来源；已记入 [`../PITFALLS.md`](../PITFALLS.md)。

---

## 11. 增量（2026-10-07）：进度写归属仲裁（T-CROSS-3 / R3 完整修复）

**问题**（首轮只做了缓解）：阅读页与听书都无条件写同一行 `progress`，但位置含义不同 —— 阅读页写「**可见页第一段**」
（`Reader.persistProgress`），听书写「**音频时钟所在段**」（`TtsController.tickProgress`，每 1s）。后写者胜，于是听书过程中
阅读页的翻页/跟随路径会把陈旧位置盖到实时位置上；`lastWriteAt` 单调时间戳挡不住它（陈旧写在墙钟上**更新**）。

**口径（用户选定）**：**播放中音频独占，阅读页只读** —— 同一本书听书正在播放时，只有音频时钟可写该书的 `progress`；
暂停 / 播完 / 未播放时归属释放，阅读页照常写。（阅读页「视图」在播放中仍可自由浏览，只有**落库位置**受管。）

**实现**

- 新增 `model/ProgressOwner.ets`（纯状态、无 import，避免循环依赖）：`ProgressWriter{NONE,READER,TTS,RESTORE}` +
  `claimProgress` / `releaseProgress`（只在仍持有时释放）/ `canWriteProgress` / `forgetProgressOwner`。
- `model/ShelfRepository.ets`：`saveProgress(p, writer)` 的 `writer` 为**必填**；`canWriteProgress` 检查放在 `lastWriteAt` 守卫**之前**
  （被拒的写不得污染时间戳）；`removeBooks` 连带 `forgetProgressOwner`（否则重新加回的书会被残留归属静默吞写）。
- `model/TtsController.ets`：`setPlaying(value)` 成为 `playing` 的**唯一**写入口（12 处赋值全部改道）—— 起播 `claimProgress(bookId, TTS)`；
  停播先 `persistProgress()` 再 `releaseProgress(...)`（1s tick 最多滞后 1s，且 `stop()` 也会在退出时跑）。
  **归属绑 `playing` 而非 `active`**：`active` 含「暂停 / 播完」，那两种状态下 TTS 已不再写，绑 `active` 会静默吞掉阅读页写入。
- `pages/Reader.ets`：`persistProgress` 以 `READER` 写；**顺带修** `onTtsProgress` 跨章跟随缺段落锚点
  （`loadChapter(this.tts.chapterIndex)` 默认 `paragraphIndex=0` → 音频在章内第 N 段时阅读页落到章首，且修复前会把章首写进库），
  现传 `this.tts.paragraphIndex`。
- `replaceShelf`（备份导入 / 全量覆盖）以 `ProgressWriter.RESTORE` 绕过仲裁，且**不**清归属映射：导入不得劫持正在进行的听书会话；
  若导入的正是正在播的书，音频下一次 tick 会覆盖回实时位置（预期行为）。
- 无新增 JSON 字段，未改 `obfuscation-rules.txt`（`make check` 通过：145 个 keep 名全覆盖）。

**真机验证（2026-10-07，设备 `33Z0224424136564`，`make run` debug 包；含修复前对照）**

方法：从沙箱拉 `shelf.db`（`/data/app/el2/100/database/com.lichtcui.sourcereader/entry/rdb/`，含 `-wal`）后用本地 `sqlite3` 查 `progress` 行；
UI 用 `uitest dumpLayout` + `uitest uiInput click` 驱动。为让「阅读页写入」与「1s tick 写入」可区分，验证期间把 `STATE_PUSH_MS`
临时抬到 `60000`（**验证后已还原 1000**），并在归属拒绝分支临时加了一条 `hilog`（**已删除**）；最终包在常量还原后复验。

| 场景 | 操作 | 修复前（对照：仲裁临时关闭） | 修复后 | 结论 |
|---|---|---|---|---|
| ① 播放中阅读页跳章 | 音频播 ch0（剑来·第一章），阅读页点「下一章」 | 库被写成 ch1 / `updatedAt` 前进（**复现覆盖缺陷**） | 库仍为音频位置（仅 1s tick 在写）+ 拒绝日志 `writer=1 owner=2` | 归属生效 |
| ② 音频推进时阅读页锚定 | 音频升到 ch0 para10–12（长段落，位于第 3 页） | — | 阅读页自动跟回音频章，可见页 = 音频所在段所在页（**非第 1 页**），库 = 音频段 | 锚点修复生效 |
| ③ 暂停即释放 | 注入媒体键 `keyCode 10`（AVSession `pause`） | — | 暂停瞬间 `updatedAt` 前进（抬到 60s 的 tick 解释不了）+ 日志 `SourceReaderTts: pause`；随后阅读页点「下一章」写入**被接受**（ch2），无拒绝日志 | 释放路径生效 |
| ④ 无 TTS 会话的书 | 天堂向左（从未听书）点「下一章」 | — | 库 ch26 → ch27，无拒绝日志 | 无回归 |

**构建/静态**：`make run`（debug）与 `make hap-release`（release + 属性混淆）均 `BUILD SUCCESSFUL`；`make check` 通过；
最终包（常量还原、临时日志删除）复验：播放中 tick 仍每秒落盘 + 播放中阅读页跳章库不动 + 音频推进后阅读页跟回音频章。

**未覆盖 / 残留**：`removeBooks` 的 `forgetProgressOwner` 只在代码层复核（真机删书链路已在 T-SHELF-1 验过，未单测「删正在播的书后重加」）；
归属是**进程内**状态，App 重启后自然清空（重启时也没有活跃播放会话，符合预期）。

---

## 12. 增量（2026-10-07）：书架进度总数反推边界加固（T-SHELF-3）

**核对（先取证，再决定改不改）**：书架进度三态不读目录，`total` 由 `percent` 反推 ——
`percent` 由两个写入者按 `(chapterIndex + 1) / chapters.length` 落库（`Reader.persistProgress` / `TtsController.persistProgress`）。
把 `Format.ets` 拷成 `.ts` 用 `node --experimental-strip-types` **直接 import 真实函数**复算：

- **正常区间零误差**：`len ≤ 20000` 的**全部**章序×章数组合（2.0 亿组）中 `Math.round((ci+1)/percent)` **无一组**不等于真实章数
  （双精度除法误差最多几个 ULP，`Math.round` 吸收）。
- **出问题的只有应用自己不会写的值**：`percent ≤ 0` / `NaN` / `Infinity`（旧码已自然落到「第N章」）；**极小值**
  （`1e-9` → 「7章/7000000000章」、次正规 `5e-324` → 「7章/Infinity章」）；**`percent > 1`**（反推出 `total < 已读` → **误报「已读到最新章」**）。

**处理**（用户选「仅边界加固」，不动书架数据流）

- 反推从 `Shelf.ets` 内联表达式收敛到 `common/Format.ets::deriveTotalChapters(chapterIndex, percent)`：`percent` 非有限 / ≤ 0 / > 1、
  章序 ≤ -1、`percent < 1/100000`、反推 `total < 已读章数` 一律回 `0` → `shelfProgressText` 降级为「第N章」（**总数不可信时不编造数字**）。
- 正常值路径与三段文案**逐字节不变**；无新增 JSON 字段（`obfuscation-rules.txt` / `make check` 不受影响）；`Shelf.ets` 由 3 行变 2 行调用。

**验证（2026-10-07 · 主机复算 + 真机三态 + 真机脏值对照）**

| 断言 | 结果 |
|---|---|
| 9 项退化值（0 / NaN / `Infinity` / 负数 / `1e-9` / 次正规 / 1.5 / `percent=1` 陈旧行 / 章序 -1） | ✅ 全部落到预期文案，含修复前/后对照（旧码：`7000000000章`、`Infinity章`、误报「已读到最新章」） |
| 8 项正常值（len 1 / 2 / 1000 / 3000 / 20000 / 100000，含末章与首章） | ✅ 与修复前逐字节一致（零回归） |
| `len ≤ 20000` 全枚举（2.0 亿组）反推 == 真实章数 | ✅ 0 组错误 |
| `make hap`（debug） | ✅ `BUILD SUCCESSFUL`；`Format.ets` / `Shelf.ets` **零告警** |
| 转译产物核对（`esmodule/debug/.../Format.ts:22-35`） | ✅ `Number.isFinite` 守卫与常量均在，未被编译期改写 |

脚本 `/tmp/tshelf3/check.ts`（未入库，复制真实文件后 import 运行）。

**真机验证（2026-10-07，设备 `33Z0224424136564`，`make run` debug 包，`uitest dumpLayout`）**

| 场景 | 真机现象 |
|---|---|
| 三态：剑来 / 大唐 / 天堂向左（库内 `percent` 0.06 / 0.106176… / 1.0） | ✅ `3章/50章` / `153章/1441章` / `已读到最新章`；拉沙箱 `shelf.db` 逐条对账一致 |
| 第三态「未读过」 | ✅ 搜索→加入书架的**第 4 本**（未打开过，无 `progress` 行）显示「未读过」 |
| **修复前 / 修复后对照**（临时插桩：注入脏 `percent`，左侧=旧内联表达式、右侧=新函数） | ✅ 大唐（`percent=1.5`）`已读到最新章 ｜ 第153章`（旧码**误报已完成**）、天堂向左（`percent=1e-9`）`28章/28000000000章 ｜ 第28章`；未注入的剑来 `3章/50章 ｜ 3章/50章`（正常区间零回归） |
| JS 错误 / 崩溃 | ✅ 0 条 |
| 复原 | ✅ 插桩已还原（`git diff` 无 TEMP 残留）并复验回三态原文案；测试书「赘婿」已删；沙箱 DB 回到 `books 3 / progress 7`，三行 `percent` 与验证前逐字节一致 |

**为何用插桩**：沙箱不可写 —— `hdc shell` 是 `uid=2000(shell)`（无 root，`hdc target mount` 拒绝：`Operate need running under debug mode`），
`/data/app/el2/...`、`/storage/media/...` 均 `Permission denied`；**真实脏行**进不了库（备份导入是「全量覆盖」，会洗掉用户数据），
所以脏值分支只能在 `progressText` 临时注入脏值来驱动（与 T-CROSS-3 的「临时抬常量 / 临时加日志」同型），验证后已还原。

**未覆盖**：真机未跑 release 包（未改混淆相关项）；「已读到最新章」的陈旧快照副作用见 T-SHELF-6。

**附带登记**：`docs/architecture.md:51` / `plan.md:163` 写的是「`chapterIndex >= toc.length-1`」，实现一直走 `percent` 反推 →
两文档原位加注记，差异与后果（源加新章后 `percent = 1` 仍判「已读到最新章」）登记为 **T-SHELF-6**（**同日已修：真正根因是 TOC 缓存无过期条件，见 §13**）。

---

## 13. 增量（2026-10-07）：TOC 缓存新鲜期 + 后台重爬（T-SHELF-6）

**根因（比原登记更大）**：`TocCache` 的失效条件**只有** `tocUrl` 变化 —— `CachedToc.fetchedAt` 有写入、**全仓库从未被读**，
目录缓存事实上永久；`Reader.loadToc` 命中缓存即返回，全仓库也没有「刷新目录」入口。后果：`tocUrl` 不变的连载书，
**首次打开之后新章永远不出现**（目录少章、书架一直「已读到最新章」），只有清缓存 / 配额驱逐 / 换源才会重爬。
原登记里「重新打开该书即刷新」的前提**不成立**：打开确实会重写 `percent`，但用的是同一份陈旧目录。

**处理**（用户选定：修根因 + **后台异步**刷新）

- `common/Const.ets` 新增 `TOC_REFRESH_AFTER_MS = 6h`（只影响网络开销，不影响首屏）。
- `model/TocCache.ets`：导出 `CachedToc`；`getCachedToc` 改为返回整条 entry（原来只回 `chapters`；调用点只有 Reader，无破坏面）；
  新增 `isTocStale(entry)` —— `fetchedAt` 缺失 / ≤ 0（老版本写的文件）视为过期，首次打开即刷新并补时间戳。
- `pages/Reader.ets`：`loadToc` 命中缓存**先返回**（不阻塞渲染），过期则 fire-and-forget 调 `refreshToc(src, book, session)`：
  - 抓取失败**静默**（仅 `hilog.warn` 一条），缓存目录继续用，下次打开再试；
  - 用**独立会话令牌** `tocSession`（不能用 `loadGen` —— 每次翻章都会 +1）保证换书 / 页面销毁后不写状态；
  - `chapters.length === 0` 或 `chapterIndex >= chapters.length`（源可能只返回不完整目录）→ **连缓存都不覆盖**，宁可继续用（可能陈旧的）目录，也不让下次打开按更短目录定位而丢阅读位置；
  - 成功则 `putCachedToc` 刷新内容与 `fetchedAt`；章数未变不动列表（只记一行 log），章数变化则重绑新数组 + `buildTocItems()` + `persistProgress()`
    —— **用新分母重写 `percent`** 是书架自愈的关键（书架本身仍不读目录、不联网）。
  - 本地书走 `isLocalBook` 分支，不联网。
- 附带修 `buildTocItems`：`this.dataSource = next` → 复用同一实例的 `setItems()`（内部 `onDataReloaded`）。
  原因：**LazyForEach 只在创建时读一次数据源**，换实例不会让**已挂载**的目录抽屉重渲染 —— 不修就会出现「目录 · 29 章」但列表仍是 28 行（真机已观察到）。
- 已知边界（写在代码注释里）：听书 `TtsController` 持有开启听书那一刻的 `chapters` **引用**（无 setter），后台重爬**不同步**给它；
  播放中阅读页的进度写被 `ProgressOwner` 仲裁丢弃，故听书期间书架不自愈（停播后下一次写入自愈）。目录源若重排章节，按 `index` 位移属已知限制。

**验证（2026-10-07 · 设备 `33Z0224424136564` · `make run` debug 包 · `uitest dumpLayout` + `hilog -T SourceReaderReader`）**

| 断言 | 真机证据 |
|---|---|
| 基线 | 天堂向左：目录 28 章、章号 28（`percent = 28/28 = 1.0`）、书架「已读到最新章」 |
| ① 过期即重爬 | 临时 `TOC_REFRESH_AFTER_MS = 0` → 打开书后日志 `toc refreshed 28 → 29 chapters (book=天堂向左 深圳往右)` |
| ② 采用新目录（插桩伪造新章） | 目录计数「· 29 章」；滚到底最后一行 = `【临时插桩】新章`；**阅读位置不动**（仍第二十八章） |
| ③ 书架自愈 | 返回书架 → `28章/29章`（若不修，该快照会永远停在「已读到最新章」） |
| ④ TTL 正值 + 时间流逝 | 临时 `TOC_REFRESH_AFTER_MS = 2000` → 打开书日志 `toc refresh: 28 chapters (cached 28, …)`（重爬了、章数未变、列表不动） |
| ⑤ 新鲜期内不重爬 | 常量还原 6h 后打开同一本书：该 tag **无任何日志**；目录仍 28 章、无插桩行 |
| ⑥ 排序不回归 | 目录抽屉「正序 → 倒序」：`第一章/第二章…` → `第二十八章/第二十七章…`（`buildTocItems` 改动后仍生效） |
| ⑦ 无异常 | 应用侧 hilog 0 条 error / exception（`ImageSource` 封面噪音、系统 `PARAM_WATCHER`/`AceTheme`/`Plugin` 为既有） |
| ⑧ 复原 | `rg TEMP` 无残留；沙箱 toc 缓存**未被插桩污染**（伪造章在 `putCachedToc` **之后**只进内存），复验后书架回到「已读到最新章」，`make doctor` ✓ |

`make check` ✅（145 个 keep 名字覆盖全部 JSON 字段；`tocUrl` / `chapters` / `fetchedAt` 均已在 `obfuscation-rules.txt`，无需新增）。

**未覆盖**：真机未跑 release 包（未动混淆相关项）；「源返回不完整目录」只做了代码守卫、未构造真实场景；
6h 数值本身没有长跑验证（只验证了 TTL = 0 / 2000ms / 6h 三档下的行为）。

## 14. 增量（2026-10-08）：封面缓存「毒化」修复（T-SHELF-5）

**根因**（两条叠加，都不在 ArkTS 侧）：

1. `rust/legado-engine/src/runtime.rs::download_cover` 只校验 `body_bytes` **非空**，从不校验**是不是图片**
   —— 源规则指向详情页、站点防盗链返回 200 + `text/html` 占位图、中间层返回 JSON 错误页，都会被 `std::fs::write` 落盘成 `cover_<hash>.img`；
2. 同一函数以 `if path.exists() { return Ok(path) }` **提前返回** —— 缓存 slot 一旦被毒化，**永不复检、永不重下**。

后果（两者同时成立）：`BookCover.ets` 里 `fileIo.accessSync` 通过 → `image.createImageSource` + `createPixelMap` 抛
**62980118 = Failed to create the image plugin**（SDK `@ohos.multimedia.image.d.ts` 原文，含义是「数据不是可识别的图片格式」，不是笼统的「文件损坏」）；
catch 只把 `pixmap = undefined` → **红渐变 + 书名占位**，且失败 URL **不进任何缓存** → 每次组件重建（切 tab / 回书架 / 重启）都重试一次，每次刷 5 行错误。
⇒ 既是**日志噪音**，也是**用户可见的永久空封面**。

**定位证据（真机 `33Z0224424136564` + 主机）**

| 步骤 | 结论 |
|---|---|
| 沙箱 `hdc file recv` 拉回 28 个 `cover_*.img`，逐个 `file` | 只有 `cover_abfeec91b5ff5574.img` 是 **HTML**（10936 B，《天堂向左 深圳往右》详情页） |
| 自建 rustc 小程序复算 `DefaultHasher` | `abfeec91b5ff5574 == hash("https://tiantangxiangzuoshenzhenwangyou.qwyd.net/")`，与 DB `books` 行 `8200e532` 的 `cover_url` 一致（**哈希对得上 ⇒ 就是封面下载路径写进去的，不是别人误写**） |
| 插桩 `hilog.warn`（已移除） | 失败 URL 恰为该页地址，全应用仅此一例失败 |
| `uitest dumpLayout` | `剑来` 封面区无 Text（图片正常），《天堂向左》《大唐（无封面 URL）》封面区各有书名 Text ⇒ 失败走**占位分支**（用户可见） |
| 现源规则 + `make probe … search/info --json` | `coverUrl: ""` —— 该行值属 **DB 历史行**（源规则后来被改/从未有 coverUrl 规则），今天无法再产出；但「源改动后指向页面」「防盗链返回 HTML」是常见情形，且中毒后永不自愈 |

**处理**

- Rust（`runtime.rs` 封面段）：
  - 抽出 `cover_cache_path(dest_dir, cover_url)`（命名逻辑单点，供测试复用）；
  - 新增 `has_image_magic`（JPEG / PNG / GIF87a·89a / BMP / ICO / `RIFF….WEBP` / offset 4 处 `ftyp` 的 HEIC·HEIF·AVIF）、
    `starts_like_markup`（跳 UTF-8 BOM 与空白后首字节为 `<` / `{` / `[`，或全空白）、`is_text_content_type`、
    `looks_like_image`（markup 直接否 → 有 magic 直接是 → 否则**只**认 `image/*` 且非 text）、`cached_cover_is_usable`（读头 64 B 非空且非 markup）；
  - `download_cover`：**缓存命中也要先过 `cached_cover_is_usable`**，不过则**删除旧文件重下**（自愈既有中毒项）；
    下载后 `!looks_like_image` → **删文件 + 不落盘**，返回 `not_image`。
  - `status.rs::fail_message` 加 `"not_image" => "封面地址返回的不是图片"`（沿用非变体键惯例，**不新增 `FailReason` 变体** ⇒ 不涉及 keep 列表与混淆）。
- ArkTS（`components/BookCover.ets`）：新增会话级 `failedCache: Set<string>`（上限 128，与 `pixmapCache` 同款最旧驱逐）
  ⇒ 同一 URL 每会话只尝试一次；catch 中清 `pathCache` 并 `fileIo.unlinkSync(path)`（解不开的字节不该留到下次启动），
  保留一条 `hilog.warn(0x0000, 'SourceReaderCover', 'cover unavailable url=… err=…')`（负缓存后每 URL 每会话恰一次）。

**为什么不做**（都已评估）：

- **持久负标记** `cover_*.miss`：`model/CacheTrim.ets` 按 `COVER_PREFIX` + `.img` 后缀扫描驱逐，新命名 = 永不被清理的**泄漏**；接受「每次启动对该 URL 一次无效请求」（`not_image` 会立即返回，无解码成本）。
- **临时文件 + rename 原子写**：同理会留下 `cover_*.tmp` 孤儿；且校验现在发生在**写之前**，部分写只可能来自崩溃/写满，而 ArkTS 的删文件兜底已能自愈。
- **`ImageSource.release()`**：无法在无截图条件下确认渲染没回归，风险大于收益。

**验证（2026-10-08 · 设备 `33Z0224424136564` · `make test` → `make rust` → `make run` debug 包）**

| 断言 | 证据 |
|---|---|
| ① 单测 | `make test` **56 项全过**（+2）：`test_looks_like_image`（JPEG/PNG/GIF/WebP/HEIC/HTML/JSON/空/全空白/BOM+HTML/content-type 说谎/未知二进制 + `image/*`）；`test_download_cover_validates_and_self_heals`（新 `mock_cover_server` 二进制路由：HTML 拒且**不落盘**、说谎 content-type 拒、PNG 接受且字节相符、**预置毒文件 → 自愈重下**） |
| ② 启动无噪音 | `hilog -r` 清净后 `aa start` + 8s：`62980118` / `failed to create decoder object` / `Create PixelMap error` **0 行**（修复前基线 15 行 = 3 次尝试 × 5 行） |
| ③ 失败原因可读 | 恰 1 条失败日志（不再是解码噪音）：`SourceReaderCover: cover unavailable url=https://tiantangxiangzuoshenzhenwangyou.qwyd.net/ err=not_image`（插桩基线为 `err=undefined`） |
| ④ 沙箱自愈 | 毒文件 `cover_abfeec91b5ff5574.img` 已消失；全量 `file recv` 后 38 个 `cover_*.img` **全为合法 JPEG**（含本次新下载的 5 个 83K/109K/78K/16K/5.6K） |
| ⑤ 渲染无回归 | `uitest dumpLayout` 与修复前**逐行一致**：`剑来` 封面区仍无 Text（图片渲染），另两本仍占位（一本无 coverUrl、一本就是本次的不可用 URL） |
| ⑥ 负缓存生效 | 书架 ↔ 搜索来回切 3 轮：该 tag **0 条**日志（不再重复下载/解码） |
| ⑦ 新下载路径未被误杀 | 搜索「剑来」→ 107 条结果，5 个新封面全部解码成功、无一条 `cover unavailable` |

**未覆盖**：release 包未复跑（本次改动不涉及 JSON 契约与混淆面，`make check` 仍按原样通过）；跨启动「不重下」未验证（设计上就是每启动重试一次）；
HEIC/AVIF 只验了 magic 分支，未构造真实 HEIC 封面。

---

## 15. 增量（2026-10-08）：章节预取去重（T-READ-3）

**问题**：`ReaderPage` 每一条取正文的路径都直接打引擎 —— `loadChapter`（当前章）与 `warmNeighbors`（上一章 / 下一章）。
频繁切章时同一 `bookId#index` 会被**同时在飞**的多条路径索要（新章与上一次 `warmNeighbors()` 正在暖的邻居重叠，下一次切章又暖同一批邻居），
于是同一章**发两次引擎请求 + 写两次 `putCachedChapter`**（含重复的 `JSON.stringify` 落盘），而后到的那份结果还会被
`loadChapter` 的 `loadGen` 守卫直接丢弃（`if (gen !== this.loadGen) return;`）—— 纯浪费。
T-READ-2 的内存 LRU 只压低「撞车概率」，**挡不住并发**：`warmNeighbors` 的判重是 `paraCache.has(n)`（判「已解析缓存」），
两条路径在**缓存都未命中**时才同时进来，正是需要去重的那一档。

**修法**（纯 ArkTS，`entry/src/main/ets/pages/Reader.ets`）

- `fetchContent` 加**单飞（single-flight）**层：内存 / 文件缓存查询保持不变；未命中则按 `bookId#index`
  （与 `ChapterCache.memoryKey` 同形）查在飞表 `inflight: Map<string, Promise<string>>`，命中即返回**同一个 promise**；
  未命中则建任务入表，`finally` 出表（落定即删 ⇒ 不残留、失败仍可重试）。
- 引擎请求 + 写盘下沉到新的 `fetchRemote(src, ctx, book, chapter, index)`，**只被 `fetchContent` 调用** ⇒ 全文件只有一条真正打引擎的路径。
- key 带 `bookId`：跨书复用同一 `ReaderPage` 实例（`@Param` 变化）也不会串；不做 `load()` 清理（表项自删，无跨书泄漏）。
- **顺带删除死代码 `prefetch(index)`**：全仓库无调用（`HANDOFF-S10.md` §6.1 记的「保留未删，无碍」随之失效），
  `warmNeighbors` 已覆盖「把邻居暖进文件缓存」这一用途；文件索引行同步由 `… / warmNeighbors / prefetch` 改为 `… / fetchContent / fetchRemote / cachedContent / warmNeighbors`。
- 无新增 JSON 字段 ⇒ `obfuscation-rules.txt` / keep 列表不动。

**验证（2026-10-08 · 本机；设备未连接，真机项待复验）**

> **⚠️ 真机部分已于 2026-10-11 补齐 —— 见本节末「真机复验」；下表是当时（本机）的证据快照。**

| 断言 | 证据 |
|---|---|
| 编译 | `make hap` → `BUILD SUCCESSFUL`（14.6s）；122 条 ArkTS 告警**无一在 `Reader.ets`**（均为既有的 `Window.ets` / `ShelfRepository.ets`） |
| 契约 | `make check` ✓（145 个 keep 名字覆盖全部 JSON 字段、目录与链接均最新）、`make doctor` 无阻断项 |
| 转译产物未被改写 | `entry/build/.../esmodule/debug/.../pages/Reader.ts:443-454`：`inflight.get` → 早退 `return running` + `set` + `finally delete` 均在；全文件已无 `prefetch` 残留 |
| 调用面闭合 | `rg` 复核 `fetchContent` 的全部调用点（`loadChapter`、`warmNeighbors`）与定义（唯一 `bookEngine.content` 在 `fetchRemote` 内）⇒ 无绕过去重的路径 |
| 真机行为 | ✅ **2026-10-11 已验**（设备 `33Z0224424136564`）：修复后 key `#11` = miss×2 + join×1 + engine×1；修复前对照（旁路 `inflight.set`）key `#39`/`#45` = miss×2 + engine×2、join 0 次 → 见下方「真机复验」 |

**真机复验（2026-10-11 · 设备 `33Z0224424136564` · debug HAP · `make run`）**

场景：《剑来》（`bookId=5b4fad87`，联网源，远程章节），`uitest uiInput doubleClick 1159 2434` 连点底栏「下一章」制造并发索要。
临时插桩三行（验证后随 `git checkout` 全部还原）：`fetchContent` 缓存未命中 → `TEMP-TR3 miss`；命中在飞表 → `TEMP-TR3 join`；`fetchRemote` 真正打引擎 → `TEMP-TR3 engine`。

| 轮次 | 改动 | 同一 key 的日志 | 结论 |
|---|---|---|---|
| A 修复后 | 单飞表生效 | `#11`：`miss` ×2 → `join` ×1 → `engine` ×1 | 两调用方共享同一 promise：**1 次引擎请求 / 1 次写盘** |
| B 修复前对照 | 临时注释 `this.inflight.set(key, task)` | `#39`：`miss` ×2 → `engine` ×2；`#45`：`miss` ×2 → `engine` ×2；全程 `join` ×0 | 对照确凿：**同一章 2 次引擎请求 / 2 次写盘**（即修复前行为） |

- 关键点：**join 是自然触发的**（无人工延时）—— 单次连点落在「该章引擎请求仍在飞」的窗口内（实测该源单章 ≈200 ms），与 `warmNeighbors` 邻居预取同源并发。
- 写盘次数：`putCachedChapter` 唯一调用点在 `fetchRemote` 内 ⇒ engine 次数即写盘次数（沙箱对 shell 不可读，故以调用面 + 引擎请求数取证）。
- 还原复跑（工作区干净、`rg TEMP` 无残留 → `make run` 重装）：应用内「清理全部缓存」归零四类缓存 → 打开《剑来》**第五十章正文由引擎重新拉取并渲染**（缓存为空）、点「上一章」→ **第四十九章正文正常**；全程 **0 JSCRASH/CPPCRASH、0 条应用级 error**（仅框架噪音 `AceStateMgmt: No views to update`）。

**附带观察（与本次改动无关，未定性）**：同次会话中《大唐：李世民求我造反》打开时目录显示「目录加载失败」—— TOC 拉取失败。
该路径为 `loadToc → bookEngine.toc`，**不经过** `fetchContent`；未定性为源侧失效还是缓存被驱逐后的重拉失败，如需排查另立任务。

**未覆盖**：release 包（改动纯 ArkTS 内存层，不触 JSON 契约与混淆面；真机 debug 已于 2026-10-11 跑过）。
TTS 侧 `model/BookContent.ets::loadChapterParagraphs` 有同型「未命中即打引擎」写法，但它与阅读页是两条独立调用链、
没有共享单飞表 ⇒ **本次不合并**（合并需引入共享模块，另立任务）。

---

## 16. 增量（2026-10-11）：T-TTS-5 客户端收尾 + 服务端「纯标点分段」500 修复

范围：`RemoteTtsClient.ets`（超时/语速）、`common/Const.ets`（音色列表 + 归一）、`model/TtsController.ets`（语速下发 + 远端改档）、
`pages/ListeningSettings.ets`（读 pref 归一）、`server/app.py` + `server/tts.service`（`SPEED_SCALE` / 除零护栏）。
真机：设备 `33Z0224424136564`，debug HAP，`make run`；服务端：`systemctl restart tts` 后 `/health` 复核。

### 16.1 服务端 500：纯标点分段除零（真机才暴露）

真机把 App 语速拉到 2.0x 后，播《剑来》第四章出现 `remote synth failed para=3` → App 弹「远端合成失败，已切换回系统 TTS」→
重建 16 kHz 系统引擎并从头播。直连复现（`POST /tts` 固定文本）：

| 文本 | 修复前 | 修复后 |
|---|---|---|
| `：` / `“` / `”` / `——“` | **500**（`ZeroDivisionError` in `_resample_fft`） | 200（320 ms 静音） |
| `…` | 200 | 200 |
| `他说：“你来了。”` | **500**（分出的 `”` 段为空） | 200，日志 `drop unspeakable segment len=1 '”'` |

根因：sherpa 对「一个可发音字都没有」的段返回 `sample_rate=0` 的空音频（只打 `Ignore OOV` 警告），
旧代码直接 `_resample_fft` → `x * sr_in / sr_out` 除零。**影响面比看到的大**：`他说：“你来了。”` 会多切出一个 `”` 段，
即**每个对白段落都会 500** ⇒ 这是「远端听书一播到对话就变系统音色」的直接原因。
修法：`_synth_vits` 跳过 `sr_in<=0 / 空样本` 分段（句间停顿跟着已发音段走），整段无字时回 320 ms 静音（不中断播放）；
`_resample_fft` 加 `sr_in<=0` 硬护栏。

### 16.2 客户端四项

| 项 | 改动 | 证据 |
|---|---|---|
| ② 超时 | `readTimeout` 60000 → **120000** | 实测最坏单请求 wall ≈46 s（279 字 / 5 句 / effective 1.5） |
| ③ 音色 | 选项 = `[刻晴,甘雨,胡桃,钟离,雷电将军]`，默认 **钟离**；新增 `normalizeRemoteVoice()` 归一 `流萤→甘雨 / 花火→胡桃 / 卡芙卡→雷电将军` | 设备 pref 残留 `流萤` → 界面显示「远端音色 · 甘雨」，服务端请求 `voice=甘雨` |
| 语速 | 客户端**真下发**（原先硬编码 1.0）；服务端有效 = `clamp(client,0.5,2.0) × SPEED_SCALE`；`setSpeed()` 新增远端分支（远端无 `engine`，旧分支原本空转）→ 改档即时生效 | App 2.0x → `speed=1.500`；改回 1.0x → 下一条即 `speed=0.750` |
| ④ 语速基准 | `SPEED_SCALE` 0.85 → **0.75**（起点值，待用户听感定稿） | `/health` `speed_scale=0.75`；实测 5.2 字/秒，与客户端 `CHARS_PER_SECOND=5` 吻合 |

### 16.3 端到端复跑（修服务端之后）

同一章、同一本书：`start book=剑来 chapter=3 para=7` → `play para=8/9/10/11`，67 s 内连续推进，
**回退次数 0**、应用级 error 0；服务端同期 11 条 `synth engine=vits`，`voice=甘雨`，`speed` 与 UI 档位逐条一致。

### 16.4 未覆盖 / 待决策

- **5 音色的真机逐个切换**未走完：验收中途设备掉线（`hdc list targets` 为空、`uitest` 只回 `need connect-key`）。
  服务端侧已逐个 200 验证，试听包 `~/Desktop/tts-abtest-tts5/`（5 音色 + 3 档 `SPEED_SCALE`）。
- **听感结论**（T-TTS-5 ① 与 ④ 终值）需要用户耳朵，Agent 侧无法判定。
- ⚠️ **语速上限（已决）**：有效语速 ≈1.0 是这台 4C 机器的可持续上限（每字合成 0.13–0.16 s）→ 新增
  `TTS_REMOTE_SPEED_MAX = 1.2`（有效 0.9），远端下 1.5x/2.0x 菜单项/档位置灰，`effectiveSpeed()` 下发前夹取。
- ⚠️ **回退不落盘（已决）**：`fallbackToSystem()` 不再写 `tts_engine` pref，只在本次会话回退系统 TTS，
  下次听书自动重试远端（Toast 已改为「本次已切换回系统 TTS」）。

## 17. 增量（2026-10-11）：Legado `text.` 前缀未实现（目录 / 正文只取第一页）

范围：`rust/legado-engine/src/rule_dsl/parser.rs`（新增 `RuleToken::TextContains`）、
`rust/legado-engine/src/rule_dsl/html_extractor.rs`（新增 `apply_text_filter`）。
验证环境：**纯主机侧**（`make test` / `make probe`），本轮设备离线（`hdc list targets` = `[Empty]`），未上真机。

### 17.1 症状与影响面

规则 DSL 只认 `class.` / `id.` / `tag.`，`text.关键字@href` 这类 Legado 文本选择器落入裸 CSS 兜底 →
选择器 `text.下一页` 永远匹配不到元素 → **0 结果且无诊断**（`diagnose` 只校验 CSS 语法，`text` 恰好是合法标签名）
→ `runtime.rs` 的 `nextTocUrl` / `nextContentUrl` 翻页循环在第一页后 `break`。翻页循环本身（`MAX_TOC_PAGES=50`、
`seen` 去重、`resolve_url` 后自引用比较）**逻辑没错**，缺的就是这一步提取。

内置 13 源里 **9 条规则 / 8 个源**命中：

| 字段 | 源 |
|---|---|
| `ruleToc.nextTocUrl = text.下一页@href` | 爱下书 · bbiquge8 · 笔趣阁8 |
| `ruleContent.nextContentUrl = text.下一页@href` / `text.下一章@href` | 小说 · 🔖天堂向左 深圳往右 · 爱下书 · bbiquge8 · 笔趣阁8 |
| `ruleBookInfo.tocUrl = text.目录@href` | 💯 连尚读书 |

语义依据（Legado 官方规则说明）：「第一段是类型，如 `class,id,tag,text`…`text` 可以根据文本内容获取」，
即 `text.关键字` = 选取**自身文本包含关键字**的元素（对应 jsoup `:containsOwn`）—— 是真源常用写法，不是坏规则。

### 17.2 修复前后对照（《剑来》@ bbiquge8，`info` 报最新章节「第83章 今日无事」）

| 场景 | 修复前 | 修复后 |
|---|---|---|
| `probe toc http://m.bbiquge8.net/dir/814/ --index 8` | **50 条**（末条「第一卷 笼中雀 第五十章 天行健」） | **1308 条**，末条 = 最新章「第83章 今日无事」 |
| 同上 @ 笔趣阁8（另一源、同写法） | 50 条 | 1308 条 |
| `probe toc http://m.aixiawx.com/63/63398/ --index 5`（爱下书） | 20 条 | **58 条** |
| **对照**：爱下书 `nextTocUrl` 置空后跑（修复后） | — | 20 条 ⇒ 差异只来自该规则（唯一变量） |
| `probe content` bbiquge8 首章（`(第1/3页)`） | 只第 1 页 | 拼到 **第 3/3 页**，结尾出现 `ps3:好久不见，剑来！` |
| `probe parse text/html 'text.下一页@href'`（剑来目录页） | 0 个结果 + **无诊断** | 命中分页 `<a>` |

站点侧复核：`curl '…/dir/814/?page=4&sort=asc'` 已到「第200章」⇒ 该源目录确实多页，App 侧 50 条是缺章。
附带解释：真机书架《剑来》此前的 **`3章/50章`**（T-SHELF-3 三态取证记下的）就是本 bug 的表现，目录修好后总章数为 1308。

### 17.3 修法与验证

`parser.rs` 新增 `RuleToken::TextContains`，**必须在裸 CSS 兜底之前**判断（否则仍会静默退化成 CSS 选择器）；
`html_extractor.rs` 新增 `apply_text_filter`：按**直接文本子节点**匹配、ASCII 大小写不敏感、按文档序返回外层 HTML、
**排除 fragment 包装节点 `<html>`**（否则关键字命中包装节点时会把整页当结果返回）。
`json_extractor` / `diagnose` 的兜底分支不动 ⇒ JSON 路径与诊断行为零变化。

- `make test`：**56 → 58 项全通过**（新增 parser / html_extractor 用例：关键字只在子孙里不命中、命中多个可用 `.n` 取第 n 个、未命中返回空而非整页兜底）。
- `make probe ARGS='… search 剑来'`：**588 条 / 成功 11-13，与修复前逐源一致**（纯增补，零回归）。
- `make rust`：交叉编译 `.so` 成功（设备可用，签名面 / NAPI 签名均未变）。

### 17.4 未覆盖 / 附注

- **设备侧复跑待设备上线**：`make run` 后打开《剑来》应看到目录 >1000 章、正文一次拉全 3 页；release 包未复跑（纯 Rust 改动，不涉混淆面）。
- 💯 连尚读书的 `ruleBookInfo.tocUrl = text.目录@href` 在**现行站点**上本就无命中（目录页 HTML 里「目录」二字出现 **0 次**）
  ⇒ 属源规则过期，与本次前缀修复无关（该源目录仍回退 `bookUrl`）。
- 本轮同批「不接设备」任务的另两项结论：多页目录问题=本 bug；《大唐》目录加载失败在主机侧 **无法复现**
  （`probe toc` 正常返回 1449 条 / 30 KB / 0.7 s）⇒ 非引擎缺陷，最终定性需设备日志（见 TASKS.md §T-READ-3）。

## 18. 增量（2026-10-13）：换源候选被静默丢掉 / 每轮白等 13 源（T-SWITCH-1）

范围：`common/Format.ets`、`model/SourcePrefetch.ets`（新）、`model/SourceSwitch.ets`、
`components/SourceSwitchPanel.ets`、`pages/SearchResult.ets`、`pages/Reader.ets`（换源确认链路）。
验证环境：**真机 + 主机侧**（`make probe` 逐条对帐、`make run` 上机，`uitest dumpLayout` 逐屏核对）。

### 18.1 症状

用户报《剑来》在阅读页「换源」抽屉里**只有 1 个候选**；且每次打开抽屉都要等 13 个书源全跑完
（进度行长时间停在 `已检索 N/13`）。设备侧另有两处只有真机才看得见的问题：
预热回填拿到了「最新：第83章」却**不上屏**（行内恒显「该源未提供最新章节」）；「重新检索」**点了没反应**。

### 18.2 根因（四个独立原因）

1. **候选漏判（主因）**：`isSameBook` 比作者时走 `normalizeKey`（只删空白），而书源规则常把页面标签一起抓进来。
   `probe search 剑来 --json`（13 源 / 560 条）里同名 8 条的 author 有 2 条是 `作者：烽火戏诸侯` →
   与书架的 `烽火戏诸侯` 不等 → 被当成「另一本书」**静默丢掉**（命中 6/8）。
2. **同域重复**：`m.bbiquge8.net` 有两条内置书源（`bbiquge8` / `笔趣阁8`，`bookSourceUrl` 一字不差）。
3. **等待时长**：单源超时 10s、无全局预算，最慢一源决定整体时长；候选够用后仍在空等。
4. **UI 刷新（真机才发现）**：候选行 `ForEach` 的 key 只含 `bookSourceUrl + 序号`，预热回填只换行内文案 →
   key 不变 → **子树不重建**；且 `startSearch()` 对用户主动「重新检索」也会先命中会话缓存。

### 18.3 修法

- `作者：` / `作家：` / `最新章节：` 前缀清洗收敛到 `common/Format.ets` 单点（`stripLabel` / `cleanAuthor` /
  `cleanChapter`），`SearchResult` 里的私有副本删除改 import；`SourceSwitch.isSameBook` 比作者前先削。
- `SourceRepository.dedupeBySite`（域名 + 搜索模板）兜「同站两个入口」，候选项行级也按域名去重。
- 检索预算：单源超时 **10s → 6s**、全局派发预算 **10s**、候选够 **3 条**即收尾（进度行写明原因 + 「继续检索」回头路）。
- 候选结果**会话缓存 30 分钟**（同一批书源 + 同一本书重开抽屉直接上屏 + 「重新检索」）。
- 新 `model/SourcePrefetch.ets`：行一上屏就预热最靠前 **2** 个候选的 `bookInfo` + `toc`（切换 7s → 命中 ≤1s），
  其余候选串行补一次 `bookInfo` 换掉行内占位；**只放内存**（不写 `TocCache`）。
- 列表 `ForEach` 的 key 追加 `chapter`（`row.key + '|' + row.chapter`），`SwitchRow.key` 字段保持稳定；
  `startSearch(forceFresh)` 让「重新检索」绕过缓存；「继续检索」在 `nextIndex >= sources.length` 时不再显示。

### 18.4 验证

| 项 | 修复前 | 修复后（真机 2026-10-13） |
|---|---|---|
| 候选行 | 2 行 | **7 行**（12 源参与；`probe` 侧 8 条同名 → 7 行） |
| 首屏 | 等 13 源跑完 | 3s 已上屏 6 行，进度行 `已检索 12/12 个书源 · 候选已够用` |
| 行内回填 | 恒显占位 | `黑炎小说` / `悠久小说` / `玄幻阁` → 「最新：第83章 今日无事」（另 2 源确实无最新章节节点，`probe info` 复核） |
| 切换耗时 | 7s（`bookInfo` 1.1s + 目录 5.9s） | **≤1s**（预热命中） |
| 重开抽屉 | 重新检索 10s | 「上次检索到的 7 个候选」秒上屏；「重新检索」确实重跑 |
| 往返切换 | — | `bbiquge8 ↔ 小说` 进度 `104章/1308章` 未丢 |

未解释的观测（不阻塞发布，留待复现）：曾有一次换源后重开抽屉，7 行**全无「当前」标记**；随后三次复现均正常
（逐行日志 `eq=Y`）。详见 `TASKS.md` §T-SWITCH-1 末条。

## 19. 增量（2026-10-13）：书架「更新」批量查新章（T-SHELF-7）—— ✅ 真机验收通过

范围：`entry/src/main/ets/model/ShelfUpdater.ets`（新，编排 + 纯函数）、`entry/src/main/ets/pages/Index.ets`（书架顶栏入口）、
`scripts/shelf-updater-sim.py`（新，主机侧仿真）。
验证环境：**主机侧**（`tsc` + `node` 仿真 30 断言、`make hap`、`make check`）+ **真机**（设备 `33Z0224424136564` · debug · `make run` 闭环，2026-10-13，12 项）。
真机实证：进度 `检查中 0/2` → `检查中 1/2`、**`total = 2`（本地书《大唐：李世民求我造反》被正确排除）**、结束 toast `没有发现新章节，1 本未检查` 与（停用两个同 URL 孪生源后）`检查失败，请检查网络或书源` 两个分支、
失败书不建基线且不影响其余书、**全程 `shelf.db` 逐列零写入**（比对用 `shelf.db` + `-wal` + `-shm` 三件套 —— 只 recv 主库会漏掉未 checkpoint 的写，见 §19.6 与 [`../PITFALLS.md`](../PITFALLS.md)）、连点两次只跑一轮、幂等、编辑态顶栏无入口；注入用的两个书源开关已恢复启用。
「有新章」分支**2026-10-13 晚已用一次性调试版真机走通**（原「真机不可造」的结论已被绕过，配方与四步证据见 §19.5.3）：toast `1 本有新章节` + 基线前移 + 复跑幂等。

### 19.1 需求与已拍板

用户 2026-10-13：「书架中也需要一个更新的功能（更新所有书籍，查看是否有新章节）」。
现状：书架 `reload()` 只读 DB + 进度、**零网络 I/O**，「最新：xxx」/「N章/M章」只在**打开那本书**时由 `Reader.refreshToc` 重写
`percent` 才自愈（T-SHELF-6）⇒ 不打开书就永远不动。
拍板：① 入口 = 书架顶栏标题右侧**独立「更新」按钮**；② 探测深度 = **只查详情 `bookInfo`，不爬目录**；③ 触发 = **仅手动**（不做启动/定时）。

### 19.2 卡点：书架行没有 `bookUrl` ⇒ 2 请求/书

`Book`（`engine/types.ets`）没有 `bookUrl`，而 `bookInfo(source, bookUrl)` 需要它；`bookId` 是 `computeBookId(sourceUrl, bookUrl)`
的哈希 ⇒ 不可逆；`tocUrl` 也不能顶（13 个内置源里 7 个显式指向目录页，是另一个页面）。
⇒ 本轮走**零 schema 方案**：`search([source], book.name)` → 复用换源的 `isSameBook`（书名 + 作者严格匹配）命中拿 `item.bookUrl` → `bookInfo`，**2 请求/书**。
代价是 20 本书 ≈ 40 次请求（不是 20 次）；换来的是**不碰 DB**（`initShelf` 只有 `CREATE TABLE IF NOT EXISTS`，加列要幂等 ALTER + 3 个写入点 + 存量回填）。

### 19.3 实现与三个被改掉的设计点

- 常量：`SEARCH_TIMEOUT_MS = 6000`（对齐 T-SWITCH-1 单源超时）、`ENGINE_INFO_TIMEOUT_MS = 15000`、`CHECK_CONCURRENCY = 3`、`CHECK_BUDGET_MS = 90000`。
- 返回 `ShelfUpdateOutcome { total, checked, failed, skipped, updated }`；进度回调 = 起始 `(0,N,0)` + 每本结束一次 `(done,N,failed)`（第三个参数是累计失败数，2026-10-13 收尾小迭代加的）；书架按钮显示 `shelfProgressText()`（无失败 `检查中 1/2`，有失败 `检查中 1/2 · 1 本未检查`）+ 防重入。
- 结束 toast：`N 本有新章节` / `没有发现新章节` / `没有发现新章节，N 本未检查` / `检查失败，请检查网络或书源` / `书架里没有可检查的网络书籍` / `更新失败，请稍后重试`。
- ① **基线比较走 `cleanChapter` 归一化**（立项时打算直接比字符串）：同一章在详情页是 `第83章 今日无事`、在搜索结果/换源是 `最新：第83章 今日无事`
  ⇒ 直接比会把**没更新**的书报成有新章。归一化后**相等但原串不同**时**静默对齐**基线（不回显「有新章」），下次比较即退化成纯字符串相等 ⇒ 幂等。
- ② **无基线（`last_chapter_title` 为空）时不当「有新章」**，只静默写入当前值**建基线**：否则加书后第一次更新会把**整架书**报成有新章。
  保留的已知代价：加入书架后到第一次更新之间章节变过的书，基线还停在加入那天 ⇒ 会被报成有新章，写一次后即准。
- ③ **单本超时 6s → 15s**：当时用 ArkTS `Promise` 竞速兜底；2026-10-19 已改为把
  `ENGINE_INFO_TIMEOUT_MS` 传给 `bookInfo`，由 Rust 对整个详情操作（含重定向和解析）统一计时，
  ArkTS 侧不再维护竞速定时器。90s 整体预算仍用于限制一轮书架更新的总时长。
- 失败/预算语义：搜索失败 / 未命中同一本书 / `bookInfo` 失败 / 超时 / 无章节名 / 书源缺失或停用 ⇒ 计 `failed`，**不写库、不动基线、不影响其余书**；
  本地书排除（不计入 `total`）；预算耗尽而未开始的书计 `skipped`（下次点击继续）。

### 19.4 验证（主机侧 30 断言 + 构建门禁）

`scripts/shelf-updater-sim.py`：从**真源码机械切片**（`Format.ets` 的 `stripLabel`/`cleanAuthor`/`cleanChapter` + `ShelfUpdater.ets` 去掉 `import` 的全文）
+ 只打桩 3 个外部依赖（`bookEngine` / `upsertBook` / `isLocalBook`）→ `tsc` + `node`。**被测的是真编排与真 `chapterKey`，没有重写被验逻辑**。

| 组 | 断言 |
|---|---|
| 计数 | `total`=4（本地书已排除）/ `checked`=3 / `failed`=1（搜索失败静默）/ `skipped`=0 / `updated`=[剑来] |
| 基线 | 新章前移 1 次写库；**等价对齐静默写 1 次但不报新章**；无基线书静默建基线；失败书基线未被动过 |
| 幂等 | 第二次点击 `updated`=0、写库 0 次 |
| 并发/进度 | 同时在飞 ≤ 3（打桩计数）；进度首尾 `0/4`→`4/4`、条数 = N+1；**失败数在进行中就上报**（一本 0ms 即败 + 一本 150ms 才回 ⇒ 序列 `检查中 0/2` → `1/2 · 1 本未检查` → `2/2 · 1 本未检查`）；`shelfProgressText` 4 种形态 |
| 预算 | deadline 在过去 ⇒ `skipped`=4 / `checked`=0 / 0 写库 |
| 书源 | 源列表为空 ⇒ `failed`=4 / `checked`=0 / 0 写库；只有本地书 ⇒ `total`=0 不报错 |
| 超时护栏 | 一本打桩 16s 不返回 ⇒ 该本 `failed`、其余书 `checked`、**整体 15002ms 返回**（15s 护栏生效） |

`make hap` 通过（`make doctor`：signed HAP 10-13 09:25 晚于全部 ets 源）；`make check` 全绿（TOC / 相对链接 / 混淆 keep 145 名字覆盖全部 JSON 字段，
本轮**未新增**跨 NAPI 或落盘 JSON 字段）。

### 19.5 未覆盖

1. ~~真机三项~~ **已验（2026-10-13 真机）**：进度与结果文案（读法：`uitest screenCap` 连拍 + 主机 `tesseract -l chi_sim` OCR，因为 `uitest dumpLayout` **不导出系统 toast 窗口**）、本地书排除（`total = 2`）、失败静默与零误写、防重入、幂等、编辑态隐藏。
2. ~~失败注入~~ **已验**：停用 `bbiquge8` **及其同 URL 孪生** `笔趣阁8`（两者都指 `m.bbiquge8.net`）⇒ `checked === 0`，toast `检查失败，请检查网络或书源`，不崩、不写库（真机链路的错误码路径已走通）。
3. ~~「有新章」分支在真机上不可造~~ **已被一次性调试版绕过并真机走通（2026-10-13）**：它需要「基线落后于源最新章」的初始状态，两条**常规**注入路径仍封死 —— ① 沙箱 DB 对 shell **只读**（`touch` / `hdc file send` 均 `Permission denied`）；
   ② App 内写基线的两处（换源 `SourceSwitch.ets:206`、加入书架 `BookDetail.ets:71`）写的都是**同一个源的详情页值**，而本功能比对的就是这个值 ⇒ 除非站点自然更章，否则必然相等。
   ③ 改用调试版：临时在 `ShelfUpdater.probeBook` 里只对《剑来》把**落库值**写成 `latest + ' [T-MARK]'`（比较逻辑不变，返回 `PROBE_SAME`）⇒ 真机写库后 DB 得 `第83章 今日无事 [T-MARK]`（**真 `upsertBook` 写库**已证）；
   `git checkout` 还原后复跑 ⇒ toast **`1 本有新章节`** + 基线前移回 `第83章 今日无事`（`chapterKey` 把标记认成新章，即该分支本体）；再点一次 ⇒ `没有发现新章节，1 本未检查` 且整库逻辑 diff 为空（幂等）；收尾无 `[T-MARK]` 残留、书源 13/13 启用、工作树干净。
4. release 包未复跑（本轮无新增 JSON 契约 ⇒ 混淆面未变）。
5. 探测深度只到详情页（不爬目录，按决策不做）；书架行内角标留待下一轮。

### 19.6 收尾小迭代（2026-10-13）：进行中进度行显示未检查数（主机侧 + 真机均已验证）

动机：检查中只显示 `检查中 done/total`，**失败数却要等结束 toast** 才知道 —— 而源失效这种失败正是用户最想中途知道的（等 90s 预算跑完才告知）。
改法：`checkShelfUpdates` 的进度回调扩为 `(done, total, failed)`（`failed` = **累计**值），并新导出**纯函数** `shelfProgressText(done, total, failed)`：无失败 `检查中 1/2`，有失败 `检查中 1/2 · 1 本未检查`，`total = 0` 时 `检查中…`；`pages/Index.ets` 只把原拼串换成调函数。
放在 `ShelfUpdater.ets` 而非 Index：主机仿真按整文件切片该模块 ⇒ 字符串本身有断言（纯 UI 里写就只能靠真机截图 OCR）。
口径：进行中的 `N 本未检查` **只算已结束的失败书**（`failed`），不含 `skipped`（整体预算耗尽后没开始的书要等所有 lane 收尾才知道）；结束 toast 仍是 `failed + skipped`，两者不冲突。
UI：仍是 13fp `text_3`、`maxLines(1)`，**未新造令牌/样式**，「更新」按钮的 16fp `brand` / 44 热区 / `accessibilityText` 未动（[`../specs/UI-SPEC.md`](../specs/UI-SPEC.md) §1.7 令牌）。
验证：`python3 scripts/shelf-updater-sim.py` **25 → 30 断言 `ALL PASS`**（新增 4 条文案形态 + 1 条进行中失败数序列；顺带订正本节旧写的「27 断言」笔误）、`make hap` 通过。
真机（2026-10-13，`make run` 闭环 + `uitest screenCap` 连拍 + 主机 `tesseract` OCR）：
- 无失败形态 `检查中 1/2`（`dumpLayout` 实测 `[658,190][869,241]`，宽 211px = 105.5vp）；
- 有失败形态 `检查中 1/2 · 1 本未检查` —— 注入方式：停用 `bbiquge8` **及其同 URL 孪生 `笔趣阁8`**（该源不请求即计失败），另一本仍要走网络 ⇒ 失败数在**进行中**就上屏（这正是本迭代的目的）；注入后两个开关已还原，复检「书源（13/13 启用）」；
- 同一注入轮 DB 无写入（全部失败 ⇒ 不该有 `upsertBook`；比对用 `shelf.db` + `-wal` 合并；**只 recv 主库会漏 WAL**）；
- 宽度/截断：以实测字宽外推最长形态 `检查中 20/20 · 19 本未检查` ≈ 550px，可用区间 ≈ 710px（标题右缘 190 → 「更新」按钮左缘 ~900）⇒ 余量 ≈ 160px（~80vp），**不截断**；该最长形态本身未在真机出现（架上只有 2 本网络书）⇒ 仍是外推。

## 20. 增量（2026-10-19）：换源当前位置兜底 + 封面加载单飞

范围：`components/SourceSwitchPanel.ets`、`pages/Reader.ets`、`components/BookCover.ets`。
验证环境：**主机侧**（`make hap` / 回归脚本 / `make check`）+ **真机部分路径**（设备 `33Z0224424136564`，
debug HAP）；真机已覆盖书架读路径、更新检查、启动缓存裁剪与备份导入导出，其余路径见 §20.6。

### 20.1 换源：当前源检索失败时仍显示「我在哪」

换源抽屉原先只用候选行上的 `current` 标记当前源。若单源瞬时超时或本轮没返回当前源，抽屉里会完全没有当前位置。
现在检索结束后若没有任何 `current` 候选，就在进度行下方固定显示当前源名 +「本轮检索未返回当前源」+「当前」：
`currentSourceName` 由 `Reader` 传入；该行不可点击、不显示「切换」，且**不计入候选数**。检索中不插入，避免列表跳动。

### 20.2 封面：并发渲染同一 URL 只下载并解码一次

`BookCover` 原先只有成功的 PixelMap / 路径缓存；书架、搜索、详情同时在首帧请求同一封面时，会各自穿过空缓存并重复下载、解码。
现在模块级 `inflightLoads` 按 `cacheDir + coverUrl` 单飞整段「下载 + 解码」，后到组件直接等待同一个 Promise；成功后共享 PixelMap LRU，
失败后共享 `failedCache` 且任务出表。`ImageSource` 在解码完成后显式 `release()`，不再把文件句柄和解码器状态留到 GC。

### 20.3 书架：一条 JOIN、按 URL 只读书源、轻量缓存进度

书架刷新原先串行 `getSource()`，随后又需要先读完整投影、按 URL 选行，再按 id 批读完整规则。现在拆成三条
更窄的查询：

- `ShelfRepository.getShelfBooks()` 用一条 `books LEFT JOIN progress` 同时取书籍与当前进度，保持
  `added_at DESC` 的展示顺序，不再分别读两张表后在内存合并。
- `SourceStore.sourcesForUrls()` 只接收书架实际使用的 URL，去空、去重、400 个一组读取完整书源；同一 URL
  优先最早的启用行，否则回退最早的可解析行。坏 JSON 不占位，后续候选仍可命中，结果按输入 URL 顺序返回。
- 书架「更新」也改用同一 URL 批读入口；`CacheTrim` 只取 `book_id + chapter_index`，不再反序列化整行
  `ReadProgress`。`getBooks()` / `getAllProgress()` 的列下标仍保持每张结果集解析一次。

完整书源的 `enabled` 与 `confidence` 都由索引列覆盖 `json` 中的旧副本，避免启停后读到陈旧的 JSON 值。

### 20.4 备份：文件 I/O 异步化并分块编解码

`BackupManage` 的导入/导出原先使用 `openSync` / `statSync` / `readSync` / `writeSync` / `closeSync`，
大备份会把整段文件读写压在 UI 线程。现在改用异步 API，按 1 MiB 分块读取、流式 UTF-8 解码，并用
`TextEncoder.encodeIntoUint8Array()` 分块编码后写入；短写会循环补齐，编码边界不会拆开代理对。
JSON 的 `stringify` / `parse` 与备份事务语义未变。

### 20.5 批量写：删除、恢复、检测结果一次事务提交

书架与书源管理原先还有几处「循环里逐条 await 写库」：批量删书每条开一次事务，备份恢复复用逐条
`upsertBook` / `saveProgress`，书源页处理全部不可用源时逐行 `setEnabled` / `remove`，检测作业也按 32 条
结果逐条 UPDATE。数据量一大，事务日志和 SQLite 往返会随行数线性膨胀。

现在：

- `ShelfRepository.removeBooks()` 在**一个事务**内分块删除 `books` / `progress`（每块 400 个 id），提交后
  再清理 `lastWriteAt` 与 `ProgressOwner`；中途失败整批回滚，不会留下「书删了、进度还在」的半成品。
- `ShelfRepository.replaceShelf()` 在**一个事务**内清空两张表并重建备份内容；进度行直接插入，保持既有的
  RESTORE 语义（绕过 TTS 仲裁、不清 `ProgressOwner`），但不再为每行起一次自动提交。
- `SourceStore` 新增 `setEnabledMany()` / `removeMany()`，按 400 个 id 分块、整批一个事务；新增
  `patchDetects(DetectPatch[])`，一批检测结果共用一次 commit。单条入口仍保留给行内开关和菜单操作。
- `SourceStore.sourcesForEngine()` 的稳定 id 批读也按 400 个 id 分块；去重后的输入顺序、缺失行跳过和
  `confidence` 列覆盖 `json` 副本的语义不变，避免超大批次 `IN (...)` 撞 SQLite 绑定变量上限。
- `BookSourceManage` 的「关闭 / 删除不可用源」先收集 id，再调用一次批量接口；`DetectJobRunner` 每批
  JSONL 落盘后一次回写，进程恢复时也按完整批次回写并继续检查取消状态。

### 20.6 验证边界

- 主机侧已通过：`make test` 73 passed、`make test-pregen` 114 条断言、`make test-detect` 135 条断言、
  `scripts/shelf-updater-sim.py` ALL PASS；`make native-fresh`、`make check`、`make docs-toc`、
  `make hap` 均成功，`git diff --check` 无空白错误。构建日志中的 `createTransaction` /
  `querySql` API 12 兼容性 warning 属于既有存储层写法；本轮没有新增 NAPI 契约或 schema 变更。
- 真机已通过（2026-10-19，`make restart` 后取证）：书架 4 本及进度 / 章数正常；「更新」完整走到
  `没有发现新章节，1 本未检查`；启动日志 `SourceReaderCache: trim scanned=5 freed=0 files 0 B keptRead=4`；
  备份页显示 `13 个 / 4 本 / 9 条`，导出 33.26 KB 的 `sourcereader_backup_2026-10-19.json` 成功，
  导入该同一份备份后计数不变，force-stop 重启后仍为 `13 / 4 / 9`、书架 4 本正常；相关日志无应用 JS
  异常或 RDB 失败。
- 未验证：真机上并发封面是否只出现一次 `downloadCover`、换源抽屉固定当前源行的实际排版与点击穿透，
  以及批量删除 / 检测结果回写的事务耗时。

## 21. 增量（2026-10-23）：书架更新混合书架分母与无章节名源兜底（主机侧与真机均通过）

### 21.1 症状与根因

用户书架实际有 2 本，点击「更新」却先显示 `检查中 0/1`，随后提示「检查失败，请检查网络或书源」。书架中一本是
`source_url=local://` 的本地 TXT，另一本是《中国少了一味药》，书源为 qwyd。前者按设计不参与网络检查，但旧进度只拿
网络书作分母，导致显示与用户看到的书架数量不一致；后者的搜索与详情请求正常，只是该源没有 `lastChapter` 规则，
详情和搜索结果都没有章节名，旧逻辑因此把整本书计入失败。

主机探针确认：qwyd 搜索能命中《中国少了一味药》，`bookInfo` 返回空章节名，`toc` 返回 38 章、末章为 `第三十七章`。

### 21.2 修复

- `ShelfUpdateOutcome` 新增 `local`；进度回调扩为 `(done,total,failed,local)`，`shelfProgressText()` 只显示网络书进度，
  本地书仅在末尾显示数量，例如 `网络 1/2 · 本地 2`；失败时追 ` · N 本未检查`。
- 新增 `shelfUpdateResultText()` 统一结束 toast：混合书架网络书全失败时显示「网络书检查失败，请检查网络或书源」；
  无新章时明确本地书跳过；部分网络书失败与本地书跳过同时存在时分别说明。
- 只有详情页与搜索结果都没有章节名时才回退 `bookEngine.toc()`，URL 顺序为 `info.tocUrl` → 书架 `book.tocUrl` →
  搜索命中 `bookUrl`，超时使用 `ENGINE_TOC_TIMEOUT_MS = 45s`；取末个非卷、非空章节。正常源仍是 2 请求，兜底最多 3 请求。

### 21.3 验证

- `python3 scripts/shelf-updater-sim.py`：**55 断言 `ALL PASS`**，覆盖本地书分母、混合书架结果文案、目录兜底、
  卷标题跳过、三级 URL 回退、45s 预算、目录失败不写库，以及本地 TXT 文件名的六种书名/作者拆分形态。
- `make hap` 通过；`make check` 全绿；`git diff --check` 无空白错误。
- 真机已通过（2026-10-23，设备 `33Z0224424136564`，debug HAP：构建、覆盖安装、force-stop、启动）：
  OCR 捕获首轮 `检查中 1/2 · 本地书 1 本跳过`，结束 toast 为「没有发现新章节，1 本本地书跳过」。
- 拉取 `shelf.db` + `-wal` + `-shm` 后核对：qwyd 网络书 `c99cb66a` 的基线写为 `第三十七章`；本地书
  `155886f3` 的 `source_url=local://`、书名与作者已规范化，阅读进度仍为第 152 章 / `chapter_index=152` /
  `paragraph_index=4` / `percent=0.10617626648161`。
- 第二次点击更新后的逻辑数据库 dump 哈希仍为
  `8c1464d262654cb2cf0606eed7a83f91b34a6d459ed4f30add82246929ed8185`，与首轮完全一致，确认幂等且零误写。

### 21.4 本地 TXT 导入元数据

- 《大唐：李世民求我造反 作者：天下乐.txt》旧导入结果为 `name=大唐：李世民求我造反 作者：天下乐`、
  `author=天下乐`。新增 `splitTitleAuthor()`，只剥离文件名尾部作者标签并优先采用文件名作者；得到规范书名
  《大唐：李世民求我造反》和作者「天下乐」，可用于后续按书名 + 作者检索书源。
- 已有 `local://` 行在书架加载时原地幂等修复书名和作者，`bookId`、来源、`addedAt` 与阅读进度不变；
  本地 `toc.json` 的元数据同步修正，不改正文和章节索引。
- 真机旧行修复已验证：`book_id=155886f3`、`source_url=local://`、`added_at=1790260398161` 保持不变，
  数据库与 `toc.json` 均为 `name=大唐：李世民求我造反`、`author=天下乐`，目录仍为 1441 章。
- 未单独复测「全新导入一份重复 TXT」这一条路径，以避免向用户书架增加测试书；旧行修复已走真机，
  新导入与旧行修复共用同一套已通过主机断言的解析与规范化函数。该修复只规范本地书元数据，不会自动把
  `local://` 书绑定到在线书源。

---

## 22. 增量（2026-10-30）：长章节首屏冻结（T-READ-5）—— ✅ 真机实证并修复

### 22. T-READ-5 现象与取证

打开《剑来》第 25 章，正文出现要 **5s**；同一时刻系统日志报
`WMSMain OnVsyncTimeOut` + `Vsync PrintRequestTs: recv vsync timeout ... timeInterval:2630443928ns`，
即**单个渲染帧耗时 2.63s**。应用侧临时埋点（`rg -n "TEMP PERF|PERF " entry/src/main/ets`）给出链路：

| 阶段 | 修复前 |
|---|---|
| `getCachedToc` / `loadToc HIT` | 读 1ms + parse 1ms / 2ms（1321 章，163KB，**未走网络**） |
| `buildTocItems` | 4ms |
| `refreshDownloadState` | 44ms |
| `sanitizeText` | 14ms，**paras=2405 chars=133983** ← 异常 |
| 首次 `rebuildWindow` | **604ms**（6674 次 measure，413 页） |
| `warmNeighbors → rebuildWindow` | **1942ms**（19,978 次 measure，1244 页） |
| 累计到正文 | **2719ms** |

### 22.1 根因一：书源规则把 30 章拼成一章

内置 `小说`（`http://www.yetianlian.info`）的 `ruleContent.nextContentUrl = text.下一章@href`。
`nextContentUrl` 的语义是「**本章**正文分页的下一页」，而 `text.下一章` 匹配的是**下一章**；引擎
`rust/legado-engine/src/runtime.rs` `content_inner` 会顺着它最多追 `MAX_PAGES = 30` 页并全部拼进同一章。

设备侧取证（`hdc file recv .../files/chapters/4b445f13_2{4,5,6}.json`）：

| 章节 | 字节 | 段数 | 内嵌链接 |
|---|---|---|---|
| ch24 | 136,376 | 2439 | 30 个（`649742..649771`） |
| ch25 | 133,983 | 2404 | 30 个（`649743..649772`） |
| ch26 | 133,612 | 2387 | 30 个（`649744..649773`） |

ch26 首句出现在 ch25 第 71 行 ⇒ **相邻章重复 29 章正文**。主机 `curl` 实测单页正文 **4,309 字**、页面内
`下一页` / `下页` / `_2.html` 命中 **0 次** ⇒ 该站根本不存在正文分页，这条规则纯属多余。

修法：删掉该源 `ruleContent.nextContentUrl`。主机 `make probe` 复核：修前返回多页拼接体；修后
`正文：4305 字，nextUrl=（无）`。旧缓存按域名作废（`chapters/4b445f13_*.json` 已清，缓存在下一次打开时重新生成）。

### 22.2 根因二：分页窗口每次重建都全量重排

严重度与篇幅强相关，但它是**兜底缺口**：上游再错一次（或遇到天然超长章）仍会冻。`rebuildWindow` 一次要排
上/本/下三章**全部**页流，而 `warmNeighbors` 暖载完邻章后还要整体重排一次 —— 本次章在这一步里被**重排两遍**。

修法：`pages = F(章文本, 排版参数)`，其中排版参数 = 内容宽 × 高 @ 字号 / 行距。
1. `Reader.pageCache: Map<number, PageSeg[][]>` + `chapterPages(index, paras)`：命中直接返回；
   `layoutKey()` 指纹变化（含 `onAreaChange` 尺寸变化、`changeFont`、`changeLineHeight`）→ 整体清空。
   `applyChapter`（正文可能变）与 `resetContentState`（换源 / 换书）分别 `delete` / `clear`，不留脏页。
2. `Swiper` 内 `ForEach` → `LazyForEach`：新 `common/PageDataSource.ets`（`IDataSource`，`onDataReloaded` 通知），
   `PageSeg` 从 `Reader.ets` 抽到 `common/PageSeg.ets` 供两者共用。原先一次性实例化整本页流（本页 413，warm 后 1244）。

### 22.3 真机验证（2026-10-30 · 设备 `33Z0224424136564` · debug · `make run`）

| 指标 | 修复前 | 修复后 |
|---|---|---|
| 首屏 `rebuildWindow` | pages=413 / measures=6674 / **604ms** | pages=14 / measures=209 / **27ms** |
| `warmNeighbors` 后重建 | pages=1244 / measures=19,978 / **1942ms** | pages=52 / measures=548 / **209ms** |
| vsync timeout（2.63s 丢帧） | **1 次** | **0 次** |
| 正文就绪 | ~2.7s（+ 转场 → 5s） | **0.77s** |

- 章内时间线（修复后）：toc 4ms / `refreshDownloadState` 32ms / `fetchContent` 657ms / `sanitizeText` 2ms / 首次排版 27ms → **769ms**。
- **缓存生效的直接证据**（同一次进入里同一章被重排）：
  短章节 `pages=7 measures=94`（邻章暖载前）→ `pages=21 measures=210`（暖载后拼接重排）；
  再进一章 `pages=15 measures=0` → `pages=23 measures=134` ⇒ **本章 0 次重测**，只排了增量邻章。
  无缓存时单章约 2,000 次 measure；连按两次字号 18→20 只测 362 / 425 次。
- 顺带：该源一本书的章节磁盘缓存由 30×~394KB 降为单章级，换章请求数 30 → 1。

### 22.4 未覆盖 / 顺带记录（未修）

- 修复后仍有约 **4s** 在「转场 + 迁移列表」判定：该源目录已被站点重排（`tocs/4b445f13.json` 1321 条里 `index 25`
  现是「第一卷 笼中雀 第十四章 五月初五」，而 `index 0` 是「第84章 上升地」），迁移在解析旧进度快照。
  属另一条链路（进度迁移），本次不动。
- 该源目录开头 `第84章 / 第83章 / 第82章 …` **倒序**：原记的「疑似站点目录分页本身倒排」**已证伪**（该源目录只有一页、无 `nextTocUrl`）——
  那 12 行是详情页顶部 `<dt>《剑来》最新章节列表</dt>` 预览块被 `chapterList = "dd"` 一起收进了目录，尾部另有第二次上传；见 §23。
- release 包未复跑：纯 ArkTS + 资源改动，**无新增 JSON 字段** ⇒ 未动 `obfuscation-rules.txt` keep 列表；`make check` 待跑。
- 埋点仍在（`PERF` 前缀，样例日志见上）—— 复验后按需删除；不影响卡顿（均在微秒~毫秒级或已排到正文之后）。

---

## 23. 增量（2026-11-02）：换源候选「目录体检」徽标（T-SWITCH-2）—— 主机侧 + 真机均已验证

范围：`model/TocQuality.ets`（新）、`model/SourcePrefetch.ets`、`components/SourceSwitchPanel.ets`、
`pages/Reader.ets`（换源确认框）、`scripts/toc-quality-sim.py`（新）、`Makefile`（`make test-toc`）。
验证环境：**主机侧**（`make test-toc` + 用设备抓下来的两份真实目录喂同一份实现）。**未上设备。**

### 23.1 起因（用户真机提问）

手机上《剑来》的目录长成三段：`第84章 第83章 … 第73章` + `第一卷 第一章 … 第1218章` + `第1章 … 第84章`。
用户问「为什么不是 `第1章 … 第1218章`」，随后提出「能不能在**搜索**时就判断这个书源存在脏数据 / 让脏源**排序靠后**」。

### 23.2 根因（设备侧取证）

`小说`（`http://www.yetianlian.info`，301 → `www.xyetianlian.com`）的 `ruleToc.chapterList = "dd"`，
而该站目录**只有一个 `<dl>`、只有一页**，里面塞了三段 `<dd>`：

| 段 | 下标 | 是什么 |
|---|---|---|
| ① | 0–11 | `<dt>《剑来》最新章节列表</dt>` 下的**详情页预览块**（最新 12 章、最新在前 ⇒ 开头的 `第84章…第73章`；`index 3–6` 正是设备上正在读的那几章） |
| ② | 12–1235 | `<dt>《剑来》正文卷</dt>` 真目录（`第一卷 笼中雀 第一章 惊蛰` → `第一千二百一十八章 看书人`，1224 行） |
| ③ | 1236–1320 | **另一次上传**，从 `第1章 少年游` 重新编号到 `第84章 上升地`（85 行；章节 id 45,995,408+ 比正文卷最后一条 45,982,482 更新，正文还是另一本西幻） |

⇒ 1321 行 / **1309 个唯一 URL**（12 行预览块的 URL 与尾部 12 行完全相同）。
⇒ 该源**没有目录分页**（`ruleToc` 无 `nextTocUrl`）⇒ T-READ-5 §22.4 的「站点目录分页本身倒排」**不成立**，已就地改正。

### 23.3 为什么判据落在「换源候选」而不是搜索排序

- **成本**：候选里只有最靠前 **2** 个会连目录一起爬（`SourcePrefetch` 为「点切换即命中」本来就要爬）⇒ 体检**零新增请求**；
  搜索页要判同样的事得给每个候选各加一次全量目录爬取（该源 1 页 / `bbiquge8` 13 页），不进主路径。
- **跨源共识失效**：`bbiquge8`（`m.bbiquge8.net/dir/814/`）同一本书 **1309 行 / 0 重复 URL**，但末段同样从 `第1章` 重新编号，
  也同样有 `第349章` 重号与两条公告（`紧急通知` / `请假一天，顺便小聊几句。`）⇒ **末段重新编号是上游采集数据本身的问题，换源解决不了**；
  能在候选之间做出区分的只有「重复 URL 行」（该源特有的预览块）。
- **元数据信号方向不对**：按 `字数 ÷ 最新章号` 判会奖励「元数据暴露得多」的源 —— 该源 `16091823 ÷ 84 = 191,569 字/章`
  （剑来真实 ~13,200 字/章），而 `bbiquge8` / `玄幻阁` 的 `wordCount` 是空的。
- 因此**不写回 `sources.confidence`**（那列是可达性自愈分：成功 +5 / 失败扣 15–30，语义见 `model/SourceConfidence.ets`）。

### 23.4 修法

1. 新 `model/TocQuality.ets`（纯函数，只依赖 `Chapter` 类型）：一次 O(n) 扫描算
   `rows / volumes / dupUrls / dupTitles / notices / untitled / numbered / tailRestart`，三级 ——
   `SUSPECT`（有重复 URL 行，**或整份目录没有标题**）/ `NOTICE`（末段重新编号、≥3 个重复标题、≥3 条公告）/ `CLEAN`。
   卷行（`isVolume` 或空 URL）不参与去重；带「卷/部/篇/册」的标题不参与章号回退判定（避免逐卷重新编号误报）；
   公告判定用宽松的「带章号」（`第` + 数字）而非严格「第N章」—— 站点把 `第四百二十张 山水依旧` 打成了「张」；
   且**带章号的行不到一半时不判公告**（站点根本不按「第 N 章」编号，否则整份目录会被读成一条条「公告」——真机实测过）。
   `untitled`（标题为空的行）另立一条：阈值「≥3 行且占可读行 ≥1/4」才升级为可疑级（零星空行不触发）。
2. `model/SourcePrefetch.ets`：目录爬回来即体检，结论存进 `tocCache` 条目（`PrefetchedToc.quality`），
   经新的 `onToc` 回调回填候选行；缓存命中路径复用结论（`tocTasks` 的 promise 改为返回结论）。
   空目录 / 爬取失败 / 未体检 = `undefined`（**缺证据既不当作干净、也不当作脏**）。
3. `components/SourceSwitchPanel.ets`：`SwitchRow.quality` + 行内第二行徽标（可疑级 `⚠ …` 用既有 `warning` 令牌，
   提示级用次要色），排在「最新：xxx」**之前**（该行 `maxLines(1)` + 省略号，窄屏先截尾部）；`ForEach` key 追加徽标。
   **不重排行**（体检比候选上屏晚数秒，行序抖动会误点，而换源是删行 + 清缓存的破坏性动作），
   拦截改由点击后的确认框承担：`Reader.confirmSwitch` 对可疑级追一句说明 —— 重复行 =「换源不会消除」，
   无标题 =「换源后目录同样显示不出章名」。

### 23.5 验证（主机侧 + 真机）

- `make test-toc` = 新 `scripts/toc-quality-sim.py`：**直接编译真实 `model/TocQuality.ets` 源码**（`Chapter` 形状从
  `engine/types.ets` 切片，防漂移），**67 条**契约断言 **PASS**（含数字解析、三级判定、卷行/逐卷重编号/短尾/小书四类防误报、空目录、
  整份无标题与「不按第N章编号」两类新信号）。
- 用设备抓下来的两份真实目录喂同一份实现：
  `小说` **1321 行 / 12 重复 URL / 13 重复标题 / 2 公告 / level=SUSPECT**（徽标 `⚠ 目录 12 行重复`）；
  `bbiquge8` **1309 行 / 0 重复 URL / level=NOTICE**（徽标 `目录末段重新编号`）⇒ 两个候选被体检分开。
- **真机（2026-11-02，设备 `33Z0224424136564`，debug；`make hap NO_DAEMON=1` → 独立安装 → 阅读页「换源」→ `uitest dumpLayout`）**：
  7 个候选的逐行文案与主机预测**逐字一致** —— `bbiquge8` = `目录末段重新编号 · 最新：第84章 上升地`（提示级、次要色）；
  `黑炎小说` = `⚠ 目录 1331 行没有标题 · 最新：第84章 上升地`；当前源 `小说` 行无徽标也无「切换」（当前源不是候选）。
  点 `黑炎小说` 的「切换」→ 确认框消息实测 =
  `当前源的书架记录与缓存会被清除，阅读进度将按章节对齐迁移到新源，此操作不可撤销。\n\n⚠ 该源目录有 1331 行没有标题，换源后目录同样显示不出章名。`；
  点「取消」后抽屉仍在、当前源仍是 `小说`（**未发生切换**，验证未改动设备状态）。
- **真机逮到的误报（已修）**：`黑炎小说` 行一度显示 `目录含 1331 条公告`（该候选整份目录 1331 行都判不出章节号，
  原逻辑把它们全读成「公告」）⇒ 新增 `untitled` 信号 + `numberingOff` 闸门，修后徽标 = `⚠ 目录 1331 行没有标题`。
- **未覆盖 / 待办**：① `⚠ 目录 N 行重复` 这一条真机未见 —— 能触发它的 `小说` 正是当前源（当前源不体检），
  要看到它得先切到别的源再重开抽屉；文案本身由 67 条断言覆盖，渲染路径与「无标题」徽标完全相同（同色同位置）；
  ② release 包未复跑（纯 ArkTS、**无新增 JSON 字段** ⇒ 未动 keep 列表）；
  ③ **未解释的观测**（已登记 `TASKS.md` §T-SWITCH-2）：同一条 `chapterList = ".book_list@li"` 规则在主机 `probe parse` 上能取到
  `上架感言` / `第一章 惊蛰`，设备侧这 1331 行标题却全为空（`probe info/toc --index 2` 本机 30–60s 超时，未定因）。
