# SPEC — `source-list`

状态：**待批准（draft）** · 归属：[`SPEC-BOOKSOURCE-REVAMP.md`](./SPEC-BOOKSOURCE-REVAMP.md) 模块 `source-list`
Commands / Project Structure / Code Style / Testing Strategy / Boundaries 见 map 文件 §4–§8，本文只写本模块特有内容。

> **布局已定（2026-10-14）**：布局 2 两段式的「书源」段，完整设计见
> [`SPEC-BOOKSOURCE-LAYOUT.md`](./SPEC-BOOKSOURCE-LAYOUT.md) §3.2。本文写数据源、筛选语义与
> 危险操作等与布局无关的部分。

## Objective

3000 行列表可滚动、可搜索、可按状态筛选、可按 `bookSourceGroup` 分组；行上的破坏性操作不再裸奔。

用户可见的成功：滚动不卡；输入关键词即时收敛到目标源；不会误删。

## Non-goals

- 不做书源的新增/编辑表单（导入是唯一新增路径；编辑规则字段是 v1 范围外）。
- 不做拖拽排序（`customOrder` 字段只读取展示，排序能力见开放问题 3）。
- 不在本模块做检测（那是 `detect-job` / `detect-ui`）；本模块只**展示** `SourceRow.detectState`。

## 关键设计决策

**1. `LazyForEach` + `IDataSource`。** 仓库已有两份同模式实现可照抄：`common/SourceListDataSource.ets`
（选择来源列表）与 `common/ChapterDataSource.ets`。现状 `pages/BookSourceManage.ets:577` 用的是
`ForEach`——3000 项会一次性建组件，这是必须换掉的那处。

**2. 只持投影。** 数据源持 `SourceRow[]`（`source-store` 的投影接口），不持完整 `BookSource`。
行渲染需要的字段（名称 / URL / 分组 / 启用 / 置信度 / 检测态）全在投影里，行内不做 JSON 解析。

**3. 过滤在内存，不在 build。** 启动拉一次全量投影（3000 条约 0.5 MB），搜索与筛选在这份内存数组上做完再
交给 `LazyForEach`。**禁止**把 `filter` / `sort` / `enabledSources` 写在 `build` 里——现状
`pages/BookSourceManage.ets:612` 的 `enabledSources(this.sources).length` 就是每帧跑 3000 项。

- 搜索输入防抖 150 ms；匹配 `name` / `url` / `group`，大小写不敏感。
- 筛选维度：全部 / 启用 / 停用 / 未测 / 失败（`unavailable`），以及结果面的
  可用 / 无结果 / 超时 / 不可用（后四项来自投影的 `detectState`，与 `detect-ui` 的结果面
  共用同一套语义，不要再定义第二套）。chips 的具体形态见布局文件 §3.2。

**4. 分组（只做筛选，不分段展示）。** 由筛选条末端的「分组 ▾」选一个组看（默认不分组）；
无分组归入「默认」。3000 条下 flat list + 三档排序已够用，而分组分段展示会与「异常置顶」排序
直接冲突（同一列里既要按组分块又要按异常排序）。带组内计数的分段展示列为后续可选。

**5. 危险操作。** 现状 `removeSource`（`:266`）与 `resetBundled`（`:281`）都是**立即落盘、无确认**，
且 `resetBundled` 会整体覆盖用户导入的书源。本模块统一：

- 删除：二次确认（`AlertDialog`），文案含源名。
- 恢复内置：二次确认，且文案必须点明「会替换当前全部书源」。或者改为「合并内置」——需用户裁决，
  见开放问题 4。
- 批量「启用全部 / 停用全部」：二次确认（3000 条的批量改动走 `source-store` 事务）。
- 行内**不再放裸文本「删除」**；入口统一为**行尾「⋯」菜单**（详情 / 停用或启用 / 删除），
  删除走 `AlertDialog` 二次确认，文案含源名。点行 = 打开详情抽屉（与菜单里的「详情」同一目标）。

**6. 空态。** 0 条书源时给出明确空态（现状只剩一句「书源（0/0 启用）」标题，`:652` 的 `ForEach` 无 else）。
空态要带「恢复内置」入口。

## Success Criteria

1. 3000 行滚动无可感知掉帧（与 13 行时的手感无差别）。
2. 默认视图为「启用」且检测异常态置顶；搜索框与筛选条在首屏可见，进页不需要先滚动。
3. 搜索输入到列表更新 ≤ 100 ms（含防抖则 ≤ 250 ms）。
4. 切换筛选/分组 ≤ 100 ms，且不触发全量重建。
5. 删除与恢复内置 100% 走确认弹窗；取消后数据与落盘均不变。
6. 同 URL 不同名的两条在列表各自成行、可独立操作（`ForEach` 同 key 去重的老问题不再有——
   现在是稳定 `id`，天然解决）。
7. 空态：搜索/筛选无结果时有文案；0 条书源时空态带「恢复内置」出口。

## Boundaries

- **Never**：在 `build` 里做随列表长度增长的 filter/sort/map；直接读 preferences 取书源（一律走
  `source-store`）；在行内放无确认的破坏性操作。

## Open Questions

1. ~~页面信息架构~~ **已定**：布局 2「书源」段，见 [`SPEC-BOOKSOURCE-LAYOUT.md`](./SPEC-BOOKSOURCE-LAYOUT.md) §3.2。
2. ~~分组头是否 sticky~~ **已定（2026-10-14）**：分组只做筛选，不做分段展示，故无分组头。
3. 排序能力：默认按导入顺序 / `customOrder` / 置信度 / 最近检测时间？要不要让用户切？
   （布局文件 §3.2 已定「异常优先 + 导入顺序」为默认，此处指用户可切换的部分。）
4. 「恢复内置」语义是**替换**还是**合并**？现状是替换（`resetToBundled`），对一个装了几千源的
   用户来说这是最危险的一个按钮。
5. 是否需要多选模式（供 `detect-job` 的「仅选中项」复用）。与 map 文件开放问题 2 相关。
6. 筛选条 chips 在计数为 0 时是否隐藏（布局文件 §6 开放问题 4）。
