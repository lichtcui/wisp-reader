# 技术决策记录（ADR 摘要）

> 决策**已定**，勿擅改。改动任一决策前先在这里查有没有反对理由。
> **禁令类**（「不要做什么」）留在 [`../AGENTS.md`](../AGENTS.md) §项目禁令；本文件记「选了什么 + 为什么」。

| # | 决策 | 理由 | 影响面 |
|---|---|---|---|
| D1 | 引擎复用 Rust：`rust/legado-engine`（纯核心）+ `rust/legado-core`（NAPI 壳）+ `ohos-rs`，**不降级** | 复用 `legado-source-filter` 已有规则引擎与链路校验，避免在 ArkTS 重写一遍 | `rust/`、`engine/` |
| D2 | Rust 持有 HTTP：`reqwest` + `rustls`；每源独立 `Client`（Cookie 隔离，上限 64 后回收）+ `concurrentRate` 限速；**禁用证书放行** | 书源各自需要独立 Cookie/UA/限速；rustls 免 OpenSSL 交叉编译 | `http_client.rs` |
| D3 | 书源持久化用 `preferences` JSON（`SourceRepository`）；书籍/进度用 `relationalStore`（`ShelfRepository`，表 `books`/`progress`） | 书源是低频小数据；书架需要查询与事务 | `model/` |
| D4 | 搜索调度：ArkTS 滑动窗口（并发 8）+ **书源置信度**排序（`confidence` 字段持久化：`server_error`/`timeout`/`network_error`/`blocked` 扣分，成功回分） | 端侧无全局调度器；置信度让劣质源自动下沉 | `SearchResult.ets`、`SourceConfidence.ets` |
| D5 | 阅读排版：**横向分页翻页**（Swiper + `measureTextSize` 精确分页，跨章连续滑动） | 接近实体书体验；跨章预取已在 M4 打通 | `Reader.ets` |
| D6 | 封面由 Rust 代下（带 header/Cookie），落盘后 ArkTS 加载（二进制不过 NAPI） | 部分站点封面需 Cookie/Referer | `downloadCover` |
| D7 | 状态管理 **V2**（`@ComponentV2` / `@Local` / `@Param` / `@Monitor`）；跨页 `AppStorageV2`、跨启动 `PersistenceV2` | 与既有页面一致（V1/V2 不可混用于同一组件） | 全部 UI |
| D8 | 视觉：白 + 红（`#DA3838`，红系轻渐变 `#e35a5a → #da3838`），颜色走 `resources/{base,dark}/element/color.json` 令牌化 | 参考 `harmony-pokerouge` | 全部 UI |
| D9 | bundle `com.lichtcui.sourcereader`；`compatibleSdkVersion 5.0.0(12)` / `targetSdkVersion 6.1.1(24)` | 目标设备与 SDK 约束 | `AppScope`、`build-profile.json5` |
| D10 | JS 例外：`@js:` 的 **L1 字符串模式**仍走 `resolve_js_l1` 解析，失败才排除（非 L1 才直接排除）；v1 不做 JS 运行时 | 内置 13 个源里有 L1 用法，一律砍掉会误伤 | `search_url.rs`、`gate.rs` |
| D11 | v1 不做：JS 运行时、登录型源、换源、发现(explore)、真分页、在线 TTS | 控制范围，先跑通主链路 | 全局 |
| D12 | 端侧自建 TTS（GPT-SoVITS 音色替代系统 TTS）是**并行增量**、未立项，不改动 M5 代码 | 与 M5 系统 TTS 路线不冲突，可独立推进 | [`research/TTS-PLAN.md`](./research/TTS-PLAN.md) |
| D13 | 门禁只在导入时做（`gate::run`）：非文字/禁用/登录/JS 源排除，可选字段含 JS 则**降级丢规则**而非排除整源 | 保源数量与可用性平衡（13 源 filter 后保留） | `gate.rs` |

## 已知取舍（相对 Legado 官方语义）

`known_gaps`：负索引、区间选取、`&&`、`children`、`ownText/all` 未支持。见 [`engine.md`](./engine.md) §已发现 / 已修的坑。

## 参考项目

- 引擎来源：`~/Documents/playground/legado-source-filter`（Rust，含完整规则引擎 / 链路校验）
- 视觉参考：`~/Documents/playground/harmony-pokerouge`（HarmonyOS，白 + 红）
