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

## NAPI 接口（语义）

**签名不在这里重复**：以 `entry/src/main/cpp/types/liblegado_core/index.d.ts` 为唯一真源。
那份 .d.ts **由 `ohrs build` 从 `rust/legado-core/src/lib.rs` 的 `///` doc comment 生成**，
所以**要改接口说明就改 Rust 的 `///`**（改完 `make rust` 会自动把新 .d.ts 拷到 entry 下），
本节只写「每个函数保证什么」——也就是 doc comment 装不下的部分。
万一两边不一致，以 Rust 侧为准（并顺手修本节）。

要点：

- 10 个导出：`parse` / `parseWithDiagnostics` / `fetchText` / `gateSources` / `search` /
  `bookInfo` / `toc` / `content` / `detect` / `downloadCover`；参数与返回类型看 `index.d.ts`。
- **粗粒度 JSON 进出**；失败以 NAPI error（reject）返回 `reason` key，ArkTS 侧 `FailReason` 文案映射。
- `search`：按源并发（默认 8）+ 每源超时（默认 10s），返回每源 `SourceStatus`（ok/count/error/elapsedMs）。
- `toc`：内部走 `nextTocUrl` 分页（上限 50、自引用防环）+ 卷 `isVolume` 跳过。
- `content`：内部走 `nextContentUrl` 翻页（上限 30、自引用防环）拼成**整章**。
- `detect`：`mode="full"`（缺省，未知值也回退到此档）走搜索 → 详情 → 目录 → 首章正文，含
  「详情页书名 ≠ 搜索结果」一致性校验；`mode="probe"` 在搜索命中后早退，只发 1 次请求并返回
  `stage="search"` / `contentLen=0`。probe 未命中仍是 `stage="no_results"`，不是 `unavailable`。
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
- **`text.关键字` 文本定位器**（2026-10-11 修）：DSL 曾只认 `class.` / `id.` / `tag.`，`text.下一页@href` 被当成 CSS 选择器 →
  **0 结果且无诊断**（静默失败）→ 目录/正文翻页在第一页后停止（《剑来》目录 50 条 vs 实际 1308 章；8/13 内置源命中）。
  现 `RuleToken::TextContains` + `html_extractor::apply_text_filter`：按 Legado 语义取「**自身文本**包含关键字」的元素（大小写不敏感），
  `json_extractor` / `diagnose` 不受影响。详见 [`bugfix/TASKS.md`](./bugfix/TASKS.md) §T-READ-4。
- **known_gaps（相对 Legado 官方语义）**：负索引、区间选取、`&&`、`children`、`ownText/all` 未支持。

## JSON 契约（跨 NAPI / 落盘的字段名）

引擎与 ArkTS 之间传的是 **serde JSON**，字段名即契约。新增/改名一个字段要同步**三处**：

1. `rust/legado-engine/src/types.rs` 的 struct（`camelCase`，字段名就是 JSON key）；
2. `entry/src/main/ets/engine/types.ets` 的 interface（同一份类型给 ArkTS 用）；
3. `entry/obfuscation-rules.txt` 的 `-keep-property-name`（release 开了属性混淆，漏了 → release 读到
   `undefined`，debug 一切正常）。

第 2、3 步由 `make check`（`scripts/check-keep-props.sh`）机械核对：它扫描 `types.ets` 与所有含
`JSON.parse/stringify` 的 `.ets` 里的 interface 字段（备份文件、章节/目录缓存、进度），缺一个就报错。
`BookSource` 用 `#[serde(flatten)] extra` 透传未识别字段，保证导入导出 round-trip 不掉规则。

已知的**不一致**（非 bug，但会让你白查半天）：

- ArkTS 的 `Chapter` 多声明了 `bookId`，**引擎返回的章节没有这个字段**（只有本地导入的书会填它）；
- 详情页的书名/作者取自搜索结果：部分源压根没写 `ruleBookInfo.name/author`，`make probe info` 打印空串是正常的。

## 主机侧调试：`make probe`（不上真机）

改规则 DSL / URL 模板 / 门禁 / 编码时先在这里秒级验证，不要每轮都走真机：

```bash
make probe ARGS='entry/src/main/resources/rawfile/bundled-sources.json gate'
make probe ARGS='源.json search 剑来 --limit 3'
make probe ARGS='源.json detect 剑来 --mode probe'   # L1：只跑搜索，1 次请求后早退
make probe ARGS='源.json detect 剑来 --mode full'    # L2：搜索→详情→目录→正文（缺省也是 full）
make probe ARGS='源.json parse html "id.bookintro@tag.p@text" < page.html'
```

默认只打摘要（样本条数、字数、前 200 字），`--json` 才 dump 完整 JSON；`--index N` 选源，`--timeout`/`--concurrency` 可调；
`detect --mode probe|full` 直接走引擎两档，缺省 `full`。
完整命令表在 `rust/legado-engine/examples/probe.rs` 头部。网络全在 Rust 侧，与 App 同一条链路（含 header/Cookie/限速/编码）。

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
2. 重新构建：`make rust`（先看 `docs/engine.md` §JSON 契约，新增字段别忘了 keep 列表）。
3. `make rust` 已把生成的 `dist/index.d.ts` 拷到 `entry/src/main/cpp/types/liblegado_core/index.d.ts`（勿手改）。
4. 拷贝 `.so` 到 `entry/libs/arm64-v8a/` 一并完成；再 `make run` 上真机。
