# 进度 / 下一步

> 权威设计见 [`../plan.md`](../plan.md)（含 27 项修订与全部决策）。本文件只记**进度与待办**。

## 里程碑状态

| 阶段 | 内容 | 状态 |
|---|---|---|
| **M0** | 引擎 PoC：交叉编译 + 解析 + 网络 + 体积 + 冷启动 | ✅ 已完成（真机验证） |
| M1 | 项目骨架 + Design Token（红白）+ 路由 + 三 Tab | ✅ 已完成（真机验证，浅色切换待复验） |
| M2 | 引擎接口（search/bookInfo/toc/content）+ JS/登录门禁 + 书源导入 | ✅ 已完成（真机验证：detect 8/13 可用） |
| M3 | 搜索聚合 + 详情 + 加入书架 + 持久化 | ✅ 已完成（真机验证：加入书架重启仍在） |
| M4 | 阅读页（竖向滚动）+ 目录（含分页）+ 进度 + 阅读设置 | ✅ 已完成（真机验证：目录/跳转/字号/进度重启恢复；修 bindSheet + 正文清洗；**收尾项已补**）|
| M5 | 听书 + 系统 TTS + 后台播放 + AVSession | ⏳ 未开始 |
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

## 未决 / 风险

- M5 TTS：Core Speech Kit 的 PCM → `AudioRenderer`/`AVPlayer` → `AVSession` 链路需单独 PoC。
- 目录分页 `nextTocUrl` / 卷 `isVolume` 已在引擎实现（真机 detect 覆盖当页路径），多页目录待复验。
- 书源持久化仍用 `preferences` JSON（书籍/进度已用 `relationalStore`）；后续可迁移统一。
- 规则「静默失败」诊断：`parseWithDiagnostics` 已可返回 regex/CSS/JS 诊断，调试器 UI 待 M6。
- 文件导入/剪贴板导入：URL 导入已真机复验（成功 1 / 排除 2：需 JS 1、需登录 1）；文件/剪贴板走同一门禁函数。
- 搜索排序目前按「源完成顺序」；书名相似度 + 源权重排序待打磨。

## 交接备忘

- 构建/安装/调试命令见 [`../AGENTS.md`](../AGENTS.md) §4。
- 引擎复用清单与门禁见 [`engine.md`](./engine.md)。
- 架构与 NAPI 边界见 [`architecture.md`](./architecture.md)。