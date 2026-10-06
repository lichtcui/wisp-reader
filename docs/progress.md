# 进度 / 下一步

> 权威设计见 [`plan.md`](./plan.md)（含 27 项修订与全部决策）。本文件只记**进度与待办**。

## 里程碑状态

| 阶段 | 内容 | 状态 |
|---|---|---|
| **M0** | 引擎 PoC：交叉编译 + 解析 + 网络 + 体积 + 冷启动 | ✅ 已完成（真机验证） |
| M1 | 项目骨架 + Design Token（红白）+ 路由 + 三 Tab | ✅ 已完成（真机验证，浅色切换待复验） |
| M2 | 引擎接口（search/bookInfo/toc/content）+ JS/登录门禁 + 书源导入 | ✅ 已完成（真机验证：detect 8/13 可用） |
| M3 | 搜索聚合 + 详情 + 加入书架 + 持久化 | ✅ 已完成（真机验证：加入书架重启仍在） |
| M4 | 阅读页（横向分页翻页）+ 目录（含分页）+ 进度 + 阅读设置 | ✅ 已完成（真机验证：目录/跳转/字号/进度重启恢复；修 bindSheet + 正文清洗；**收尾项已补**）|
| M5 | 听书 + 系统 TTS + 后台播放 + AVSession | ✅ 已完成（真机验证：PCM→AudioRenderer→AVSession 成为 top session，锁屏控件/媒体键可控，切后台不断，定时关闭，段落高亮/进度同步）|
| M6 | 规则调试器 + 缓存清理 + 备份恢复 | ⏳ 未开始 |
| v2 | QuickJS/Boa JS 引擎、换源、在线 TTS、真分页 | ⏳ |

## M0 结果（2026-09-24）

设备 `33Z0224424136564`（HarmonyOS NEXT，API 24）：

| 验证项 | 结果 |
|---|---|
| ohos-rs + `aarch64-unknown-linux-ohos` 交叉编译 | ✅ |
| `reqwest` + `rustls` + `ring` + `scraper/html5ever` | ✅ |
| `parse`（scraper 规则引擎） | ✅ `["斗破苍穹","武动乾坤"]`，1ms |
| HTTPS（rustls）真机请求 | ✅ 811ms |
| 明文 HTTP 真机请求 | ✅ 未被拦截 |
| `.so` / HAP 体积 | 5.3MB / 5.2MB |
| 冷启动（AppStartMetrics e2e） | ≈ 304ms |

**结论：引擎路线 GO，不降级。**

## 已完成的可复用资产

- HarmonyOS 工程骨架（可编译、可签名、可安装、可启动）。
- `rust/legado-core`：`parse` / `fetchText` 两个 NAPI，已含从 legado-source-filter 移植的规则引擎。
- 项目级 cargo 镜像 `.cargo/config.toml`（rsproxy）。
- 真机调试闭环（hilog tag `SourceReaderPoC`）。

## M1 结果（2026-09-24）

设备 `33Z0224424136564`（HarmonyOS NEXT，API 24）：

| 验证项 | 结果 |
|---|---|
| 目录结构落地（pages / components / engine / common） | ✅ |
| Design Token（`base` + `dark` color.json，全量红白令牌） | ✅ 代码内无写死 hex |
| `Navigation` + `NavPathStack` 路由（占位 NavDestination + TitleBar） | ✅ push/back 正常 |
| 三 Tab（书架 / 搜索 / 设置）真机切换 | ✅ |
| 设置页 iOS 分组列表（版本动态读取 0.1.0） | ✅ |
| 深色令牌生效（设备为系统深色，`bg_page` → `#121212`） | ✅ |
| 主题切换（跟随系统 / 浅色 / 深色）+ `preferences` 持久化 | ⚠️ 切换触发正常、重启不崩；设备中途断连，浅色视觉未复验 |
| 冷启动 e2e | ≈ 210ms |
| 编译（`hvigorw assembleHap`） | ✅ 0 error 0 warn |

- 新增：`common/{Const,Format,Prefs,Theme}`、`engine/{types,IBookEngine}`、`components/{EmptyView,ListCells}`、`pages/{Index,Shelf,Search,Settings}`。
- `Index.ets` 已由 M0 PoC 自检页改为 App 主入口（PoC 结果留在 §M0）；`.so` 仍在包内，待 M2 接入。

## M2 结果（2026-09-24）

设备 `33Z0224424136564`（HarmonyOS NEXT，API 24）：

| 验证项 | 结果 |
|---|---|
| 引擎拆 crate：`legado-engine`（纯 Rust 核心）+ `legado-core`（薄 NAPI 层） | ✅ |
| 主机单测（含 mock 服务器 search→bookInfo→toc→content→detect） | ✅ 50 passed |
| 新 NAPI：`search/bookInfo/toc/content/detect/gateSources/fetchText/parseWithDiagnostics/downloadCover` | ✅ |
| v1 门禁（非文字 / 禁用 / URL 修复 / 登录 / JS：`<js>`、非 L1 `@js:`、关键字段 JS） | ✅ gate 单测 8 项 |
| `bundled-sources.json` 生成（filtered.json 17 → 保留 13，排除 4 需登录） | ✅ 26 KB |
| `pages/BookSourceManage` 真实实现（列表 / 启用开关 / 删除 / 文件·剪贴板·URL 导入 / 恢复内置 / 检测） | ✅ 真机渲染，加载内置 13 源 |
| 真机 `detect` 全链路（搜索→详情→目录→正文） | ✅ **8 / 13 可用**（含 1901 / 2540 / 1198 字正文） |
| 编译（`hvigorw assembleHap` debug） | ✅ 0 error |

- 新增：`rust/legado-engine`（`types/status/url_fixer/search_url/http_client/rule_dsl/gate/runtime`）、
  `rust/legado-core`（NAPI）、`engine/BookEngineNapi.ets`、`model/SourceRepository.ets`、
  `pages/BookSourceManage.ets`、`resources/rawfile/bundled-sources.json`。
- 生成内置源：`cd rust/legado-engine && cargo run --example bundled_gen -- <filtered.json> <out>`。
- 安全：移除 `danger_accept_invalid_certs`；每源独立 `Client`（Cookie 隔离）+ 限速；未执行 JS 运行时。

## M3 结果（2026-09-24）

设备 `33Z0224424136564`（HarmonyOS NEXT，API 24）：

| 验证项 | 结果 |
|---|---|
| 搜索聚合（ArkTS 逐源并发，渐进 append） | ✅ 真机「搜索中 11/13」渐进出结果 |
| 全局超时（每源 10s，超时源标 `timeout`） | ✅ |
| 搜索结果页（封面 / 书名红 / 作者·分类·字数 / 2 行简介 / 来源标签 / 已在书架） | ✅ |
| 详情页（`bookInfo`，来源只读，简介折叠，加入书架 / 立即阅读） | ✅ 真机取回书名/来源 |
| 加入书架 → `relationalStore` 持久化 | ✅ 重启后书架仍显示 1 本（未读过） |
| `bookId = hash(normalize(sourceUrl+bookUrl))` | ✅ `common/Format.computeBookId` |
| 搜索→书架去重（按书名+作者） | ✅ `ShelfRepository.isInShelf`，命中显「已在书架」 |
| 封面 `downloadCover` → PixelMap + 红渐变兜底 | ✅ 组件就绪（部分源无封面走兜底） |
| 编译（`hvigorw assembleHap` debug） | ✅ 0 error |

- 新增：`model/ShelfRepository.ets`（books + progress 表）、`components/BookCover.ets`、
  `pages/SearchResult.ets`、`pages/BookDetail.ets`；`pages/Shelf.ets` 接真实书架；
  `common/Format.computeBookId`。

## M4 结果（2026-09-24，真机验证）

设备 `33Z0224424136564`（HarmonyOS NEXT，API 24）：

| 验证项 | 结果 |
|---|---|
| 书架点书 → 详情 → 立即阅读 → 正文 | ✅ |
| 三点击区（左上一章 / 中呼出菜单 / 右下一章，`ClickEvent.x`） | ✅ 左中右均生效，不干扰滚动 |
| 顶栏（返回/章节名/更多）+ 底栏（进度/上一章/目录/设置/下一章） | ✅ |
| 目录 `bindSheet` + 章节目录 `LazyForEach` + 点击跳转 | ✅ 跳转到「第四章」正确 |
| 阅读设置 `bindSheet`（字号 A-/A+、行距 −/+） | ✅ 字号 18→20 即时生效 |
| 字号 / 行距 `preferences` 持久化（重装 `-r` 后仍为 20 / 1.8） | ✅ |
| 进度 `relationalStore`：第二章 → 下一章到第五章 → 重启回到第五章 | ✅ |
| 正文清洗：HTML 实体解码 + 去 `<script>/<style>` | ✅ 消除 `&nbsp;` 字面量与内联广告 JS |
| 主机单测 `cargo test` | ✅ 52 passed（+2 清洗用例） |
| 编译（`hvigorw assembleHap` debug） | ✅ 0 error |

**本次修复的 Bug**：
1. **两个 `bindSheet` 链在同一节点会错乱**（点「设置」弹出「目录」、点「目录」弹「设置」，且首次点击不弹）。
   改为**单个 `bindSheet($$this.sheetVisible, this.sheetContent())`**，用 `sheetMode` 分支渲染目录/设置。
2. **`clean_text` 未解码 HTML 实体、未剔除 `<script>/<style>`**，导致 `@html` 类正文规则把 `&nbsp;`
   字面量与内联广告 JS 当正文显示。已用 `scraper` 解码实体 + `strip_script_style` 剔除脚本样式（Legado 兼容），
   顺带移除手写 `<...>` 剥离器。Rust 改动：`rust/legado-engine/src/runtime.rs`（`.so` 已重编）。

**M4 收尾已完成（2026-09-24，真机验证）**：

| 验证项 | 结果 |
|---|---|
| 目录正/倒序切换 | ✅ `toggleTocOrder`，切换后自动重新定位当前章，sheet 不关闭 |
| 目录「定位」到当前章 | ✅ 列表滚动后点「定位」回到当前章行首 |
| 卷 `isVolume` 展示 | ⚙️ 代码就绪（引擎 `isVolume` 入 JSON、目录行加粗灰显；内置源暂无可测卷的书，未实测） |
| 进度细化到 `paragraphIndex` | ✅ 退出重进正文回到原段落（`scrollToIndex`） |
| 进度三态显示 | ✅ 书架显示「未读过 / N章/总数章 / 已读到最新章」 |
| 章节正文文件缓存 | ✅ `files/chapters/{bookId}_{index}.json`（含 url 校验失效） |
| 预取下一章 | ✅ 读第 N 章时后台缓存 N+1（真机 `files/chapters` 可见相邻章文件） |
| 顶栏「更多」→ 详情页 | ✅ 跳转 `ROUTE_BOOK_DETAIL` |
| 返回书架自动刷新进度 | ✅ 阅读页返回时 `shelfRefresh++`，`@Monitor` 触发书架 reload |

**本次修复的 Bug（M4 收尾）**：
3. **`bindSheet` 默认右上角关闭按钮**（`Button` 覆盖「定位/正序」区域）导致点表头控件被当作关闭 sheet。
   加 `showClose: false` 修复（`Reader.ets` bindSheet options）。
4. 书架从阅读页返回后进度不刷新 → 阅读页 `onBack` 内 `shelfRefresh++`（`Index.ets`）。

**仍未做（M5 前 / 可延后）**：
- 目录分页 `nextTocUrl` 多页复验（引擎已实现，真机当页路径已覆盖）。
- 源级正文面包屑：`class.span12@html` 会带出「当前位置：/作者/书名/章节名」导航行（源规则固有，Legado 亦同，非引擎 bug）。

## M4 已写代码（已完成真机验证，见上）

- `pages/Reader.ets`：竖向滚动正文；三点击区（左上一章 / 中呼出菜单 / 右下一章，用 `ClickEvent.x` + `onAreaChange` 宽度判定）；
  顶栏（返回/章节名/更多→详情）、底栏（进度/上一章/目录/设置/下一章）；单个 `bindSheet`（`showClose: false`）目录 + 阅读设置；
  目录正/倒序切换 + 定位 + 卷展示；字号/行距 `preferences` 持久化；进入章节即写 `progress`（chapterIndex/title/paragraphIndex/percent）并预取下一章。
- `common/ChapterDataSource.ets`：`IDataSource` + `LazyForEach`（`cachedCount(20)`）。
- `model/ChapterCache.ets`：正文文件缓存（内存 + `filesDir/chapters`，url 校验失效）。
- `pages/Shelf.ets`：真实书架（`relationalStore`）+ `BookCover` + 进度三态；`refreshToken` 随 Tab 切换/阅读页返回刷新。
- `pages/SearchResult.ets`：逐源并发渐进聚合 + 每源状态 + 已在书架标记。
- `pages/BookDetail.ets`：`bookInfo` + 简介折叠 + 加入书架 + 立即阅读。
- `model/ShelfRepository.ets`：`books` / `progress` 两张表。
- `pages/Index.ets`：路由 `SearchResult / BookDetail / Reader` 与 `openReader`；阅读页返回刷新书架。

## 书架页整改（2026-09-24，真机验证）

按 `plan.md` §12 附录 1 demo 调整：

| 验证项 | 结果 |
|---|---|
| 书架点书 → **直接进阅读页**（不再先经详情） | ✅ |
| 顶部导航：三 Tab（书架/搜索/设置）**靠左** + 右侧「…」功能键 | ✅ 物理像素实测 Tab 位于左侧，`•••` 在右 |
| 「…」下拉菜单含「导入本地书籍」「切换列表模式/切换宫格模式」 | ✅ |
| 宫格 / 列表双视图切换 | ✅ 列表项 封面+书名+作者+进度 |
| 书名固定占两行（短标题补足、长标题省略） | ✅ `maxLines(2)` + `constraintSize(minHeight)` |
| 本地 TXT 导入 → 直接可读 | ✅ 真机导入「测试书」→ 阅读三章正常 |
| 进度三态（未读过 / N章/总数章 / 已读到最新章） | ✅ 分别实测「未读过」「1章/3章」「已读到最新章」 |

- 新增 `model/LocalBook.ets`：`DocumentViewPicker` 选 `.txt` → 编码识别（UTF-8/UTF-16/GBK 兜底）→
  「第X章/回/节…」正则分章 → 落盘 `files/local/{bookId}/{book.txt,toc.json}`；`sourceUrl` 用哨兵值 `local://`。
  阅读页与书架按 `local://` 分支走本地数据，不进引擎。
- 改造 `pages/Index.ets`：`Tabs` 隐藏自带 bar（`barHeight(0)`），自绘顶栏（Tab 靠左 + `bindMenu` 功能键）；
  菜单项动态生成（导入 / 视图切换）。
- 改造 `pages/Shelf.ets`：双视图 + 书名两行 + 本地书源解析（`localSource()`）。
- **修复 Bug**：`ForEach` 复用 key 未含进度 → 阅读返回后书架进度不刷新。key 改为
  `bookId#chapterIndex_percent`（`entryKey`），进度变化即重建列表项。
- **修复 Bug**：用**系统返回手势**退出阅读页时读不到 `Reader.onBack`，书架不刷新（进度停在旧值）。
  `Navigation` 加 `onNavBarStateChange`，导航栏重新可见且当前是书架 Tab 时 `shelfRefresh++`。
- 顶栏功能键三个点改为三个 4vp 圆点（原 `'•••'` 在 CJK 字体下按全宽渲染，间距过大）。
- **待办**：本地书的「详情页」尚未适配（阅读页「更多」→ 详情对 `local://` 走引擎会失败），
  归入后续阅读页/详情页整改。
  - 2026-09-24 更新：本地书「更多 → 详情」实测可用（`book` 直传，不再走引擎 `bookInfo`）。

## 详情页整改（2026-09-24，真机验证）

按 `plan.md` §6 / 附录 2 demo 调整（第二轮：头部背景 + 卡片 + 去展开）：

| 验证项 | 结果 |
|---|---|
| 顶栏：隐藏 `Navigation` 自带标题栏，自绘**无背景返回箭头**（去掉「书籍详情」标题） | ✅ |
| 头部**深红渐变背景**（demo 同款 `#402028→#8C2C38`，160°，白字） | ✅ |
| 「来源」移到作者下方（含「（只读）」）；**删除来源下方的类型/状态/字数等 meta 行** | ✅ |
| 简介显示全部正文、**无「展开/收起」**、无「简介」标题 | ✅ |
| 「目录 + 简介」= 白色圆角面板（圆角上边 + 负 margin 上叠红色头部），对齐 demo 的 content-wrap | ✅ |
| 底部整体操作栏：左侧「✓ + 已在书架」纯文字（灰色、无按钮），右侧「立即阅读」红渐变胶囊按钮 | ✅ |
| 本地书详情页可用（阅读页「更多」进入，来源显示「本地书籍」） | ✅ |

- 改动文件：`pages/BookDetail.ets`（`topBar(light)` / `header(d)` 渐变 / `contentPanel(d)` / `bottomBar` 勾选 icon）、
  `pages/Index.ets`（`ROUTE_BOOK_DETAIL` 改 `hideTitleBar(true)`，透传 `onBack`）。
- 新增色令牌：`detail_header_a`(#402028) / `detail_header_b`(#8C2C38)（base + dark），对齐 demo 头部渐变。
- 注：该头部渐变按用户要求对齐 demo（`plan.md:90` 原写「白底」，已按 demo 改为深红渐变）。

## 搜索结果页整改（2026-09-24，真机验证）

按 `plan.md` 附录 3 demo 与用户要求调整：

| 验证项 | 结果 |
|---|---|
| 顶栏自绘（`hideTitleBar(true)`）：`‹` 无背景返回 + **可编辑搜索框**（预填关键词 / `✕` 清空 / 回车重搜） | ✅ 页面内直接重搜，不必退回搜索 Tab |
| 去除「“关键词” + 共 N 条」头部（搜索目标 + 结果数量） | ✅ |
| 列表行只留 封面 / 书名（红）/ `作者 · 最新章节` / 2 行简介；去 kind、字数、单一「来源」标签 | ✅ |
| Legado `SearchModel.mergeItems` 语义：同名同作者**跨源合并**；分桶 精确→包含→其他；桶内按覆盖源数 → 源 `weight` → 书名 | ✅ 「夜的命名术」4 源合并排首位 |
| 字段归一：剥离源规则残留的 `作者：` / `最新章节：` 前缀（否则合并失配、meta 重复标签） | ✅ 合并与显示均正常 |
| 合并行显示 `N个来源`，点击弹来源选择 sheet（v1 无换源，选一个进详情） | ✅ 4 个来源可选，选中进详情 |
| 搜索代次 guard（连续重搜不混入旧结果） | ✅ |
| `ForEach` key 含 `origins.length`，合并后行才刷新（否则沿用旧行不更新） | ✅ |
| 返回箭头逐级回退 | ✅ 详情 → 结果 → 搜索 Tab |
| **封面修复**：`resolve_url("")` 曾返回源 base（无封面规则的源拿到 `http://m.bbiquge8.net`）；`##…##…/$1s.jpg` 中 `$1s` 被 Rust 正则当作组 `1s`（悠久小说封面变成 `…/.jpg###`） | ✅ 两处引擎 bug 修复，`cargo test` 54 passed，列表封面全部加载 |
| 合并行按**提供封面的那个源**去下载封面（Referer/headers 匹配） | ✅ |
| 仅对**多来源合并行**后台补拉一次 `bookInfo` 补简介/封面（并发 4、按 `sourceUrl|bookUrl` 缓存、代次 guard） | ✅ 合并行简介出现；单来源行维持搜索数据 |

- 改动文件：`pages/SearchResult.ets`（重写）、`pages/Index.ets`（`ROUTE_SEARCH_RESULT` 去标题 + `onBack`）、
  `rust/legado-engine/src/search_url.rs`（`resolve_url` 空串）、`rust/legado-engine/src/rule_dsl/combinator.rs`（`$1s` 归一化）。
- 说明：用户先要求「去除来源」，后又选「Legado 完整版（含合并多源）」；折中为列表不显示单一来源名，仅合并时显示 `N个来源` 并可点选。如需彻底不显示来源，可改为直接取最高 `weight` 源打开。

## 设置页整改（2026-09-25，真机验证）

按 `plan.md` §12 附录 8 设置页 demo 的结构，视觉对齐参考项目 `harmony-pokerouge` 的设置页
（**白底分组列表**：13sp `#999` 灰色分组标题 + 行 + 内缩分隔线，**不使用卡片**）：

| 验证项 | 结果 |
|---|---|
| 主设置页采用灰色分组标题 + 白色行 + 内缩分隔线（无卡片，对齐 pokerouge） | ✅ |
| 「设置」组：阅读设置 / 听书设置 / 书源管理 / 通用设置（右侧显示当前外观） | ✅ 通用设置值随主题变「浅色/深色」 |
| 「数据」组：清理缓存 / 备份与恢复 / **应用更新（新增，显示「已是最新」）** | ✅ |
| 「关于」组：应用版本 / 书源来源 / 作者 / GitHub / 法律与免责声明 | ✅ |
| **屏幕常亮移入「阅读设置」**（并新增字号 / 行距调节） | ✅ 开关切换即时生效、`preferences` 持久化，重启后仍为开 |
| **外观（主题）移入「通用设置」** | ✅ 跟随系统 / 浅色 / 深色；返回主设置页值同步刷新 |
| 新增路由 `ReadingSettings` / `GeneralSettings`（`Index.pageMap`） | ✅ |
| 编译（`hvigorw assembleHap` debug） | ✅ BUILD SUCCESSFUL |

- 新增文件：`pages/ReadingSettings.ets`、`pages/GeneralSettings.ets`、`common/Window.ets`。
- 改动文件：`pages/Settings.ets`（重写为 demo 卡片结构）、`pages/Index.ets`（新路由 + `settingsRefresh` 返回刷新）、
  `common/Const.ets`（路由 / `KEY_KEEP_SCREEN_ON`）、`common/Prefs.ets`（`get/putBoolean`）、
  `common/Theme.ets`（`themeModeLabel`）、`entryability/EntryAbility.ets`（`setMainWindow` + 启动应用屏幕常亮）。
- 说明：`屏幕常亮` 经 `window.setWindowKeepScreenOn` 实现（主窗口在 `EntryAbility` 存于 `common/Window`）；
  `听书设置` 已于 M5 实现；`清理缓存 / 备份与恢复` 仍为占位（M6），`应用更新` 暂无远端清单，点击提示「当前已是最新版本」。

## 阅读页整改（2026-09-25，真机验证）

按用户反馈 + `plan.md` 附录 5/6 demo 重写 `pages/Reader.ets`（去掉 `bindSheet`，改为阅读页内浮层）：

| 验证项 | 结果 |
|---|---|
| 正文冗余清除：去掉「当前位置：/作者/书名/章节名」面包屑、分页子页重复的章节名 | ✅ 真机正文只剩 1 个章节标题 |
| 章节名仅作正文首个粗体标题出现一次（不再每页重复） | ✅ |
| 去除章末「下一章」按钮 | ✅ |
| 中键点击可呼出**并可再次点击收起**功能菜单 | ✅ 真机验证开/合 |
| 顶栏返回箭头/章节名/更多纵向居中；「更多」= 三点图标 + `bindMenu` 下拉「书籍详情」（不再直接跳详情） | ✅ |
| 底栏去 `N/M`、`%` 文字；进度条左右 `‹ ›` 切换上/下一章；进度条改为带旋钮**可拖动 `Slider`**（拖动到章跳转） | ✅ |
| 目录/昼夜/设置均为图标（`sys.symbol`：line_3_horizontal / sun_max·moon / gearshape），图标间含昼夜切换 | ✅ |
| 阅读页独立昼夜模式（`reader_*_day` 令牌），`preferences` 持久化 | ✅ 代码就绪、真机切换不崩 |
| 目录改为**阅读区内浮层**：顶部导航栏下方 → 底栏上方（不再从手机底部弹出、不再过小） | ✅ 真机区域 [257..2367] |
| 目录顶部书籍卡片（封面/书名/作者，点击进详情） | ✅ 封面走 `BookCover` 兜底 |
| 正序/倒序切换后**滚动到目录最上方**再生效（避免 LazyForEach 中间态错乱） | ✅ 真机验证 |
| 目录项 LazyForEach key 改为稳定 `chapter.index` | ✅ |

- 改动文件：`pages/Reader.ets`（重写）、`common/Const.ets`（`KEY_READER_NIGHT` / `READER_NIGHT_DEFAULT`）、
  `resources/{base,dark}/element/color.json`（`reader_bg_day` / `reader_text_day` / `reader_panel_day` / `reader_dim` / `reader_dim_day`）。
- 说明：v1 正文为**竖向整章滚动**，故左右点击区与进度条 `‹ ›` 语义为**上/下一章**（非分页）；「下一章」引导按钮已按用户要求移除。
  面包屑清洗在 ArkTS 侧完成（`Reader.sanitize`，带章节标题上下文），无需改 Rust `.so`。
- 构建（`hvigorw assembleHap` debug）：✅ BUILD SUCCESSFUL（0 error）。

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

## 阅读页横向分页翻页 + 跨章连续滑动（2026-10-04，真机验证）

阅读页从「竖向滚动」改为「横向分页翻页」（Swiper + `measureTextSize` 测字精确分页），并实现
「上一章+本章+下一章」跨章连续滑动。完整踩坑与代码状态见 [`handoff/HANDOFF-S10.md`](./handoff/HANDOFF-S10.md)。

| 验证项 | 结果 |
|---|---|
| 横向 Swiper 分页（测字精确分页，段可跨页拆字符） | ✅ |
| 跨章连续滑动（上一章+本章+下一章扁平页流，上一章/下一章暖载） | ✅ |
| 单手/非单手翻页模式 + 左右滑手势 | ✅ |
| 字号/行距/昼夜即时重排 | ✅ |
| 目录缓存（`model/TocCache.ets`，内存 LRU + 落盘） | ✅ |
| **末页/首页闪烁一帧「满页」** | ✅ 已修（声明式 `.index(this.pageIndex)` 原子跳位，弃用 postFrameCallback 命令式 changeIndex） |
| 编译 + 真机装机闭环（只改 ArkTS，不动 Rust/.so） | ✅ |

## 书源置信度 + 搜索滑动窗口调度（2026-10-06，真机验证）

为应对「搜索时源大量报错」及后续 300–4000 个源，给书源加了**置信度系统**，并把搜索调度重写为
**滑动窗口 + 按置信度排序**。全部在 ArkTS 搜索层完成，未改 Rust / `.so`。

| 验证项 | 结果 |
|---|---|
| 置信度扣分（`blocked` -30 / `server_error` -25 / `network_error` -20 / `timeout` -15；`no_results` 等不计分） | ✅ 真机：server_error 连续两轮 100→75→50 |
| 成功回分（+5，封顶 100 下限 0；无时间回弹） | ✅ 真机：network_error 80 → 成功 85 |
| 持久化（`confidence` 字段随 `book_sources_v1` 存 preferences，重启不丢） | ✅ 直接读 preferences XML 确认落盘 |
| 每次搜索前按置信度降序排序源 | ✅ |
| 滑动窗口并发（`SEARCH_CONCURRENCY=8`，完成一个补下一个，非严格分批） | ✅ 3000 源不会一次性打爆连接/内存 |
| 逐源渐进渲染（高置信源先出结果先上屏） | ✅ t+2s 见「正在搜索…更新中」+ 部分结果，t+4s「共 194 条」 |
| 编译 + 真机装机闭环 | ✅ BUILD SUCCESSFUL（0 error） |

- 新增：`model/SourceConfidence.ets`（`confidenceOf` / `sortByConfidence` / `applyOutcomes`）。
- 改动：`pages/SearchResult.ets`（滑动窗口 `drain`/`searchOne` + `persistConfidence`）、
  `engine/types.ets`（`BookSource.confidence?`）、`obfuscation-rules.txt`（`-keep-property-name confidence`）。
- 规模扩展提醒（300–4000 源时再处理）：总耗时 ≈ 源数/并发 × 平均耗时，Rust `concurrency.clamp(1,16)` 是硬上限；
  `book_sources_v1` 单条 JSON 存 preferences 届时可能过大，或需迁 RDB。

## 抽屉统一样式 + 打开方式（2026-10-06，真机验证）

把全项目底部抽屉统一为**阅读页目录/阅读设置**那一套：从**屏幕最底部上滑**的番茄式浮层。
规范已归档为 [`specs/UI-SPEC.md`](./specs/UI-SPEC.md)（**改动抽屉前必读**，含 7 处调用点清单 + 检查清单）。

| 验证项 | 结果 |
|---|---|
| 全部抽屉 `mode` 统一 `overlay`（去 `system`/`bindSheet`） | ✅ 书源管理 / 搜索页两处 / 听书目录 |
| 打开方式统一：都从屏幕最底边上滑 | ✅ 慢放到 1500ms 连拍，面板顶边逐帧 2672 → 2281 → 1480 → 845 → 588（屏高 2844） |
| 首开不再「弹出」（面板常驻测量，消除 3000 兜底起点） | ✅ 页面加载即测高，打开行程 = 面板实测高度 |
| 关掉遮罩后页面仍可滚动/点击（命中测试） | ✅ 修掉常驻挂载吞手势的回归（宿主 `Stack` 需 `HitTestMode.None`） |
| 圆角 20 可见（白叠白加阴影 `#33000000`） | ✅ 逐像素：顶部出现阴影渐变，左右角镜像对称 |
| 阅读页目录 / 阅读设置无回归 | ✅ 目录照旧打开、内容正常 |
| 编译 + 真机装机闭环 | ✅ BUILD SUCCESSFUL（0 error） |

- 改动：`ui/common/BottomDrawer.ets`（常驻挂载 + 精确测高 + 命中测试 + 阴影）、
  `pages/BookSourceManage.ets` / `pages/SearchResult.ets` / `pages/Listening.ets`（改 overlay + 常驻挂载）。
- **作废旧规**：旧 UI-SPEC「目录走系统 sheet」与 `RELEASE-NOTES.md` 对应条目已标注取代，**勿回改**。
- 未提交；听书目录抽屉待联上可用书源后补一次真机点开复验。

### 补修：底部锚点 + 关闭态阴影（2026-10-06，用户真机反馈）

反馈两条：①「书源状态/书源选择」从底部 menu 上方弹出，「书源校验」从安全区上方一点弹出（都不是从屏幕最底部）；
②抽屉没打开时，在弹出位置能看到**一条两端缺角的阴影带**。

定位（用已有实测数据反推几何，逐项吻合）：

| 抽屉 | 宿主布局区底边 | 实测面板顶 | 推算验证 |
|---|---|---|---|
| 书源管理「书源状态」(large) | 屏幕底 − 安全区 = **2717** | ~557–570 | 2717 − 0.9×(2717−317) ≈ 557 |
| 搜索页「源状态/选择来源」 | **tab 栏顶边 2597** | 1181 / 996 | 2597 − 0.7×(2597−296) ≈ 987 ≈ 996 ✅ |
| 阅读页（基准） | 屏幕底 2844 | — | 基准正常 |

结论：宿主 `clip`/布局区被**底部安全区（127px）**与**底部 tab 栏（120px）**截断；关闭态阴影是面板常驻后 `shadow` 从宿主裁切区上方溢出（`clip(true)` 裁不掉阴影）。

修复（三处）：

1. **锚定屏幕物理底边**：`overlayHost` 加 `.expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])`；
2. ~~打开期间让出底部 tab 栏~~（**已废弃**，见下节）；
3. **关闭后彻底不可见**：新增 `@Local panelShown` → `visibility(Hidden)`（保留布局与测高），关闭动画结束 +40ms 才隐藏。

- 附带：打开时改为「先重新测高再起滑」（`MEASURE_WAIT_MS = 32`）。
- 规范已同步：[`specs/UI-SPEC.md`](./specs/UI-SPEC.md) §1.2.1（必须锚定屏幕物理底边）/ §1.2.2（关闭后必须完全不可见）。
- 状态：编译 ✅ BUILD SUCCESSFUL。

### 修正：tab 页内抽屉改用窗口模态层 `mode: 'cover'`（2026-10-06，用户真机二次反馈）

反馈：「源状态 / 选择来源」抽屉打开时，**下方 tab 栏会先消失再出现**；要求像阅读页目录抽屉那样——
**tab 栏原地不动，只是被抽屉遮罩盖住**。

根因：上节方案 ②「隐藏 tab 栏」本身就是被反馈的缺陷；且从绘制序上说，tab 栏是 `Index` 里 `Tabs` 的**后置兄弟**，
而抽屉声明在 `TabContent` 内的页面里 → 页面级抽屉**永远画不到 tab 栏之上**（除非让 tab 栏让出布局，而那会带动整页重排）。

方案（新增 `BottomDrawer` 第三种模式）：

- **`mode: 'cover'`**：抽屉用 `bindContentCover` 画到**窗口模态层**（`ModalTransition.NONE` + `backgroundColor: Color.Transparent`
  + `onWillDismiss` 回到 `onClose()`），面板天然锚定窗口底边、且**在 tab 栏之上**；
  打开/关闭动画仍由 `BottomDrawer` 自己的状态机驱动（`translate` + `animateTo`），所以视觉与阅读页抽屉一致；
  关闭动画结束后整层模态卸载（不会残留阴影，不需要 `visibility` 补救）。
- **搜索页「源状态 / 选择来源」两个抽屉迁到 `cover`**；`NavDestination` 页（阅读页 / 书源管理 / 听书）与
  页面已直达屏幕底边的场景继续用 `overlay`（已验证、无 tab 栏干扰）。
- **删除** `model/DrawerOverlay.ets` 计数单例，`Index.ets` 恢复**无条件**底部栏（tab 栏位置全程不变）。
- 规范已订正：[`specs/UI-SPEC.md`](./specs/UI-SPEC.md) §1.2.1 新增「页内 `overlay` / 窗口层 `cover` 二选一」规则，
  并明文**禁止**再用「让 tab 栏让位」腾空间。
- 状态：编译 ✅ BUILD SUCCESSFUL；**真机验证待用户复测**（设备当时不在线）。

### 源状态抽屉内容整改（2026-10-06，用户真机反馈）

| 反馈 | 处理 |
|---|---|
| 去掉「搜索源名」 | 删除 `statusSearchBox()` 与 `@Local statusFilter`（含 `statusRows()` 的名称过滤分支）；抽屉内已无 `TextInput` |
| 所有组默认不展开 | 收起态改为**每次关闭抽屉时复位**（`BottomDrawer.onClose` 里清 `expandedReason/expandedOk`；遮罩/拖拽/X/系统 dismiss 四条关闭路径都经 `onClose`），不再保留上次展开态 |
| 排序改为按「置信度影响」 | 新增 `statusGroups()`：成功组置顶，其余按 `-penaltyFor(reason)` 降序 → 成功 → 未搜索到 → 超时 → 网络错误 → 服务器错误 → 被拦截；同分按源数、再按名称 |
| 展开后的源行去掉色点 | `statusSourceRow()` 不再画 8vp 圆点（**组头保留**，用于区分成功/失败） |
| 「3 源」展开只有 2 行 | **根因：ForEach key 用了 `'s:' + sourceUrl`**，而用户书源里 `bbiquge8` 与 `笔趣阁8` 指向同一 URL（`http://m.bbiquge8.net`）→ 同 key 被 ForEach 静默去重。改为组内序号 key `'s:<group>#<i>'`（`StatusRow.id`），组内保持 `statuses` 追加序以保证 key 稳定 |
| 统计区与下方列表无间隔 | 对齐目录抽屉的呼吸感：统计区改 `padding({ top: 16, bottom: 24 })`（原 `6/6`），并在统计区与列表之间加一条**通栏**分割线（`margin({left:-16,right:-16})` 抵消内容区左右 padding，与标题栏分割线同宽）。实测：“成功率”距标题栏分割线 8vp → **16vp**；“2 失败”距首个分组 30vp → **52vp**，中间夹 1px 分割线。内容区本身无顶部内边距（`BottomDrawer.contentArea`）→ 顶部留白由各页内容自备 |

- `penaltyFor` 由 [`../entry/src/main/ets/model/SourceConfidence.ets`](../entry/src/main/ets/model/SourceConfidence.ets) 导出，**排序与计分共用同一张影响表**（改扣分即同步改排序）。
- 真机验证（`uitest dumpLayout`）：抽屉内页面级 `TextInput` 仅剩顶部搜索框，抽屉自身 0 个；关闭重开后全部 `▸`；成功组置顶且「5 源」= 展开 5 行（含两个同 URL 源）、失败组「2 源」= 2 行；展开行内 8vp 圆点 = 0（组头保留）。
- 抽屉规范已同步：[`specs/UI-SPEC.md`](./specs/UI-SPEC.md) §1.5（内容区无顶部内边距 + 通栏分割线写法）、§1.6/§2 修正陈旧的 `sheetSize`（「源状态」原记 `fit`、「选择来源」原记 `medium`，实际均为 `large`；现全项目 6×`large` + 1×`fit`）。
- 已知无害噪音：cover 模态层开合时 ArkUI 记 `E AceStateMgmt: No views to update for containerId=100000`。
  已实测**与本改动无关**（把复位写入删掉后该日志反而更多），属 `bindContentCover` + 大量页面 `@Local` 写入的既有现象；
  复位展开态必须在 `onClose`（内容仍挂载）里做，别放进 `@Monitor('statusVisible')`（那时模态层可能尚未挂载）。

## 未决 / 风险
- 目录分页 `nextTocUrl` / 卷 `isVolume` 已在引擎实现（真机 detect 覆盖当页路径），多页目录待复验。
- 书源持久化仍用 `preferences` JSON（书籍/进度已用 `relationalStore`）；后续可迁移统一。
- 规则「静默失败」诊断：`parseWithDiagnostics` 已可返回 regex/CSS/JS 诊断，调试器 UI 待 M6。
- 文件导入/剪贴板导入：URL 导入已真机复验（成功 1 / 排除 2：需 JS 1、需登录 1）；文件/剪贴板走同一门禁函数。
- 搜索排序已改为 Legado 分桶 + 同名同作者跨源合并 + 源 `weight`（见「搜索结果页整改」）；
  另加**书源置信度**（失败扣分/成功回分/持久化）决定**搜索调度顺序**（见「书源置信度 + 搜索滑动窗口调度」）。
- **同 URL 重复书源**（用户库内确有两例：`bbiquge8` / `笔趣阁8` → `http://m.bbiquge8.net`）是「ForEach key 用 URL」
  这一类缺陷的共同诱因。搜索侧已修（见「源状态抽屉内容整改」）；**书源管理列表仍是待办**（见 `bugfix/TASKS.md` T-SRC-1）。

## 交接备忘

- 构建/安装/调试命令见 [`../AGENTS.md`](../AGENTS.md) §4。
- **底部抽屉规范见 [`specs/UI-SPEC.md`](./specs/UI-SPEC.md)**（唯一权威；改动抽屉必须全项目同步）。
- 引擎复用清单与门禁见 [`engine.md`](./engine.md)。
- 架构与 NAPI 边界见 [`architecture.md`](./architecture.md)。
- 端侧自建 TTS（本地 GPT-SoVITS 音色）调研与原型计划见 [`research/TTS-PLAN.md`](./research/TTS-PLAN.md)
  （与 M5 系统 TTS 并行、未立项；下一步 = TTS-PLAN §9 P0）。
