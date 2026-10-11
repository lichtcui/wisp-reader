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
2. 按 `docs/development.md` §签名：将 `build-profile.json5` 的本地签名差异 `git update-index --skip-worktree`，仓库保存 `signingConfigs: []` 干净版；**勿提交**含路径/口令的版本。
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
