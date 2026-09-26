# HANDOFF-S6 — 搜索模块原地化 + 抽屉化（A–F）

日期：2026-09-26
范围：**仅搜索模块**（`pages/Search.ets` / `pages/SearchResult.ets`，含 `pages/Index.ets` 路由接线、`common/Const.ets` 清理）。
基线：`ad136e7`（S5 收尾）。HEAD：`f5d66a4`（本轮提交，见 §2）。
约束履行：
- E/F 均使用 `HANDOFF-S3.md` 的 `ui/common/BottomDrawer.ets`（`mode:'system'`，未自绘 sheet）。
- D 的自定义动画复用 `UI-SPEC.md` §1.3「overlay 抽屉打开」参数：`260ms / Curve.FastOutSlowIn`。
- **搜索/合并/排序逻辑零改动**：`rebuildGroups` / `bucketOf` / `weightOf` / `cleanAuthor` / `cleanChapter` /
  `enrichMerged` / `enrichOne` / `primaryOrigin` 全部原样保留。

> 构建：`assembleHap` **BUILD SUCCESSFUL**（仅既有 ArkTS 警告：`audio` syscap、函数可能抛异常、剪贴板权限）。
> **真机验证已完成**：设备 `33Z0224424136564`，A–F 全项通过（见 §5），无崩溃。

---

## 0. 调查来源

- 现有实现：`Search.ets`（居中输入框 + 「管理书源」入口，`onSearch` push 新页面）、
  `SearchResult.ets`（独立路由页，自带返回键 + 输入框 + 结果 + 内联「源状态」+ `bindSheet` 选源）。
- 参考组件：`ui/common/BottomDrawer.ets`（`@Param visible/title/sheetSize/mode` + `@Event onClose` +
  尾随 `@BuilderParam content`），接入写法沿用 S5 的 `BottomDrawer({...}) { this.xxxContent() }`。
- 动画参数来源：`UI-SPEC.md` §1.3。

---

## 1. 变更清单（按项）

### A. 原地搜索：不再跳新页面，当前页直接展示结果

- `Search.ets` 由「纯输入页」改为「**搜索 Tab 全页**」：顶部输入栏 + 下方结果区；
  `SearchResultPage` 作为**内嵌子组件**渲染在同一页（`Column().layoutWeight(1)` 包裹）。
- `Search.ets` 新增 `@Local submittedKeyword`（首次提交后非空）与 `@Local searchToken`（每次提交自增）：
  - 未提交：显示 `idleHint()`（放大镜 + "输入书名或作者开始搜索"）。
  - 已提交：渲染 `SearchResultPage({ keyword, searchToken, onOpenDetail })`。
- `SearchResult.ets`：
  - 删除独立页的 `topBar()`（返回键 + 输入框）与 `@Event onBack`；
  - 新增 `@Param searchToken` + `@Monitor('searchToken')`：同关键词再次提交也能重搜；
  - 根布局由 `Column` 改 `Stack`（承载两个抽屉），内容列 `height('100%')`。
- `Index.ets`：删除 `openSearchResult()` 与 `ROUTE_SEARCH_RESULT` 路由分支，`SearchPage` 改为直接接收
  `onOpenDetail`；`Const.ets` 删除已无用的 `ROUTE_SEARCH_RESULT` / `SearchParam`。

### B. 输入框移到页面最上方

- `Search.ets` 用 `this.searchBar()`（圆角胶囊：放大镜 + `TextInput` + 清空「✕」）置于 `Column` 第一个子节点，
  顶部 padding 8；页面不再 `justifyContent(FlexAlign.Center)`。
- 搜索栏常驻（结果页也能改词重搜），`enterKeyType(Search)` / `onSubmit` 行为不变。

### C. 暂时隐藏「管理书源」入口

- 删除 `Search.ets` 中「管理书源」`Text` 与 `@Event onOpenSource`，`Index.ets` 不再传入该回调。
  > `openSourceManage()` 仍保留（「设置 → 书源管理」在用）。

### D. 搜索中动画 / 标识

- 新增 `@Local enriching: boolean`，标记「各源已返回完毕、正在 `enrichMerged` 补简介/封面」阶段；
  `enrichMerged` 有目标时置 `true`、结束置 `false`，`startSearch()` 复位。
- 新增派生 `isSearching()` = `pending > 0 || enriching`（**进度期间覆盖「聚合后刷新排序」二次刷新**）。
- 新增 `@Builder searchBanner()`：结果列表上方常驻一条弱提示行——
  - 搜索中：`LoadingProgress`（14×14，brand 色）+「正在搜索…结果仍在更新，排序可能变化」；
  - 完成：「共 N 条结果」。
  - 整行 `.opacity(isSearching()?1:0.7)` + `.animation({ duration: 260, curve: Curve.FastOutSlowIn })`
    （复用 UI-SPEC §1.3 参数）。
- 空结果居中态同步改为 `pending > 0 || enriching` 时显示 `LoadingProgress + 正在聚合书源…`。

### E. 书源状态抽屉 → `BottomDrawer`

- 删除原「收起 / 源状态」内联展开（`showSources` + 140vp `Scroll`）。
- 状态汇总行（`源 x/y 成功` + 「源状态」）保留在结果区底部作**触发入口**，点击置 `statusVisible = true`。
- 抽屉：`BottomDrawer({ visible:true, title:'源状态', sheetSize:'fit', mode:'system', onClose })`
  内为 `statusContent()`（沿用原状态行，去掉横向 padding 交给抽屉内容区）。

### F. 选择来源弹层 → `BottomDrawer`

- 删除原页面级 `bindSheet($$this.pickerVisible, this.pickerSheet(), { height: MEDIUM, dragBar:true, showClose:true })`
  与自带标题。
- 改为 `BottomDrawer({ visible:true, title:'选择来源', sheetSize:'medium', mode:'system', onClose })`
  内为 `pickerContent()`（原 `List` + 来源行，去掉横向 padding）。
- 为规避 S4 §6.3 的 V2 `@BuilderParam` 不随普通状态重跑，两个 system 抽屉均**按 `visible` 条件挂载**
  （`if (this.statusVisible) { BottomDrawer(...) { ... } }`），保证每次打开都按当前 `statuses` / `pickerGroup`
  重新求值。

---

## 2. 每项 commit 对照

> 本轮提交：`f5d66a4`（单 commit，含 4 个代码文件 + 本文件）。`git show --stat`：

| 项 | 文件 | 说明 |
|---|---|---|
| A / B / C | `pages/Search.ets` | 重写为搜索 Tab 全页（顶部输入 + 内嵌结果） |
| A / D / E / F | `pages/SearchResult.ets` | 去独立页外壳；searchToken；搜索中标识；状态/选源改 `BottomDrawer` |
| A | `pages/Index.ets` | 去掉 SearchResult 路由；`SearchPage` 接收 `onOpenDetail` |
| A | `common/Const.ets` | 删除 `ROUTE_SEARCH_RESULT` / `SearchParam` |

```
entry/src/main/ets/common/Const.ets       |   9 -
entry/src/main/ets/pages/Index.ets        |  20 +-
entry/src/main/ets/pages/Search.ets       | 113 +++++---
entry/src/main/ets/pages/SearchResult.ets | 365 ++++++++++++++++------------
```

> 说明：`AGENTS.md` / `docs/progress.md` 的改动来自并行 TTS 调研工作流，与本轮无关，未纳入。

---

## 3. 关键文件

- `entry/src/main/ets/pages/Search.ets`（A/B/C）
- `entry/src/main/ets/pages/SearchResult.ets`（A/D/E/F）
- `entry/src/main/ets/pages/Index.ets`、`entry/src/main/ets/common/Const.ets`（A）
- `entry/src/main/ets/ui/common/BottomDrawer.ets`（E/F，S3 原版，未改动）

---

## 4. 构建命令 / 结果

```bash
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:$PATH"
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
# → BUILD SUCCESSFUL in 13 s 353 ms（33 tasks；仅既有 ArkTS 警告）
```

---

## 5. 真机验证结果

设备 `33Z0224424136564`；HAP 安装后 `aa force-stop` + `aa start`，搜索关键词「重生」（内置 13 源默认启用）。

| 项 | 结果 | 依据（`uitest dumpLayout` / 点击坐标，物理像素 1260×2844） |
|---|---|---|
| A 原地搜索 | ✅ | 提交后仍停留「搜索」Tab（顶栏「书架/搜索/设置」在），结果列表与输入栏同页；进详情点「‹」返回后仍保留结果与输入「重生」 |
| B 输入框置顶 | ✅ | `TextInput` bounds `[162,331][1179,480]`，紧贴顶栏（底 y≈251）之下；空态「输入书名或作者开始搜索」居中 |
| C 隐藏管理书源 | ✅ | dump 无「管理书源」节点；空态仅放大镜 + 提示 |
| D 搜索中标识 | ✅ | 提交后立即 dump 得 `正在搜索…结果仍在更新，排序可能变化`（`[128,534]`）+ 已渲染的「3个来源」结果行；约 8s 后该行变为 `共 170 条结果` |
| E 源状态抽屉 | ✅ | 点「源状态」→ 出现标题 `源状态` 的底部抽屉，列出 13 源状态（`network_error` / `✓ 50` / `no_results` 等） |
| F 选择来源抽屉 | ✅ | 点「4个来源」结果行 → 出现标题 `选择来源` 的底部抽屉，列 `小说 / bbiquge8 / 笔趣阁8 / 悠久小说`；点「小说」进入详情页，详情显示 `来源：小说` |
| 稳定性 | ✅ | 进程 PID `43801` 全程存活；`hilog` 无 `undefined is not callable` / `JSCRASH` / `CPPCRASH` |

> 结论：system 模式 `BottomDrawer`（`fit`/`medium`）与「条件挂载」方案在本机正常起落、内容正确，S3 §5.5 的 system 模式待验项关闭。
> 验证后未改动设备数据；如需可继续清理测试输入。

---

## 6. 遗留问题 / 已知风险

1. **system 模式 `BottomDrawer` 已真机通过**（源状态/选源均正常起落）；唯一未单独观察的是**关闭收场动画**：
   E/F 为「按 `visible` 条件挂载」，关闭时节点立即卸载，`bindSheet` 的退场动画可能被截断（真机观感未逐帧确认）。
   若要求退场动画完整，需改回常驻 + `visible` 切换，并另寻 V2 内容刷新方案。
2. **V2 `@BuilderParam` 陈旧内容风险**：E/F 用「条件挂载 + 每次新建组件」规避，真机已验证内容随当前 `statuses`/`pickerGroup`
   正确渲染；代价是关闭无退出动画（见上条）。
3. **搜索 Tab 无返回语义**：移除独立路由后，结果与输入栏同页，系统返回键不再有「返回搜索页」的层级；
   当前未定义「返回清空结果」行为（A 项本身要求原地展示）。若需，可后续在 Tab 返回态时清空 `submittedKeyword`。
4. **`enriching` 覆盖度**：仅合并行（`origins.length>1` 且缺简介/封面）才触发 enrich，故单源结果下
   `pending` 归零即结束；`enrichMerged` 在 `gen` 变化时提前 return 且不复位（由 `startSearch()` 复位），属有意。
5. **`searchToken` 依赖 V2 `@Monitor`**：已编译通过；`@Param` 更新与 `@Monitor` 触发同帧，使用最新 `keyword`。
6. **改动了 `Const.ets` 导出**：`ROUTE_SEARCH_RESULT` / `SearchParam` 已删；`plan.md` §「搜索 Tab」与
   `docs/architecture.md` 仍写 `SearchResultPage` 为独立页，属文档滞后（未改文档，遵「只处理搜索模块」）。
7. **`SearchResult.ets` 文件名/结构名沿用**：组件仍叫 `SearchResultPage`，但已非 `NavDestination` 路由页。
8. **其余文档未提交**：`HANDOFF-S3/4/5.md`、`AUDIT.md`、`ROOT-CAUSE.md`、`TASKS.md`、`UI-SPEC.md` 仍 untracked
   （本文件已随 `f5d66a4` 提交）。