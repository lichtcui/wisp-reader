# 架构

## 技术栈

| 层 | 选型 |
|---|---|
| 框架 | ArkTS + ArkUI 声明式（Stage 模型） |
| 路由 | `Navigation` + `NavPathStack`（不用已废弃的 `@ohos.router`） |
| 状态 | `@ComponentV2` + `@Local/@Param/@Monitor`；跨页 `AppStorageV2`；跨启动 `PersistenceV2` |
| 网络 | **Rust 侧** `reqwest` + rustls（ArkTS 不发书源请求） |
| 引擎 | Rust `legado-core` → `.so`（ohos-rs）+ NAPI |
| 持久化 | `@ohos.data.preferences` + `@ohos.data.relationalStore` |
| TTS/播放 | Core Speech Kit `textToSpeech` → `AudioRenderer`/`AVPlayer` → `AVSession` + `backgroundTaskManager` |
| API | `compatibleSdkVersion 5.0.0(12)` / `targetSdkVersion 6.1.1(24)` |

## 分层

```
ArkTS（UI / 状态 / 持久化 / TTS / 播放）
  │  IBookEngine 端口（ArkTS 接口，便于替换实现）
  │  NAPI（粗粒度、异步 Promise，JSON 进出）
legado-core（规则解析 / HTML·JSON 提取 / HTTP / Cookie / 限速 / 正文清洗）
```

- **端口隔离**：ArkTS 只依赖 `IBookEngine`，Rust 实现藏在后面；native 受阻时可整体替换而不动 UI。
- **开发内循环**：规则调试/回归在桌面用 `legado-source-filter` 的 CLI 完成，不依赖真机。
- **懒加载**：`.so` / 运行时在首次进搜索/阅读时初始化，避免拖慢书架首屏。

## NAPI 接口

**签名唯一真源**：`entry/src/main/cpp/types/liblegado_core/index.d.ts`。该文件由 `ohrs build` 从
`rust/legado-core/src/lib.rs` 的 `///` doc comment 生成（`make rust` 会一并拷贝），**勿手改**。
本文件与 [`engine.md`](./engine.md) **不再粘贴签名列表**，只写「边界契约」与「语义」。

- 当前导出（10 个）：`parse` / `parseWithDiagnostics` / `fetchText` / `gateSources` / `search` /
  `bookInfo` / `toc` / `content` / `detect` / `downloadCover`。
- ArkTS `engine/BookEngineNapi.ets` 实现 `IBookEngine`，把 JSON 字符串解析为类型化对象。
- 尚未实现：`search` 的「流式渐进进度」回调（当前一次返回 + 每源超时）。

要点（边界契约，改引擎时必须遵守）：
- **粗粒度**：输入完整 JSON，返回结构化；禁止按字段跨语言回调。
- **异步**：Rust 内跑 tokio 工作线程（`search`/`detect` 用 `buffer_unordered` 限并发 + 超时）。
- **二进制不过 NAPI**：封面由 Rust 写沙箱文件，返回路径，ArkTS 用 `PixelMap` 加载。
- **逐函数语义 / 错误码 / 分页与限流规则** → [`engine.md`](./engine.md)。

## 领域模型（对齐 Rust `types.rs`）

`BookSource` / `Book` / `Chapter` / `ReadProgress` / `ChapterCache`。
- `Book.bookId = hash(normalize(sourceUrl + bookUrl))`。
- 进度用 `paragraphIndex + charOffset`（与字号无关）。
- 书架进度三态：无进度→「未读过」；`chapterIndex >= toc.length-1`→「已读到最新章」；否则 `{i+1}章/{total}章`。
  （实现**不读目录**，`total` 由 `percent = (chapterIndex+1)/toc.length` 反推——与 `toc.length` 直读的差异、以及陈旧快照的后果见
  [`bugfix/TASKS.md`](./bugfix/TASKS.md) T-SHELF-6；反推的边界口径见 `common/Format.ets::deriveTotalChapters`。）

## 页面与路由

```
MainPage (Tabs)
 ├─ 书架 → BookDetailPage → ReaderPage
 │                           ├─ 目录 bindSheet
 │                           ├─ 阅读设置 bindSheet
 │                           └─ 听书 bindContentCover
 ├─ 搜索 → SearchResultPage / BookSourceManagePage
 └─ 设置 → 阅读/听书/书源/通用 + 关于
```

## 设计规范（红白，见 plan §2）

- 品牌红 `#da3838`（轻渐变 `#e35a5a → #da3838`），白底 `#ffffff`，卡片 `#f7f7f7`。
- 中性色阶 `#333/#666/#888/#999/#bbb/#ccc/#ededed/#f2f2f2`。
- 所有颜色走 `resources/{base,dark}/element/color.json` 令牌化。
- 参考项目：`~/Documents/playground/harmony-pokerouge`（白+红、扁平、iOS 分组列表）。

## 目录结构（当前）

```
AGENTS.md / README.md        根目录只放这两个文档（其余文档一律进 docs/）
Makefile / scripts/         命令统一入口（`make help`）/ 工具脚本（`docs-toc.sh`）
docs/                        plan / progress / architecture / engine / development /
                             PITFALLS / decisions；specs/ / research/ / bugfix/ / handoff/ /
                             archive/（已完结历史，**默认不读**）
build-profile.json5          含 signingConfigs（**含凭据，勿提交**）
.cargo/config.toml           cargo 镜像（rsproxy）
entry/
  libs/arm64-v8a/liblegado_core.so        native 产物
  src/main/module.json5                   权限 INTERNET / KEEP_BACKGROUND_RUNNING
  src/main/ets/
    entryability/  EntryAbility
    pages/         Index / Shelf / Search / SearchResult / BookDetail / Reader / Listening /
                   ListeningSettings / BookSourceManage / Settings / ReadingSettings /
                   GeneralSettings / CacheManage / BackupManage / RuleDebugger
    ui/common/     BottomDrawer（唯一抽屉实现）/ AppBackButton / FloatingListenButton / MoreMenuButton
    engine/        IBookEngine（端口）+ BookEngineNapi + types
    model/         SourceRepository / ShelfRepository / CacheRepository / SourceConfidence /
                   BookContent / ChapterCache / TocCache / LocalBook / BookRemoval /
                   ShelfEditState / ProgressOwner / TtsController / RemoteTtsClient
    common/        Const（含 ROUTE_*）/ Format / Prefs / Theme / ReaderTheme / Window /
                   ChapterUtil / ChapterDataSource / SourceListDataSource
    components/    EmptyView / ListCells / BookCover
  src/main/cpp/types/liblegado_core/      NAPI 类型声明
  src/main/resources/rawfile/bundled-sources.json   v1 兼容内置源（13 个）
rust/legado-engine/  纯 Rust 核心（可主机 cargo test）+ examples/bundled_gen.rs
rust/legado-core/    薄 NAPI 层（cdylib），依赖 legado-engine
```

> 目录会随迭代变化；**权威以 `rg --files` 为准**，本表只用于定位。

## 改动定位（改什么 → 动哪些文件）

> 先在这里定位，再读文件；避免“先全仓搜一遍”。路径都相对 `entry/src/main/ets/`（Rust/资源另标）。

| 你要改什么 | 动哪些文件（先读） |
|---|---|
| 底部抽屉（样式/高度/打开方式） | **先读 [`specs/UI-SPEC.md`](./specs/UI-SPEC.md)**；`ui/common/BottomDrawer.ets`（唯一实现）+ 7 处调用点 |
| 阅读页翻页 / 分页测算 / 排版 / 字号行距 | `pages/Reader.ets`（顶部有文件索引）、`common/ReaderTheme.ets`、`common/ChapterDataSource.ets` |
| 听书 / 播放 / 锁屏卡片 / 后台 / 音色 | `model/TtsController.ets`（顶部有文件索引）、`pages/Listening.ets`、`pages/ListeningSettings.ets`、`model/RemoteTtsClient.ets`、`model/BookContent.ets`、`entryability/EntryAbility.ets`（退出释放）、`src/main/module.json5`（`backgroundModes`） |
| 搜索结果页 / 来源抽屉 / 书源置信度 | `pages/SearchResult.ets`（顶部有文件索引）、`model/SourceConfidence.ets`、`common/SourceListDataSource.ets` |
| 书架 / 编辑模式（多选删除）/ 进度 | `pages/Shelf.ets`、`model/ShelfRepository.ets`、`model/ShelfEditState.ets`、`model/BookRemoval.ets`、`components/BookCover.ets` |
| 进度写归属（阅读 ↔ 听书互不覆盖） | `model/ProgressOwner.ets`（纯状态仲裁：`claim/release/canWrite/forget`）、`model/ShelfRepository.ets`（`saveProgress(p, writer)` 唯一写口）、`model/TtsController.ets`（`setPlaying` 起播 claim / 停播 release） |
| 路由 / 页面注册 / 顶栏底栏 | `pages/Index.ets`、`common/Const.ets`（`ROUTE_*`） |
| 书源导入 / 能力门禁（非文字/禁用/登录/JS） | `rust/legado-engine/src/gate.rs`、`pages/BookSourceManage.ets`、`model/SourceRepository.ets`、`src/main/resources/rawfile/bundled-sources.json` |
| 规则 DSL / HTML·JSON 提取 | `rust/legado-engine/src/rule_dsl/*`、`rust/legado-engine/examples/bundled_gen.rs` |
| 搜索 URL / header / `@js:` 的 L1 字符串模式 | `rust/legado-engine/src/search_url.rs` |
| 网络 / Cookie / 限速 / 编码探测 | `rust/legado-engine/src/http_client.rs` |
| **NAPI 接口（增删函数/改返回 JSON）** | `rust/legado-core/src/lib.rs`（签名 + `///` doc comment → 生成 `index.d.ts`）；ArkTS 侧 `engine/IBookEngine.ets`、`engine/BookEngineNapi.ets`、`engine/types.ets` |
| 缓存（章节/目录/清理） | `model/ChapterCache.ets`、`model/TocCache.ets`、`model/CacheRepository.ets`、`pages/CacheManage.ets` |
| 备份恢复 / 本地书 | `pages/BackupManage.ets`、`model/LocalBook.ets` |
| 规则调试器（已实现） | `pages/RuleDebugger.ets` |
| 颜色 / Design Token | `src/main/resources/{base,dark}/element/color.json`；规范见 [`plan.md`](./plan.md) §2 |
| 权限 / SDK 版本 / bundle / 混淆 | `src/main/module.json5`、`AppScope/app.json5`、`build-profile.json5`、`entry/obfuscation-rules.txt` |

改完的必走闭环：`make run`（编译 → 安装 → force-stop → 启动）；Rust 侧先 `make test`。
踩坑按症状查 [`PITFALLS.md`](./PITFALLS.md)。