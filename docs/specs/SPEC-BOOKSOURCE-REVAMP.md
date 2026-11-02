# SPEC — 书源管理改造（capability map + 共享契约）

状态：**待批准（draft）** · 更新：2026-10-14 · 基线：当前工作区

> 本文件是本次改造的**索引与共享契约**：模块 id、依赖方向、构建顺序，以及各模块 spec 共用的
> Commands / Project Structure / Code Style / Testing Strategy / Boundaries。
>
> 逐模块 spec（按 id 命名，均在本目录）：[`SPEC-SOURCE-STORE.md`](./SPEC-SOURCE-STORE.md)、
> [`SPEC-SOURCE-LIST.md`](./SPEC-SOURCE-LIST.md)、[`SPEC-DETECT-ENGINE.md`](./SPEC-DETECT-ENGINE.md)、
> [`SPEC-DETECT-JOB.md`](./SPEC-DETECT-JOB.md)、[`SPEC-DETECT-UI.md`](./SPEC-DETECT-UI.md)。
> 跨模块的页面布局决定单列在 [`SPEC-BOOKSOURCE-LAYOUT.md`](./SPEC-BOOKSOURCE-LAYOUT.md)。
> 下游任务按 **模块 id** 选取工作，不靠猜文件名。

## 1. 为什么做

原判「书源管理页面很混乱」经量化后不成立：**页面排版是次要问题，3000 条书源同时压穿了三个结构性上限**。

| 面 | 现状 | 3000 条下 | 证据 |
|---|---|---|---|
| 存储 | 全部书源进 preferences 单键 `book_sources_v1`，每次改动 `JSON.stringify(全量)`+`putSync`+`flush()` | 内置 13 条实测 1832 B/源 → **5.2–7 MB 单值**（官方定位轻量 KV） | `model/SourceRepository.ets:23,40`、`common/Prefs.ets:84` |
| 启动 | 7 处调用点各自 `getString`+`JSON.parse` 全量，再各跑一遍 filter/dedupe/sort | 每次进页面**主线程 parse 5–7 MB** | `Index.ets:140`、`Shelf.ets:53`、`SearchResult.ets:108-109`、`BookSourceManage.ets:155,612`、`BackupManage.ets:42,57`、`components/SourceSwitchPanel.ets:220` |
| 列表 | `Scroll > Column > ForEach` 全量建组件；`enabledSources()` 在 `build` 里每帧跑 | **3000 行一次性建组件** | `pages/BookSourceManage.ets:577,612` |
| 检测 | 单次 `detect()` 全量过桥；每源 ≥4 次网络请求（搜索→详情→目录→首章）；并发硬编码 4、Rust clamp 上限 8、单源默认超时 45 s；**无进度 / 无取消 / 无续传 / 不落盘** | 现实 **1–5 小时**（最坏 45s×3000/4≈9.4 h） | `rust/legado-engine/src/runtime.rs:439-452,479+`、`engine/BookEngineNapi.ets`、`rust/legado-core/src/lib.rs:113-132` |

`detect` 是 NAPI async（不阻塞 JS 线程），所以缺的不是线程，而是**进度、取消、断点续传、落盘**。

**最大的单点杠杆是检测策略**：每源从「4+ 请求的完整链路」降为「1 次搜索请求的预检」，3000 源的
单轮时长从小时级降到十数分钟级；再叠加增量（只测待测）与分组，可降到分钟级。

## 2. 已批准的范围决定

| # | 决定 | 选择 |
|---|---|---|
| 1 | 交付范围 | **全五层**（含分层预检 + 增量） |
| 2 | 「后台运行」语义 | **系统长时任务：息屏继续**（需权限 + 常驻通知） |
| 3 | 检测策略 | **分层预检 + 增量**（分组 / 多选范围已于 2026-11-02 撤，见 §5） |
| 4 | 书源存储 | **迁到 SQLite 表**（复用 `relationalStore` 先例） |
| 5 | 页面布局 | **单一主体（书源列表）+ 检测任务态**（[`SPEC-BOOKSOURCE-LAYOUT.md`](./SPEC-BOOKSOURCE-LAYOUT.md) §3；2026-11-02 取代「布局 2 两段式」） |
| 6 | 3000 条默认视图 | **全量 + 检测异常置顶**（同上 §3.2；2026-11-02 起不再默认筛「启用」） |
| 7 | 单源操作入口 | **行尾「⋯」菜单 + 确认弹窗**（详情用抽屉，同上 §3.2） |

## 3. Capability map

| 模块 id | 职责 | 依赖 |
|---|---|---|
| `source-store` | 书源持久化层：SQLite 表取代 preferences 单键；单行读写；分页/筛选查询；轻量行投影 | — |
| `detect-engine` | 分层检测策略：L1 预检 / L2 完整链路两档；`respondTime` 接回 | — |
| `source-list` | 大列表 UI：`LazyForEach` + 三档排序 + 行操作（含危险操作确认）；搜索 / 筛选已于 2026-11-02 撤 | `source-store` |
| `detect-job` | 后台任务：分批派发、进度、取消、增量落盘、重启续跑、长时任务 | `source-store`、`detect-engine` |
| `detect-ui` | 进度与结果呈现：任务态进度卡、完成摘要、一键清理、检测范围入口（范围与计数写进 `⋯` 菜单项） | `detect-job`、`source-list` |

依赖方向单向、无环。边界契约（表结构、作业状态机、落盘格式、NAPI 签名）写在**提供方**模块的 spec 内。

**构建顺序：** `source-store` ∥ `detect-engine` → `source-list` ∥ `detect-job` → `detect-ui`

`source-store` 与 `detect-engine` 互不依赖，可并行；`source-list` 与 `detect-job` 各自只依赖其中一个，
也可并行；`detect-ui` 是两个分支的汇合点。

## 4. 共享：Commands

```bash
make hap           # 编译 debug HAP
make hap-release   # 编译 release HAP（含混淆 + 签名）
make run           # 编译 → 安装 → force-stop → 启动（真机闭环）
make run-release   # 同上，release 包（验 JSON 契约 / keep 列表）
make rust          # 交叉编译 .so + 生成并拷 index.d.ts（勿手改）
make test          # rust/legado-engine 的 cargo test（不碰真机）
make probe         # 主机直接跑引擎（例：make probe ARGS='源.json search 剑来'）
make test-pregen   # 主机仿真「客户端纯逻辑」（scripts/tts-pregen-sim.py）
make check         # 行号目录 / md 失效链接 / JSON keep 列表 / hilog 格式串
make log           # 抓日志
```

新增主机仿真（见 §7）沿用 `make test-pregen` 的命名与写法，target 名待定（建议 `make test-detect`）。

## 5. 共享：Project Structure

```
entry/src/main/ets/model/SourceStore.ets        ← 新  source-store：SQLite 表（建表/迁移/查询/单行写）
entry/src/main/ets/model/DetectJob.ets          ← 新  detect-job：作业契约 + 纯函数（可主机仿真）
entry/src/main/ets/model/DetectJobRunner.ets    ← 新  detect-job：进程级单例（仿 TtsPregenRunner）
entry/src/main/ets/components/SourceRows.ets    ← 新  source-list：行组件 + 三档排序
entry/src/main/ets/components/SourceDetailPanel.ets
                                                ← 新  单源详情抽屉内容（替代现「书源状态」抽屉）
entry/src/main/ets/components/DetectProgressCard.ets
                                                ← 新  detect-ui：任务态整页检测视图 + 完成摘要
                                                    （2026-11-02 取代 `DetectPanel.ets`）
entry/src/main/ets/pages/BookSourceManage.ets   ← 改  壳：头行（汇总 + `⋯`）+ 任务态切换 + 组装
entry/src/main/ets/ui/common/BottomDrawer.ets   ← 不改  仍 8 处调用点（第 6 处改名「书源详情」）
docs/specs/UI-SPEC.md                          ← 改  第 6 处调用点的名称与用途
entry/src/main/ets/pages/{Shelf,SearchResult,BackupManage,Index}.ets
                                                ← 改  改走 source-store，去掉 loadSources 全量
entry/src/main/ets/components/SourceSwitchPanel.ets
                                                ← 改  同上
entry/src/main/ets/model/SourceConfidence.ets   ← 改  confidence 落到 source-store（见开放问题 7）
entry/src/main/ets/engine/types.ets             ← 改  respondTime / lastUpdateTime / DetectState
entry/src/main/ets/engine/BookEngineNapi.ets    ← 改  mode 透传
entry/src/main/cpp/types/liblegado_core/index.d.ts
                                                ← 生成 勿手改（make rust 产物）
rust/legado-engine/src/{runtime.rs,types.rs}    ← 改  probe 模式 + respond_time 字段
rust/legado-core/src/lib.rs                     ← 改  /// 是 NAPI 契约的唯一来源
entry/src/main/ets/common/Const.ets             ← 改  批大小 / 增量窗口 / 并发等常量
entry/obfuscation-rules.txt                     ← 改  新增 JSON 字段名
```

## 6. 共享：Code Style

沿用仓库既有约定，不新立风格。关键几条：

- **组件一律 `@ComponentV2` + `@Local` / `@Param` / `@Event`**（禁 `@State` / `@Prop`，禁令 D7）。
- **颜色只走 `color.json` 令牌**（禁硬编码色值，禁令 D8）：`$r('app.color.text_1')` 等。
- **NAPI 契约单点**：签名与 `///` 说明只写在 `rust/legado-core/src/lib.rs`；`index.d.ts` 是 `make rust` 产物，
  不得手改；`docs/engine.md` 只写语义。
- **JSON 字段名三处同步**：Rust struct / `engine/types.ets` / `entry/obfuscation-rules.txt` keep 列表。
- 大 `.ets` 顶部写成员名索引（只有名字、无行号）。

```ts
// 进程级单例 + @Trace 驱动 UI（仿 model/TtsPregenRunner.ets:34-56）
@ObservedV2
export class DetectJobRunner {
  private static shared: DetectJobRunner | undefined = undefined;

  static instance(): DetectJobRunner {
    if (DetectJobRunner.shared === undefined) {
      DetectJobRunner.shared = new DetectJobRunner();
    }
    return DetectJobRunner.shared;
  }

  @Trace running: boolean = false;
  @Trace done: number = 0;
  @Trace total: number = 0;
  @Trace message: string = '';
}
```

## 7. 共享：Testing Strategy

| 层次 | 手段 | 用于 |
|---|---|---|
| 引擎规则 / 分层预检路由 | `make test`（`cargo test`）+ `make probe ARGS='…'`（真源真网） | `detect-engine` |
| 客户端纯逻辑 | **主机仿真**（真源码机械切片 + `tsc` + `node`，仿 `scripts/tts-pregen-sim.py`） | `detect-job`：分批边界、增量筛选真值表、进度/续跑状态机 |
| UI 与闭环 | `make run` + `uitest dumpLayout` + `rg` 日志 | `source-list`、`detect-ui` |
| JSON 契约 | `make check`（`scripts/check-keep-props.sh` 机械核对）+ `make run-release` | 所有新增落盘/过桥字段 |
| 存储层 | 一次性迁移幂等性 + 3000 条造数脚本（主机无法跑 ArkTS，靠真机造数） | `source-store` |
| 长时任务 | 真机息屏 10 分钟推进 + 与 TTS 播放共存 | `detect-job` |

纯逻辑必须放成不依赖 `@kit.*` 的模块（`DetectJob.ets`），才能被主机仿真覆盖——这是把状态机
从 UI 里剥出来的主要动机。

## 8. 共享：Boundaries

**Always**
- 改完走 `make run` 闭环；动 Rust 先 `make test`；改引擎规则先 `make probe`。
- 新增/变更任何跨 NAPI 或落盘的 JSON 字段 → 三处同步 + `make check`。
- 新文档进 `docs/` 对应子目录，同步更新引用它的链接。

**Ask first**
- 变更 NAPI 契约（`lib.rs` 的 `///`）——含 `detect` 的 `mode` 参数与新增字段。
- 变更 `shelf.db` 表结构，或新建独立 DB 文件。
- 提高引擎并发上限（站点压力 / 被 ban 风险）。
- 改动 `docs/specs/UI-SPEC.md` 记录的 `BottomDrawer` 调用点清单。
- 一次性的数据迁移策略变更（回退路径）。

**Never**
- 违反既有禁令：引擎降级（D1）、ArkTS 侧发书源请求（D2）、证书放行（D2）、`@State`/`@Prop`（D7）、
  阅读排版改回纵向滚动（D5）、换配色（D8）、v1 范围外功能（D10/D11）。
- 在 preferences 里继续存放书源全量 JSON。
- 把 5 MB 级 JSON 一次性过 NAPI 边界，或一次性 `JSON.parse` 全量书源。
- 在 `build` 里做随列表长度增长的计算（filter / sort / map）。

## 9. 成功判据（可度量）

1. 3000 条书源下进入书源管理页，**首帧不阻塞**、数据就绪 ≤ 300 ms（现为每次主线程 parse 5–7 MB）。
2. 单条 toggle / 删除落盘为 O(1)：不序列化全量，UI 无可见卡顿（≤ 16 ms）。
3. 3000 行列表滚动无可感知掉帧。（~~搜索输入到列表更新 ≤ 100 ms~~ —— 2026-11-02 随搜索一起撤除。）
4. L1 预检 3000 源，8 并发下**现实 ≤ 20 分钟**（对比现状 1–5 小时），全程有进度、可取消。
5. 检测中途强杀进程 → 重启 → 从落盘进度续跑，**已完成结果不丢**、不从头重跑。
6. 长时任务：息屏 10 分钟期间检测继续推进（真机验证）。
7. 备份导出 JSON 与 `BACKUP_SCHEMA_VERSION` 既有格式**逐字段兼容**，旧备份文件仍可导入。
8. release 包下所有新增落盘字段可读（`make check` + `make run-release` 通过）。
9. `make test` 与 `make check` 通过。
10. 3000 条下打开书源页：**全量列表且检测异常态置顶**，页面体不含第二组工具栏
    （2026-11-02 起不再默认筛「启用」，也不再有搜索框 / 筛选条 / 分段）。

## 10. Open Questions（批准前需答）

**阻塞实现（必须先定）**

1. ~~页面信息架构~~ **已定（2026-11-02 改版）**：单一主体（书源列表）+ 检测任务态 + 页内头行单一
   `⋯`；搜索 / 筛选 / 分段 / 底部作业条已撤。见
   [`SPEC-BOOKSOURCE-LAYOUT.md`](./SPEC-BOOKSOURCE-LAYOUT.md) §3 与 §7（改版理由与已知代价）。
2. ~~**检测范围怎么选。**~~ **已收敛（2026-11-02）**：范围与计数写进 `⋯` 菜单项
   （`检测书源（增量 N）` / `全部重测（M）`），不再有范围条；**分组检测已撤**（分组选择器随之撤除）。
3. **并发上限提到多少。** Rust 现为 `clamp(1, 8)`（`runtime.rs:452`），`BookEngineNapi` 传 4。
   3000 源场景下 8 明显偏低，但提高并发有站点压力与被 ban 风险，需要显式决定目标值与依据。
4. **`BackgroundMode.DATA_TRANSFER` 是否存在且可用。** 现仓库只用过 `AUDIO_PLAYBACK`
   （`TtsController.ets:633`）。同时需确认「长时任务与 TTS 播放并存」是否允许（同一应用能否持有
   两个长时任务）——这是 `detect-job` 的实现前提，须真机验证。

**可后置（不阻塞拆分任务，但需在对应模块实现前答）**

5. 增量窗口默认天数（建议 7 天）与是否需要「全部重测」入口。
6. L1 预检用的关键词：复用 `DEFAULT_DETECT_KEYWORD`（当前为「重生」）？预检命中判定与阈值。
7. `confidence` 是否一并从 preferences 迁进 `source-store`（现随 `BookSource` 全量 blob 落盘，
   `model/SourceConfidence.ets`）。
8. 检测结果的保留策略：留几轮、淘汰规则、是否上限条数。
9. 复用 `shelf.db` 加表，还是新建独立 `sources.db`。
10. 迁移时机的用户可见性：首次启动静默迁移，还是提示？迁移失败的回退路径（保留旧 preferences 键？）。
11. 是否新增「未测 / 上次失败」这类筛选维度（增量策略的 UI 面）。
