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
| R3 / T-CROSS-3 | 阅读与听书对同一本书的无条件进度写互相覆盖 | `saveProgress` 增加 `lastWriteAt` 时间戳防旧写覆盖（`ShelfRepository.ets:132-152`）；叠加 R1 消除跨书污染 |
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

## 3. 签名审计（重要）

| 字段 | 状态 |
|---|---|
| `signingConfigs` 数量 | 1（`default`，`type: HarmonyOS`） |
| 产品绑定 | `products.default.signingConfig = default`（Debug / Release **共用同一身份**） |
| `keyAlias` | `debugKey` |
| 密码字段 | `keyPassword` / `storePassword` 为 86 字符 DevEco 密文（前缀 `000000`）→ `DEVECO_CIPHERTEXT_LIKELY`（非明文） |
| 证书/Profile/keystore | 全部位于仓库**外部** `~/.ohos/config/` |
| Profile 类型 | **`debug`**（含 `debug-info`、development-certificate；无 distribution-certificate） |
| 仓库边界 | `.p12/.p7b/.cer/.keystore` **未被跟踪、历史中亦无**（无泄漏） |
| 但 | `build-profile.json5` **本身被跟踪且内含本地绝对路径 + DevEco 密文口令** |

**结论：`SIGNING_READY` 未达成（针对公开发布）。** `assembleHap/assembleApp` 成功、`verify-app` 通过，但产物由 **Debug 身份/Profile** 签发，**不得**用于正式分发或 AppGallery 上架；仅适用于本地开发安装。

**建议（发布前必做）**
1. 申请正式 Release 证书与 Profile（release 类型、distribution-certificate），新增独立 `signingConfig` 并仅绑定 `products.default` 的 Release 构建；Debug 与 Release 身份分离。
2. 按 `AGENTS.md` §7：将 `build-profile.json5` 的本地签名差异 `git update-index --skip-worktree`，仓库保存 `signingConfigs: []` 干净版；**勿提交**含路径/口令的版本。
3. 完成正式 Release 构建后用 `hap-sign-tool verify-app` + `verify-profile` 复核 profile 类型为 release 且 bundle 一致。

---

## 4. 已知遗留 / 未完成

### 4.1 发布阻塞项

| 项 | 说明 |
|---|---|
| **Release 签名身份** | 见 §3，当前为 Debug Profile |
| **版本号** | `versionName`/`versionCode` 未提升 |

### 4.2 顺延的 TASKS（非本轮范围）

- `T-SHELF-1` 删除书籍清理缓存：`removeBook` 无调用点（无删除 UI），待删除入口一并实现。
- `T-SHELF-3` 进度三态在 `percent` 极小值时的反推边界，待真机复验。
- `T-READ-1` `Reader.sanitize` 与 `BookContent.sanitizeText` 合并（两份当前**逐字节一致**，纯重构）。
- `T-READ-3` 章节预取 in-flight 去重（LRU 已降低重复写盘概率）。
- `T-DATA-3` 备份/恢复、`T-DATA-4` 缓存 LRU/上限策略（M6）。
- `T-VER-3` 真机闭环已完成（见 §5）；跨书串扰与后台任务结束的直接观测待条件复验。
- M6 规则调试器整体未开始。

### 4.3 保留的工作文档（未纳入版本控制）

`AUDIT.md`、`ROOT-CAUSE.md`、`TASKS.md`、`UI-SPEC.md`、`TTS-PLAN.md`、`HANDOFF-S3/4/5.md` 为未跟踪工作文档（`HANDOFF-S6..S9.md` 已跟踪）。
> 注：其中 `UI-SPEC.md` 已于 2026-10-06 重建为 [`docs/specs/UI-SPEC.md`](../specs/UI-SPEC.md)（底部抽屉统一规范，现行有效）。
建议择一：提交归档，或加入 `.gitignore`；**本轮未删除**这些审计轨迹。

---

## 5. 真机冒烟（2026-09-27，设备 `33Z0224424136564`）

设备接通后完成 `AGENTS.md` §4 闭环（安装 → `aa force-stop` → `aa start` → `hilog`/`uitest` 观测）。
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
| release 构建 + SignHap + SignApp | ✅ |
| Rust `cargo test` | ✅ 54/54 |
| `verify-app` / `verify-profile` | ✅（身份为 debug） |
| 签名就绪（公开发布） | ❌ Debug Profile |
| 真机冒烟 | ✅ 已执行（见 §5） |
| 真机跨书串扰 + 后台任务结束直接观测 | ⏭ 待联网/工具条件复验 |
| Git 清理 | ⚠️ 已提交 `596f16a`；`build-profile.json5` 凭据边界待处理 |

**最高发布状态：`SMOKE_TESTED`（仅限内部/开发渠道；公开发布仍受 Release 签名身份阻塞，未达 `READY_FOR_PUBLICATION`）。**
---

## 8. 增量（2026-10-07）：书架编辑模式（多选删除）+ 目录缓存统计

> 计划与逐行代码见 [`../research/SHELF-EDIT-PLAN.md`](../research/SHELF-EDIT-PLAN.md)（§8 S1–S4）。
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
| 真机 DoD D1–D21 | ✅ **已验（2026-10-07，设备 `33Z0224424136564`）**：D1–D9 / D11 / D13 / D15–D17 / D19 / D21 全通过；D10 / D12 / D14 / D18 按用户决定跳过；D20 部分通过（书架书量不足）。逐条证据见 [`../research/SHELF-EDIT-PLAN.md`](../research/SHELF-EDIT-PLAN.md) §12.3 |

### 8.5 真机验证与真机专属修复（2026-10-07）

- **长按手势 bug（真机专属，计划外）**：计划 §8 的 `longPressToEdit(entry): GestureType` + `.gesture(...)` 写法在真机上**从不触发**——`.gesture()/.parallelGesture()` 只接受**内联手势字面量**，helper 返回的 gesture 被 ETS 编译器**静默丢弃**（转译产物退化为 `Gesture.create(GesturePriority.Parallel); Gesture.pop();`）；另 `.gesture()` 为 `GesturePriority.Low`，在 `Navigation` 下输掉竞争。
  **修复**：改为 `.parallelGesture(LongPressGesture({ repeat: false, duration: 500 }).onAction(() => this.onLongPress(entry)))`（grid/list 同形），helper 改名 `onLongPress(entry): void`（只留 `longPressFired` + `edit.enter`）。长按 +498ms 触发 ✅。已回写计划 §1.6 #42/#43、§5 K16/§5.2、`TASKS.md` `T-SHELF-4`。
- **三个真机疑点关闭**：**R6** 500ms 手感 ✅（+498ms）；**R10** `Index.onBackPress` 生效、`EntryAbility.ets` **未改** ✅；**R12** 长按后不补送 click（`longPressFired` 兜底未依赖）、3s 慢滑不误进编辑态、编辑态慢滑不改选 ✅。
- **删除链路端到端**：删「夜的命名术」（当时 TTS 在播）→ 书架 4→3 且重启仍 3；DB `books` 4→3 / `progress` 7→6；`chapters/` 13→6、`tocs/` 4→3；应用内章节缓存 125.2→28.6KB、目录缓存 235.5→**73.8KB**（与文件字节逐一对应）；点击「清理全部缓存」四类归零；TTS 停（无后续 `play para=`）+ 听书 FAB 消失；双击「删除」防重入只删一次。
- **异常面**：`hilog` 全量扫描 **0 条** JS/ArkTS 错误 + **0 条**本应用 error 级日志（仅框架内部既有 `ImageSource` 等封面噪音）。
- **未验完整项**：**D20**（编辑态滚动）—— 本机书架 3–4 本不足一屏、不可滚，且三条加书路径（搜索 onSubmit / 文件选择器 / 缩小窗口）均不可自动化 → 以「慢滑不误触 + 编辑态慢滑不改选 + 不阻断滚动」三项替代证据；**D10 / D12 / D14 / D18** 已跳过（用户决定：未授权删本地书 / 删空书架，并跳过深色模式与读屏项）。
- **临时诊断已清理**：排查用的 3 条 `hilog('ShelfDiag')`（+ import）已移除，重新构建安装后复验 D1–D4/D6 通过。

**已知限制**：本轮仅完成「编译 + release 混淆面」闭环，**未做真机验证**；§10 DoD 的 D1–D20 全部待设备接回后补测（重点 R10 返回键是否被 `Navigation` 吞、R12 长按是否补送 click/是否影响滚动、R6 500ms 手感、R3 角标刷新）。
