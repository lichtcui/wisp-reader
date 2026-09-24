# 鸿蒙阅读 App 开发方案（定稿）

> 目标：HarmonyOS NEXT 原生阅读 App，兼容 Legado 书源格式。
> 本方案由原型说明（第 12 节附录 demo）经多轮评审优化而成，共落实 27 项修订，见第 13 节「修订清单」。
>
> 关键外部依赖：
> - 书源引擎来源：`~/Documents/playground/legado-source-filter`（Rust，已有 Lexer / HTML·JSON 提取 / HTTP / 限速 / 链路校验）
> - 视觉基准：`~/Documents/playground/harmony-pokerouge`（白 + 红、扁平）
>
> **实施进度**：M0–M5 ✅ 已完成真机验证；M6 未开始。
> 进度、验证结果与下一步见 [`docs/progress.md`](./docs/progress.md)；接手说明见 [`AGENTS.md`](./AGENTS.md)。
> 本文件是**唯一权威设计**，只描述目标方案，不随进度改动。

---

## 0. 项目定位与范围

- **目标**：HarmonyOS NEXT 原生阅读 App（ArkTS + ArkUI），兼容 Legado 书源格式。
- **核心策略**：复用本地 Rust 规则引擎，经 `ohos-rs` 编译为鸿蒙原生库（`.so`），ArkTS 通过 NAPI 调用。
- **v1 范围**：单源完整链路 —— 搜索 → 详情 → 加入书架 → 阅读（竖向滚动）→ 听书。
- **v1 明确不做**：
  - 换源（依赖 `bookUrlPattern`，列入 v2）
  - JS 运行时（`<js>` / 非 L1 `@js:`；L1 字符串模式仍解析，见 5.2）
  - 登录型书源（`loginUrl` / `loginUi` / `loginCheckJs`）
  - 发现（explore）分类/榜单
  - 真分页（左右滑动翻页）/ 在线 TTS
- **原型定位**：第 12 节 HTML demo 仅作结构与交互参考，实现以第 2 节 Design Token 为准。

---

## 1. 技术栈与架构

| 层 | 选型 |
|---|---|
| 框架 | ArkTS + ArkUI 声明式（Stage 模型） |
| 路由 | `Navigation` + `NavPathStack`（不用已废弃的 `@ohos.router`） |
| 状态 | **`@ComponentV2` + `@Local/@Param/@Monitor`**；跨页 `AppStorageV2`；跨启动 `PersistenceV2` |
| 网络 | **Rust 侧 `reqwest`**（ArkTS 不发书源请求；封面亦由 Rust 代下） |
| 引擎 | `legado-core`（Rust）→ `.so`（`ohos-rs`）+ NAPI |
| 持久化 | `@ohos.data.preferences` + `@ohos.data.relationalStore` |
| TTS | Core Speech Kit `textToSpeech` → `AudioRenderer`/`AVPlayer` → `AVSession` + `backgroundTaskManager` |
| 图标 | `SymbolGlyph`（HarmonyOS Symbol）+ 本地 SVG |
| API | `compatibleSdkVersion` 12 / `targetSdkVersion` 24（与参考项目同档） |

**架构分层**

```
ArkTS（UI / 状态 / 持久化 / TTS / 播放）
  │  IBookEngine 端口（ArkTS 接口，便于替换实现）
  │  NAPI（粗粒度、异步 Promise，JSON 进出）
legado-core（rule_dsl 解析 / HTML·JSON 提取 / HTTP / Cookie / 限速 / 正文清洗）
```

**架构要点**
- **端口隔离**：ArkTS 只依赖 `IBookEngine` 接口，Rust 实现藏在后面。若 native 工具链受阻，可整体替换为纯 ArkTS 实现而不动 UI。
- **开发内循环**：规则调试与回归在桌面用现有 CLI（`cargo run --example chain_check`）完成，不依赖真机。
- **懒加载**：`.so` 与运行时在首次进入搜索/阅读时初始化，避免拖慢书架首屏。
- **工程约定（借鉴参考项目）**：安全区用 `setWindowBackground('#ffffff')`；列表 `scrollBar(BarState.Off)`；release 混淆需维护 `-keep-property-name`；`.so` 的 native 构建需集成进 hvigor。

---

## 2. 设计规范（Design Token）

```
品牌（红系轻渐变）
  brand          #da3838        主按钮 / 选中态 / 开关 / 强调
  brand-press    #c22f2f        按下态
  brand-grad-a   #e35a5a        渐变起（封面 / 主按钮）
  brand-grad-b   #da3838        渐变止
中性
  bg-page        #ffffff
  bg-card        #f7f7f7
  bg-pill        #f2f2f2        未选中分段 / 胶囊
  text-1 #333333  text-2 #666666  text-3 #888888  text-4 #999999  text-5 #bbbbbb
  divider        #ededed        arrow #cccccc    shadow #99000000
  warning #c77700   info #3a6fd8
阅读页（独立于全局主题）
  reader-bg #181820   reader-text #d1d1d6   reader-panel rgba(44,44,56,.85)
字号 12 / 13 / 14 / 16 / 18 / 20（UI）+ 阅读正文 16–28 可调
圆角 封面 8 / 卡片 12 / 胶囊与分段 18 / 主按钮 胶囊
间距 4 的倍数；水平内边距 16；内容最大宽 600vp，超出居中
```

- **令牌化**：所有颜色走 `resources/base/element/color.json` + `resources/dark/element/color.json`，禁止代码内写死 hex（参考项目是内联 hex，但本 App 需支持主题 + 深色，必须令牌化）。
- **组件语言**（对齐参考项目）：
  - 设置页 = iOS 分组列表：分组标题 13sp `#999` → 行（标签 16sp `#333` / 值 14sp）→ `›` `#ccc` → 内缩分隔线。
  - 分段控件：高 36、圆角 18；选中红底白字，未选中 `#f2f2f2` 底 + `#666` 字。
  - 主按钮：高 52–54、红渐变底白字 17–18sp、宽约 84%；`Toggle.selectedColor = #da3838`。
  - 弹窗：取消 `#666`、确认 `#da3838`。
- **替换项**：删除原 demo 的粉色渐变与 `#f4f4f6`；详情页删除深红渐变 `#402028→#8c2c38`，改白底。

---

## 3. 信息架构与路由

```
MainPage (Tabs)
 ├─ 书架 Tab ─ BookDetailPage ─ ReaderPage
 │                              ├─ 目录       bindSheet（可拖高度）
 │                              ├─ 阅读设置    bindSheet
 │                              └─ 听书        bindContentCover（全屏）
 ├─ 搜索 Tab ─ SearchResultPage / BookSourceManagePage
 └─ 设置 Tab ─ 阅读设置 / 听书设置 / 书源设置 / 通用设置 + 关于
```

---

## 4. 领域模型

字段命名对齐 Rust `types.rs`，便于 serde 直通，减少转换层。

```ts
BookSource   // 直接序列化 Rust BookSource；enabledRuntime / lastError 另列
Book         // bookId, sourceUrl, name, author, coverUrl, intro, kind, wordCount,
             // status, lastChapterTitle, tocUrl, inShelf, addedAt
Chapter      // bookId, index, title, url, isVip
ReadProgress // bookId, chapterIndex, chapterTitle, paragraphIndex, charOffset, percent, updatedAt
ChapterCache // bookId, index, content, fetchedAt（文件缓存，不入库）
```

- `Book.bookId = hash(normalize(sourceUrl + bookUrl))`（**先归一化为绝对 URL**，避免源 base 变动导致进度丢失）。
- **进度语义**：`paragraphIndex + charOffset`（与字体/字号无关，切字号不失效）。
- **书架进度三态**：
  - 无进度 → 「未读过」
  - `chapterIndex >= toc.length - 1` → 「已读到最新章」
  - 其他 → `{chapterIndex + 1}章/{total}章`
- **搜索 → 书架去重**：无换源时，同一本书来自不同源会生成不同 `bookId`。搜索页命中「已在架」书籍（按书名 + 作者匹配）时显示「已在书架」并跳转，不重复加入。

---

## 5. 书源引擎（复用 Rust，最高风险）

### 5.1 复用清单与拆解

| 模块 | 复用 | 备注 |
|---|---|---|
| `rule_dsl/parser.rs` | ✅ | DSL 词法：`class./id./tag./.n/!n/@css:/@href/@html/@textNodes/$./data.` |
| `rule_dsl/html_extractor.rs` | ✅ | `scraper`(Servo CSS) 求值；`\|\|` 回退、类型不匹配短路 |
| `rule_dsl/json_extractor.rs` | ✅ | JSONPath 求值 |
| `rule_dsl/combinator.rs` | ✅（有坑） | `##` 正则替换；正则/选择器解析失败会**静默跳过**，见 5.5 |
| `types.rs` | ✅ | 含 `parse_concurrent_rate`、`bookUrlPattern`、`coverDecodeJs`、`header` |
| `preflight.rs` | ✅ | `preflight::run` 是纯函数，可直接作「导入源校验」 |
| `search_url.rs` | ✅ | `{{key}}` / POST / `resolve_js_l1` / header 解析 |
| `http_client.rs` | ⚠️ 改造 | 编码探测/限速可用；**必须删证书放行**，补 Cookie，见 5.4 |
| `content_check.rs` | ⚠️ 双拆 | `verify_chain` 用于「书源检测」；运行时链路只复用其内部工具函数 |
| `status.rs::FailReason` | ✅ | 映射 UI 错误文案 |
| `js_polyfill/` | ❌ | 依赖 Node，v1 不启用（cargo feature 门控） |

- **拆 crate**：抽 `legado-core`（仅 `rule_dsl` + `types` + 精简 `http_client` + 链路工具），避免把 `rusqlite` / `clap` / `toml` / Node 拖进 `.so`。
- **`content_check` 必须解耦 Node**：`content_check.rs` 直接 `use crate::js_polyfill::runner`，需引入 `JsEvaluator` trait（v1 给 no-op 实现），并用 cargo feature 门控。
- **运行时 vs 检测**：
  - 运行时 = 独立 NAPI（`search` / `bookInfo` / `toc` / `content`），只复用工具函数 `substitute_book_fields`、`expand_template`、`is_literal_url`、`page_headers`、`extract_items`、`parse_pair_list`、`resolve_url`。**不要每次请求走 `verify_chain`**。
  - `verify_chain` 本身 → 用作 App 的「书源检测」功能。
- **known_gaps（显式标记，不静默失败）**：负索引、区间、`&&`、`children`、`ownText/all`。

### 5.2 v1 能力门禁（import 时执行）

在 `preflight::run` 之上叠加一道 **v1 门禁**，产出可用源：

1. **非文字源排除**：仅保留 `bookSourceType == 0`。
2. **JS 排除**：
   - `searchUrl` 含 `<js>` → 排除。
   - `searchUrl` 为 `@js:` → **先走 `resolve_js_l1`（`search_url.rs`）**；能解析则保留，失败才排除。
   - 字段级 JS（`is_js_rule`，含 `java.`）：关键字段 `bookList` / `name` / `bookUrl` 含 JS → 排除；仅可选字段 `coverUrl` / `intro` 含 JS → 降级保留（封面走兜底）。
3. **登录源排除**：`loginUrl` / `loginUi` / `loginCheckJs` 非空 → 排除。
4. 打标：被排除但在库中的源，管理页显示「需 JS」/「需登录」徽标。

> 措辞精确：v1 是「**不执行 JS 运行时**」，但仍会对 `@js:` 做 L1 字符串解析，二者不同。

### 5.3 NAPI 接口（粗粒度 + 异步）

```
search(sourcesJson, keyword, opts)   -> Promise<{ items: BookSearchItem[], sources: SourceStatus[] }>
bookInfo(sourceJson, bookUrl)        -> Promise<BookInfo>
toc(sourceJson, tocUrl)              -> Promise<Chapter[]>
content(sourceJson, chapterUrl)      -> Promise<{ content, nextUrl? }>
parse(html, ruleJson)                -> { values, diagnostics }       规则调试器
detect(sourcesJson, opts)            -> 流式进度 + 结果              书源检测
```

- **搜索提取器必须扩展**：`rule_dsl/mod.rs::extract_results` 目前只返回 `[name, author, bookUrl, coverUrl]`，需补 `intro / kind / wordCount / lastChapter`（否则搜索页信息全空）。
- **`content()` 语义 = 整章**：内部按 `nextContentUrl` **循环翻页（上限 30、自引用防死循环）** 后拼接所有非空段（对齐 `eval_rule_concat`），否则正文截断。
- **`search()` 必需能力**：
  - 返回**每源状态**（成功/失败 + `FailReason`），供 UI 展示「部分源失败」。
  - **渐进返回 + 全局超时**：结果到一批推一批（分段回调或轮询），全局上限约 10s，超时源标失败。
- **二进制不过 NAPI**：封面由 Rust 直接写沙箱缓存文件，返回路径；ArkTS 用 `PixelMap` 从文件加载。
- Rust 内跑 tokio 工作线程，回调 ArkTS 用线程安全函数；大数据走 JSON 字符串。

### 5.4 网络、Cookie、并发与安全

- **HTTP 由 Rust 持有**（`reqwest`），编码探测沿用 `chardetng` + `encoding_rs`。
- **Cookie 隔离**：reqwest 的 cookie store 绑定在 `Client` 上，按源隔离需**每源一个 `Client`**（连接池有上限 + LRU 回收），或自定义按域键控的共享 store。**v1 仅内存**（登录源已排除，暂不需持久化）。
- **限速**：`concurrentRate` 令牌桶 + 同域串行（`http_client.rs` 已有 `parse_concurrent_rate` / `with_rate_limits`）。
- **熔断**：连续失败 N 次自动禁用源，记录 `lastError`（持久化到 relationalStore）。
- **安全红线**：**禁止 `danger_accept_invalid_certs(true)` 进入 App**（现 `http_client.rs:164,175` 硬编码，必须删）。
- **UA 可配置**；超时 15s、重试 2 次、失败降级下一源。
- **搜索聚合**：多源并发，结果按「书名相似度 + 源权重（`BookSource.weight`）」排序、源内去重。

### 5.5 规则诊断（治理「静默失败」）

引擎对无法解析的规则目前**静默吞掉**，用户只看到「读不到内容」：

- **Java 正则 ≠ Rust 正则**：`##regex##` 是 Java 语义（支持 lookaround/反向引用），而 `combinator.rs` 用 Rust `regex`，不支持的模式 `Regex::new` 报错后被 `if let Ok` 跳过，替换静默不生效。
- **CSS 解析失败同样静默**：`html_extractor.rs::apply_selector_all` 的 `Selector::parse` 失败返回空集。

**要求**：引擎解析时**收集诊断**（哪些规则编译失败、原因），随结果返回；「书源检测」UI 展示具体失败规则。（可选：对含 lookaround 的 `##` 回退 `fancy-regex`——回溯引擎、有 ReDoS 风险，需权衡。）

### 5.6 M0 PoC（决策门，必须最先做）

用 `ohos-rs` 编译 `legado-core`（不含 JS）为 `.so`，ArkTS 同时验证：

1. `parse` 规则提取正确；
2. `reqwest` + `rustls` 从 `.so` 访问真实 https 站点；
3. **明文 HTTP 放行**（大量书源是 `http://`，HarmonyOS NEXT 对明文流量有安全策略，需确认 `module.json5`/network 配置）；
4. NAPI 异步 Promise + 线程安全回调；
5. `.so` 体积 + 冷启动耗时。

- 注意：交叉编译 `aarch64-…-ohos` 可能需要 **nightly + `-Z build-std`**。
- 通过 → 全面走 Rust 引擎。
- TLS 不通 → 降级「ArkTS 持有 HTTP、Rust 只解析」（端口不变，换实现）。

---

## 6. 页面规格

每页补齐状态机：`loading`（骨架屏）/ `empty` / `error`（重试）/ `no-network` / `source-invalid`。

- **书架**
  - 宫格/列表切换 + 排序（最近阅读/添加时间/书名）；断点：手机 3 / 折叠屏 5 / 平板 6–8（`GridRow` + `breakpoints`）。
  - 长按卡片：置顶 / 分组 / 删除 / 详情。
  - FAB：**仅听书任务进行中显示**。
  - 封面加载失败 → 红系渐变底 + 书名；封面统一由 Rust 代下后经文件加载（避免 Referer/Cookie 缺失）。
- **书籍详情**
  - 头部白底；来源**只读展示**（v1 无换源）；简介默认折叠 4 行 + 展开。
  - 底部栏：「加入书架」可点 / 「已在书架」置灰；「立即阅读」有进度续读、无进度从第 1 章。
- **搜索**
  - 有源：大搜索框 + 「管理书源」；无源：居中「导入书源」。
  - 导入方式：`DocumentViewPicker` 选 JSON / 剪贴板粘贴 / URL 导入 / 扫码（可选）。
  - 导入后走 5.2 门禁，展示「成功 N / 排除 M（需 JS、需登录、非文字）」明细。
- **搜索结果**
  - 列表项：封面、书名（品牌红）、作者 · 连载状态 · 字数、2 行简介、来源标签。
  - 渐进展示 + 加载态；空结果态；「已在书架」标记。
- **阅读页**
  - **v1 竖向滚动**；三点击区：左 1/3 上一章、中 1/3 呼出/隐藏菜单、右 1/3 下一章。
  - 顶栏：返回、章节名、更多（→ 详情）；底栏：上一章、进度条、下一章、目录、日/夜间、设置。
  - 设置面板 `bindSheet`：字号、行距、段间距、字体（`font.registerFont`）、页边距、背景色、亮度。
  - 状态：正文加载中 / 失败重试 / VIP 章节提示 / 章末「下一章」引导。
- **目录**
  - `bindSheet` 可拖高度（50% / 90%）；顶部卡片（封面/书名/作者，点进详情）。
  - 章节总数 + 正序/倒序；当前章高亮 + 定位按钮。
  - **必须支持目录分页**：`toc()` 内部走 `nextTocUrl` 循环 + 卷（`isVolume`）合并。
  - 性能：`LazyForEach` + `cachedCount`，5000 章不卡。
- **听书**
  - `bindContentCover` 全屏由下往上；封面、章节名、书名+作者、进度条、语速、上一章/暂停/下一章、定时关闭、音色。
  - 实现：系统 TTS（`textToSpeech`）→ PCM/音频帧 → `AudioRenderer`/`AVPlayer` → `AVSession`（锁屏可控）。
  - 后台长时任务（`KEEP_BACKGROUND_RUNNING`）；定时关闭；阅读位置高亮与进度回写（依赖竖向滚动的段落定位）。
  - 预留「在线 TTS」扩展点。
- **设置**
  - 分组列表：阅读设置 / 听书设置 / 书源设置（列表、导入导出、启停、分组、检测、调试器）/ 通用设置（夜间、主题、清缓存显示占用、应用更新、备份恢复）/ 关于（版本、书源来源、作者、GitHub、免责声明）。

---

## 7. 持久化与缓存

| 数据 | 方案 |
|---|---|
| 书源 / 书籍 / 章节 / 进度 | `relationalStore`，索引 `bookId`、`sourceUrl` |
| 熔断状态（`enabledRuntime` / `lastError`） | `relationalStore` |
| 用户配置（字号/主题/音色…） | `preferences` |
| 章节正文 | 文件系统 + 内存 LRU；上限约 200MB；已读永久保留、未读超 N 天清理 |
| 封面 | Rust 下载至沙箱缓存目录 + LRU |
| 备份 | 导出 JSON（书源 + 书架 + 进度），**带 `schemaVersion`**，支持导入恢复 |

- **内置默认书源**：随包携带 **v1 兼容子集** `bundled-sources.json`（由桌面引擎 + 5.2 门禁从 `filtered.json` 再生成；**不能直接用 `filtered.json`**，因为它含需 JS 的源）。
- **书源更新机制**：设置页「书源检测」+ 支持重新导入；内置集可随版本更新。

---

## 8. 非功能需求与安全健壮性

- **性能**：书架首屏 < 500ms（引擎懒加载）；目录 5000 章滚动不掉帧；正文懒加载；可预取下一章。
- **网络**：统一超时 15s、重试 2 次、失败降级下一源；搜索全局超时约 10s。
- **权限**：`ohos.permission.INTERNET`、`ohos.permission.KEEP_BACKGROUND_RUNNING`（`DocumentViewPicker` 选文件无需额外权限）。
- **无障碍**：所有图标按钮加 `accessibilityText`；兼容系统字体缩放。
- **响应式**：断点 sm(<600vp) / md(600–840vp) / lg(>840vp)。
- **深色**：跟随系统 + 手动覆盖；阅读页独立于全局主题。
- **安全（不可信书源输入）**：
  - **v1 不支持 JS = 无任意代码执行**（相比 Legado 的安全优势，明确写入）。
  - Rust `regex` 为线性时间（无 ReDoS），但需给**单页 HTML 大小、章节长度、目录分页数、重定向次数**设上限，防畸形源打爆内存/死循环。
  - 封面/正文文件名做安全清洗，禁止路径穿越。

---

## 9. 合规与交付物

- **合规**：
  - App **不内置任何正文内容**；书源由用户自行导入；提供「法律与免责声明」页（可借鉴参考项目 `Legal`）。
  - 隐私声明：`INTERNET` + `KEEP_BACKGROUND_RUNNING`；说明「搜索关键词会发送至第三方书源站点」。
- **应用更新**：App **无法自装 HAP**，只能「检测 + 浏览器引导」——复用参考项目 `AppUpdate` 模式。
- **交付物清单**：
  - 应用图标 + 启动窗口（`resources`，参考项目 `design/`）。
  - `bundled-sources.json`（v1 兼容子集）。
  - 版本号方案 + 发版流程（版本文件 + 更新引导）。

---

## 10. 里程碑与验收标准

> 状态（随进度更新）：M0 ✅ / M1 ✅ / M2 ✅ / M3 ✅ / M4 ✅ / M5 ✅ / M6 ⏳。
> 真机验证记录见 [`docs/progress.md`](./docs/progress.md)。

| 阶段 | 内容 | 验收标准（DoD） |
|---|---|---|
| **M0（决策门）** | `legado-core` → `.so` PoC：解析 + https 网络 + 明文 HTTP + 异步 NAPI + 体积 | 真机调通 `parse` 与一次真实源搜索；https + http 均能取回内容；记录 `.so` 体积与冷启动耗时；据此确认或降级引擎路线 |
| M1 | 骨架 + Design Token（红白）+ 路由 + 三 Tab | 三 Tab 真机可切换；颜色全部走 color.json；深色可切 |
| M2 | 引擎集成（CSS/正则/变量/JSONPath）+ JS/登录门禁 + 书源导入/检测 | 导入一份真实书源 JSON 得到「成功/排除」明细；`detect` 能跑通至少 1 个真实源全链路；生成 `bundled-sources.json` |
| M3 | 搜索聚合 + 详情 + 加入书架 + 持久化 | 多源搜索渐进出结果、全局超时生效；加入书架后重启仍在；「已在书架」去重生效 |
| M4 | 阅读页（竖向滚动）+ 目录（含分页）+ 进度 + 阅读设置 | 5000 章目录滚动流畅；阅读位置跨重启恢复；字号切换后进度不错位 |
| M5 | 听书 + 系统 TTS 管线 + 后台播放 + AVSession | 锁屏可控播放；切后台不断；定时关闭生效；高亮/进度同步 |
| M6 | 规则调试器 + 缓存清理 + 备份恢复 + 打磨 | 调试器能定位失败规则；缓存占用可见可清；备份可导出再导入 |
| v2 | QuickJS/Boa JS 引擎、换源（依赖 `bookUrlPattern`）、在线 TTS、真分页 | — |

---

### M0 实机验证结果（已完成，2026-09-24）

设备：`33Z0224424136564`（HarmonyOS NEXT，API 24）

| 验证项 | 结果 |
|---|---|
| ohos-rs + `aarch64-unknown-linux-ohos` 交叉编译 | ✅ |
| `reqwest` + `rustls` + `ring` + `scraper/html5ever` 编译到 ohos | ✅ |
| 规则解析 `parse`（scraper 引擎） | ✅ `["斗破苍穹","武动乾坤"]`，1ms |
| HTTPS（rustls）真机请求 | ✅ 811ms |
| 明文 HTTP 真机请求 | ✅ 未被拦截 |
| `.so` 体积 | release 5.3MB（strip 后）；HAP 合计 5.2MB |
| 冷启动 | AppStartMetrics e2e ≈ 304ms |

**结论：引擎路线判定为 GO** —— 全面采用 Rust `legado-core` + NAPI，不启用降级方案。

工程地址：`rust/legado-core`（crate）、`entry/libs/arm64-v8a/liblegado_core.so`（产物）。
构建：`OHOS_NDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony ohrs build --arch arm64 --release`。

---

## 11. 建议目录结构

```
entry/src/main/
├── ets/
│   ├── entryability/EntryAbility.ets
│   ├── pages/            Index / BookDetail / Reader / Search / SearchResult / BookSourceManage / Settings
│   ├── components/       BookCard / ChapterList / ReaderMenu / TtsPanel / Loading / Empty / ErrorView
│   ├── engine/           IBookEngine.ets        # 端口接口
│   │                     BookEngineNapi.ets     # NAPI 实现
│   │                     types.ets              # 对齐 Rust types.rs
│   ├── model/            ShelfRepository / SourceRepository / ProgressRepository / TtsController / AppUpdate
│   ├── common/           Const / Prefs / Theme / Format / HttpCover
│   └── viewmodel/
├── resources/base|dark/element/color.json
└── cpp/  (ohos-rs 生成的 NAPI 绑定；Rust 源码在独立 crate `legado-core`)

rust/legado-core/         # 从 legado-source-filter 抽出：rule_dsl + types + http_client + 链路工具
```

---

## 12. 附录：原 HTML demo（仅结构与交互参考）

> 配色/圆角/字号一律以第 2 节 Design Token 为准；下列 demo 中的粉色渐变、`#f4f4f6`、详情页深红渐变均已废弃。

## 附录 1：书架页

> 仅作结构与交互参考，配色/圆角/字号一律以第 2 节 Design Token 为准。

```html
<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0,maximum-scale=1.0,user-scalable=no"><title>书架</title><style>*{box-sizing:border-box}body{margin:0;background:#f4f4f6;font-family:system-ui,-apple-system,"PingFang SC","Microsoft YaHei",sans-serif}button{border:0;padding:0;background:none;cursor:pointer}.container{max-width:480px;margin:0 auto}.topbar{display:flex;justify-content:space-between;align-items:center;padding:16px 20px 12px}.tabs{display:flex;gap:20px}.tab{flex:1;padding:9px 0;font-size:18px;color:#666}.tab.active{color:#1f1f1f;font-weight:bold}.book-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;padding:0 20px 140px}.book-card{display:flex;flex-direction:column}.book-cover{display:flex;flex-direction:column;align-items:center;justify-content:center;width:100%;aspect-ratio:3/4;padding:8px;text-align:center;background:linear-gradient(180deg,#f6b5c1,#eea7b4);color:#fff;border-radius:8px;box-shadow:0 6px 18px rgba(0,0,0,.16);overflow:hidden}.cover-name{font-size:15px;font-weight:500;line-height:1.375}.cover-icon{margin-top:12px}.cover-format{margin-top:8px;font-size:13px;font-weight:500}.book-title{margin-top:9px;font-size:13px;color:#1f1f1f;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}.book-progress{margin-top:4px;font-size:12px;color:#9a9a9a}.nav-fab-btn{position:fixed;right:24px;bottom:24px;z-index:50;display:flex;align-items:center;justify-content:center;width:48px;height:48px;border-radius:999px;background:linear-gradient(180deg,#f6b5c1,#eea7b4);color:#fff;box-shadow:0 6px 18px rgba(238,167,180,.45)}</style></head><body><div class="container"><div class="topbar"><div class="tabs"><div class="tab active">书架</div><div class="tab">搜索</div><div class="tab">设置</div></div><button><svg width="18" height="18" viewBox="0 0 18 18" fill="#4b5563"><circle cx="4" cy="9" r="1.6"/><circle cx="9" cy="9" r="1.6"/><circle cx="14" cy="9" r="1.6"/></svg></button></div><div class="book-grid"><div class="book-card"><div class="book-cover"><div class="cover-name">谁说我不是正经冒险者</div><svg class="cover-icon" width="42" height="52" viewBox="0 0 44 54"><path fill="#fff" fill-opacity="0.85" d="M22 8 L32 23 L27 26 L22 20 L17 26 L12 23 Z"/><path fill="#fff" fill-opacity="0.85" d="M22 26 L22 48"/></svg><div class="cover-format">-TXT-</div></div><div class="book-title">谁说我不是正经冒险者</div><div class="book-progress">已读到最新章</div></div><div class="book-card"><div class="book-cover"><div class="cover-name">大唐：李世民求我造…</div><svg class="cover-icon" width="42" height="52" viewBox="0 0 44 54"><path fill="#fff" fill-opacity="0.85" d="M22 8 L32 23 L27 26 L22 20 L17 26 L12 23 Z"/><path fill="#fff" fill-opacity="0.85" d="M22 26 L22 48"/></svg><div class="cover-format">-TXT-</div></div><div class="book-title">大唐：李世民…</div><div class="book-progress">7章/570章</div></div><div class="book-card"><div class="book-cover"><div class="cover-name">other book</div><svg class="cover-icon" width="42" height="52" viewBox="0 0 44 54"><path fill="#fff" fill-opacity="0.85" d="M22 8 L32 23 L27 26 L22 20 L17 26 L12 23 Z"/><path fill="#fff" fill-opacity="0.85" d="M22 26 L22 48"/></svg><div class="cover-format">-TXT-</div></div><div class="book-title">other book</div><div class="book-progress">未读过</div></div></div><div class="nav-fab-btn"><svg width="18" height="18" viewBox="0 0 18 18" fill="#fff"><rect x="2.5" y="9.5" width="3" height="6" rx="1"/><rect x="7.5" y="5.5" width="3" height="10" rx="1"/><rect x="12.5" y="2.5" width="3" height="13" rx="1"/></svg></div></div></body></html>
```

## 附录 2：书籍详情页

> 仅作结构与交互参考，配色/圆角/字号一律以第 2 节 Design Token 为准。

```html
<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0,maximum-scale=1.0,user-scalable=no"><title>书籍详情页</title><style>*{box-sizing:border-box}body{margin:0 auto;max-width:480px;background:#f4f4f6;line-height:1.5;font-family:system-ui,-apple-system,"PingFang SC","Microsoft YaHei",sans-serif}.header-gradient{position:relative;padding:48px 20px 36px;background:linear-gradient(160deg,#402028,#8c2c38);color:#fff}.header-top-nav{position:absolute;top:16px;left:20px;right:20px;display:flex;justify-content:space-between;align-items:center}.book-header-row{display:flex;gap:16px}.book-cover{width:120px;height:160px;border-radius:8px;overflow:hidden;box-shadow:0 4px 12px rgba(0,0,0,.25)}.book-cover img{width:100%;height:100%;object-fit:cover}.book-info h1{margin:0;font-size:28px;font-weight:bold;line-height:1.3}.book-info p{margin:0}.book-info .author{margin-top:6px;font-size:18px;opacity:.95}.content-wrap{position:relative;z-index:2;margin-top:-16px;padding:24px 20px 92px;background:#fff;border-radius:24px 24px 0 0}.section-title-row{display:flex;justify-content:space-between;align-items:center}.section-title{font-size:22px;font-weight:600}.section-right-text{font-size:15px;color:#777}.divider-line{height:1px;margin:20px 0;background:#eee}.desc-text{font-size:17px;line-height:1.7;color:#333}.bottom-action-bar{position:fixed;bottom:0;width:100%;max-width:480px;height:72px;box-sizing:border-box;z-index:10;display:flex;justify-content:space-between;align-items:center;padding:12px 20px calc(env(safe-area-inset-bottom,0px) + 12px);background:#fff;box-shadow:0 -2px 10px rgba(0,0,0,.06)}.btn-shelf{min-width:76px;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:4px;font-size:13px;color:#333}.btn-read{flex:1;max-width:180px;height:46px;display:flex;align-items:center;justify-content:center;padding:0;border:0;border-radius:999px;background:linear-gradient(180deg,#f6b5c1,#eea7b4);color:#fff;font-size:17px;font-weight:600;box-shadow:0 4px 14px rgba(229,75,88,.3)}</style></head><body><div class="header-gradient"><div class="header-top-nav"><svg width="24" height="24" viewBox="0 0 24 24"><path d="M15 5 8 12l7 7" stroke="#fff" stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg></div><div class="book-header-row"><div class="book-cover"><img src="https://p3-flow-image-sign.byteimg.com/tos-cn-i-a9rns2rl98/34001241004040089120100404404001~tplv-a9rns2rl98-image.image" alt="书籍封面"></div><div class="book-info"><h1>我的魔法没有上限！</h1><p class="author">瑟瑟发抖梨花猫</p><p>来源：番茄小说 ></p></div></div></div><div class="content-wrap"><div class="section-title-row"><div class="section-title">目录</div><div class="section-right-text">连载至538章 · 16小时前更新 ></div></div><div class="divider-line"></div><div class="desc-text">转生成异世界魔法师的泽利尔，获得了可以解锁神级天赋技能的外挂。<br>升到二级，即可从以下天赋技能之中二选一：<br>其一：【法术汹涌】</div></div><div class="bottom-action-bar"><div class="btn-shelf"><svg width="20" height="20" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9" fill="none" stroke="#e54b58" stroke-width="2"/><path d="M8 12.5l3 3 5-6" stroke="#e54b58" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg><span>已在书架</span></div><button class="btn-read">立即阅读</button></div></div></body></html>
```

## 附录 3：搜索结果页

> 仅作结构与交互参考，配色/圆角/字号一律以第 2 节 Design Token 为准。

```html
<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>小说搜索页面复刻</title><style>*{box-sizing:border-box}body{margin:0 auto;max-width:448px;background:#f4f4f4;line-height:1.5;font-family:system-ui,-apple-system,"PingFang SC","Microsoft YaHei",sans-serif}.search-bar{display:flex;align-items:center;gap:12px;padding:16px 16px 8px;margin-bottom:24px}.search-box{flex:1;display:flex;align-items:center;padding:10px 16px;background:#fff;border-radius:999px;box-shadow:0 1px 2px rgba(0,0,0,.05)}.search-icon{margin-right:8px}input{flex:1;outline:none;font-size:16px;border:0;padding:0;background:none;font-family:inherit}.book-list{display:flex;flex-direction:column;gap:20px;padding:0 16px 32px}.book-item{display:flex;gap:12px}.book-cover{width:112px;height:144px;flex-shrink:0;border-radius:4px;overflow:hidden;background:#f3f4f6;box-shadow:0 2px 8px rgba(0,0,0,.08)}.book-cover img{width:100%;height:100%;object-fit:cover}.book-info{flex:1}.book-title{margin:0;font-size:18px;font-weight:500;color:#e63946}.book-meta{margin:0;margin-top:4px;font-size:14px;color:#777}.book-desc{margin:0;margin-top:4px;font-size:14px;color:#777;display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;overflow:hidden}</style></head><body><div class="search-bar"><svg width="20" height="20" viewBox="0 0 24 24"><path d="M15 5 8 12l7 7" stroke="#1f2937" stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg><div class="search-box"><svg class="search-icon" width="16" height="16" viewBox="0 0 20 20"><circle cx="9" cy="9" r="6" stroke="#9ca3af" stroke-width="2" fill="none"/><path d="M13.5 13.5 18 18" stroke="#9ca3af" stroke-width="2" stroke-linecap="round"/></svg><input type="text" value="夜的命名术" readonly><svg width="16" height="16" viewBox="0 0 20 20"><circle cx="10" cy="10" r="7" fill="#d1d5db"/><path d="M7 7l6 6M13 7l-6 6" stroke="#fff" stroke-width="1.8" stroke-linecap="round"/></svg></div></div><div class="book-list"><div class="book-item"><div class="book-cover"><img src="https://p3-flow-image-sign.byteimg.com/tos-cn-i-a9rns2rl98/31121004109b40389220420014403111~tplv-a9rns2rl98-image.image" alt="封面"></div><div class="book-info"><h3 class="book-title">夜的命名术之第二位JOKER</h3><p class="book-meta">如鱼滑水 · 完本 · 90万字</p><p class="book-desc">壮烈、牺牲、残酷，这个世界似乎一直都是如此。许多人在创造新世界的路上前仆后继，…</p></div></div><div class="book-item"><div class="book-cover"><img src="https://p3-flow-image-sign.byteimg.com/tos-cn-i-a9rns2rl98/04012140043c40089101100120414043~tplv-a9rns2rl98-image.image" alt="封面"></div><div class="book-info"><h3 class="book-title">夜的命名术之全知读者视角</h3><p class="book-meta">筱晓亮 · 连载 · 29万字</p><p class="book-desc">【夜的命名术同人文+部分原创】。任小粟的宫殿？吕树的系统？你让我收集感谢币抽奖…</p></div></div></div></body></html>
```

## 附录 4：搜索页

> 仅作结构与交互参考，配色/圆角/字号一律以第 2 节 Design Token 为准。

```html
<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0,maximum-scale=1.0,user-scalable=no"><title>搜索</title><style>*{box-sizing:border-box}body{margin:0 auto;max-width:480px;background:#f4f4f6;line-height:1.5;font-family:system-ui,-apple-system,"PingFang SC","Microsoft YaHei",sans-serif}button{border:0;padding:0;background:none;cursor:pointer}.nav-bar{display:flex;justify-content:space-between;align-items:center;padding:16px 20px 12px}.tabs{display:flex;gap:20px}.top-tab-item{flex:1;padding:9px 0;font-size:18px;color:#666}.top-tab-item.active{color:#1f1f1f;font-weight:bold}.center-wrap{display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:calc(100vh - 70px);padding:0 20px}.big-search-box{display:flex;align-items:center;gap:12px;width:100%;padding:14px 18px;background:#fff;border-radius:999px;box-shadow:0 4px 14px rgba(0,0,0,.08)}.big-search-box input{flex:1;border:0;outline:none;font-size:16px;color:#1f1f1f;font-family:inherit;background:none}.big-search-box input::placeholder{color:#b7b7bc}.text-btn{margin-top:24px;font-size:15px;color:#e54b58}.primary-large-btn{width:100%;padding:14px 0;text-align:center;border-radius:999px;font-size:16px;font-weight:500;background:#e54b58;box-shadow:0 4px 14px rgba(0,0,0,.08)}@media(max-width:360px){.center-wrap{padding:0 16px}}</style></head><body><div class="nav-bar"><div class="tabs"><div class="top-tab-item">书架</div><div class="top-tab-item active">搜索</div><div class="top-tab-item">设置</div></div><button><svg width="18" height="18" viewBox="0 0 18 18" fill="#4b5563"><circle cx="4" cy="9" r="1.6"/><circle cx="9" cy="9" r="1.6"/><circle cx="14" cy="9" r="1.6"/></svg></button></div><div class="center-wrap"><script>const hasBookSource=true;document.write(hasBookSource?'<div class="big-search-box"><svg width="20" height="20" viewBox="0 0 20 20"><circle cx="9" cy="9" r="6" stroke="#9a9a9a" stroke-width="2" fill="none"/><path d="M13.5 13.5 18 18" stroke="#9a9a9a" stroke-width="2" stroke-linecap="round"/></svg><input type="text" placeholder="输入小说名称、作者"></div><div class="text-btn">管理书源</div>':'<div class="primary-large-btn">导入书源</div>')</script></div></body></html>
```

## 附录 5：阅读书籍页

> 仅作结构与交互参考，配色/圆角/字号一律以第 2 节 Design Token 为准。

```html
<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0,maximum-scale=1.0,user-scalable=no"><title>小说阅读页</title><style>*{-webkit-tap-highlight-color:transparent}body{margin:0;min-height:100vh;position:relative;overflow:hidden;background:#181820;color:#d1d1d6;line-height:1.5;font-family:system-ui,-apple-system,"PingFang SC","Microsoft YaHei",sans-serif}button{border:0;padding:0;background:none;cursor:pointer}.top-bar{display:flex;justify-content:space-between;align-items:center;padding:32px 20px 12px}.top-left{display:flex;align-items:center;gap:12px}.top-right{display:flex;gap:16px}.icon-btn{width:44px;height:44px;display:flex;align-items:center;justify-content:center}.icon-btn.sm{width:40px;height:40px}.chapter-title{color:#d1d5db}.read-content{padding:16px 24px}.read-content p{margin:0 0 1.2rem;font-size:19px;line-height:2.1;color:#d1d1d6;text-indent:2em}.audio-btn{position:absolute;right:20px;bottom:192px}.audio-circle{width:56px;height:56px;border-radius:999px;background:#2c2c38;display:flex;align-items:center;justify-content:center}.bottom-control{position:absolute;bottom:0;left:0;right:0;padding:20px 24px;border-radius:16px 16px 0 0;background:rgba(44,44,56,.85);backdrop-filter:blur(8px)}.progress-row{display:flex;align-items:center;gap:12px;margin-bottom:24px}.slider{position:relative;flex:1;height:12px;border-radius:999px;background:#444452}.slider-thumb{position:absolute;left:55%;top:50%;transform:translate(-50%,-50%);width:28px;height:28px;border-radius:999px;background:#fff;box-shadow:0 10px 15px -3px rgba(0,0,0,.1),0 4px 6px -4px rgba(0,0,0,.1)}.func-row{display:flex;justify-content:space-around;align-items:center}</style></head><body><div class="top-bar"><div class="top-left"><div class="icon-btn"><svg width="18" height="18" viewBox="0 0 24 24"><path d="M15 5 8 12l7 7" stroke="#fff" stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg></div><span class="chapter-title">第024章 秦王妃</span></div><div class="top-right"><div class="icon-btn"><svg width="16" height="16" viewBox="0 0 18 18" fill="#fff"><circle cx="4" cy="9" r="1.6"/><circle cx="9" cy="9" r="1.6"/><circle cx="14" cy="9" r="1.6"/></svg></div></div></div><div class="read-content"><p>“我这边还好，中央钱庄的工作就是稳步就班的进行就可以了，大的变革和变动估计很少了。倒是尚书省这边在商讨成立一个新的部门，应该是殿下您之前说过的发展和改革部，简称发改部。最近一直在开会商讨。”李嫣开口道。</p><p>“我这里也还好，大唐不夜城这边的员工都是殿下您精心培训过的，反倒是我一直得学习。”武诩也微笑着开口道。</p><p>看着李嫣和武诩，李恪突然又缓慢的陷入了沉思，李嫣是不是文成公主，李恪不太清楚，历史上没有过文成公主的出生年月日，不管是李嫣还是李歆都是有可能得，虽然</p></div><div class="audio-btn"><div class="audio-circle"><svg width="20" height="20" viewBox="0 0 24 24"><path d="M3 9v6h4l5 4V5L7 9H3z" fill="#fff"/><path d="M16.5 8.5a5 5 0 0 1 0 7M19 6a8 8 0 0 1 0 12" stroke="#fff" stroke-width="2" fill="none" stroke-linecap="round"/></svg></div></div><div class="bottom-control"><div class="progress-row"><button class="icon-btn sm"><svg width="18" height="18" viewBox="0 0 24 24"><path d="M14 5 7 12l7 7" stroke="#fff" stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg></button><div class="slider"><div class="slider-thumb"></div></div><button class="icon-btn sm"><svg width="18" height="18" viewBox="0 0 24 24"><path d="M10 5l7 7-7 7" stroke="#fff" stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg></button></div><div class="func-row"><button><svg width="20" height="20" viewBox="0 0 24 24"><path d="M4 6h16M4 12h16M4 18h16" stroke="#fff" stroke-width="2" stroke-linecap="round"/></svg></button><button><svg width="20" height="20" viewBox="0 0 24 24"><circle cx="12" cy="12" r="4.5" stroke="#fff" stroke-width="2" fill="none"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M19.1 4.9l-1.4 1.4M6.3 17.7l-1.4 1.4" stroke="#fff" stroke-width="2" stroke-linecap="round"/></svg></button><button><svg width="20" height="20" viewBox="0 0 24 24"><path d="M4 5a2 2 0 0 1 2-2h14v18H6a2 2 0 0 1-2-2V5z" fill="#fff"/></svg></button></div></div><script>const b=document.querySelector('.bottom-control'),t=document.querySelector('.top-bar'),a=document.querySelector('.audio-btn');let s=true;document.querySelector('.read-content').addEventListener('click',()=>{s=!s;b.style.display=s?'block':'none';t.style.display=s?'flex':'none';a.style.display=s?'block':'none'})</script></body></html>
```

## 附录 6：目录

> 仅作结构与交互参考，配色/圆角/字号一律以第 2 节 Design Token 为准。

```html
<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0,maximum-scale=1.0,user-scalable=no"><title>小说目录页</title><style>*{-webkit-tap-highlight-color:transparent}body{margin:0;background:#121212;color:#b8b8b8;line-height:1.5;font-family:system-ui,-apple-system,"PingFang SC","Microsoft YaHei",sans-serif}button{border:0;padding:0;background:none;cursor:pointer;font:inherit;color:inherit}.top-bar{display:flex;align-items:center;justify-content:space-between;padding:24px 20px}.top-left{display:flex;align-items:center;gap:8px}.top-left span{color:#e2e2e2}.card{background:#1e1e1e;border-radius:16px;padding:16px}.card-top{display:flex;gap:16px}.cover{width:96px;height:128px;border-radius:8px;overflow:hidden;background:#374151}.cover img{width:100%;height:100%;object-fit:cover}.book-info{flex:1;display:flex;flex-direction:column;justify-content:center}.book-title-row{display:flex;justify-content:space-between;align-items:flex-start}.book-title{margin:0;color:#e2e2e2;font-size:20px;line-height:1.25}.book-author{margin:0;margin-top:4px}.tab-row{display:flex;margin-top:20px;border-bottom:1px solid #2c2c2c}.tab-active{padding-bottom:8px;margin-right:32px;border-bottom:2px solid #ff7034;color:#e2e2e2;font-size:18px}.info-row{display:flex;justify-content:space-between;align-items:center;padding:16px 0}.chapter-item{display:flex;align-items:center;gap:8px;padding:16px 0 16px 4px;border-bottom:1px solid #2c2c2c}.chapter-name{font-size:18px;color:#b8b8b8}.chapter-name.active{color:#ff7034}.bottom-nav{position:fixed;bottom:0;left:0;right:0;display:flex;justify-content:space-around;align-items:center;padding:16px 40px;border-top:1px solid #222;background:#121212}.nav-btn{display:flex;flex-direction:column;align-items:center;gap:4px;color:#b8b8b8}.nav-btn.on{color:#e2e2e2}.nav-btn span{font-size:14px}.spacer{height:96px}</style></head><body><div class="top-bar"><div class="top-left"><svg width="20" height="20" viewBox="0 0 24 24"><path d="M14 5 7 12l7 7" stroke="#e2e2e2" stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg><span>第30章 七宗罪</span></div></div><div class="card"><div class="card-top"><div class="cover"><img src="https://p3-flow-image-sign.byteimg.com/tos-cn-i-a9rns2rl98/31121134003c40189002102010410111~tplv-a9rns2rl98-image.image" alt="书籍封面"></div><div class="book-info"><div class="book-title-row"><div><h2 class="book-title">这个世界什么时候轮到你们做…</h2><p class="book-author">灰烬寓言</p></div><svg width="20" height="20" viewBox="0 0 24 24" style="margin-top:4px"><path d="M10 5l7 7-7 7" stroke="#b8b8b8" stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg></div></div></div><div class="tab-row"><button class="tab-active">目录</button></div><div class="info-row"><span>连载至98章</span><button>倒序</button></div><div><div class="chapter-item"><svg width="16" height="16" viewBox="0 0 24 24"><circle cx="12" cy="12" r="8" stroke="#ff7034" stroke-width="2" fill="none"/><circle cx="12" cy="12" r="3" fill="#ff7034"/></svg><span class="chapter-name active">第30章 七宗罪</span></div><div class="chapter-item"><span class="chapter-name">第31章 宁宁</span></div><div class="chapter-item"><span class="chapter-name">第32章 【傲慢】</span></div><div class="chapter-item"><span class="chapter-name">第33章 叫你们老板来!</span></div><div class="chapter-item"><span class="chapter-name">第34章 开玩笑?</span></div><div class="chapter-item"><span class="chapter-name">第35章 欲望使徒</span></div><div class="chapter-item"><span class="chapter-name">第36章 阴沟里的老鼠</span></div><div class="chapter-item"><span class="chapter-name">第37章 原罪</span></div><div class="chapter-item"><span class="chapter-name">第38章 沈清月的晋升</span></div><div class="chapter-item"><span class="chapter-name">第39章 招募大学生</span></div></div></div><div class="bottom-nav"><button class="nav-btn on"><svg width="20" height="20" viewBox="0 0 24 24"><path d="M4 6h16M4 12h16M4 18h16" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg><span>目录</span></button><button class="nav-btn"><svg width="20" height="20" viewBox="0 0 24 24"><circle cx="12" cy="12" r="4.5" stroke="currentColor" stroke-width="2" fill="none"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M19.1 4.9l-1.4 1.4M6.3 17.7l-1.4 1.4" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg><span>日间</span></button><button class="nav-btn"><svg width="20" height="20" viewBox="0 0 24 24"><circle cx="12" cy="12" r="3.5" stroke="currentColor" stroke-width="2" fill="none"/><path d="M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.3 5.3l2.1 2.1M16.6 16.6l2.1 2.1M18.7 5.3l-2.1 2.1M7.4 16.6l-2.1 2.1" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg><span>设置</span></button></div><div class="spacer"></div></body></html>
```

## 附录 7：听书

> 仅作结构与交互参考，配色/圆角/字号一律以第 2 节 Design Token 为准。

```html
<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0,maximum-scale=1.0,user-scalable=no"><title>听书播放页</title><style>*{-webkit-tap-highlight-color:transparent}body{margin:0;min-height:100vh;display:flex;flex-direction:column;padding:40px 32px;background:#783843;color:#fff;line-height:1.5;font-family:system-ui,-apple-system,"PingFang SC","Microsoft YaHei",sans-serif}button{border:0;padding:0;background:none;cursor:pointer;font:inherit;color:inherit}.top-bar{width:100%;margin-bottom:24px}.cover-wrap{display:flex;justify-content:center;margin:32px 0}.book-cover{position:relative;display:flex;flex-direction:column;align-items:center;justify-content:center;width:240px;height:320px;border-radius:6px;background:#c96b7c;overflow:hidden;box-shadow:0 12px 30px rgba(0,0,0,.25)}.cover-frame{display:flex;flex-direction:column;align-items:center;justify-content:center;width:85%;height:90%;border:2px solid rgba(255,255,255,.6)}.cover-title{margin:0;color:#fff;font-size:36px;text-align:center;line-height:1.375}.cover-art{margin-top:64px;opacity:.6}.cover-format{margin:0;margin-top:-48px;color:#fff;font-size:30px}.chapter-row{margin-top:16px}.chapter-head{display:flex;justify-content:space-between;align-items:flex-start}.chapter-title{margin:0;font-size:clamp(1.8rem,6vw,2.5rem);font-weight:500}.chapter-sub{margin:0;margin-top:8px;color:#e7d9dc;font-size:18px}.progress-block{margin-top:40px}.slider{-webkit-appearance:none;width:100%;height:5px;border-radius:999px;background:rgba(255,255,255,.25)}.slider::-webkit-slider-runnable-track{height:5px;border-radius:999px}.slider::-webkit-slider-thumb{-webkit-appearance:none;width:14px;height:14px;border-radius:50%;background:#fff;cursor:pointer}.time-row{display:flex;justify-content:space-between;margin-top:12px;color:#e7d9dc;font-size:16px}.controls{display:flex;align-items:center;justify-content:space-between;margin-top:40px}.speed-btn{display:flex;flex-direction:column;align-items:center}.speed-btn span{margin-top:8px;font-size:16px}.play-btn{display:flex;align-items:center;justify-content:center;width:112px;height:112px;border-radius:999px;background:#fff}.model-row{margin-top:24px;padding:0 8px}.model-btn{display:flex;align-items:center;justify-content:space-between;width:100%;padding:16px 20px;border-radius:16px;background:rgba(255,255,255,.15);backdrop-filter:blur(12px)}.model-label{color:#fff;font-size:18px;opacity:.9}.spacer{flex:1}.safe{height:32px}</style></head><body><div class="top-bar"><svg width="24" height="24" viewBox="0 0 24 24"><path d="M5 9l7 7 7-7" stroke="#e7d9dc" stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg></div><div class="cover-wrap"><div class="book-cover"><div class="cover-frame"><p class="cover-title">大唐：李世民<br>求我造…</p><div class="cover-art"><svg width="140" height="140" viewBox="0 0 100 100"><path fill="#592b33" d="M50,70 C35,60 25,45 40,40 C55,35 65,20 70,35 C75,50 60,65 50,70Z"/></svg></div><p class="cover-format">−TXT−</p></div></div></div><div class="chapter-row"><div class="chapter-head"><div><h1 class="chapter-title">第934章 秦王妃</h1><p class="chapter-sub">大唐：李世民求我造反 作者：天下乐</p></div><svg width="30" height="30" viewBox="0 0 24 24"><path d="M8 6h13M8 12h13M8 18h13" stroke="#e7d9dc" stroke-width="2" stroke-linecap="round"/><circle cx="4" cy="6" r="1.2" fill="#e7d9dc"/><circle cx="4" cy="12" r="1.2" fill="#e7d9dc"/><circle cx="4" cy="18" r="1.2" fill="#e7d9dc"/></svg></div></div><div class="progress-block"><input type="range" min="0" max="100" value="45" class="slider"><div class="time-row"><span>03:31</span><span>08:39</span></div></div><div class="controls"><button class="speed-btn"><svg width="24" height="24" viewBox="0 0 24 24"><path d="M4 14a8 8 0 0 1 16 0" stroke="#fff" stroke-width="2" fill="none" stroke-linecap="round"/><path d="M12 14l4-4" stroke="#fff" stroke-width="2" stroke-linecap="round"/><circle cx="12" cy="14" r="1.5" fill="#fff"/></svg><span>1.0x</span></button><button><svg width="36" height="36" viewBox="0 0 24 24"><rect x="4" y="5" width="3" height="14" fill="#e7d9dc"/><path d="M19 5l-9 7 9 7V5z" fill="#e7d9dc"/></svg></button><button class="play-btn"><svg width="48" height="48" viewBox="0 0 24 24"><rect x="5" y="4" width="5" height="16" rx="1.5" fill="#783843"/><rect x="14" y="4" width="5" height="16" rx="1.5" fill="#783843"/></svg></button><button><svg width="36" height="36" viewBox="0 0 24 24"><rect x="17" y="5" width="3" height="14" fill="#e7d9dc"/><path d="M5 5l9 7-9 7V5z" fill="#e7d9dc"/></svg></button><button class="speed-btn"><svg width="24" height="24" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9" stroke="#fff" stroke-width="2" fill="none"/><path d="M12 7v5l3 2" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg></button></div><div class="model-row"><button class="model-btn"><span class="model-label">朗读音色·端逸师兄</span><svg width="20" height="20" viewBox="0 0 24 24"><path d="M20 12a8 8 0 1 1-2.3-5.6M20 3v4h-4" stroke="rgba(255,255,255,.7)" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg></button></div><div class="spacer"></div><div class="safe"></div></body></html>
```

## 附录 8：设置页

> 仅作结构与交互参考，配色/圆角/字号一律以第 2 节 Design Token 为准。

```html
<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0,maximum-scale=1.0,user-scalable=no"><title>设置页面</title><style>*,*:before,*:after{box-sizing:border-box}*{-webkit-tap-highlight-color:transparent}body{margin:0;min-height:100vh;background:#eee;color:#111;line-height:1.5;font-family:system-ui,-apple-system,"PingFang SC","Microsoft YaHei",sans-serif}button{border:0;padding:0;background:none;cursor:pointer;font:inherit;color:inherit}.top-bar{display:flex;align-items:center;position:relative;padding:20px 16px;background:#eee}.top-bar h1{position:absolute;left:50%;transform:translateX(-50%);margin:0;font-size:20px;font-weight:500}.card{margin-left:16px;margin-right:16px;overflow:hidden;border-radius:16px;background:#fff}.card+.card{margin-top:16px}.cell{display:flex;align-items:center;justify-content:space-between;padding:20px;border-bottom:1px solid #f3f4f6}.cell-label{font-size:20px}.cell-sub{margin:0;margin-top:4px;color:#757575;font-size:16px}.spacer{height:40px}</style></head><body><div class="top-bar"><button><svg width="24" height="24" viewBox="0 0 24 24"><path d="M15 5l-7 7 7 7" stroke="#111" stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg></button><h1>设置</h1></div><div class="card"><div class="cell"><span class="cell-label">阅读设置</span><svg width="20" height="20" viewBox="0 0 24 24"><path d="M9 5l7 7-7 7" stroke="#757575" stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg></div><div class="cell"><span class="cell-label">听书设置</span><svg width="20" height="20" viewBox="0 0 24 24"><path d="M9 5l7 7-7 7" stroke="#757575" stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg></div><div class="cell"><span class="cell-label">书源设置</span><svg width="20" height="20" viewBox="0 0 24 24"><path d="M9 5l7 7-7 7" stroke="#757575" stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg></div><div class="cell"><div><span class="cell-label">通用设置</span><p class="cell-sub">夜间模式</p></div><svg width="20" height="20" viewBox="0 0 24 24"><path d="M9 5l7 7-7 7" stroke="#757575" stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg></div></div><div class="card"><div class="cell"><span class="cell-label">清除缓存</span><svg width="20" height="20" viewBox="0 0 24 24"><path d="M9 5l7 7-7 7" stroke="#757575" stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg></div><div class="cell"><span class="cell-label">应用更新</span><span class="cell-label">已是最新</span></div></div><div class="card"><div class="cell"><span class="cell-label">应用版本</span><span class="cell-label">1.0.0</span></div><div class="cell"><span class="cell-label">书源来源</span><span class="cell-label">xxx/legado-source</span></div><div class="cell"><span class="cell-label">作者</span><span class="cell-label">lichtcui</span></div><div class="cell"><span class="cell-label">GitHub</span><span class="cell-label">lichtcui/source-reader</span></div><div class="cell"><span class="cell-label">法律与免责声明</span><svg width="20" height="20" viewBox="0 0 24 24"><path d="M9 5l7 7-7 7" stroke="#757575" stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg></div></div><div class="spacer"></div></body></html>
```

---

## 13. 修订清单（相对原始原型说明）

**引擎 / 正确性**
1. 搜索提取器从 4 字段扩展到 7 字段（补 intro/kind/wordCount/lastChapter）
2. `content()` 语义 = 多段拼接 + `nextContentUrl` 分页（整章）
3. 目录分页 `nextTocUrl` + 卷 `isVolume` 支持（补 `TocRule` 字段）
4. JS 三级策略 + `resolve_js_l1`（L1 可解析）
5. 拆 `legado-core` crate，剔除 CLI/DB/Node
6. `content_check` 运行时/检测双拆（`JsEvaluator` trait + feature 门控）

**网络 / 安全**
7. 每源 Cookie 隔离（每源 Client + 上限/LRU，v1 仅内存）
8. 删除 `danger_accept_invalid_certs`
9. UA 可配置
10. M0 验证明文 HTTP 放行
11. 封面由 Rust 代下（带 header/Cookie，走文件缓存）

**边界 / 一致**
12. 详情页来源只读（v1 无换源）
13. 搜索 → 书架去重
14. NAPI 返回每源错误状态 + 调试器/检测可发请求
15. 搜索渐进返回 + 全局超时
16. 引擎懒加载（启动预算）
17. TTS 阅读位置同步

**工程 / 交付**
18. 内置 `bundled-sources.json`（v1 兼容子集，非原始 filtered.json）
19. 复用 `FailReason` / `preflight` / `bookUrlPattern`
20. 合规免责 + 隐私声明
21. App 自更新用浏览器引导
22. ohos-rs 构建链前置（含 `.so` 集成 hvigor）

**设计**
23. 红白令牌（红系轻渐变 + 白底 `#ffffff`）
24. V2 状态管理

**补充（第五、六轮）**
25. 规则「静默失败」诊断（Java 正则/Rust 正则差异、CSS 解析失败）
26. 安全/健壮性章节（无 JS 优势、资源上限、路径清洗）
27. 里程碑验收标准 / 交付物 / 目录结构 / 备份版本号 / 书源更新机制
