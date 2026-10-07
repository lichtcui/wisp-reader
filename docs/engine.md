# 引擎（legado-core / legado-engine）

Rust 书源规则引擎，经 ohos-rs 编译为 `liblegado_core.so`，ArkTS 通过 NAPI 调用。
代码来源：`~/Documents/playground/legado-source-filter`（已有完整规则引擎与链路校验）。

## crate 结构（M2 拆分）

```
rust/
├── legado-engine/          纯 Rust 核心（无 NAPI，可在主机上 cargo test）
│   ├── src/
│   │   ├── lib.rs          parse/fetch_text 门面
│   │   ├── types.rs        BookSource / 各 Rule / 运行时输出模型 / concurrentRate
│   │   ├── status.rs       FailReason / fail_message
│   │   ├── url_fixer.rs    bookSourceUrl 修复 + 域名归一化
│   │   ├── search_url.rs   {{key}}/POST/resolve_js_l1/header/URL 解析
│   │   ├── http_client.rs  reqwest+rustls、每源 Client（Cookie 隔离）、编码探测、限速
│   │   ├── preflight.rs    （并入 gate.rs）
│   │   ├── gate.rs         v1 导入门禁（非文字/禁用/登录/JS）
│   │   ├── runtime.rs      search / book_info / toc / content / detect / cover
│   │   └── rule_dsl/       parser / html_extractor / json_extractor / combinator
│   └── examples/bundled_gen.rs   生成 bundled-sources.json
└── legado-core/            薄 NAPI 层（cdylib），依赖 legado-engine
    └── src/lib.rs          #[napi] 导出（JSON 进出）
```

- 原单 crate 拆成「纯核心 + NAPI 壳」：核心可在 macOS 上 `cargo test`（含 mock 服务器端到端测试），
  且 `bundled_gen` 与 App 导入共用**同一份**门禁实现。
- 依赖：`napi-ohos`/`napi-derive-ohos`/`napi-build-ohos`（v1.2）、`scraper 0.22`、`serde`/`serde_json`、
  `regex`、`reqwest 0.12`（`rustls-tls` + `gzip` + `cookies`）、`chardetng`、`encoding_rs`、`url`、`futures`。

## NAPI 接口（M2）

```ts
import * from 'liblegado_core.so';
parse(content, contentType, rule): string[]                 // 旧接口，保留
parseWithDiagnostics(content, contentType, rule): string    // JSON { values, diagnostics }
fetchText(url): Promise<string>
gateSources(sourcesJson): string                             // JSON { total, eligible, excluded }
search(sourcesJson, keyword, optsJson): Promise<string>      // JSON { items, sources }
bookInfo(sourceJson, bookUrl): Promise<string>               // JSON BookInfo
toc(sourceJson, tocUrl): Promise<string>                     // JSON Chapter[]
content(sourceJson, chapterUrl): Promise<string>             // JSON { content, nextUrl }
detect(sourcesJson, optsJson): Promise<string>               // JSON DetectResult[]
downloadCover(sourceJson, coverUrl, destDir): Promise<string>
```

要点：

- **粗粒度 JSON 进出**；失败以 NAPI error（reject）返回 `reason` key，ArkTS 侧 `FailReason` 文案映射。
- `search`：按源并发（默认 8）+ 每源超时（默认 10s），返回每源 `SourceStatus`（ok/count/error/elapsedMs）。
- `toc`：内部走 `nextTocUrl` 分页（上限 50、自引用防环）+ 卷 `isVolume` 跳过。
- `content`：内部走 `nextContentUrl` 翻页（上限 30、自引用防环）拼成**整章**。
- `detect`：搜索 → 详情 → 目录 → 首章正文，含「详情页书名 ≠ 搜索结果」一致性校验。
- **二进制不过 NAPI**：封面由 Rust 下载写入沙箱目录，返回文件路径。

## v1 能力门禁（`gate::run`）

1. 仅保留 `bookSourceType == 0` 且 `enabled`。
2. `bookSourceUrl` 可修复（`url_fixer`），否则排除。
3. 登录源排除：`loginUrl` / `loginUi` / `loginCheckJs` 非空 → `needs_login`。
4. JS 排除：
   - `searchUrl` 含 `<js>` → `needs_js`；
   - `searchUrl` 为 `@js:` → 先走 `resolve_js_l1`（L1 字符串模式），失败才排除；
   - 关键字段 JS（`ruleSearch.bookList/name/bookUrl`、`ruleToc`、`ruleContent`）→ `needs_js`；
   - 可选字段（`coverUrl/intro/kind/lastChapter/wordCount`、`ruleBookInfo.coverUrl/tocUrl`）含 JS → **降级**（丢弃该规则）。
5. 缺 `ruleSearch` / `ruleToc.chapterList` / `ruleContent.content` → 对应 `no_*` 原因。

## 已发现 / 已修的坑

- **搜索提取器扩展**：`extract_search_items` 现已返回 8 字段（name/author/bookUrl/coverUrl/intro/kind/wordCount/lastChapter）。
- **`@js:` L1 丢 keyword**（原实现只取路径不拼关键词）已在 `resolve_js_l1` 修复。
- **诊断**：`diagnose` 收集 regex 编译失败（Java lookaround）、CSS 解析失败、JS 规则，随 `parseWithDiagnostics` 返回。
- **安全红线**：`danger_accept_invalid_certs` 已移除；每源独立 `Client`（Cookie 隔离，上限 64 后整体回收）+ `concurrentRate` 限速。
- **known_gaps（相对 Legado 官方语义）**：负索引、区间选取、`&&`、`children`、`ownText/all` 未支持。

## 生成内置书源

```bash
cd rust/legado-engine
cargo run --example bundled_gen -- \
  ~/Documents/playground/legado-source-filter/output/filtered.json \
  ../../entry/src/main/resources/rawfile/bundled-sources.json
# filtered.json 17 → 保留 13（排除 4 需登录）
```

## 新增一个 NAPI 导出

1. 在 `rust/legado-core/src/lib.rs` 加函数，标 `#[napi]`；异步用 `async fn`。
2. 重新构建：`ohrs build --arch arm64 --release`（见 [`development.md`](./development.md)）。
3. 用生成的 `dist/index.d.ts` 更新 `entry/src/main/cpp/types/liblegado_core/index.d.ts`。
4. 拷贝 `.so` 到 `entry/libs/arm64-v8a/`，重编 HAP。