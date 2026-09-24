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

### 当前（M2）

```ts
import {
  parse, parseWithDiagnostics, fetchText,
  gateSources, search, bookInfo, toc, content, detect, downloadCover
} from 'liblegado_core.so';

parse(content, contentType, rule): string[]                         // 同步
parseWithDiagnostics(content, contentType, rule): string            // { values, diagnostics }
gateSources(sourcesJson): string                                    // { total, eligible, excluded }
search(sourcesJson, keyword, optsJson): Promise<string>            // { items, sources }
bookInfo(sourceJson, bookUrl): Promise<string>                     // BookInfo
toc(sourceJson, tocUrl): Promise<string>                           // Chapter[]（内部 nextTocUrl 分页 + 卷）
content(sourceJson, chapterUrl): Promise<string>                   // { content, nextUrl }（内部拼整章）
detect(sourcesJson, optsJson): Promise<string>                     // DetectResult[]
downloadCover(sourceJson, coverUrl, destDir): Promise<string>      // 落盘路径
fetchText(url): Promise<string>
```

- ArkTS `engine/BookEngineNapi.ets` 实现 `IBookEngine`，把 JSON 字符串解析为类型化对象。
- 尚未实现：`search` 的「流式进度」回调（当前一次返回 + 每源超时，M3 再做渐进）。

要点：
- **粗粒度**：输入完整 JSON，返回结构化；禁止按字段跨语言回调。
- **异步**：Rust 内跑 tokio 工作线程（`search`/`detect` 用 `buffer_unordered` 限并发 + 超时）。
- **二进制不过 NAPI**：封面由 Rust 写沙箱文件，返回路径，ArkTS 用 `PixelMap` 加载。

## 领域模型（对齐 Rust `types.rs`）

`BookSource` / `Book` / `Chapter` / `ReadProgress` / `ChapterCache`。
- `Book.bookId = hash(normalize(sourceUrl + bookUrl))`。
- 进度用 `paragraphIndex + charOffset`（与字号无关）。
- 书架进度三态：无进度→「未读过」；`chapterIndex >= toc.length-1`→「已读到最新章」；否则 `{i+1}章/{total}章`。

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

## 目录结构（目标，见 plan §11）

```
entry/src/main/ets/
  pages/ components/ engine/ model/ common/ viewmodel/
entry/src/main/cpp/types/liblegado_core/   NAPI 类型声明
rust/legado-core/                          Rust 引擎 crate
```