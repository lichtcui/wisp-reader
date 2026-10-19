# SPEC — `source-store`

状态：**T1.1–T1.3 已落地（2026-10-17）** · 归属：[`SPEC-BOOKSOURCE-REVAMP.md`](./SPEC-BOOKSOURCE-REVAMP.md) 模块 `source-store`
Commands / Project Structure / Code Style / Testing Strategy / Boundaries 见 map 文件 §4–§8，本文只写本模块特有内容。

## Objective

让 3000 条书源在**冷启动、单条改动、查询筛选**三件事上都不再做全量工作，并使书源数据脱离
preferences 单值。这是其他四个模块的地基。

用户可见的成功：进书源页不再等 1 s+；切一个开关不再卡一下；3000 行的列表能滚、能搜。

## Non-goals

- 不改书源 JSON 的语义与字段（规则字段原样保留，仍是引擎的输入）。
- 不改备份文件的导出格式（`BackupPayload` + `BACKUP_SCHEMA_VERSION` 保持逐字段兼容）。
- 不引入 ORM / 不引入新依赖（只用 `@kit.ArkData` 的 `relationalStore`）。
- 不做书源的在线更新与规则字段编辑（v1 范围外，D10/D11）。

## 关键设计决策

**1. 稳定主键。** 现在书源没有 id，列表 key 靠 `url + '#' + index + '#' + enabled` 拼出来
（`pages/BookSourceManage.ets:651-658`），这是 T-SRC-1 事故的产物：同 URL 不同名的两条必须共存，
而 `index` 会随删除漂移。表给出 `id INTEGER PRIMARY KEY`，**自然键取 `(url, name)`** 并加唯一索引——
它既满足「同 URL 多条共存」，又让重复导入能原地更新而不是插重复。

**2. 索引列 + JSON 列。** 书源有 20+ 个字段，但只有少数需要查询/投影。表中为可查询项建列，
完整 JSON 存 `json` 列：

- 好处：规则字段不用一一映射成列（新增规则字段不用改 schema），同时列表的轻量投影不必解析 JSON。
- 代价：`json` 列冗余了索引列的数据（接受：写路径是单行/批量事务，不敏感）。

```sql
CREATE TABLE IF NOT EXISTS sources (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  url              TEXT    NOT NULL,
  name             TEXT    NOT NULL DEFAULT '',
  grp              TEXT,
  enabled          INTEGER NOT NULL DEFAULT 1,
  sort_order       INTEGER,
  confidence       INTEGER,
  respond_time     INTEGER,
  last_detect_at   INTEGER,
  last_detect_state TEXT,
  json             TEXT    NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_sources_url_name ON sources (url, name);
CREATE INDEX IF NOT EXISTS idx_sources_enabled ON sources (enabled);
```

（`grp` 而非 `group`：`group` 是 SQL 保留字。）

**3. 轻量行投影。** 列表与筛选只持 `SourceRow`，不持 3000 个完整 `BookSource`（每个含多条规则字符串）。
完整 `BookSource` 只在送引擎（分批）与详情/备份导出时按需取。

**`SourceRow` 形状已冻结（T1.1，2026-10-14）**：后续任务（`T3.*` / `T4.3`）**只消费不改**；
要加字段先改本文件并知会两条线。

```ts
// entry/src/main/ets/model/SourceStore.ets
export interface SourceRow {
  id: number;
  name: string;
  url: string;
  group: string;
  enabled: boolean;
  confidence: number;
  /** '' 表示从未检测。取值同 DetectState：ok | noResult | timeout | unavailable */
  detectState: string;
  detectAt: number;
  respondMs: number;
}
```

## Interface（**已冻结：T1.1 实现签名**）

以下签名 = `entry/src/main/ets/model/SourceStore.ets` 的实际导出（实现见该文件）。
两处与早期草案不同，均为 ArkTS 编译约束所迫（`arkts-no-obj-literals-as-types`：对象字面量不能当类型）：

- `countRows` 返回具名 `SourceCounts` 而非 `Promise<{ total; enabled }>`；
- `upsertMany` 返回具名 `UpsertResult` 而非 `Promise<{ added; updated }>`。

```ts
import { relationalStore } from '@kit.ArkData';
import { BookSource } from '../engine/types';

export interface SourceFilter {
  enabled?: boolean;   // 只取启用 / 停用
  group?: string;      // 只取该分组；'' = 无分组（「默认」组）
  states?: string[];   // 只取这些检测态；'' = 未测（last_detect_state IS NULL）
}
export interface SourceCounts { total: number; enabled: number }
export interface UpsertResult { added: number; updated: number }
export interface ConfidenceUpdate { url: string; name: string; confidence: number }
export interface DetectPatch { id: number; state: string; elapsedMs: number; at: number }

initSourceStore(ctx: common.UIAbilityContext): Promise<void>      // 建表建索引，幂等
/** 首次启动把 preferences 的 book_sources_v1 迁入；幂等，旧键保留作回退。 */
migrateFromPrefsOnce(ctx: common.UIAbilityContext): Promise<MigrateResult>

// 读（投影优先）
listRows(filter?: SourceFilter): Promise<SourceRow[]>          // 全量投影，见 §内存策略
countRows(filter?: SourceFilter): Promise<SourceCounts>
getSource(id: number): Promise<BookSource | undefined>         // 解析 json 列
sourcesForEngine(ids: number[]): Promise<EngineSource[]>       // 稳定 id 批读；400 个 id 一组，按输入顺序返回
sourcesForUrls(urls: string[]): Promise<Map<string, BookSource>> // 书架 URL 批读；去重、400 组、按输入顺序返回
allForEngine(filter?: SourceFilter): Promise<BookSource[]>     // 送 NAPI，按批调用
                               // 筛选在 SQL 侧做（避免为「仅未测 420 条」解析 3000 条 json）
exportAll(): Promise<BookSource[]>                             // 备份导出，保持既有格式

// 写（单行/单事务，不做全量重写）
setEnabled(id: number, on: boolean): Promise<void>
setEnabledMany(ids: number[], on: boolean): Promise<void>       // 单事务；按 400 个 id 分块 UPDATE
remove(id: number): Promise<void>
removeMany(ids: number[]): Promise<void>                       // 单事务；按 400 个 id 分块 DELETE
patchDetect(id: number, state: string, elapsedMs: number, at: number): Promise<void>
patchDetects(updates: DetectPatch[]): Promise<void>            // 单事务；一批检测结果一次提交
patchConfidence(id: number, value: number): Promise<void>
patchConfidences(updates: ConfidenceUpdate[]): Promise<void>     // 单事务，按 (url, name) 只更新 confidence 列
upsertMany(list: BookSource[]): Promise<UpsertResult>           // 单事务，自然键命中即原地更新
replaceAll(list: BookSource[], expectedCount?: number): Promise<void>
                                                               // 恢复内置 / 备份恢复；迁移传入条数做事务内核对
sourceNaturalKey(url: string, name: string): string
applyStoredConfidence(sources: BookSource[], rows: SourceRow[]): void
                                                               // 用投影列覆盖 BookSource 里的旧 confidence 副本
```

**三条实现约定（T1.1–T1.3 落地时定，写路径改动必须遵守）：**

- **`enabled` / `confidence` 列是权威**：启停与置信度写路径只 `UPDATE` 索引列，不重写 `json`（否则每次
  切换或调权都要整条序列化）。因此凡从 `json` 读出 `BookSource` 的路径（`getSource` / `sourcesForEngine` /
  `sourcesForUrls` / `allForEngine` / `exportAll`）一律用列值覆盖这两个字段；`confidence` 缺省存 `NULL`
  （= 从未调整过），导出时该字段照旧省略，与既有备份逐字段一致。
- **重复导入更新 `grp` / `enabled` / `json`，保留 `id` / `sort_order` / `confidence` / 检测列**：
  再次导入同一份文件不能把用户已调整的置信度与稳定 `id` 冲掉（`id` 是列表 key，漂了就是第二次 T-SRC-1），
  也不能把「已检测」退回「未测」。
- **置信度变更不重写 `json`**：搜索结束后调用方只收集发生变化的自然键 → `patchConfidences()` 单事务
  更新列；读取完整 `BookSource` 的消费点必须用投影列覆盖旧副本。
- **批量写边界**：`setEnabledMany` / `removeMany` 的 id 先去非法值、去重，再以 400 个为一组拼
  `IN (...)`（低于 SQLite 常见的 999 个绑定变量上限）；整批仍由一个事务提交。`patchDetects()` 的
  每条 UPDATE 使用自己的结果时间戳，但整批共用一次 commit。单条入口保留给行内开关 / 菜单操作，
  页面级「全部不可用」与检测作业不得退化为逐行 await。
- **按 id 批读边界**：`sourcesForEngine()` 对输入 id 去非法值、去重后以 400 个为一组查询；结果按去重后的
  输入顺序返回，缺失或 JSON 损坏的行跳过。这样检测续跑、书架装配在超大批次下也不会撞 SQLite 绑定变量上限。
- **按 URL 批读边界**：`sourcesForUrls()` 对书架实际使用的 URL 去空、去重后以 400 个为一组查询完整规则，
  结果只包含输入顺序可命中的 URL。同 URL 孪生源优先取最早的启用行；没有可解析的启用行时，回退到最早的
  可解析行。坏 JSON 不会提前占位，后续候选仍可被选中；缺失与全坏 URL 直接省略。

**内存策略（明确的门槛）：** 3000 条投影 ≈ 0.5 MB 量级，可全量驻内存，搜索/筛选在内存完成（最快、
无往返）。**超过 2 万条再改为 SQL 分页查询**——这条门槛写死在这里，免得以后争论。

## Success Criteria

1. 3000 条下 `initSourceStore` + 首批投影就绪 ≤ 300 ms，且首帧不阻塞。
2. `setEnabled` / `remove` 为单行操作，端到端 ≤ 16 ms，不做任何全量序列化。
3. `upsertMany` 3000 条单事务 ≤ 2 s；`replaceAll` 同量级。
4. 迁移幂等：连续调用两次结果一致；迁移后旧 preferences 键**保留**（回退路径，见开放问题 4）。
5. 同一 URL 不同名的两条各自有独立 `id`，启停/删除互不影响（T-SRC-1 的回归不重演）。
6. 旧版导出的备份 JSON 可导入；新版导出的 JSON 与既有格式逐字段一致。

## Boundaries

- **Ask first**：表结构变更；复用 `shelf.db` 还是新建 `sources.db`；迁移的回退策略变更。
- **Never**：在 preferences 继续存放书源全量 JSON；把规则字段拆成 20+ 列；
  在 `build` 里做随列表长度增长的 filter/sort/map。

## Open Questions

1. 自然键 `(url, name)` 是否足够？是否存在同 URL 同名但规则不同的两条（若有，重复导入会误合并）。
2. ~~复用 `shelf.db` 还是新建 `sources.db`~~ **已定（2026-10-14）**：新建独立 `sources.db`。
   理由：备份恢复目前把「源」与「书架」生命周期绑在一起，分库后清理书不会动到源。
3. ~~迁移的用户可见性~~ **已定**：静默迁移，不打断启动，但**迁移前自动导出一份备份到 `filesDir`**
   并做条数校验（不一致即中止）；失败不破坏旧键。
4. ~~旧 preferences 键保留多久~~ **已定**：保留 1 个版本作为回退。
5. ~~`confidence` 是否一并迁入~~ **已定**：迁入 `sources.confidence` 列，不再随全量 blob 落盘
   （否则又留下第二套存储与第二次全量 parse）。
