# SPEC — `detect-engine`

状态：**待批准（draft）** · 归属：[`SPEC-BOOKSOURCE-REVAMP.md`](./SPEC-BOOKSOURCE-REVAMP.md) 模块 `detect-engine`
Commands / Project Structure / Code Style / Testing Strategy / Boundaries 见 map 文件 §4–§8，本文只写本模块特有内容。

## Objective

把单轮检测的时长从**小时级降到十数分钟级**，并让「源可用性」这类数据变得可持久化、可用于筛选。

这是本次改造里杠杆最大的一环：现状每源要跑 `搜索 → 详情 → 目录 → 首章正文` 至少 4 次网络请求
（`rust/legado-engine/src/runtime.rs:479+` 的 `detect_chain`），3000 源下最坏 9.4 小时。

## Non-goals

- 不改搜索链路本身的规则语义（`search_one` / `detect_chain` 的解析逻辑不动）。
- 不在引擎里做分批调度、进度上报或取消（那是 `detect-job` 的职责）。引擎保持无状态、一次调用一
  个输入集合，这是它现在能被 `make probe` 主机直跑的原因，不要破坏。
- 不引入持久化（引擎不碰磁盘）。

## 关键设计决策

**1. 两档检测（分层）。**

| 档 | 链路 | 单源请求数 | 用途 |
|---|---|---|---|
| **L1 预检 `probe`** | 只跑 `search_one` | 1 | 先用它把 3000 源过一遍，得到「疑似可用」子集与明确的失败原因 |
| **L2 完整 `full`** | 现状 `detect_chain` | 4+ | 只对 L1 通过者（或用户手选者）跑，验证完整阅读链路 |

`detect_chain` 已经是独立函数、内部已分阶段（`search_one` → 详情 → 目录 → 正文），所以 L1 不是新链路，
而是早退：L1 只需在 `search_one` 返回后的那个分支收口。

T2.2 实现把成功阶段也放在 `stage` 中：probe 命中为 `ok=true` / `stage="search"` /
`detail="搜索命中"` / `contentLen=0`，full 成功仍为 `stage="content"`。probe 未命中不新增失败原因，
仍返回 `ok=false` / `stage="no_results"`；只有搜索请求本身分类出的错误才保留 `blocked` /
`network_error` / `timeout` 等原因，不能把「没搜到」误写成 `unavailable`。

**2. 契约：复用 `detect`，加 `mode`，不新增 NAPI 函数。**

```rust
/// Detect whether sources can complete a reading chain; returns JSON
/// `DetectResult[]`. `opts_json` may carry
/// `{ keyword, concurrency, timeoutMs, mode }`.
///
/// `mode` 取 `"probe"` 时只跑搜索链路（1 次请求），用于对整个书源集合做
/// 快速预检；取 `"full"`（默认）时跑完整链路（搜索 → 详情 → 目录 → 首章正文）。
/// 两档的 `DetectResult` 形状相同；失败 `stage` 沿用 `FailReason`，成功为
/// `"search"`（probe）或 `"content"`（full）。
#[napi]
pub async fn detect(sources_json: String, opts_json: String) -> Result<String>
```

缺省、显式 `"full"` 和未知 mode 都走 full，保证旧调用方与旧选项 JSON 兼容；只有精确的 `"probe"`
进入预检。ArkTS 包装层的第三参数缺省值同样是 `"full"`。

理由：`detect-job` 是分批调用（建议 32 源/批），结果一次返回完全在预算内，因此不需要
`detectStart / detectProgress / detectResults / detectCancel` 这套分片接口。少一个 NAPI 函数就少一处
契约面、少一份 `index.d.ts` 与 keep 列表的维护成本。（若将来 `detect-job` 改由 Rust 侧常驻调度，
再引入分片接口——不在本次范围。）

**3. 超时按档给不同默认值（T0.2 实测取值：L1 = 8 s，L2 = 45 s）。**

L1 只发 1 次请求，长下限没有意义；L2 要串 4+ 次请求，保持现状。

| 档 | 单源预算 | 依据（实测） |
|---|---|---|
| L1 `probe` | **8 s** | 命中源的搜索耗时 p50 0.74 s / p90 1.6 s / p95 1.9 s / **p99 8.5 s** / max 9.65 s（2400 次观测里 220 次命中）|
| L2 `full` | 45 s（现状 `DEFAULT_DETECT_TIMEOUT_MS`，`runtime.rs:437`）| 4 次请求 × 单请求 15 s（`http_client.rs:142`），3 倍余量 |

- **L1 的可用区间是 3–15 s**：单请求超时是 15 s（`http_client.rs:142`），L1 只发一次请求，
  所以 aggregate cap ≥ 15 s 等于不生效。clamp 下界要从 10 s 放宽到 3 s（`runtime.rs:447` 的
  `timeout_ms.clamp(10_000, 120_000)`），否则 8 s 传不进去。
- **8 s 的代价**（实测）：2400 次观测里只有 2 次命中 >8 s（占命中 0.9%、占全部观测 0.08%）——它们会从
  「命中」变成 `timeout`。`timeout` 属 A10 的**「待复查」**档、不是 `unavailable`，不参与一键清理 →
  不会误删可用源。
- **8 s 的收益**（实测）：把挂死源的 15 s 压到 8 s，单轮总工作量 −14%（cap 5 s 可省 27%，但会切掉
  2.3% 的命中，不值）；单批（32 源）最坏收尾时间从 ≤15 s 降到 ≤2×8 s（批 32 ÷ 并发 16 = 2 波，
  见 `SPEC-DETECT-JOB.md` §2「取消」）。
- 实现在 `T2.2`（与 `mode` 一起落）。**Ask first 项已确认：L1 = 8 s（2026-10-15）。**

**4. `respondTime` / `lastUpdateTime` 接回（T2.1，已完成并 release 真机验证 2026-10-17）。**

书源 JSON 里本来就有 Legado 原生的 `respondTime` / `lastUpdateTime`（`resources/rawfile/bundled-sources.json`
可见）。2026-10-17 以 `c357fb7` 为基线核对时，Rust `BookSource` 与混淆 keep 列表已声明这两个字段；
本次补齐 ArkTS `BookSource` 接口和真实书源回归单测。release 混淆包启动探针读到「黑炎小说」的
`respondTime=3662` / `lastUpdateTime=1685889740162`，与内置 JSON 一致。接回之后：

- 检测结果的时间/耗时可以直接落在书源自身的字段上，成为 `source-store` 的
  `respond_time` / `last_detect_at` 列来源，也是「增量检测」的输入。
- 三处同步：`rust/legado-engine/src/types.rs`、`entry/src/main/ets/engine/types.ets`、
  `entry/obfuscation-rules.txt`（`scripts/check-keep-props.sh` 会核对）。

**5. 并发上限 = 16（T0.2 实测取值，2026-10-15；Ask first 项已确认）。**

现状 Rust `clamp(1, 8)`（`runtime.rs:452`），`engine/BookEngineNapi.ets` 又硬编码传 4。

**测法**：`scripts/detect-bench.py`（主机 release 构建，走 `make probe` 同一条链路），源池 = 一份
3911 条 Legado 导出里「启用 + 有搜索规则」的 **3180 条真实混合源**，固定种子抽 400 条，每档 2 轮。
复现：

```sh
python3 scripts/detect-bench.py --input <3911条导出.json> --sample 400 --seed 42 --rounds 2 \
    --concurrency 8,16,32,64 --cmd search --timeout 20000     # L1；--cmd detect 为 L2
```

**注意**：`runtime.rs` 的 `clamp(1, 8)` 会把 16/32/64 静默夹回 8，测之前必须临时放宽
（本轮改为 `clamp(1, 64)`，**测完已回退**：`git diff rust/` 为空；转正归 `T2.2`）。

| 并发 | L1 源/分钟 | L2 源/分钟 | 每翻倍加速比 | L1 命中率 | L1 超时率 | L2 超时率 | `blocked` | `rate_limited` |
|---|---|---|---|---|---|---|---|---|
| 8（现状） | 312.5 | 296.9 | — | 9.1% | 5.0% | 5.4% | 5.5% | 0.5% |
| **16（取）** | **582.5** | **552.2** | 1.86× | 9.1% | 5.4% | 5.6% | 5.8% | 0.5% |
| 32（备选） | 879.1 | 843.9 | 1.51× | 9.2% | 5.6% | 5.9% | 5.8% | 0.5% |
| 64（不取） | 1241.3 | 1205.8 | 1.41× | 9.2% | 5.9% | 6.9% | 5.4% | 0.5% |

（每档 800 次观测 = 400 源 × 2 轮；超时率含 `http_client` 单请求 15 s 超时。）

- **取 16 的依据**：主机上测不到吞吐拐点（64 仍 +41%，瓶颈不在本机），所以按「失败率不再上升的最后一档」
  取，并优先保守：8→16 几乎是线性收益（1.86×），而 8→16→32 的失败构成**逐项一致**：`network_error`
  18.0–18.5%、`not_found` 17.2–17.5%、`no_results` 35.1–35.8%、`builder_error` 5.5%、`blocked`
  **5.8% 完全相同**、`rate_limited` 0.5% 相同——**提高并发没有制造新的失败**。
- **为什么不取 32/64**：并发上限同时是真机上的在途 TLS 连接数上限，手机 CPU/内存未实测。32 的吞吐
  还剩 +51%（不是噪声），但代价是**翻倍的在途连接**；真机若证实宽裕，改 `Const.ets` 一个常量即可上 32
  （实测数据已在上表，无需重测）。64 明确不取：L2 超时率 5.9%→6.9%（+8 例/800，属 1σ 噪声但方向
  不利），而 3000 源单轮只再省 ~1 分钟。
- **「被 ban」在本数据里不是并发问题**：16–32 并发摊在 3000 个不同域名上 ≈ 每域同时 1 个在途请求。
  逐源比对 6 次观测（3 档 × 2 轮）：**没有任何一个源出现「某档 ok、某档失败」**，`blocked` 的 46 例
  在三档里是同一批 23 个源（站点 WAF/403），与并发无关。
- **设备侧未验**：本表是 macOS 主机数字。手机上 `napi-ohos` 的 `#[napi] async fn` 同样跑在多线程
  tokio runtime 上（`napi-ohos/src/tokio_runtime.rs` 的 `new_multi_thread()`），但单核性能与无线链路
  会让「源/分钟」整体下移；真机数字由 `T1.6` / `T2.3` 补——**单轮 >15 min 就上调到 32**。
- **L1 3000 源单轮估算**（对照 map §9-4 的「≤20 分钟」，按 3000 ÷ 源/分钟，再按 L1 的 8 s cap 折算 −14%）：

| 并发 | L1 单轮（3000 源） | 判据 |
|---|---|---|
| 8 | ≈8.3 min | ✅（现有并发也能过，但设备侧没有余量） |
| **16** | **≈4.4 min** | ✅ 取（给手机留 ~4.5× 余量） |
| 32 | ≈2.9 min | ✅ 留作上调档 |
| 64 | ≈2.1 min | ✅ 但不取 |

  估算前提是本样本的源构成（91% 死源、命中率 9%）；若源池几乎全存活（内置 13 条那种），
  单源搜索耗时仍是 0.7–2 s 量级 → 3000 源在并发 16 下也在数分钟量级。
- 落点：`Const.ets` 单一常量（`T2.2` 已把 Rust clamp 与 ArkTS 传值一起改为 16），`detect-job` 的批大小 32
  与它对齐（批 32 ÷ 并发 16 = 2 波，最坏收尾 ≤16 s，见 `SPEC-DETECT-JOB.md` 开放问题 3）。
  **Ask first 项已确认：并发 = 16（2026-10-15）。**

## Success Criteria

1. L1 预检 3000 源，在决定的并发与超时下**现实 ≤ 20 分钟**（现状同集合 1–5 小时）。

   **T2.3 主机实测（2026-10-18，非真机）**：全量导出 3907 条中筛出 3171 条启用且有搜索规则的源，
   固定关键词「剑来」、并发 16；L1 墙钟 **237 s（3m57s）**，低于 20 分钟判据。L2 同批墙钟
   283 s（4m43s）。完整逐源表、集合关系与边界见
   [`T2.3-DETECT-TRUTH-TABLE.md`](../research/T2.3-DETECT-TRUTH-TABLE.md)。手机端 3000 源单轮仍未验证。
2. L1 的 `DetectResult` 与 L2 形状一致，失败 `stage` 复用既有 `FailReason` 取值；成功阶段分别为
   `search`（L1）与 `content`（L2），**不新增语义重复的字段**。
   L1 未命中必须是 `no_results`（「源可用但探测词没命中」），不能记成 `unavailable`——现状
   `pages/BookSourceManage.ets:24-36` 的 `detectStateOf` 依赖这个区分来决定什么该被一键清理，不许破坏它。
3. `mode` 经 NAPI 往返在 release 包下可读（keep 列表；`make run-release` 验证）。
4. `make test` 覆盖两档的路由真值表（同一份 HTML：L1 命中 / L1 未命中 / L2 通过 / L2 在目录阶段失败）。
5. `make probe` 用真实书源实测 L1 与 L2 各至少 3 个源，耗时与结论记入任务条目。

## Boundaries

- **Ask first**：`detect` 的 `mode` 参数（NAPI 契约变更）。
- ~~并发上限值；超时 clamp 边界~~ → **已定：并发 16 / L1 8 s**（T0.2 实测 + 用户确认，2026-10-15，
  见「关键设计决策 3 / 5」）；`T2.2` 按这两个值落，无需再确认。
- **Never**：在引擎里做 UI 分片/进度（保持无状态）；在 `types.ets` 加字段而不同步 keep 列表；
  手改 `index.d.ts`。

## Open Questions

1. ~~并发目标值（map 开放问题 3）：8 → 16 / 32？~~ → **已定 16**（T0.2 实测 + 用户确认，2026-10-15），
   见「关键设计决策 5」；32 留作真机上调档。
2. L1 用的关键词：复用 `DEFAULT_DETECT_KEYWORD`（当前「重生」）还是单独配一个命中率更高的词？
3. L1 的「命中」判定阈值：`search_one` 返回 ≥1 条即通过，还是要求 ≥N 条 / 名称相关性？
4. ~~`stage` 是否需要为 L1 新增取值？~~ → **已定：probe 命中用 `stage="search"`，调用方结合 `mode`
   解释为预检通过；失败值不变。**
