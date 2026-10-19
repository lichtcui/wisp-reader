# BOOKSOURCE-REVAMP — 任务清单（Phase 3: Tasks）

状态：**待审** · 日期：2026-10-14 · 上游：[`BOOKSOURCE-REVAMP-PLAN.md`](./BOOKSOURCE-REVAMP-PLAN.md)（Plan）、
[`../specs/SPEC-BOOKSOURCE-REVAMP.md`](../specs/SPEC-BOOKSOURCE-REVAMP.md)（capability map）

> 存放位置同 Plan（项目约定：根目录不收新文档，方案/计划进 `docs/research/`）。
> 本文件 = Phase 3 产出：20 个任务卡片（acceptance / verify / files / 依赖）+ 6 个检查点 + 并行分工。
> 卡片全部获批后进入 Phase 4（Implement），逐个任务按 `incremental-implementation` 执行。

## 0. 执行约定

- **每个任务收尾都跑 `make check`**（md 链接 / JSON keep 列表 / hilog 格式 / 行号目录）。
- **动 Rust 的任务先 `make test`；改引擎规则先 `make probe`；改 ArkTS 走 `make run` 闭环。**
- 一个任务只碰 ≤5 个文件；超出就在动手前拆成两任务并回写本文件。
- 任务完成即勾选，并在 `docs/progress.md` 记一行当前状态。

## 1. 并行分工（已批准：两会话并行）

| 会话 | 承担 | 顺序 |
|---|---|---|
| **A（存储 + 列表）** | T1.1–T1.6 → T3.1–T3.4 | ArkTS 线；**T1.1 不受任何门禁阻塞，可立刻开工** |
| **B（引擎 + 作业）** | T0.2 → T0.1 → T2.1–T2.3 → T4.1–T4.4 | Rust 线；两个门禁都在 B（它们的结论只影响 B 的参数）；等 A 的 `T1.1` 落地后开 `T4.3` |
| **汇合** | T5.1–T5.4 | 单会话串行（同一批文件） |

**必须先冻结的两个契约**（冻结后两边照它做，不许各写各的）：

1. **`SourceRow` 投影形状** — 由 `T1.1` 冻结；`T3.*` 只消费不改，B 的 `T4.3` 依赖
   `SourceStore.allForEngine()` / `patchDetect()` 的同批签名。
2. **`DetectJobRunner` 的 `@Trace` 字段名** — 由 `T4.1` 冻结；`T4.3` 与 `T5.2` 照用。

**等待窗口的用法**：B 在等 `T1.1` 时做 `T2.1`–`T2.3`（纯 Rust，不依赖存储）；A 全程不依赖引擎，`T3.*` 可直接做。

---

## 2. Phase 0 — 门禁验证

### Task T0.1 长时任务能力验证（真机）✅ **已完成（2026-10-15）**

**结论（A1，证据与分析全文见 [`../research/T0.1-LONG-TASK-EVIDENCE.md`](../research/T0.1-LONG-TASK-EVIDENCE.md)）**：
① `BackgroundMode.DATA_TRANSFER` **存在且可用**（真机申请成功 + 常驻通知；`module.json5` 已加 `dataTransfer`）；
② **息屏 606 秒零丢 tick**（07:46:38→07:56:39，PID 未重启），停表恰在**10 分 03 秒**，与 SDK 原文规则
「进度 >10 分钟不更新即取消（进度通知须为**实况窗 live view**）」吻合 ⇒ 作业必须按 **≤10 分钟节奏更新进度**；
③ **同一 UIAbility 不能持两个长时任务**（第二个 `start` 报 `9800005`），并存正解是**一个任务带多类型**
（`startBackgroundRunning(ctx, bgModes[], wantAgent)` / `updateBackgroundRunning(ctx, bgModes)`，均 @since 12）
—— 该路径需待急 P0 修复后复验；④ **新 P0**：TTS 的 `AUDIO_PLAYBACK` 任务约 **24 秒**后即被系统停
（`AVSessionNotifyUpdateNotification failed ret=980000502`）、息屏 50 秒应用被冻结 ⇒ 「靠听书任务保命」不可依赖。

**Description:** 确认 `backgroundTaskManager.BackgroundMode.DATA_TRANSFER` 存在且可用；确认同一应用
能否同时持有「音频播放」与「数据传输」两个长时任务；确认息屏后作业仍在推进。产出 plan 的 A1 决定。

**Acceptance criteria:**
- [x] 在真机上 `startBackgroundRunning(ctx, DATA_TRANSFER, wantAgent)` 成功返回，且通知栏出现常驻通知
- [x] TTS 正在播放时启动作业，10 分钟内二者都没有被系统终止 —— **结论为否**：第二个任务直接 `9800005`；
      TTS 自己的任务 24 秒后被系统停（P0）。并存须改「一任务多类型」，待 P0 后再验
- [x] 息屏 10 分钟，作业推进计数持续增长（不依赖应用处于前台）—— 实测 606 秒连续、零丢 tick，随后按 10 分钟规则取消
- [x] 结论 + 证据（SDK 版本、hilog 片段）写入 [`../specs/SPEC-DETECT-JOB.md`](../specs/SPEC-DETECT-JOB.md) §3.6

**Verification:**
- [x] `make run` 后在真机手工走：起 TTS → 起作业 → 息屏 10 min
- [x] 抓日志：`hilog -x | grep` + 探针落盘文件 `filesDir/t0-1-probe.log`（**hilog 缓冲区会滚**，落盘才可数）
- [x] 降级路径**未触发**（`DATA_TRANSFER` 可用），仍保留在 spec §3.6 备案

**临时探针已清理（2026-10-15）**：`model/BackgroundProbe.ets` 已删除、`Settings.ets` 顶部 TEMP 组已移除
（该文件已回到与 HEAD 一致，`make hap` ✓、真机 `make run` 后设置页无残留）；`module.json5` 的
`"backgroundModes": ["audioPlayback", "dataTransfer"]` **保留**（Phase 4 沿用）。

**Dependencies:** None
**Files likely touched:** `entry/src/main/module.json5`（如需）、`docs/specs/SPEC-DETECT-JOB.md`、
`docs/research/`（结论记录）
**Estimated scope:** Small（允许写一次性验证代码，验完删除；正式实现归 `T4.4`）

### Task T0.2 并发 / 超时实测调参 ✅ **已完成（2026-10-15）**

**结论（Ask first 已确认）**：并发 **16**、L1 超时 **8 s**、L2 保持 45 s；3000 源 L1 单轮 ≈4.4 min
（判据 ≤20 min 留 ~4.5× 余量）；32/64 的实测数据已备，真机若 >15 min 改一个常量上调到 32。
实测台 `scripts/detect-bench.py`（可复现，一条命令重跑四档）；结论已回写
[`../specs/SPEC-DETECT-ENGINE.md`](../specs/SPEC-DETECT-ENGINE.md) §3.3 / §3.5 + [`BOOKSOURCE-REVAMP-PLAN.md`](./BOOKSOURCE-REVAMP-PLAN.md) §2 的 A2。

**Description:** 用 `make probe` 对同一批真实书源跑并发 8 / 16 / 32，记录吞吐、成功率、超时率与
限流迹象，定并发上限与 L1 超时。产出 plan 的 A2 决定。

**Acceptance criteria:**
- [x] 三个并发档位的「源/分钟、成功率、超时率、其他失败」成表记录 —— 实测 8/16/32 **+ 补测 64** 四档，
      每档 800 次观测（400 源 × 2 轮）：L1 312.5 / 582.5 / 879.1 / 1241.3 源/分钟，命中率 9.1–9.2%，
      L1 超时率 5.0 / 5.4 / 5.6 / 5.9%，L2 超时率 5.4 / 5.6 / 5.9 / **6.9%**；失败构成逐项同表
- [x] 给出推荐并发值 + 依据 —— **16**：主机上 64 仍 +41%（测不到拐点，瓶颈不在本机），故按「失败率不再
      上升的最后一档」取并优先保守：8→16 近乎线性（1.86×），8/16/32 的失败构成逐项一致（`blocked`
      恒 5.8%、`rate_limited` 0.5%），且逐源比对 6 次观测**没有任何源「某档 ok、某档失败」**；
      32 留作真机上调档（收益真实但翻倍在途连接，手机侧未测），64 不取（超时率抬头，只再省 ~1 min）
- [x] 给出 L1 超时推荐值 + 3000 源单轮估算 —— **8 s**（命中耗时 p99=8.5 s、max 9.65 s；2400 次观测里
      只有 2 次命中 >8 s，且落「待复查」不误删）→ 3000 源单轮 ≈**4.4 min**（并发 16；8 s cap 已折算 −14%）
- [x] 结论写入 [`../specs/SPEC-DETECT-ENGINE.md`](../specs/SPEC-DETECT-ENGINE.md) §3.3 / §3.5，
      并回写 plan §2 的 A2

**Verification:**
- [x] `make probe … detect <关键词> --concurrency N --timeout M` 多轮 —— 本轮用 `scripts/detect-bench.py`
      把 probe 包成「抽样 → 多档 → 多轮 → 统计」，原命令与参数见 spec §3.5 的复现行
- [x] **必做**：`clamp(1, 8)` 临时放宽 —— 改成 `clamp(1, 64)`（search 侧 `clamp(1, 16)` → 64）测完 16/32/64，
      **已回退**（`git diff rust/` 为空，probe 二进制已重建）；转正归 `T2.2`，spec §3.5 记录了这次临时改动
- [x] 样本量 —— 内置 13 条只有 2 个波次，故另拼源池：一份 3911 条 Legado 导出里「启用 + 有搜索规则」的
      3180 条（≈ 用户的 3000 源导入），固定种子抽 400 条；内置 13 条与「L1 命中过的 38 条存活源」作对照
      （存活源逐源耗时中位在 8/16/32/64 下为 1.55/1.58/1.61/1.64 s —— 并发没把源拖慢）

本轮原始日志（临时，重启即失）：`/tmp/detect-bench/`（`sweep-*.log` 为汇总表，`l1/`、`l2/`、`alive2/`、
`bundled/` 下是每档每轮的 `--json` 原始结果；汇总 JSON 为各自的 `summary-*.json`）。

**Dependencies:** None
**Files likely touched:** `scripts/`（一次性测速脚本）、`docs/specs/SPEC-DETECT-ENGINE.md`
**Estimated scope:** Small

### Checkpoint 0 — 门禁

- [ ] A1 / A2 两条决定已落进 spec，且 map §9-4 / §9-6 仍可达（或已按降级改写）
      —— **A2 ✅ 已落**（T0.2 实测 + 用户确认：并发 16 / L1 8 s）；**A1 待 `T0.1`**（真机，未做）
- [ ] **与人对齐后再进 Phase 1**

---

## 3. Phase 1 — `source-store`（会话 A）

### Task T1.1 `SourceStore.ets`：建表 + 接口（冻结契约）

**Description:** 新建 SQLite 存储层，取代 preferences 单键。建 `sources` 表（索引列 + JSON 列，
自然键 `(url, name)` 唯一索引），实现轻量投影读与单行/单事务写。**本任务冻结 `SourceRow` 形状。**

**Acceptance criteria:**
- [x] 表与索引按 [`../specs/SPEC-SOURCE-STORE.md`](../specs/SPEC-SOURCE-STORE.md) §关键设计决策 2
      建好（`grp` 而非 `group`；`json` 列存完整书源）
- [x] `SourceRow` 投影 + 接口齐全：`listRows` / `countRows` / `getSource` / `setEnabled` / `remove` /
      `patchDetect` / `patchConfidence` / `upsertMany` / `replaceAll` / `allForEngine` / `exportAll`
- [x] 同 URL 不同名两条各自有独立 `id`，启停/删除互不影响（T-SRC-1 回归不重演）
- [x] `setEnabled` / `remove` 为单行写，无任何全量序列化

**Verification:**
- [x] `make run` 后在真机确认建表成功、投影字段完整（`uitest dumpLayout` / hilog）
      —— 2026-10-17 一次性自检：`add=2 upd=1 dupid=1 idstable=1 grp=1 proj=1 iso=1 patch=1 flt=1 exp=2 rm=1 rows=2`
- [x] `make check` 通过
- [x] 形状冻结：把 `SourceRow` 与接口签名贴进 `SPEC-SOURCE-STORE.md`（替换「建议签名」措辞）

**Dependencies:** None
**Files likely touched:** `entry/src/main/ets/model/SourceStore.ets`（新）、`common/Const.ets`、
`docs/specs/SPEC-SOURCE-STORE.md`
**Estimated scope:** Medium

### Task T1.2 迁移：preferences → SQLite（幂等 + 回退）

**Description:** 首次启动把 `book_sources_v1` 迁入 `sources` 表。**必须整条跑通再切消费点**——
迁移没稳就改读取方等于丢数据。

**Acceptance criteria:**
- [x] 幂等：连续调用两次结果一致，不重复插入
- [x] 迁移前自动导出一份备份到 `filesDir`；迁移后 `countRows` == 迁移前解析条数（不一致即中止并报错）
- [x] 旧 preferences 键**保留**（1 个版本的回退路径）
- [x] 迁移失败时不破坏旧键、不产生半张表数据（事务内完成）

**Verification:**
- [x] 真机：导入一份多源文件 → 触发迁移 → 核对条数与备份文件存在
      —— 2026-10-17：13 条迁入，备份 23068 B 与迁移前 preferences 原文逐字节一致
- [x] 手工制造「第二次启动」确认幂等
      —— 第一次 `migrated count=13`，第二次 `already-migrated count=0`
- [x] `make check` 通过

**Dependencies:** T1.1
**Files likely touched:** `model/SourceStoreMigration.ets`（新）、`model/SourceStore.ets`、
`model/SourceRepository.ets`
**Estimated scope:** Medium

### Task T1.3 `confidence` 迁入 `sources` 表（A6）

**Description:** 把置信度从「随 `BookSource` 全量 blob 落盘」改为 `sources.confidence` 列，消除第二套
存储与第二次全量 parse。

**Acceptance criteria:**
- [x] `confidence` 读写全部走 `patchConfidence` / `patchConfidences` / 投影列，不再有独立的全量写路径
- [x] 既有置信度数据在迁移中一并带入（不丢）
- [x] `model/SourceConfidence.ets` 的调用方全部改完，无残留

**Verification:**
- [x] `rg -n "SourceConfidence" entry/src/main/ets` 确认只剩存储层引用
- [x] 真机：改一次置信度 → 重启 → 值仍在
      —— 2026-10-17：👍玄幻阁 `90→100`、黑炎小说 `40→50`、云中书库 `35→45`；force-stop 重启后保持
- [x] `make check` 通过

**Dependencies:** T1.1、T1.2
**Files likely touched:** `model/SourceStore.ets`、`model/SourceConfidence.ets`
**Estimated scope:** Small

### Task T1.4 消费点切换 A：备份导出/导入 + 换源面板

**Description:** 去掉这两处的全量 `getString` + `JSON.parse`，改走存储层接口。
**不改备份 JSON 的对外格式。**

**Acceptance criteria:**
- [x] `BackupManage` 的导入/导出走 `upsertMany` / `replaceAll` / `exportAll`
- [x] `SourceSwitchPanel` 走投影查询，不再全量 parse
- [x] 导出的备份 JSON 与既有格式**逐字段一致**（`BACKUP_SCHEMA_VERSION` 不变）
- [x] 旧备份文件仍可导入

**Verification:**
- [x] 真机：导出 → 与改动前的备份逐字段对比（diff）
- [x] 真机：用旧备份文件导入成功
- [x] `make check` 通过

**证据（2026-10-17 真机）：** 导出备份保持 `schemaVersion=1`，顶层与全部嵌套字段路径不变；旧备份导入后计数 `13 / 3 / 7`，最新备份回导后恢复为 `13 / 4 / 8`。换源面板直接显示
`换源 · 3 个候选` / `已检索 8/12 个书源`，候选来自已启用书源的投影查询。

**Dependencies:** T1.2
**Files likely touched:** `pages/BackupManage.ets`、`components/SourceSwitchPanel.ets`、
`model/SourceStore.ets`
**Estimated scope:** Medium

### Task T1.5 消费点切换 B：阅读链路

**Description:** 启动、书架、搜索结果三处改走投影查询，消除每次进页面的主线程全量 parse。

**Acceptance criteria:**
- [x] `Index.ets` / `Shelf.ets` / `SearchResult.ets` 不再调用 `loadSources()` 全量
- [x] 启动路径无 >1 MB 的 `JSON.parse`（正常启动只查投影；唯一例外是 T1.2 尚未执行的一次性旧 preferences 迁移）
- [x] 换源/启用状态在上述三处与书源页保持一致（同一份 `sources.db`；页面均先 `ensureSourceStore()`，再查 `listRows()`）

**Verification:**
- [x] `rg -n "loadSources" entry/src/main/ets` 确认调用点只剩存储层与迁移
- [x] `make run` 真机走一遍：启动 → 书架 → 搜索 → 换源（2026-10-17，`33Z0224424136564`）
- [x] `make check` 通过

**Implementation evidence (2026-10-17):** `make run` 编译、签名、安装、force-stop、启动全部成功；启动日志为
`source migration status=already-migrated count=0`，书架网络书《剑来》可进入阅读页并换源成功。
`Index.ets` / `Shelf.ets` / `SearchResult.ets` 改为 `ensureSourceStore()` + `listRows()`，仅按书架实际使用的 URL
或逐源搜索的稳定 `id` 调用 `getSource()`；`SourceSwitchPanel.ets` 与 `BookSourceManage.ets` 同读 SQLite 投影。
`rg -n "loadSources" entry/src/main/ets` 仅命中 `model/SourceRepository.ets:22`（定义）。
新增 `scripts/check-source-consumers.sh` 并接入 `make check`，同时锁定启动/三个阅读消费点不得出现 `JSON.parse`。
启用状态一致性实测：管理页关闭一条后为 `书源（12/13 启用）`，搜索显示 `源 8/11 成功`，换源面板显示
`已检索 10/11 个书源`；force-stop 重启后仍为 `12/13`，恢复启用后回到 `13/13`，再次搜索显示 `源 10/12 成功`。
`SearchResult.ets` 现在每次 `searchToken` 变化都会重读启用投影，避免在管理页改启停后沿用旧集合。

**Dependencies:** T1.2
**Files likely touched:** `pages/Index.ets`、`pages/Shelf.ets`、`pages/SearchResult.ets`
**Estimated scope:** Medium

### Task T1.6 3000 条造数入口 + 性能实测（真机）

**Description:** 提供一次性造数路径（导入一份 3000 条 JSON），实测冷启动就绪时间、单条 toggle、
批量 upsert。造数文件不入仓库。

**Acceptance criteria:**
- [x] 能在一台真机上得到 3000 条书源（含同 URL 不同名、多分组、混合启用状态）
- [x] 实测：进书源页数据就绪 ≤ 300 ms 且首帧不阻塞（map §9-1）
- [x] 实测：单条 toggle / 删除 ≤ 16 ms 且不触发全量序列化（map §9-2）
- [x] 实测：`upsertMany` 3000 条单事务 ≤ 2 s

**Verification:**
- [x] `make log` 抓 hilog 中的耗时打点，`rg` 出三组数字
- [x] 造数脚本/数据存放路径记进 `docs/research/`（不入仓库）
- [x] `make check` 通过

**Implementation evidence (2026-10-17, `33Z0224424136564`):** debug-only 入口位于书源管理页「工具」组，
由 `BuildProfile.DEBUG` 门控。临时 JSON 为 3000 行（1000 个 URL × 3 个不同名称、12 组、
2000 enabled / 1000 disabled）；最新轮 `upsertMany=477 ms`、冷就绪 `44 ms`（首帧 `18 ms`）、
首次 toggle `10 ms`、10 次中位 `1 ms`、remove `1 ms`、`jsonSerialize=0`。测后恢复原 13 条书源，
`exact=1`。前一轮首次 toggle 为 `20 ms`，保留在证据中作为调度抖动风险。
路径、哈希、日志与复跑说明 →
[`T1.6-SOURCE-STORE-BENCH.md`](./T1.6-SOURCE-STORE-BENCH.md)。新增 `scripts/check-t16-bench.sh`
锁定 debug 门控、首帧后测量路径、单行写不 reload、`upsertMany` 单事务和无全量序列化。

**Dependencies:** T1.1、T1.2
**Files likely touched:** `pages/BookSourceManage.ets`（隐藏调试入口）、`common/Const.ets`、
`docs/research/`（记录）
**Estimated scope:** Small

### Checkpoint 1 — 存储地基

- [x] map §9-1 / §9-2 有实测数字支撑
- [x] 迁移幂等、旧键仍在、条数校验通过
- [x] 备份导出逐字段一致、旧备份可导入（map §9-7）
- [x] `rg -n "loadSources"` 确认消费点已全部切换
- [x] `make check` 通过
- [ ] **与人对齐后再进 Phase 3**

---

## 4. Phase 2 — `detect-engine`（会话 B，可与 Phase 1 并行）

### Task T2.1 `respond_time` / `last_update_time` 接回

**Description:** 书源 JSON 里本就有这两个字段，但 Rust `BookSource` 未声明 → serde 静默丢弃。
补上并做三处同步，使检测结果的时间/耗时有地方落。

**Acceptance criteria:**
- [ ] `rust/legado-engine/src/types.rs` 声明两字段（`#[serde(rename_all = "camelCase")]` 语义正确）
- [ ] `engine/types.ets` 同步；`entry/obfuscation-rules.txt` keep 列表同步
- [ ] `make check` 的 keep 核对通过（无遗漏、无多余）
- [ ] 解析带这两个字段的真实书源后，值不丢（`make probe` 或单测验证）

**Verification:**
- [ ] `make test` 通过
- [ ] `make check` 通过
- [ ] `make run-release` 后确认 release 包下字段可读（混淆不吞字段）

**Dependencies:** None
**Files likely touched:** `rust/legado-engine/src/types.rs`、`entry/src/main/ets/engine/types.ets`、
`entry/obfuscation-rules.txt`
**Estimated scope:** Small

### Task T2.2 `detect` 加 `mode`（probe 早退）

**Description:** 复用 `detect` 而不新增 NAPI 函数：加 `mode: "probe" | "full"`，probe 在
`search_one` 返回后早退（1 次请求），full 保持现状完整链路。`lib.rs` 的 `///` 是契约唯一来源。

**Acceptance criteria:**
- [ ] `lib.rs` 的 `///` 更新（含 `mode` 取值与两档语义），`make rust` 重生成并拷 `index.d.ts`
- [ ] probe 只发 1 次请求即收口；full 行为与改动前完全一致
- [ ] `BookEngineNapi.ets` 透传 `mode`；旧调用方不传时默认 `full`（行为不变）
- [ ] **probe 未命中记 `no_results`，绝不记 `unavailable`**

**Verification:**
- [ ] `make rust` 后确认 `index.d.ts` 已更新且未被手改
- [ ] `make test` 通过
- [ ] `make check` 通过（keep 列表含 `mode`）
- [ ] `make run-release` 确认 release 下 `mode` 生效

**Dependencies:** T2.1
**Files likely touched:** `rust/legado-engine/src/runtime.rs`、`rust/legado-core/src/lib.rs`、
`entry/src/main/ets/engine/BookEngineNapi.ets`、`entry/src/main/cpp/types/liblegado_core/index.d.ts`（生成）
**Estimated scope:** Medium

### Task T2.3 L1/L2 真值表 + 真源实测

**Description:** 用固定 HTML 夹具覆盖三条关键路由，并用真实书源对比 L1 与 L2 的耗时与结论一致性。

**Acceptance criteria:**
- [ ] `make test` 覆盖：L1 命中 / L1 未命中（记 `no_results`）/ L2 在目录阶段失败
- [ ] `make probe` 真源实测 L1 与 L2 各 ≥3 个源，记录耗时比与结论差异
- [ ] 确认 **L1 通过的集合 ⊇ L2 通过的集合**（若有反例，记录并评估）
- [ ] 实测结论写入 `docs/research/`，并回写 `SPEC-DETECT-ENGINE.md` §Success 1

**Verification:**
- [ ] `make test` 通过
- [ ] `make probe ARGS='...'` 输出落 `/tmp`，`rg` 出对照表
- [ ] `make check` 通过

**Dependencies:** T2.2
**Files likely touched:** `rust/legado-engine/src/runtime.rs`（tests）、`docs/research/`、
`docs/specs/SPEC-DETECT-ENGINE.md`
**Estimated scope:** Medium

### Checkpoint 2 — 引擎两档

- [ ] L1 与 L2 的 `DetectResult` 形状一致，`stage` 复用既有 `FailReason`
- [ ] L1 未命中 ≠ `unavailable`（否则一键清理会误删可用源）
- [ ] 单轮时长估算对照 map §9-4 的 ≤20 分钟（用 T0.2 定的并发/超时）
- [ ] `make test` / `make check` / `make run-release` 通过
- [ ] **与人对齐后再进 Phase 4**

---

## 5. Phase 3 — `source-list`（会话 A）

### Task T3.1 页面骨架：两段 + LazyForEach

**Description:** `BookSourceManage` 重写为壳：段选择器 + 段内容容器 + `LazyForEach` 列表 +
`＋`/`⋯` 页内行 + 底部作业条占位。撤掉现有导入区与「工具」组。

**Acceptance criteria:**
- [x] `SegmentedCell` 两段；两段共用**同一份**投影（不重复持有 3000 行）
- [x] 列表用 `LazyForEach`，`build` 里无随行数增长的 filter/sort/map
- [x] 导入 / 规则调试器 / 导出 / 恢复内置 收进 `＋` / `⋯`；滚动区第一屏是列表
- [x] 两段各自保留滚动与筛选状态；进页面总是「书源」段

**Verification:**
- [x] `make run` + `uitest dumpLayout`：确认首屏可见搜索框与筛选条，列表在首屏
- [x] 3000 条下实际滚动无掉帧
- [x] `make check` 通过

**Evidence（2026-10-18，设备 `33Z0224424136564`）：** `reload()` 只调用一次 `listRows()`，
`rows` / `sourceDs` / `detectDs` 共用同一份 `SourceRow[]`；两个 `LazyForEach` 的构建体都只调用
`sourceRowCell(source)`。`make run` 完成 debug HAP 编译、安装、force-stop 与启动；
`uitest dumpLayout` 成功取得 145236 B：搜索框 `[162,506][1179,655]`、筛选 chips 在
`[54,682][1072,790]`、可滚动 `List` 在 `[0,925][1260,2529]`，13 条书源首屏只物化 6 个
`ListItem`。真机把书源段查询设为 `abc`、选中「启用」，检测段选中「失败」后切回，两个段的状态均保留；
书源列表下滑后切到检测段再切回，首批可见行不变；在检测段退出页面再进入，书源段为选中态（品牌底色）。
`＋` 菜单可打开并显示导入入口，`⋯` 菜单可打开并显示导出与 T1.6 入口；菜单项与代码核对一致。
设备上未启动 T1.6 造数：现有 seeded 路径会先做 store 测量并自动恢复，未提供可停留滚动的 3000 行列表，
因此本轮不修改 T1.6 流程，取消确认后原数据未变。**3000 条列表滚动首帧仍未验证。**

**Dependencies:** T1.1–T1.6
**Files touched:** `entry/src/main/ets/pages/BookSourceManage.ets`、
`docs/research/BOOKSOURCE-REVAMP-TODO.md`、`docs/progress.md`
**Estimated scope:** Medium

### Task T3.2 行 + `⋯` 菜单 + 二次确认

**Description:** 两行式行（名称 / 分组·检测态·耗时）+ 开关 + 行尾 `⋯`（详情 / 启停 / 删除）。

**Acceptance criteria:**
- [x] 行尾 `⋯` 菜单含 详情 / 停用（或启用）/ 删除；删除走 `AlertDialog` 二次确认且文案含源名
- [x] 「恢复内置」二次确认，文案点明**会替换当前全部书源**
- [x] 行内无裸文本「删除」；点行 = 打开详情抽屉
- [x] 取消确认后数据与落盘都不变（`remove` 未调用）

**Verification:**
- [x] 真机：删除/恢复内置各走一次确认与取消，核对数据未变
- [x] 真机：行尾菜单、整行详情入口、启停隔离与重启后状态保持
- [x] `rg -n "removeSource|resetBundled"` 确认无绕过确认的调用路径
- [x] `make check` 通过

**Dependencies:** T3.1
**Files touched:** `entry/src/main/ets/components/SourceRows.ets`（新）、
`entry/src/main/ets/pages/BookSourceManage.ets`、`docs/research/BOOKSOURCE-REVAMP-TODO.md`、
`docs/progress.md`
**Evidence（2026-10-18，debug 真机 `33Z0224424136564`）：** `uitest dumpLayout` 看到两行式行
`👍玄幻阁` / `校验可用 · 未测`，同行有 Switch 和行尾 `⋯`；启用源菜单为「详情 / 停用 / 删除」，
停用后菜单切换为「详情 / 启用 / 删除」。
点整行和菜单「详情」均打开常驻 `BottomDrawer` 的「书源详情」，显示名称、URL、分组、检测状态和耗时；
菜单操作没有误开详情。完整规则字段详情仍留给 T3.4。
删除确认文案为 `确定删除「👍玄幻阁」吗？删除后不可恢复。`；取消后主库 SHA256 仍为
`cb660136875f0f1ae20b8bdbd561da27f476223dcaf36aa4091777b0770a5118`，WAL 仍为 0 字节，
全表 13 行逐列对比无差异。恢复内置确认文案为
`将删除当前 13 条书源，并用内置书源替换。此操作不可撤销。`；取消后主库哈希、13 条数据和 13 条启用
状态均未变。`resetBundled()` 仍只由「替换」确认回调调用，实际动作是 `replaceAll()`，与用户选定的
**替换**语义一致。
开关实测 `👍玄幻阁` 关闭后汇总为 `12/13`，数据库仅 id `12119` 的 `enabled` 从 1 变为 0，其余行及
JSON 无差异，也未误开详情；force-stop 后重启仍为 `12/13`，再开启恢复 `13/13` 且全表与基线一致。
随后再次停用并从行尾菜单点「启用」也恢复 `13/13`，菜单关闭且未误开详情。
`removeSource()` / `resetBundled()` 各只有一个确认回调调用点；`BottomDrawer` 调用点仍为 8。
`make test` 为 65 passed，`make check`、`make hap`、`make docs-toc` 与 `git diff --check` 通过。
未验证：3000 条真机滚动首帧（不属于 T3.2），以及 T3.3/T3.4 的搜索、排序、空态和完整详情字段。
**Estimated scope:** Medium

### Task T3.3 搜索 / 筛选 / 排序（默认视图）（真机完成）

**Description:** 搜索防抖 + 筛选 chips + 三档排序 + 分组筛选 + 空态。

**Acceptance criteria:**
- [x] 搜索防抖 150 ms，匹配 `name` / `url` / `group`，大小写不敏感
- [x] 默认视图 = 「启用」+ 三档排序（需处理 `不可用` / 待复查 `未测`·`超时`·`无结果` / 正常 `可用`）
- [x] chips「全部」「启用」常显，其余计数为 0 时隐藏
- [x] 空态两种：搜索/筛选无结果有文案；0 条书源带「恢复内置」出口

**Verification:**
- [x] 真机：输入到列表更新 ≤ 100 ms；切换筛选/分组 ≤ 100 ms
- [x] 真机：核对排序分档（构造一条 `unavailable`、一条 `timeout`、一条未测、一条可用）
- [x] `make check` 通过

**Dependencies:** T3.2
**Files touched:** `entry/src/main/ets/components/SourceRows.ets`、
`entry/src/main/ets/pages/BookSourceManage.ets`、`docs/research/BOOKSOURCE-REVAMP-TODO.md`、
`docs/progress.md`

**Evidence（2026-10-18，debug 真机 `33Z0224424136564`）：**`SEARCH_DEBOUNCE_MS=150`；书源段与检测段分别持有
query / appliedQuery / filter / group / counts / `DataSource` / `Scroller`。`sourceRowMatchesQuery()`
对名称、URL 与有效分组（空组显示为「默认」）做去首尾空白、转小写后的子串匹配。投影刷新先完成
query + group 过滤、chip 计数和三档稳定排序，再一次性 `setItems()`；`LazyForEach` 的 build 内不再
做随行数增长的 filter / sort / map。默认书源视图为「启用」，「全部」「启用」chip 常显，
`停用/未测/失败` 与检测段的 `未测/失败` 仅在计数非零时出现。分组菜单支持「全部分组」及空组「默认」。
两类空态分别提供「清除搜索和筛选」与「恢复内置」，后者只打开已有替换确认，不执行替换。

- 搜索：`t33-ok` 命中名称，`t33.example` 命中 URL（5 条），`t33group` 命中分组（5 条），均为大小写
  不敏感子串匹配。3000 条合成数据上输入 `PERF-2999` 后 `debounce_ms=150`、防抖结束到投影完成
  `project_ms=8`、端到端 `total_ms=158`，最终列表 1 条且为 `PerfGroupC · 可用 · 303ms`。
- 筛选 / 分组：3000 条数据上三次 chip 切换分别 `filter ms=11/6/12`；选择 `PerfGroupC` 为
  `group ms=8 rows=1000`，均低于 100 ms。
- 排序：构造 `T33-UNAVAILABLE` / `T33-TIMEOUT` / `T33-UNTESTED` / `T33-NORESULT` / `T33-OK` 后，
  `dumpLayout` 依次看到前四行，`T33-OK` 位于最后一档；即不可用 → 待复查 → 可用。
- chips / 空态：计数为 0 的 chip 隐藏，但「全部 0」「启用 0」常显。筛选无结果时看到
  「没有匹配的书源」「换个关键词、筛选或分组试试。」和「清除搜索和筛选」；0 条书源时看到
  「还没有书源」「导入书源，或恢复内置书源。」和「恢复内置」。
- 状态隔离：书源段保留 `校验` 查询、启用筛选与滚动位置；检测段独立保留 `t33` 查询、失败筛选和
  `T33Group` 分组，往返切换后两边均未被对方覆盖。
- 恢复内置出口只打开「替换全部书源」确认，文案为「将删除当前 0 条书源，并用内置书源替换。
  此操作不可撤销。」；取消后仍为 0 条，未触发实际替换。
- 测试结束后已恢复设备基线库：SHA-256 为
  `cb660136875f0f1ae20b8bdbd561da27f476223dcaf36aa4091777b0770a5118`，`sources` 全表 dump
  一致，重启后书源页显示 13 / 13 条、13 启用。最终无埋点 HAP 安装启动后无 ArkTS/JS 异常。

`make test` 为 65 passed；`make check` 全通过（185 个 keep 名、书源读路径与 T1.6 守卫）；
`make hap` 成功。`BottomDrawer({...})` 调用点仍为 8，未新增裸 `bindSheet`。计时埋点仅用于本轮
取证，已从最终代码移除。

**计时口径冲突：**规范同时写「输入防抖 150 ms」与「输入到列表更新 ≤100 ms」。实现保留 150 ms 防抖；
验收拆为防抖结束后的投影/列表更新 ≤100 ms、输入到更新端到端 ≤250 ms（后者是
`SPEC-SOURCE-LIST.md` 的 Success Criteria 原文）。
**Estimated scope:** Medium

### Task T3.4 详情抽屉 + UI-SPEC 同步（已完成）

**Description:** `SourceDetailPanel.ets` 替代现在的 `statusContent()`「书源状态」内容，并同步
`UI-SPEC.md`。**调用点数量不变（仍 8 处）。**

**Compatibility note:** 当前 `statusContent()` 仍用于检测作业状态，选中单源时原本由
`sourceDetailContent()` 输出详情。为不改检测作业分支和删除/启停语义，本任务只把选中单源的
`sourceDetailContent()` 替换为 `SourceDetailPanel`；两者继续复用同一个常驻 `BottomDrawer`。

**Acceptance criteria:**
- [x] 抽屉展示：名称 / 地址 / 分组 / 启停 / 最近检测（态·耗时·时间）/ 规则字段只读 + 删除
- [x] 仍是 `BottomDrawer` 调用点，数量 8 处不变（未新起裸 `bindSheet`）
- [x] `docs/specs/UI-SPEC.md` §2 第 6 处调用点的名称与用途已更新
- [x] 组件的展示逻辑不含每帧增长的计算

**Verification:**
- [x] `rg -n "BottomDrawer" entry/src/main/ets` 计数为 8
- [x] 真机：整行 / 菜单「详情」打开同一抽屉，字段与源数据一致，关闭后切换不串数据
- [x] `make check` 通过

**Evidence（2026-10-18）：**新增 `components/SourceDetailPanel.ets`，`BookSourceManage` 在打开详情时异步
`ensureSourceStore` + `SourceStore.getSource(row.id)`，仅对选中的单条源构造展示快照；请求序号校验避免
快速切换时旧结果回写。名称、地址、分组、启停、最近检测（状态 / 耗时 / 时间）、搜索 / 详情 / 目录 / 正文
四类规则只读字段与删除入口均由该组件展示，删除仍调用既有 `confirmRemoveSource()`。展示快照只在
`loadSourceDetail()` 完成时构建，`build()` 仅渲染固定 4 个规则字段，不按书源数量计算。静态核对
`BottomDrawer(` 为 8 处，`bindSheet` 仅存在于 `ui/common/BottomDrawer.ets` 的兼容实现；`make test`
65 passed，`make check` 通过（185 个 keep 名），`make run` 编译、安装、force-stop、启动成功。
debug 真机 `33Z0224424136564` 的 `dumpLayout` 证据：整行打开 `👍玄幻阁`
（`http://www.xuanhuange.net`），关闭后打开第三源 `黑炎小说`（`http://www.heiyan.info/`），
再关闭后经菜单「详情」打开 `小说`（`http://www.yetianlian.info`）；三条都显示名称、地址、分组
「校验可用」、已启用、未测 / `—` / `—`，规则内容分别为各自的搜索 / 详情 / 目录 / 正文 JSON，
底部均有「删除书源」。删除入口弹出既有二次确认「确定删除「👍玄幻阁」吗？」，取消后未写入。
最终干净 HAP 无 ArkTS / JS 异常，日志无临时探针。首次复现到关闭后已挂载的详情组件仍绘制首源，
而查询与快照均已更新；按选中源 id 键控重建详情组件后复验通过，`BottomDrawer` 本身仍常驻。

**Dependencies:** T3.1
**Files touched:** `entry/src/main/ets/components/SourceDetailPanel.ets`（新）、
`entry/src/main/ets/components/SourceRows.ets`、`entry/src/main/ets/pages/BookSourceManage.ets`、
`docs/specs/UI-SPEC.md`、
`docs/research/BOOKSOURCE-REVAMP-TODO.md`、`docs/progress.md`
**Estimated scope:** Small

### Checkpoint 3 — 列表

- [x] map §9-3（滚动 / 搜索 ≤100 ms）与 §9-10（默认视图 + 首屏）有实测
- [x] 删除 / 恢复内置 100% 走确认（T3.2 真机证据）
- [x] 空态齐全（T3.3 真机布局验证）
- [x] T3.4 详情抽屉整行 / 菜单共用、字段一致、关闭后切换不串数据（真机布局验证）
- [x] `UI-SPEC.md` 与实现一致（调用点 8 处）
- [x] `make check` 通过
- [ ] **与人对齐后再进 Phase 5**

**3000 条性能证据（2026-10-18，debug 真机 `33Z0224424136564`）：** 冷启动进入书源页
`init_ms=9` / `list_ms=33` / `total_ms=42` / `first_frame_ms=27` / `page_to_ready_ms=69`
（数据就绪门槛 `<=300 ms`）；默认启用视图 2000/3000 行，搜索框与筛选条首屏可见。实际滑动默认书源、
搜索后 198 行和检测段 3000 行三组时，滚动回调帧距 p50 均为 `8 ms`、p95 均为 `9 ms`，max 分别为
`25` / `23` / `24 ms`，`>=34 ms` 均为 0。搜索防抖后投影 `12 ms`（端到端 `163 ms`）、筛选 `7 ms`、
分组 `8 ms`。书源/检测往返后两段查询、筛选和滚动状态保留。临时探针已移除，设备已恢复 13 条基线。

---

## 6. Phase 4 — `detect-job`（会话 B）

### Task T4.1 `model/DetectJob.ets` 纯状态机（冻结 `@Trace` 字段名）— 已完成（2026-10-18）

**Description:** 把作业状态机写成不依赖任何 `@kit.*` 的纯模块，以便主机仿真覆盖。
**本任务冻结 `@Trace` 字段名**（`T4.3` / `T5.2` 照用）。

**Acceptance criteria:**
- [x] 状态机：`idle → running → done | cancelled → running`，非法迁移被拒绝
- [x] `fingerprint`（源 id 集合 + `mode` + `keyword`）计算与比较为纯函数
- [x] `@Trace` 字段名与语义写明在文件顶部成员索引，并进
      [`../specs/SPEC-DETECT-JOB.md`](../specs/SPEC-DETECT-JOB.md)
- [x] 模块内无 `@kit.*` / `@ohos.*` import

**Verification:**
- [x] `rg -n "@kit\.|@ohos\." model/DetectJob.ets` 无结果
- [x] `make check` 通过

**Dependencies:** None（可最早开工）
**Files likely touched:** `model/DetectJob.ets`（新）、`common/Const.ets`、
`docs/specs/SPEC-DETECT-JOB.md`
**Estimated scope:** Medium

### Task T4.2 主机仿真 + `make test-detect` — 已完成（2026-10-18）

**Description:** 仿 `scripts/tts-pregen-sim.py` 的机械切片 + `tsc` + `node`，把状态机拿到主机上跑。

**Acceptance criteria:**
- [x] `make test-detect` 可运行并覆盖：正常完成 / 取消 / 中断续跑 / fingerprint 不匹配作废 /
      `results.jsonl` 半行损坏的读回
- [x] 仿真用真源码切片（不是副本），切片失败的断言明确报错
- [x] 失败用例能给出可读的期望-实际差异

**Verification:**
- [x] `make test-detect` 通过；故意改坏一个分支确认测试会红
- [x] `make check` 通过

**Dependencies:** T4.1
**Files likely touched:** `scripts/detect-job-sim.py`（新）、`Makefile`
**Estimated scope:** Medium

### Task T4.3 `DetectJobRunner.ets`：分批派发 + 落盘 + 回写 — 已完成（2026-10-18，主机 + debug 真机）

**Description:** 进程级单例（仿 `TtsPregenRunner`）：取批 → `detect(batch, {mode})` →
追加 `results-<轮次戳>.jsonl` → `patchDetect` 单行回写 → 更新 `job.json` → 每批一次 `@Trace`。

**Acceptance criteria:**
- [x] 批大小 32；每批只刷一次 `@Trace`（3000 源 ≈ 94 次，而非 3000 次）
- [x] 结果按轮次落 `results-<轮次戳>.jsonl` 追加写，保留最近 2 轮，更早淘汰
- [x] 重启后读 `job.json`：`fingerprint` 匹配则从 `cursor` 续跑，不匹配则作废
- [x] 单例**不长期持有 `ctx`**（每次短取 `getContext`）

**Verification:**
- [x] 真机：跑到中途强杀 → 重启 → 核对续跑起点与已测条数
- [x] 真机：核对 `results-*.jsonl` 与 `job.json` 内容；确认无整文件重写
- [x] `make check` 通过

**Evidence（2026-10-18，主机）：** `make test-detect` 135 条断言通过，覆盖乱序结果按 canonical id
回映、fingerprint/source count 不匹配作废、stale cursor 重放、JSONL 半行后继续追加、真实 gap 拒绝、
同批重复 source id、两轮结果保留与非法 running/done 状态。`make test` 65 passed、`make hap` 与
`make check`（200 个 keep 名字）通过。

**Evidence（2026-10-18，debug 真机 `33Z0224424136564`）：** 64 条隔离探针源按 32 条分批；首批后
force-stop，`job.json` 为 `running` / `cursor=32`，JSONL 仅 `0 -> 32`。原包重启后记录
`detect cursor reconciled jsonl=32 cursor=32` 并从 32 续跑，最终为 `done` / `cursor=64`，JSONL 追加为
`0 -> 32`、`32 -> 64`，首批行 SHA-256 前后不变。保留测试只留下当前轮与最近一轮；探针清理后
设备恢复 13 条真实源，全表行内容与基线一致，`t1.6-sources.json` 哈希不变。runner 尚未接入生产启动/UI。

**Dependencies:** T1.1、T2.2、T4.1
**Files touched:** `model/DetectJobRunner.ets`（新）、`model/DetectJob.ets`、
`model/SourceStore.ets`、`scripts/detect-job-sim.py`、`entry/obfuscation-rules.txt`
**Estimated scope:** Large → 若动手超过一个会话，拆成「分批派发」与「落盘/续跑」两个任务

### Task T4.4 长时任务 + 取消 + 进度节流 — 已完成（2026-10-19，主机 + debug 真机）

**Description:** 按 `T0.1` 结论接入长时任务（可用则 `DATA_TRANSFER`，否则降级为仅前台推进 +
明示用户）；取消 = 置状态 + 停派发；结束/取消/失败都 `stopBackgroundRunning`。

**Acceptance criteria:**
- [x] 按 A1 结论接入 `dataTransfer`；本机可用，降级状态仅由 runner 暴露，UI 明示归 T5
- [x] 取消后 ≤1 批完全停止，无后续网络请求
- [x] 结束 / 取消 / 失败三条路径都会释放长时任务（无残留常驻通知）
- [x] 与 TTS 播放不互相终止（已有 `audioPlayback` 时合并为 `audioPlayback,dataTransfer`）

**Verification:**
- [x] 真机：取消后超过 20 秒无新批次；任务列表归零，无残留长时任务
- [x] 真机：1024 源 / 32 批 / 约 10m27s 持续推进；T0.1 已实测息屏 606 秒零丢 tick
- [x] `make check` 通过

**Evidence（2026-10-19，主机 + debug 真机 `33Z0224424136564`）：** 96 源完成路径逐批推进
`0 -> 32 -> 64 -> 96` 后进入 `done`；首批在途取消后 `job.json` 为 `cancelled` / `cursor=0`，
JSONL 为 0 行且超过 20 秒无新批次；末批缺源故障进入 `failed` / `cursor=64`。三条路径最终都无残留
长时任务。1024 源探针以 32 批、每批 20 秒延迟运行约 10m27s，最终 `done` / `cursor=1024`，
32 行 JSONL 覆盖全部批次，任务类型为 `dataTransfer`。TTS 先持任务时检测启动沿用同一任务并把模式
更新为 `audioPlayback,dataTransfer`，取消后恢复 `audioPlayback` 且 `ttsPlaying=true`。每批只刷新一次
冻结的 11 个 `@Trace` 字段，进度通知按 30 秒节流。临时探针已清理，设备恢复 13 条基线源；runner 尚未
接入生产启动/UI，Phase 5 未开始。

**Dependencies:** T4.3、T0.1
**Files likely touched:** `model/DetectJobRunner.ets`、`entry/src/main/module.json5`（如需）
**Estimated scope:** Medium

### Checkpoint 4 — 后台作业

- [x] map §9-5（强杀续跑）与 §9-6（息屏/降级）有实测
- [x] 取消 ≤1 批、无残留通知、无残留网络请求
- [x] `@Trace` 更新次数 ≈ 批次数
- [x] `make test-detect` 通过
- [ ] **与人对齐后再进 Phase 5**

---

## 7. Phase 5 — `detect-ui` 与收尾（汇合，单会话串行）

### Task T5.1 `DetectPanel.ets` 检测段

**Description:** 检测段内容：范围条 + 作业卡三态 + 结果面 + 批量动作。

**Acceptance criteria:**
- [ ] 范围条：全部 / 未测 / 上次失败 / 分组 ▾（分组来源 = `bookSourceGroup`）；默认档是**增量**
- [ ] 作业卡三态：运行中（模式 / 已用 / 预计剩余 / 取消）、已完成、已取消（+ 继续）
- [ ] 结果面用 `LazyForEach`，按检测态筛选（与书源段共用同一套维度）
- [ ] 批量动作仅对 `unavailable`，次级样式 + 二次确认 + 明确条数

**Verification:**
- [ ] 真机：三种状态各截一次 `uitest dumpLayout`，`rg` 核对文案与按钮
- [ ] 真机：确认「无结果 / 超时」在结果面上**没有**一键清理入口
- [ ] 3000 条结果滚动流畅
- [ ] `make check` 通过

**Dependencies:** T3.4、T4.3
**Files likely touched:** `components/DetectPanel.ets`（新）、`pages/BookSourceManage.ets`
**Estimated scope:** Medium

### Task T5.2 底部作业条（四态，跨段常驻）

**Description:** 从未检测 / 运行中 / 已完成 / 已取消四态；点击切到检测段。

**Acceptance criteria:**
- [ ] 四态齐备，文案见 [`../specs/SPEC-BOOKSOURCE-LAYOUT.md`](../specs/SPEC-BOOKSOURCE-LAYOUT.md) §3.4
- [ ] 跨段常驻；离开书源页再回来，进度仍是活的
- [ ] 运行中可直接取消（无需先进检测段）

**Verification:**
- [ ] 真机：起作业 → 切段 → 返回列表页 → 再进书源页，进度连续
- [ ] `make check` 通过

**Dependencies:** T5.1
**Files likely touched:** `components/DetectPanel.ets`、`pages/BookSourceManage.ets`
**Estimated scope:** Small

### Task T5.3 增量默认档 + 未测/上次失败筛选

**Description:** 增量窗口（默认 7 天）+ 「未测 / 上次失败」维度接入书源段筛选与检测段范围。

**Acceptance criteria:**
- [ ] 增量窗口常量入 `Const.ets`（7 天），另有「全部重测」入口
- [ ] 书源段可筛「未测 / 上次失败」；检测段可据此选范围
- [ ] 增量档下的耗时显著低于全量（实测对照）

**Verification:**
- [ ] 真机：同一集合分别跑增量与全量，对比耗时
- [ ] `make check` 通过

**Dependencies:** T5.1、T3.3
**Files likely touched:** `components/DetectPanel.ets`、`components/SourceRows.ets`、`common/Const.ets`
**Estimated scope:** Small

### Task T5.4 收尾

**Description:** 文案、文档、兼容性回归与判据核对。

**Acceptance criteria:**
- [ ] 判定口径文案（可用 / 无结果 / 超时 / 不可用 语义）收进按需展开，不常驻
- [ ] `docs/specs/*.md` 与实现对齐；`docs/progress.md` 更新；
      `docs/research/BOOKSOURCE-REVAMP-PLAN.md` §2 的 A1–A12 标记为已落地
- [ ] 备份兼容回归：旧备份可导入、新导出逐字段一致
- [ ] map §9 十条判据逐条有实测证据（缺的补测或改写判据）

**Verification:**
- [ ] `make check` / `make test` / `make run-release` 全通过
- [ ] 逐条核对 map §9，把证据链接写进本文件 Checkpoint 5
- [ ] **与人对齐验收后再宣布完成**

**Dependencies:** T5.1–T5.3
**Files likely touched:** `docs/specs/UI-SPEC.md`、`docs/progress.md`、
`docs/research/BOOKSOURCE-REVAMP-PLAN.md`
**Estimated scope:** Small

### Checkpoint 5 — 完成

- [ ] map §9 十条判据逐条有实测证据
- [ ] `make check` / `make test` / `make run-release` 全通过
- [ ] 备份兼容回归通过
- [ ] **与人对齐验收**

---

## 8. Open Questions（开工前需答 / 实现时必须先定）

1. **`SPEC-SOURCE-LIST.md` Q4：恢复内置是「替换」还是「合并」？** `T3.2` 动手前必须定。
   现状是替换（`resetToBundled`），对已导入数千源的用户是最危险的按钮。
2. **`SPEC-DETECT-UI.md` Q4：预检（L1）与完整（L2）结果的展示粒度。** `T5.1` 动手前必须定
   ——在同一个「可用」列里混两种置信度会误导。
3. **`SPEC-DETECT-UI.md` Q5：是否需要历史轮次对比。** 若需要，`T4.3` 的落盘保留策略要放宽
   （现定保留 2 轮）。
4. **旧 preferences 回退保留几个版本**（现定 1 个）。取决于你对已导入源数量的判断。

## 9. 变更记录

- 2026-10-14：初版。Plan 批准后（同日）追加 A1 降级路径已确认、A7/A9/A10 三条实质变更已回写 spec。
