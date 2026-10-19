# HANDOFF-S11 — 换源收尾（T-SWITCH-1 已关闭）+ 书架「更新」开工前交接（T-SHELF-7）

日期：2026-10-13
范围：**上一轮**（`换源` T-SWITCH-1 真机验证 + 缓存策略复核）已全部收口，本文只承载**下一轮该做什么**。
基线：工作树未提交（改动清单见 §5；本轮 0 代码改动，只有文档）。

> §6 是一段可直接粘贴到新 Session 的 prompt。**若只想开新会话，读 §6 即可**；
> 本文其余部分是给"为什么这么做"留的取证与决策记录。

---

## 0. 接手时的确定状态（勿重复劳动）

| 事项 | 状态 | 证据 |
|---|---|---|
| **T-SWITCH-1（P1）换源候选被丢掉 + 每轮白等 13 源** | ✅ **已关闭，真机已验证** | [`bugfix/TASKS.md`](../bugfix/TASKS.md) §T-SWITCH-1、[`bugfix/RELEASE-NOTES.md`](../bugfix/RELEASE-NOTES.md) §18 |
| 真机结果 | 候选 **2 → 7 行**（12 源参与）、3s 上屏 6 行、预热命中切换 **≤1s**（原 7s）、重开抽屉「上次检索到的 7 个候选」秒上屏、`bbiquge8 ↔ 小说` 往返后书架 `104章/1308章` 未丢 | 同上 |
| **5 层缓存策略复核（用户提问触发）** | ✅ **结论：都不改**（A/C/D + B 的精化版「读到末尾自动重爬」全部决定不改；同时定下"若将来修只提示不跳转"） | §T-SHELF-6「后续评估（2026-10-13）」 |
| **T-SHELF-7（P2）书架「更新」：批量查新章** | ✅ **已完成（2026-10-13 落地 + 真机验收 12 项）** | §7.3（真机证据）、[`../bugfix/TASKS.md`](../bugfix/TASKS.md) §T-SHELF-7、[`../bugfix/RELEASE-NOTES.md`](../bugfix/RELEASE-NOTES.md) §19 |

**已知残留（用户已明确接受，勿擅自修）**：① 读到缓存目录最后一章后再点「下一章」/翻过最后一页**完全静默**（`pages/Reader.ets:368-375` + `471-474`）；② 同一天内第二次打开且间隔 < 6h 时看不到刚更新的章。落点与修法都写在 §T-SHELF-6「后续评估」里，哪天用户改主意可直接照做。

---

## 1. 下一轮任务：T-SHELF-7 书架「更新」（批量检查在架书籍是否有新章节）

> ✅ **2026-10-13 更新：T-SHELF-7 已完成（代码落地 + 真机验收 12 项全过）——施工结果与三处偏差见 **§7**，真机证据看 §7.3。**
> 本节下面的拍板条款仍然有效（实现时未偏离），勿改。

**产品决策（2026-10-13 用户已拍板，勿再问）**

1. 入口 = **书架顶栏标题右侧独立「更新」按钮**（不是 ⋮ 菜单、不是下拉刷新）。
2. 探测深度 = **只查详情 `bookInfo`，不爬目录**（目录留在打开书时由 6h 新鲜期逻辑处理）。
3. 触发 = **仅手动**，**不做**启动自动检查 / 定时任务。
4. 若将来做"读到末尾重爬"：发现新章**只 toast 提示，不自动跳转**。

**现状事实（为什么需要它）**：书架 `reload()` 只读 DB + 进度、**零网络 I/O**（`pages/Shelf.ets:44-79`），「最新：xxx」/「N章/M章」只在**打开那本书**时由 `Reader.refreshToc` 重写 `percent` 才自愈（T-SHELF-6）⇒ 不打开就永远不动。

**基线字段的坑（已查清，实现时直接用）**：`books.last_chapter_title` **只**在「加入书架」（`pages/BookDetail.ets:76`）与「换源」（`model/SourceSwitch.ets:222`）写入，Reader 的后台重爬**不写它**；且全仓**没有任何 UI 读这一列**。
⇒ 可以把它当「上次检查到的章节」基线，**不必新增列**。代价：**第一次更新会把"自加入书架以来更新过章节"的书全部报成有新章**（基线停在加入那天），把新值回写后即准 —— 实现时要么接受，要么首轮只提示不落标。

## 2. ⚠️ 开工前必须先解决的卡点：书架行里**没有 `bookUrl`**

`Book`（`engine/types.ets`）**没有 `bookUrl` 字段**（只有 `bookId` / `sourceUrl` / `tocUrl` / `lastChapterTitle` …），而 `bookEngine.bookInfo(source: BookSource, bookUrl: string)`（`engine/BookEngineNapi.ets:33`）需要 `bookUrl`。`bookId` 是 `computeBookId(sourceUrl, bookUrl)` 的哈希 ⇒ **不可逆**。

也不能拿 `book.tocUrl` 当 `bookUrl`：**13 个内置源里只有 6 个 `ruleBookInfo.tocUrl` 为空**（此时 tocUrl 才等于详情页 URL），另 7 个（玄幻阁 / 悠久小说 / 蚂蚁阅读 / bbiquge8 / 掌阅 / 连尚 / 笔趣阁8）显式指定了目录页 URL —— 那是另一个页面，`bookInfo` 的规则通常不适用。

**两个可行方案（推荐先做 ①）**

| | 方案 ①（零 schema 改动，推荐做最小版） | 方案 ②（加持久列，请求量减半） |
|---|---|---|
| 做法 | 复用换源那套：`bookEngine.search([source], book.name, {timeoutMs: SEARCH_TIMEOUT_MS, concurrency: 1})` → 用现成的 **`isSameBook(book, item)`（`model/SourceSwitch.ets`，书名+作者严格匹配）** 命中 → 拿 `item.bookUrl` → `bookInfo` | `books` 表新增 `book_url TEXT`：`initShelf` **没有版本/migration 机制**（只有 `CREATE TABLE IF NOT EXISTS`）⇒ 需幂等 `ALTER TABLE books ADD COLUMN book_url TEXT`（try/catch 或 `store.version`）；写入点 3 处（`BookDetail.addToShelf`、`SourceSwitch`、`LocalBook`）；**已有书架行仍需用方案 ① 回填一次** |
| 请求量 | **2 请求/书**（search + bookInfo），20 本 ≈ 40 次 | **1 请求/书**（回填后） |
| 风险 | 搜索规则抽取差的书可能匹配不到 → 计为「本次未检查」，不误报 | 动 DB + 3 个写入点 + 混淆/备份回归面变大 |

> 用户当初选的是"1 请求/书"，那是**在不知道 `bookUrl` 缺失**的前提下选的；实现时先按 ① 落地（不碰 DB），若实测请求量/耗时不能接受再升级 ②。**这个取舍值得在开工时跟用户确认一句。**

## 3. 施工清单（方案 ① 最小版）

1. `pages/Index.ets`
   - `shelfNormalHeader()`（约 `:188-202`）在 `Blank()` 与 `MoreMenuButton` 之间加「更新」按钮（编辑态 `shelfEditHeader()` 不显示）。
   - 改顶栏 ⇒ **必须先读 [`specs/UI-SPEC.md`](../specs/UI-SPEC.md)**：字号 / 颜色令牌（brand `#DA3838` 或 `text_1`）/ 点击热区 / `accessibilityText` + `accessibilityLevel('yes')`。
   - 运行中防重入 + 进度文案（如 `检查中 3/12`）+ 结束 toast（`this.getUIContext().getPromptAction().showToast({...})`，Index 里已有用例 `:102`、`:155`）。
2. 新增 `model/ShelfUpdater.ets`（编排，便于主机侧复用/单测）
   - 入参：书列表 + `onProgress`；跳过 `isLocalBook`（`model/LocalBook.ets`）。
   - 每本：`search(book.name)` → `isSameBook` 取 `item.bookUrl` → `bookInfo` → 比对 `info.lastChapterTitle` vs `book.lastChapterTitle` → 不同则记入「有新章」并 **`upsertBook({...book, lastChapterTitle: info.lastChapterTitle})` 前移基线**。
   - 并发 3–4（或串行）+ 单本 6s 超时（`Const.ets::SEARCH_TIMEOUT_MS`）+ 整体预算；**单本失败静默**（保持旧基线、不影响其余书、不误报）。
   - 返回 `{ checked, failed, updated: Book[] }` 之类，便于 UI 提示与测试。
3. 书源对象：需要按 `book.sourceUrl` 取 `BookSource`（看书源仓库现有 API，`model/SourceRepository.ets` / `BookSourceManage` 的数据源；`pages/Index.ets` 已持有 `BookSource` 类型引用）。
4. 可选：书架行角标（`pages/Shelf.ets` 的 `Stack` 里已有 `selectBadge` 的叠放位置可参考）——**建议留到下一轮**，首轮只做入口反馈。

## 4. 硬性约束（违反即返工）

- **禁** `@State` / `@Prop` ⇒ 新代码一律 `@ComponentV2` + `@Local` / `@Param`（D7）。
- 顶栏/抽屉改动必须过 `specs/UI-SPEC.md`；禁止裸 `bindSheet`、禁止 `if (flag) { BottomDrawer(...) }`。
- **跨 NAPI / 落盘的 JSON 字段名必须进 `entry/obfuscation-rules.txt`**（`Book` 本身不过 JSON，走 DB；**若方案 ② 加列，需确认是否引入新的 JSON 契约**）。`make check` 会核。
- 文档落位：新文档进 `docs/` 对应子目录（bug → `bugfix/`，方案 → `research/`，交接 → `handoff/`）；改完大文档跑 `make docs-toc`；结束跑 `make check`。
- 改完必走闭环：`make run`（编译 → 安装 → `aa force-stop` → 启动）→ 真机观察（skill `harmony-device-run`）。
- 上下文卫生：`read` 用 `offset/limit` 取段，先 `rg -n` 定位；大 `.ets` 先看顶部成员索引。

## 5. 工作树状态（本轮结束时的实际状态）

- **代码（上一轮 T-SWITCH-1，已在设备上验过，未提交）**：`M entry/src/main/ets/common/Format.ets`、`M components/SourceSwitchPanel.ets`、`M model/SourceSwitch.ets`、`M pages/SearchResult.ets`、`?? model/SourcePrefetch.ets`。**本轮 0 代码改动。**
- **文档**：`docs/PITFALLS.md`、`docs/bugfix/{TASKS,RELEASE-NOTES}.md`、`docs/progress.md`、`docs/specs/UI-SPEC.md`、（TOC 行号 churn）`docs/research/TTS-PREGEN-IMPL.md`。
- **⚠️ 无关改动（并行 TTS 任务，别碰别提交）**：`server/app.py`、`server/job_worker.py`、`server/pregen_test.py`、`server/tts-job.service`、`server/tts_cache.py`、`docs/research/TTS-PREGEN-IMPL.md`。
- 上次验证用设备：`33Z0224424136564`（开工前先 `hdc list targets` 确认在线）。

## 6. 可粘贴到新 Session 的 prompt

```text
继续 source-reader（HarmonyOS NEXT 原生阅读 App，ArkTS + ArkUI，书源引擎是本仓库 Rust 经 ohos-rs 编译的 .so）。
本轮任务：实现 T-SHELF-7 —— 书架「更新」：批量检查所有在架书籍是否有新章节。

先读这三处（不要通读大文件，用 rg -n 定位再取段）：
1. docs/handoff/HANDOFF-S11.md（本文：已定决策、卡点、施工清单、约束）
2. docs/bugfix/TASKS.md §T-SHELF-7（立项条目：方案骨架 / 已知坑 / 验证方式）
3. entry/src/main/ets/pages/Index.ets 的 shelfNormalHeader()（约 :188-202，入口要加在这里）

已拍板（勿再问，除非发现新事实）：入口 = 书架顶栏标题右侧独立「更新」按钮；只查 bookInfo、不爬目录；仅手动触发，不做启动/定时自动检查。

开工前必须先解决一个卡点（详见 HANDOFF-S11 §2）：书架 Book 没有 bookUrl，而 bookInfo 需要它。
推荐先做零 schema 方案：用 bookEngine.search([source], book.name, {timeoutMs: SEARCH_TIMEOUT_MS, concurrency: 1})
+ 现成的 isSameBook(book, item)（model/SourceSwitch.ets，书名+作者严格匹配）拿 item.bookUrl，再 bookInfo（2 请求/书）。
若你认为该改 DB（新增 book_url 列 + 幂等 ALTER + 3 个写入点）来把请求降到 1 请求/书，先问我一句再动手。

实现要点：
- 基线：books.last_chapter_title 只在「加入书架」和「换源」时写，Reader 重爬不写它，且没有任何 UI 读它 ⇒ 直接当「上次检查到的章节」基线，免改表；
  比对不同 = 有新章 → upsertBook 回写新值前移基线（注意：第一次检查会把"自加入书架以来更新过章节"的书全报成有新章，属已知代价）。
- 新增 model/ShelfUpdater.ets 放编排（遍历书架书、跳过本地书、单本 6s 超时、3–4 并发、单本失败静默、整体预算、返回 { checked, failed, updated }）。
- UI：防重入 + 进度（如「检查中 3/12」）+ 结束 toast「N 本有新章节」（Index.ets 已有 showToast 用例）；书架行角标这轮先不做。
- 改顶栏必须先读 docs/specs/UI-SPEC.md（字号 / 颜色令牌 / 无障碍），别自己发明样式。
- 新代码一律 @ComponentV2 + @Local/@Param（项目禁 @State/@Prop）；跨 NAPI/落盘的 JSON 字段名必须进 entry/obfuscation-rules.txt（make check 会核）。

验收（缺一不可）：
1. make check 全绿；make docs-toc（改了带 TOC 的文档时）。
2. make run 走完整闭环（编译 → 安装 → aa force-stop → 启动），真机验证（设备 ID 先 hdc list targets 确认，上次是 33Z0224424136564）：
   点「更新」→ uitest dumpLayout 看进度与结果文案 → hdc file recv 拉 shelf.db 核对 books.last_chapter_title 已前移 → 再点一次不重复报新章（幂等）。
3. 失败注入（停用某本书的书源 / 断网）：静默、不影响其余书、不误报。
4. 结束时更新文档：TASKS.md §T-SHELF-7 置 [x] 并补真机证据、progress.md、PITFALLS.md（若出现新失败模式）、RELEASE-NOTES.md 追加一节（下一节号 §19），跑 make check。

明确不要做：不要改缓存策略（5 层缓存的复核结论是「都不改」，见 TASKS.md §T-SHELF-6 后续评估）；不要做后台/自动更新；不要修「读到末尾点下一章静默」那条（用户已决定不改，除非我改口）。
工作树里有并行 TTS 任务的无关改动（server/*、docs/research/TTS-PREGEN-IMPL.md），不要动、不要提交。
```

---

## 7. 施工结果（2026-10-13，已落地并真机验收）

### 7.1 落地内容（按 §3 施工清单，方案 ①）

| 项 | 结果 |
|---|---|
| 入口 | `pages/Index.ets` 的 `shelfNormalHeader()` 在 `Blank()` 与 `MoreMenuButton` 之间插 `shelfUpdateAction()`（`@Builder` **0 参数直读 `@Local`**）；编辑态不显示；「更新」用 `brand` 令牌 / 44 热区 / `accessibilityText` |
| 编排 | 新 `model/ShelfUpdater.ets`：`checkShelfUpdates(books, sources, onProgress, budgetMs?)` → `ShelfUpdateOutcome { total, checked, failed, skipped, updated }`；另导出纯函数 `chapterKey` / `hasNewChapter` |
| 书源 | `pages/Index.ets` 用现成的 `loadSources(ctx)`，按 `bookSourceUrl` 建 Map；缺源 / 源停用 ⇒ 计 `failed`，**不发请求** |
| 角标 | 按 §3.4 **没做**（首轮只做入口反馈） |
| 超时/并发 | 单源搜索 6s、**单本 15s**、并发 3、整体预算 90s；单本失败静默 |
| 进度/toast | 进行中 `shelfProgressText(done,total,failed)`（无失败 `检查中 1/2`，有失败 `检查中 1/2 · 1 本未检查`）+ 防重入；结束 6 种 toast：`N 本有新章节` / `没有发现新章节` / `没有发现新章节，N 本未检查` / `检查失败，请检查网络或书源` / `书架里没有可检查的网络书籍` / `更新失败，请稍后重试` |

### 7.2 与本文草稿不同的三处（复核/实测后改的，勿改回）

1. **基线比较必须 `cleanChapter` 归一化**（草稿写的是直接比 `lastChapterTitle`）：同一章在详情页是 `第83章 今日无事`、在搜索结果/换源是 `最新：第83章 今日无事` —— 直接比会把**没更新**的书报成有新章。
   归一化后「相等但原串不同」时**静默对齐基线**（不回显有新章）⇒ 下次比较退化成正字符串相等，幂等成立。
2. **无基线（`last_chapter_title` 为空）时静默建基线、不报新章**（草稿二选一里的「首轮只提示不落标」同样不落标，但没有基线 ⇒ 每次点都重复误报，更糟）。
   保留的已知代价：加入书架后到第一次更新之间章节变过的书会被报成有新章，写一次后即准。
3. **单本超时 6s → 15s**（草稿 §3.2 写 6s）：1 次搜索加 1 次详情，6s 的整链上限会让「搜索正好用满 6s」的书连 `bookInfo` 都发不出去。
   2026-10-19 后 `bookInfo` 已接受 `timeoutMs`，`ShelfUpdater` 直接传 `ENGINE_INFO_TIMEOUT_MS = 15s`；Rust 对整个详情操作统一计时，ArkTS 不再用 `Promise` 竞速。其他取页接口同样接受整段操作预算，见 [`../PITFALLS.md`](../PITFALLS.md)。

### 7.3 验证（主机侧 + 真机全部完成）

- `python3 scripts/shelf-updater-sim.py`：从**真源码机械切片**（`Format.ets` 的 `stripLabel`/`cleanAuthor`/`cleanChapter` + `ShelfUpdater.ets` 去掉 `import` 的全文）+ 只打桩 3 个外部依赖 → `tsc` + `node`，**30 条断言 `ALL PASS`**
  （计数 / 本地书排除 / 基线前移 / 等价对齐不误报 / 幂等 / 并发上限 3 / 进度序列 / 预算耗尽 / 书源缺失 / **搜索 6s 与详情 15s 预算实际传入引擎**）。以后改 `ShelfUpdater.ets` 直接重跑即可。
- `make hap` 通过（`make doctor`：signed HAP 晚于全部 ets 源）；`make check` 全绿。
- **真机（2026-10-13 · 设备 `33Z0224424136564` · debug · `make run` 闭环，12 项全过）**：`检查中 0/2` → `1/2`；**`total = 2`**（本地书《大唐》排除）；toast `没有发现新章节，1 本未检查`（《天堂向左》源已失效 ⇒ 计 `failed`、基线保持空、不影响《剑来》）；**全程 `shelf.db` 逐列零写入**；连点两次只跑一轮；再点幂等；编辑态顶栏 `"text":"更新"` 计数 0；
  失败注入（停用 `bbiquge8` **及其同 URL 孪生** `笔趣阁8`）⇒ toast `检查失败，请检查网络或书源`，停用源即时失败、不崩不写库，验完两个开关已恢复启用并复跑一致。
- **「有新章」分支真机已走通（2026-10-13 晚）**：两条常规注入路径仍不可用（沙箱 DB 对 shell 只读；App 内写基线的两处写的正是要比对的同一个源详情页值）⇒ 改用**一次性调试版**（只在 `ShelfUpdater.probeBook` 临时插 6 行，仅对《剑来》把落库值写成 `latest + ' [T-MARK]'`，比较逻辑不动）：先证真机 `upsertBook` 写库（DB 见 `[T-MARK]`），`git checkout` 还原后复跑得 toast `1 本有新章节` + 基线前移，再点一次幂等（整库逻辑 diff 为空），收尾无残留、书源 13/13。详见 [`../bugfix/TASKS.md`](../bugfix/TASKS.md) §T-SHELF-7「验证」④。
- 顺带产出五条可复用技法（已进 [`../PITFALLS.md`](../PITFALLS.md) 与 skill `harmony-device-run` §4）：**toast 读法 = `uitest screenCap` 连拍 + 主机 `tesseract -l chi_sim`**（`dumpLayout` 不导出 toast 窗口；且 `tesseract` 必须 `cd` 到图片目录用相对名）、**同 URL 孪生源让「停用书源」失效**、**拉 DB 必须 `shelf.db`+`-wal`+`-shm` 三件套**（只 recv 主库会漏 WAL，差点误判「没写库」）、**`dumpLayout` 卡死会连累其后所有 dump**（设备侧残留进程 `kill -9` 即恢复）。
- **收尾小迭代（2026-10-13，主机侧 30 断言 + 真机两形态均已验）**：进行中进度行改为 `shelfProgressText(done,total,failed)`（无失败 `检查中 1/2`，有失败 `检查中 1/2 · 1 本未检查`；进度回调加第三个参数 = **累计** `failed`，不含 `skipped`）。
  仿真 **25 → 30 断言 `ALL PASS`** + `make hap` 通过；**真机已验**：两种形态都拍到（`检查中 1/2` dump 实测 `[658,190][869,241]`），顶栏不截断（外推最长形态余量 ~80vp，但该最长形态未真机出现）；残留只剩最长形态的真实渲染（架上网络书只有 2 本）。

### 7.4 工作树新增（本轮）

`?? entry/src/main/ets/model/ShelfUpdater.ets`、`?? scripts/shelf-updater-sim.py`、`M entry/src/main/ets/pages/Index.ets`（+98 行）；
文档：`docs/bugfix/{TASKS,RELEASE-NOTES}.md`、`docs/progress.md`、`docs/PITFALLS.md`、本文。
并行 TTS 任务的 `server/*` 与 `docs/research/TTS-PREGEN-IMPL.md` 仍未动。

### 7.5 真机验收（2026-10-13 已完成）

现场执行记录：`make run` EXIT=0 → 点顶栏「更新」→ `uitest screenCap` 连拍 + 主机 `tesseract -l chi_sim` OCR 读 toast、`dumpLayout` 读进度与顶栏 → `hdc file recv` 拉 `shelf.db`+`-wal`+`-shm` 三件套比对
→ 停用 `bbiquge8` + 其同 URL 孪生 `笔趣阁8` 造全失败分支（`检查失败，请检查网络或书源`）→ 恢复开关复跑一致。**12 项全过**，细节与「有新章」分支的调试版走通见 §7.3 与 [`../bugfix/TASKS.md`](../bugfix/TASKS.md) §T-SHELF-7「验证」③④。
原「下一轮可粘贴的验收提示词」**仍作废**（该分支在真机上不可用常规手段造 —— 沙箱 DB 只读 + App 内无造旧基线的路径）；需要时改用 §7.3 / TASKS ④ 的**一次性调试版配方**（跑完必须 `git checkout` 还原）。
