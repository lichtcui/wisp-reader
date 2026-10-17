# BOOKSOURCE-REVAMP — 实施计划（Phase 2: Plan）

状态：**已批准（2026-10-14）** · 上游：[`../specs/SPEC-BOOKSOURCE-REVAMP.md`](../specs/SPEC-BOOKSOURCE-REVAMP.md)（capability map + 共享契约）

> 存放位置说明：skill 默认 `tasks/plan.md`，但本仓库 `AGENTS.md` 规定根目录只允许
> `AGENTS.md` / `README.md` / `Makefile`、新文档一律进 `docs/` 子目录，且「方案 → `docs/research/`」
> 已有先例。故存于此处，沿用项目约定。
>
> 本文件 = Phase 2 产出（架构决定 / 依赖图 / 切片顺序 / 风险 / 检查点）。
> **Phase 3（Tasks）的逐任务卡片**已产出：
> [`BOOKSOURCE-REVAMP-TODO.md`](./BOOKSOURCE-REVAMP-TODO.md)（20 个任务 + 6 个检查点 + 并行分工）。

## 1. Overview

把书源管理从「13 条内置源的能跑页面」改造为「3000 条可用」，分五层：存储换 SQLite（`source-store`）、
检测分两档（`detect-engine`）、大列表 UI（`source-list`）、可续跑后台作业（`detect-job`）、
进度与结果面（`detect-ui`）；页面按布局 2 两段式重排。

## 2. 架构决定（Plan 阶段新增，需同步回 spec）

| # | 决定 | 理由 | 要改的 spec |
|---|---|---|---|
| A1 | **长时任务用 `BackgroundMode.DATA_TRANSFER`（T0.1 真机已定 2026-10-15）**：可用，息屏 **606 秒零丢 tick**；**一个 UIAbility 只能一个任务**（`9800005`），与 TTS 并存须用「一个任务带多类型」（`bgModes[]` / `updateBackgroundRunning`，@since 12）；受 SDK 硬约束「**>10 分钟不更新进度即取消**（进度通知须为实况窗 live view）」⇒ 每批更新进度、超长作业分片。降级路径（仅前台推进，2026-10-14 批准）**未触发** | 作业跑十数分钟，息屏中断等于白跑；实测停表恰在 10 分 03 秒，与 SDK 原文吻合。**新 P0**：TTS 侧长时任务 24 秒即被系统停（`AVSessionNotifyUpdateNotification` 失败 `980000502`）⇒ 「边听书边跑作业」须先修该 P0 | `SPEC-DETECT-JOB.md` §3.6 ✅已回写；证据 [`T0.1-LONG-TASK-EVIDENCE.md`](./T0.1-LONG-TASK-EVIDENCE.md) |
| A2 | **并发上限 = 16、L1 超时 = 8 s**（T0.2 实测 + 用户确认，2026-10-15），写入 `Const.ets` 单一常量；实施在 `T2.2` | 实测 L1 吞吐：并发 8/16/32/64 = 312/582/879/1241 源/分钟；失败构成在 8→32 **逐项相同**（`blocked` 恒 5.8%），64 才见超时率抬头（5.9%→6.9%）。取 16（1.86×）= 优先保守（在途 TLS 连接数 ≤16，手机侧未实测）；3000 源 L1 单轮 ≈4.4 min（判据 ≤20 min 留 ~4.5× 余量），真机若 >15 min 则上调 32（数据已备） | `SPEC-DETECT-ENGINE.md` §3.3/§3.5 ✅已回写 |
| A3 | **检测分组来源 = `bookSourceGroup` 字段**（即 `source-store` 的 `grp` 列）；「用户勾选」= 多选模式，后置 | 字段是唯一现成数据源；多选是纯增量 UI | `SPEC-DETECT-UI.md` §3 范围入口 |
| A4 | **新建独立 `sources.db`**，不复用 `shelf.db` | 备份恢复目前把「源」与「书架」生命周期绑在一起；分库后书的清理不会动到源 | `SPEC-SOURCE-STORE.md` 开放问题 2 |
| A5 | **迁移静默进行 + 保留旧 preferences 键 1 个版本 + 迁移前自动导出一份备份到 filesDir + 条数校验** | 对已导入数千源的用户，迁移失败等于数据全失 | `SPEC-SOURCE-STORE.md` §Success 4 / 开放问题 3–4 |
| A6 | **`confidence` 一并迁入 `sources` 表**（作为列），不再随全量 blob 走 | 否则又留下第二套存储与第二次全量 parse | `SPEC-SOURCE-STORE.md` 开放问题 5 |
| A7 | **检测结果保留最近 2 轮，每轮一个 `results-<轮次戳>.jsonl`**，更早轮次淘汰 | 单文件追加写会无限增长；两轮够做「上一轮 vs 本轮」对比 | `SPEC-DETECT-JOB.md` §3.3 ✅已回写 |
| A8 | **增量窗口默认 7 天**，常量入 `Const.ets`，另留「全部重测」入口 | 与 `TTS_PREGEN_*` 同类开关的既有做法一致 | `SPEC-DETECT-UI.md` §3.4 ✅已回写 |
| A9 | **分组只做筛选**（`分组 ▾` 选一个组看），不做分组分段展示/sticky 头（MVP） | 3000 条下 flat list + 排序已够；分段展示会与「异常置顶」排序冲突 | `SPEC-SOURCE-LIST.md` §4 ✅已回写 |
| A10 | **异常置顶分三档**：需处理（`不可用`）/ 待复查（`未测`、`超时`、`无结果`）/ 正常（`可用`） | 直接按「异常」排序会把 `超时`/`无结果` 与真坏源混在一起，误导用户去清理它们（语义见 `SPEC-DETECT-UI.md`） | `SPEC-BOOKSOURCE-LAYOUT.md` §3.2 ✅已回写 |
| A11 | **`＋` / `⋯` 放段选择器同排的页内行**，不用 `NavDestination.menus()` | 不依赖导航栏空间、不引入新先例 | `SPEC-BOOKSOURCE-LAYOUT.md` §6 ✅已回写 |
| A12 | **筛选 chips 在计数为 0 时隐藏**（「全部」「启用」除外）；**段切换不记忆**，总是「书源」段 | 满屏 0 值 chip 是噪音；段记忆价值低、可预测性优先 | `SPEC-BOOKSOURCE-LAYOUT.md` §6 ✅已回写 |

## 3. 依赖图

```
                    ┌──────────────── T0.1 真机：长时任务能力 ────────┐
   Phase 0 门禁 ────┤                                                  ├──→ 决定 A1
   （高风险前置）    └──────────────── T0.2 实测：并发 / 超时 ─────────┘──→ 决定 A2

   ┌─ Phase 1  source-store ────────────┐
   │   T1.1 表 + 接口                    │
   │   T1.2 迁移（幂等 + 回退）          │
   │   T1.3 confidence 迁入              │──────┐
   │   T1.4 消费点 A（备份 / 换源）      │      │
   │   T1.5 消费点 B（阅读链路）         │      │
   │   T1.6 3000 造数 + 性能实测         │      │
   └────────────────────────────────────┘      │
                                                ├──→ Phase 5  detect-ui（汇合点）
   ┌─ Phase 2  detect-engine（可并行）──┐      │      T5.1 检测段
   │   T2.1 respondTime 接回           │      │      T5.2 底部作业条
   │   T2.2 detect(mode) 两档          │──┐   │      T5.3 增量默认档
   │   T2.3 真值表 + 真源实测          │  │   │      T5.4 收尾
   └───────────────────────────────────┘  │   │
                                          │   │
   ┌─ Phase 3  source-list ─────────────┐ │   │
   │   T3.1 页面骨架（段 + LazyForEach）│ │   │
   │   T3.2 行 + ⋯ 菜单 + 确认          │─┼───┘
   │   T3.3 搜索 / 筛选 / 排序          │ │
   │   T3.4 详情抽屉 + UI-SPEC 同步     │ │
   └────────────────────────────────────┘ │
                                          │
   ┌─ Phase 4  detect-job ──────────────┐ │
   │   T4.1 纯状态机 DetectJob.ets      │ │
   │   T4.2 主机仿真 + make test-detect │ │
   │   T4.3 Runner：分批 / 落盘 / 回写  │ │
   │   T4.4 长时任务 + 取消 + 节流      │←┘
   └────────────────────────────────────┘
```

依赖方向（模块 spec §3 已定，此处落到任务）：`source-store` ∥ `detect-engine` → `source-list` ∥
`detect-job` → `detect-ui`。

## 4. 实施顺序与并行性

**必须串行**
- Phase 0 的两个门禁结论（A1 / A2）→ 它们决定 Phase 4 与 Phase 2 的参数，必须先出结果。
- `T1.2`（迁移）→ `T1.4` / `T1.5`（消费点切换）：迁移没跑通就切消费点，等于把数据读丢。
- `T2.1` → `T2.2` → `T2.3`（同一条 Rust 链路上的连续改动）。
- Phase 5 内部：`T5.3` 依赖 `T5.1`；全部收在 `T5.4`。

**可并行**（互不碰同一文件、互不依赖）
- `T0.1`（真机 + `module.json5`）∥ `T0.2`（`make probe` 测速，主机）。
- **Phase 1 ∥ Phase 2**：ArkTS 存储层 vs Rust 引擎，文件集与工具链完全不重叠。
- **Phase 3 ∥ Phase 4**：`T3.*` 只依赖 Phase 1（读投影）；`T4.*` 依赖 Phase 1 + 2。
  `T4.1`（纯状态机，无 `@kit.*`）甚至可以和 Phase 1 一起开工。
- `T1.4` ∥ `T1.5`（不同文件集，都只依赖 `T1.2`）。

**需要先对齐契约再并行**
- `T4.3` 与 `T5.2`：都读 `DetectJobRunner` 的 `@Trace` 字段。字段名在 `T4.1` 一次性定死，
  写进 `SPEC-DETECT-JOB.md`，两边照它做。
- `T1.1` 与 `T3.*`：`SourceRow` 投影形状在 `T1.1` 定死（`const` 级），`T3.*` 只消费不改。

## 5. 任务清单（checklist 形态；逐任务卡片见 Phase 3 的 TODO 文件）

### Phase 0 — 门禁验证（高风险前置，fail fast）

- [ ] **T0.1 长时任务能力验证（真机）** — 确认 `BackgroundMode.DATA_TRANSFER` 是否存在且可用；
  与正在播放的 TTS（`AUDIO_PLAYBACK`）能否并存；息屏 10 分钟是否真的继续。**产出 A1 决定**。
  - Files: `entry/src/main/module.json5`（如需）、`docs/research/`（结论记录）
- [x] **T0.2 并发 / 超时实测调参** ✅（2026-10-15）— 用 `scripts/detect-bench.py`（把 `make probe` 包成
  「抽样 → 多档 → 多轮 → 统计」）对 3180 条真实源抽 400 条跑并发 8/16/32/**64**，每档 2 轮，记录吞吐、
  超时率、失败构成。**产出 A2 决定：并发 16 / L1 超时 8 s**（见 §2 A2）。
  - Files: `scripts/detect-bench.py`（新增）、`docs/specs/SPEC-DETECT-ENGINE.md` §3.3/§3.5、
    `docs/research/BOOKSOURCE-REVAMP-TODO.md` §T0.2

### Checkpoint 0 — 门禁
- [x] **A2 已写入** `SPEC-DETECT-ENGINE.md` §3.3/§3.5（并发 **16** / L1 **8 s**，2026-10-15，T0.2 实测
      + 用户确认）
- [x] **A1 已写入** `SPEC-DETECT-JOB.md` §3.6（`DATA_TRANSFER` 可用 + 息屏 606 s 零丢 tick +
      「一任务多类型」才是并存正解 + 10 分钟进度硬约束；真机 2026-10-15，证据
      [`T0.1-LONG-TASK-EVIDENCE.md`](./T0.1-LONG-TASK-EVIDENCE.md)）
- [x] A1 **未触发**降级路径（`DATA_TRANSFER` 可用）；Phase 4 范围不变。**新增前置 P0**：
      TTS 长时任务不成立（`docs/bugfix/TASKS.md` 第三十一次同步）——不在 Phase 4 范围，但阻塞「边听书边跑作业」的验收
- [ ] **与人对齐后再进 Phase 1**

### Phase 1 — `source-store`（地基）

- [x] **T1.1 `SourceStore.ets`：建表 + 接口** — `sources` 表（索引列 + JSON 列）、`SourceRow` 投影、
  `listRows` / `countRows` / `getSource` / `setEnabled` / `remove` / `upsertMany` / `replaceAll`；
  全是单行或单事务写，无全量序列化。
  - Files: `model/SourceStore.ets`（新）、`common/Const.ets`
- [x] **T1.2 迁移：preferences → SQLite** — 幂等；保留旧键 1 个版本；迁移前自动导出备份到
  `filesDir`；条数校验（迁移后 `countRows` 必须等于迁移前解析出的条数）。**产出 A5 落地**。
      2026-10-17 真机双启动通过：`migrated count=13` → `already-migrated count=0`，备份逐字节一致。
  - Files: `model/SourceStore.ets`、`model/SourceStoreMigration.ets`（新）、`model/SourceRepository.ets`
- [x] **T1.3 `confidence` 迁入 `sources` 表**（A6）
      2026-10-17 真机通过：搜索后按自然键批量更新列，force-stop 重启后同一 `(url, name)` 的值仍在。
  - Files: `model/SourceStore.ets`、`model/SourceConfidence.ets`
- [x] **T1.4 消费点切换 A：备份导出/导入 + 换源面板** — 去掉这两处的全量 parse。
      2026-10-17 真机通过：导出格式逐字段不变，旧备份可导入，换源面板改走投影查询。
  - Files: `pages/BackupManage.ets`、`components/SourceSwitchPanel.ets`、`model/SourceStore.ets`
- [x] **T1.5 消费点切换 B：阅读链路** — 启动 / 书架 / 搜索结果三处改走投影查询。
      2026-10-17 真机通过：启动、书架、搜索、换源链路一致，`loadSources` 只剩定义。
  - Files: `pages/Index.ets`、`pages/Shelf.ets`、`pages/SearchResult.ets`
- [x] **T1.6 3000 条造数入口 + 性能实测（真机）** — 一次性造数路径（导入一份 3000 条 JSON），
  实测冷启动就绪时间、单条 toggle、`upsertMany`。
      2026-10-17 真机通过：`upsertMany=477 ms`、冷就绪 `44 ms`（首帧 `18 ms`）、首次 toggle `10 ms` /
      中位 `1 ms`、remove `1 ms`、`jsonSerialize=0`；恢复原 13 条 `exact=1`。前一轮首次 toggle `20 ms`
      作为调度抖动风险保留。证据 → [`T1.6-SOURCE-STORE-BENCH.md`](./T1.6-SOURCE-STORE-BENCH.md)。
  - Files: 调试入口（置于书源页隐藏菜单）、`common/Const.ets`

### Checkpoint 1 — 存储地基
- [x] 3000 条下进页面数据就绪 ≤ 300 ms、首帧不阻塞（对应 map §9-1）
- [x] 单条 toggle / 删除 ≤ 16 ms 且不触发全量序列化（map §9-2）
- [x] 迁移幂等：连跑两次结果一致；旧 preferences 键仍在
- [x] 备份导出 JSON 与既有格式逐字段一致（map §9-7）
- [x] `make check` 通过

### Phase 2 — `detect-engine`（可与 Phase 1 并行）

- [ ] **T2.1 `respond_time` / `last_update_time` 接回** — Rust struct 补字段（现在 serde 静默丢弃），
  三处同步。
  - Files: `rust/legado-engine/src/types.rs`、`engine/types.ets`、`entry/obfuscation-rules.txt`
- [ ] **T2.2 `detect` 加 `mode`（probe 早退）** — `lib.rs` 的 `///` 是契约唯一来源 → `make rust`
  重生成 `index.d.ts` → Napi 层透传 `mode`。
  - Files: `rust/legado-engine/src/runtime.rs`、`rust/legado-core/src/lib.rs`、
  `engine/BookEngineNapi.ets`、`cpp/types/liblegado_core/index.d.ts`（生成，勿手改）
- [ ] **T2.3 L1/L2 真值表 + 真源实测** — `make test` 覆盖「L1 命中 / L1 未命中 / L2 目录阶段失败」
  三条路由；`make probe` 用真源对比 L1 与 L2 的耗时与结论一致性（重点核 **L1 未命中必须记
  `no_results` 而不是 `unavailable`**）。
  - Files: `rust/legado-engine/src/runtime.rs`（tests）、`docs/research/`（实测记录）

### Checkpoint 2 — 引擎两档
- [ ] L1 的 `DetectResult` 与 L2 形状一致、`stage` 复用既有 `FailReason`
- [ ] **L1 未命中 ≠ `unavailable`**（否则一键清理会误删可用源）
- [ ] `mode` 在 release 包下可读（`make run-release`；map §9-8）
- [ ] `make test` 通过

### Phase 3 — `source-list`（依赖 Phase 1）

- [ ] **T3.1 页面骨架** — `SegmentedCell` 两段 + 段内容容器 + `LazyForEach` 列表 + `＋`/`⋯` 页内行
  （A11）+ 底部作业条占位。撤掉现存的导入区与「工具」组。
  - Files: `pages/BookSourceManage.ets`
- [ ] **T3.2 行 + `⋯` 菜单 + 确认弹窗** — 两行式行、行尾 `⋯`（详情 / 启停 / 删除）、`AlertDialog`
  二次确认；「恢复内置」文案点明会替换全部书源。
  - Files: `components/SourceRows.ets`（新）、`pages/BookSourceManage.ets`
- [ ] **T3.3 搜索 / 筛选 / 排序** — 搜索防抖 150 ms；筛选 chips（0 值隐藏，A12）；默认视图
  「启用 + 三档排序」（A10）；分组筛选（A9）；空态两种。
  - Files: `components/SourceRows.ets`、`pages/BookSourceManage.ets`、`common/Const.ets`
- [ ] **T3.4 详情抽屉 + UI-SPEC 同步** — `SourceDetailPanel.ets` 替代现在的 `statusContent()`
  「书源状态」内容；同步 `docs/specs/UI-SPEC.md` §2 第 6 处调用点的名称与用途（**调用点数量不变，
  仍 8 处**）。
  - Files: `components/SourceDetailPanel.ets`（新）、`pages/BookSourceManage.ets`、
  `ui/common/BottomDrawer.ets`（不改，确认）、`docs/specs/UI-SPEC.md`

### Checkpoint 3 — 列表
- [ ] 3000 行滚动无可感知掉帧；搜索输入到更新 ≤ 100 ms（map §9-3）
- [ ] 默认视图为「启用」且异常分档置顶、搜索框与筛选条在首屏（map §9-10）
- [ ] 删除 / 恢复内置 100% 走确认；取消后数据与落盘都不变
- [ ] 空态（无搜索结果、0 条书源）都有出口
- [ ] `docs/specs/UI-SPEC.md` 与实现一致（调用点仍 8 处）

### Phase 4 — `detect-job`（依赖 Phase 1 + 2）

- [ ] **T4.1 `model/DetectJob.ets` 纯状态机** — 不依赖任何 `@kit.*`，可被主机仿真；状态机
  `idle → running → done | cancelled → running`；`fingerprint`（源 id 集合 + mode + keyword）判定；
  `@Trace` 字段名在此定死（`T4.3` / `T5.2` 照用）。
  - Files: `model/DetectJob.ets`（新）、`common/Const.ets`
- [ ] **T4.2 主机仿真 + `make test-detect`** — 仿 `scripts/tts-pregen-sim.py` 的机械切片 + `tsc` +
  `node`；覆盖正常完成 / 取消 / 中断续跑 / fingerprint 不匹配作废 / `results.jsonl` 半行损坏。
  - Files: `scripts/detect-job-sim.py`（新）、`Makefile`
- [ ] **T4.3 `DetectJobRunner.ets`：分批派发 + 落盘 + 回写** — 批 32；每批
  `bookEngine.detect(batch, {mode})` → `results-<轮次戳>.jsonl` 追加 → `patchDetect` 单行回写 →
  更新 `job.json` + 每批一次 `@Trace`；单例仿 `TtsPregenRunner`；**不长期持有 `ctx`**。
  - Files: `model/DetectJobRunner.ets`（新）、`model/DetectJob.ets`、`model/SourceStore.ets`
- [ ] **T4.4 长时任务 + 取消 + 进度节流** — 按 T0.1 结论接入；取消 = 置状态 + 停派发；结束/取消/
  失败 `stopBackgroundRunning`。
  - Files: `model/DetectJobRunner.ets`、`entry/src/main/module.json5`（如需）

### Checkpoint 4 — 后台作业
- [ ] 强杀进程 → 重启从 `cursor` 续跑，已完成结果不丢、不重复（map §9-5）
- [ ] 取消后 ≤ 1 批完全停止，无后续网络请求
- [ ] 息屏 10 分钟继续推进（map §9-6）；与 TTS 播放共存不互相终止
- [ ] `@Trace` 更新次数 ≈ 批次数，而非源数
- [ ] `make test-detect` 通过

### Phase 5 — `detect-ui` 与收尾（汇合点）

- [ ] **T5.1 `DetectPanel.ets` 检测段** — 范围条（全部 / 未测 / 上次失败 / 分组 ▾，A3）；
  作业卡三态（运行中 / 已完成 / 已取消 + 继续）；结果面 `LazyForEach` + 检测态筛选；
  批量动作（关闭不可用 / 删除不可用，次级样式 + 二次确认）。
  - Files: `components/DetectPanel.ets`（新）、`pages/BookSourceManage.ets`
- [ ] **T5.2 底部作业条四态**（跨段常驻）— 从未检测 / 运行中 / 已完成 / 已取消；点击切到检测段。
  - Files: `components/DetectPanel.ets`、`pages/BookSourceManage.ets`
- [ ] **T5.3 增量默认档 + 未测 / 上次失败筛选**（A8）
  - Files: `components/DetectPanel.ets`、`components/SourceRows.ets`、`common/Const.ets`
- [ ] **T5.4 收尾** — 判定口径文案收进按需展开；`docs/specs/UI-SPEC.md` 与
  `docs/specs/SPEC-*.md` 与实现对齐；`docs/progress.md` 更新；备份格式兼容回归；
  release 契约验证；map §9 十条判据逐条核。
  - Files: `docs/specs/UI-SPEC.md`、`docs/progress.md`、`docs/research/BOOKSOURCE-REVAMP-PLAN.md`

### Checkpoint 5 — 完成
- [ ] map §9 十条成功判据逐条有实测证据
- [ ] `make check` / `make test` / `make run-release` 全通过
- [ ] 备份兼容回归：旧备份可导入，新导出逐字段一致
- [ ] **与人对齐验收后再宣布完成**

## 6. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| `DATA_TRANSFER` 不存在，或不能与 TTS 播放并存 | **高**（`detect-job` 的息屏能力整体失效） | T0.1 前置验证（fail fast）；降级路径已定（仅前台推进 + 明示），降级后 map §9-6 判据改为「应用在前台时推进」 |
| 3000 源在并发 16 下仍 > 20 分钟 | 中（不达 map §9-4） | **T0.2 已完成（2026-10-15）**：主机实测并发 **16** → L1 单轮 ≈**4.4 min**（判据 ≤20 min 留 ~4.5× 余量），L1 超时取 **8 s**；真机数字由 `T1.6`/`T2.3` 补，若 >15 min 则上调 32（实测 ≈2.9 min，数据已备，改一个常量）；另有「分钟级增量」作主路径、全量作低频动作 |
| 提高并发被站点 ban / 大量误判 `unavailable` | **高**（可用源被误删） | **T0.2 已完成**：并发 8/16/32 的失败构成逐项一致（`blocked` 恒 5.8% 且是同一批 23 个源、`rate_limited` 0.5%），逐源比对 6 次观测无「某档 ok、某档失败」→ 取 **16** 未引入新的 ban 风险（64 才见超时率 5.9%→6.9%）；L1 未命中记 `no_results`（不是 `unavailable`）→ 不参与一键清理 |
| 迁移丢数据（用户已导入数千源） | **高**（不可逆数据损失） | A5：幂等 + 保留旧键 + 迁移前自动导出备份 + 条数校验；T1.2 单独一步、T1.4/T1.5 在其后 |
| 同 URL 不同名被误合并 | 中 | 自然键 `(url, name)`；T1.1 加唯一索引前的核对；T1.6 实测含同 URL 用例 |
| release 下新增 JSON 字段读成 `undefined` | 中 | 三处同步 + `make check` + `make run-release`（Phase 2/4 每个 checkpoint 都跑） |
| 真机造 3000 条困难（ArkTS 只能真机跑） | 中 | T1.6 做一次性造数入口；造数据文件本身放 `filesDir`，不入仓库 |
| `@ObservedV2` 单例长期持 `ctx` 泄漏 | 中 | T4.3 明确规定短取 `getContext`，不存字段 |
| 布局 2 两段各持一份 3000 行数据源 → 双倍内存 | 低 | 两段共用同一份投影（`T3.1` 明确） |
| 段切换导致列表滚动位置/筛选丢失 | 低 | `T3.1` 两段各自保留状态；A12 只定「进页面总是书源段」 |

## 7. 与 spec 的差异汇总（获批后需回写）

`A1`–`A12` 全部要回写到对应 spec（见 §2 表的最后一列）。其中三条是**实质变更**，不是补充：

1. **A7**：`SPEC-DETECT-JOB.md` §3.3 原写「单个 `results.jsonl` 追加写」，改为「每轮一个文件、
   保留最近 2 轮」。
2. **A9**：`SPEC-SOURCE-LIST.md` §4 原写「分组头显示组内条数与启用数」（隐含分段展示），
   改为「分组只做筛选」；`SPEC-SOURCE-LIST.md` 开放问题 2（sticky 头）随之消解。
3. **A10**：`SPEC-BOOKSOURCE-LAYOUT.md` §3.2 原写排序键 `不可用 → 超时 → 无结果 → 未测 → 可用`，
   改为三档（需处理 / 待复查 / 正常）；`SPEC-BOOKSOURCE-LAYOUT.md` §6.3 随之消解。

## 8. Open Questions

**已答（2026-10-14 批准时）**

1. ~~A1 降级路径是否可接受~~ **已确认**：若 T0.1 判定 `DATA_TRANSFER` 不可用，降级为「仅前台推进 +
   UI 明示离开会暂停」，map §9-6 判据相应改为「应用在前台时持续推进」。已回写 `SPEC-DETECT-JOB.md` §3.6。
2. ~~Phase 1 与 Phase 2 是否并行~~ **已确认：并行（两会话）**。分工与协调点见
   [`BOOKSOURCE-REVAMP-TODO.md`](./BOOKSOURCE-REVAMP-TODO.md) §1。

**仍未答（不阻塞 Phase 0–2，但对应任务动手前必须先定）**

3. `SPEC-SOURCE-LIST.md` Q4：恢复内置「替换 vs 合并」——`T3.2` 动手前必须定。
4. `SPEC-DETECT-UI.md` Q4：预检/完整结果的展示粒度——`T5.1` 动手前必须定。
5. `SPEC-DETECT-UI.md` Q5：是否需要历史轮次对比——若需要，`T4.3` 的保留策略要放宽。
6. 旧 preferences 回退保留几个版本（现定 1 个）。
