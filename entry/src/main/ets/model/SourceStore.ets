/**
 * 书源的 SQLite 存储层（独立 `sources.db`，plan A4）—— 落地
 * [`docs/specs/SPEC-SOURCE-STORE.md`](../../../../../docs/specs/SPEC-SOURCE-STORE.md)。
 *
 * 三条要点（改本文件前先读 spec §关键设计决策）：
 * 1. **索引列 + `json` 列**：可查询项建列，完整书源存 `json`。列表 / 筛选只 SELECT 索引列，
 *    **不碰 `json`**——3000 行投影不解析 JSON 正是本模块存在的理由；只有送引擎（`allForEngine`）
 *    与备份导出（`exportAll`）才读 `json`。
 * 2. **自然键 `(url, name)` 唯一**：同 URL 不同名的两条必须各自独立（T-SRC-1 的教训）。
 *    重复导入走 `UPDATE` 原地更新，`id` 不变——`id` 是列表 key，漂了就是第二次 T-SRC-1。
 * 3. **`confidence` 列是权威**：`patchConfidence` 只写列、不重写 `json`（否则每改一次置信度就要
 *    整条序列化）。因此读到 `json` 里的书源后一律用列值覆盖 `confidence`：`json` 里那份可能已过期，
 *    spec §决策 2 明确接受了这份冗余。
 *
 * 成员索引：
 *   建表 / `initSourceStore` / `db()`
 *   投影与筛选：`SourceRow`（**冻结形状**）、`SourceFilter`、`listRows`、`countRows`
 *   完整读：`getSource`、`allForEngine`、`exportAll`
 *   写：`setEnabled`、`remove`、`patchDetect`、`patchConfidence`、`patchConfidences`、
 *      `upsertMany`、`replaceAll`
 */
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BookSource } from '../engine/types';
import { CONFIDENCE_DEFAULT, confidenceAfterStatus } from './SourceConfidence';

export {
  applyOutcomes,
  CONFIDENCE_DEFAULT,
  confidenceAfterStatus,
  confidenceOf,
  penaltyFor,
  sortByConfidence
} from './SourceConfidence';

const DOMAIN: number = 0x0000;
const TAG: string = 'SourceStore';
const DB_NAME: string = 'sources.db';

/** `grp` 而非 `group`（SQL 保留字）；`sort_order` = 导入顺序，列表的稳定排序基准。 */
const CREATE_TABLE: string =
  'CREATE TABLE IF NOT EXISTS sources (' +
  'id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL, name TEXT NOT NULL DEFAULT \'\', ' +
  'grp TEXT, enabled INTEGER NOT NULL DEFAULT 1, sort_order INTEGER, confidence INTEGER, ' +
  'respond_time INTEGER, last_detect_at INTEGER, last_detect_state TEXT, json TEXT NOT NULL)';

const CREATE_UNIQUE_INDEX: string =
  'CREATE UNIQUE INDEX IF NOT EXISTS idx_sources_url_name ON sources (url, name)';

const CREATE_ENABLED_INDEX: string = 'CREATE INDEX IF NOT EXISTS idx_sources_enabled ON sources (enabled)';

/** 投影列（**不含 `json`**）：列表/筛选的读路径只走这几列。 */
const ROW_COLS: string =
  'id, name, url, grp, enabled, confidence, last_detect_state, last_detect_at, respond_time';

/** `json` + `confidence`：需要完整书源的读路径（送引擎 / 导出）。 */
const FULL_COLS: string = 'json, confidence';

let store: relationalStore.RdbStore | undefined = undefined;
/** 并发初始化护栏：两个调用方同一帧里 init 时共用一个 open（否则会开两次库）。 */
let opening: Promise<void> | undefined = undefined;

/**
 * 打开 `sources.db` 并建表建索引。幂等：已打开则直接返回；失败后允许重试。
 * 调用方（`EntryAbility` / 页面）不必等待——本模块其余函数在未初始化时读返回空、写为 no-op。
 */
export function initSourceStore(ctx: common.UIAbilityContext): Promise<void> {
  if (store !== undefined) {
    return Promise.resolve();
  }
  if (opening === undefined) {
    opening = openStore(ctx).catch((err: Error): Promise<void> => {
      opening = undefined;
      throw err;
    });
  }
  return opening;
}

async function openStore(ctx: common.UIAbilityContext): Promise<void> {
  const config: relationalStore.StoreConfig = {
    name: DB_NAME,
    securityLevel: relationalStore.SecurityLevel.S1
  };
  const s: relationalStore.RdbStore = await relationalStore.getRdbStore(ctx, config);
  await s.executeSql(CREATE_TABLE);
  await s.executeSql(CREATE_UNIQUE_INDEX);
  await s.executeSql(CREATE_ENABLED_INDEX);
  store = s;
}

function db(): relationalStore.RdbStore | undefined {
  return store;
}

/**
 * 列表 / 筛选的轻量行投影。**形状已冻结（T1.1）**：后续任务只消费不改。
 * 这 9 个字段足以渲染一行（名称 / 地址 / 分组 / 启停 / 置信度 / 检测态·耗时·时间），
 * 行内不需要任何 JSON 解析。
 */
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

/**
 * 读路径的筛选条件（可选，缺省 = 不过滤）。在 SQL 侧过滤，避免为「仅未测 420 条」
 * 解析 3000 条 `json`；列表页的内存筛选不必走这里（spec §内存策略）。
 */
export interface SourceFilter {
  /** 只取启用（true）/ 停用（false）的源。 */
  enabled?: boolean;
  /** 只取该分组；`''` = 无分组（「默认」组）。 */
  group?: string;
  /** 只取这些检测态；`''` = 未测（对应 `last_detect_state IS NULL`）。空数组 = 不过滤。 */
  states?: string[];
}

/** 计数结果（ArkTS 不允许把对象字面量当类型声明，故具名——`Promise<{...}>` 会编译不过）。 */
export interface SourceCounts {
  total: number;
  enabled: number;
}

/** `upsertMany` 的新增 / 更新条数。 */
export interface UpsertResult {
  added: number;
  updated: number;
}

/** 自然键 + 新置信度。搜索一轮结束后按变化项批量提交，避免全量重写 JSON。 */
export interface ConfidenceUpdate {
  url: string;
  name: string;
  confidence: number;
}

/** 把筛选条件拼成 WHERE 子句，同时按相同顺序把绑定参数 push 进 `args`。 */
function appendFilter(filter: SourceFilter | undefined, args: relationalStore.ValueType[]): string {
  if (filter === undefined) {
    return '';
  }
  const parts: string[] = [];
  if (filter.enabled !== undefined) {
    parts.push('enabled = ?');
    args.push(filter.enabled ? 1 : 0);
  }
  if (filter.group !== undefined) {
    if (filter.group.length === 0) {
      parts.push('(grp IS NULL OR grp = \'\')');
    } else {
      parts.push('grp = ?');
      args.push(filter.group);
    }
  }
  const states: string | undefined = appendStateFilter(filter.states, args);
  if (states !== undefined) {
    parts.push(states);
  }
  return parts.length === 0 ? '' : ' WHERE ' + parts.join(' AND ');
}

/** 检测态条件；返回 `undefined` 表示不需要该条件。 */
function appendStateFilter(states: string[] | undefined, args: relationalStore.ValueType[]): string | undefined {
  if (states === undefined || states.length === 0) {
    return undefined;
  }
  const named: string[] = [];
  let untested: boolean = false;
  for (const st of states) {
    if (st.length === 0) {
      untested = true;
    } else {
      named.push(st);
    }
  }
  const parts: string[] = [];
  if (named.length > 0) {
    const holes: string[] = [];
    for (const st of named) {
      holes.push('?');
      args.push(st);
    }
    parts.push('last_detect_state IN (' + holes.join(', ') + ')');
  }
  if (untested) {
    // NULL 是「从未检测」的存储形态，`= ''` 匹配不到它。
    parts.push('(last_detect_state IS NULL OR last_detect_state = \'\')');
  }
  return parts.length === 1 ? parts[0] : '(' + parts.join(' OR ') + ')';
}

/**
 * 全量轻量投影（按导入顺序）。3000 条 ≈ 0.5 MB 量级，可整套驻内存供列表筛选（spec §内存策略）。
 * 注意：返回顺序即「导入顺序」，列表的二次排序（可用性优先等）应以它为稳定基准。
 */
export async function listRows(filter?: SourceFilter): Promise<SourceRow[]> {
  const out: SourceRow[] = [];
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return out;
  }
  try {
    const args: relationalStore.ValueType[] = [];
    const sql: string =
      'SELECT ' + ROW_COLS + ' FROM sources' + appendFilter(filter, args) + ' ORDER BY sort_order, id';
    const rs: relationalStore.ResultSet = await s.querySql(sql, args);
    // 列下标只解析一次：3000 行 × 9 列，逐格调 getColumnIndex 是白付的开销。
    const cId: number = rs.getColumnIndex('id');
    const cName: number = rs.getColumnIndex('name');
    const cUrl: number = rs.getColumnIndex('url');
    const cGrp: number = rs.getColumnIndex('grp');
    const cEnabled: number = rs.getColumnIndex('enabled');
    const cConf: number = rs.getColumnIndex('confidence');
    const cState: number = rs.getColumnIndex('last_detect_state');
    const cAt: number = rs.getColumnIndex('last_detect_at');
    const cMs: number = rs.getColumnIndex('respond_time');
    while (rs.goToNextRow()) {
      out.push({
        id: rs.getLong(cId),
        name: rs.getString(cName),
        url: rs.getString(cUrl),
        group: rs.isColumnNull(cGrp) ? '' : rs.getString(cGrp),
        enabled: rs.getLong(cEnabled) !== 0,
        // NULL = 从未调整过 → 契约上的缺省满分（`SourceConfidence.confidenceOf` 同口径）。
        confidence: rs.isColumnNull(cConf) ? CONFIDENCE_DEFAULT : rs.getLong(cConf),
        detectState: rs.isColumnNull(cState) ? '' : rs.getString(cState),
        detectAt: rs.isColumnNull(cAt) ? 0 : rs.getLong(cAt),
        respondMs: rs.isColumnNull(cMs) ? 0 : rs.getLong(cMs)
      });
    }
    rs.close();
    return out;
  } catch (err) {
    hilog.error(DOMAIN, TAG, 'listRows failed: %{public}s', JSON.stringify(err));
    throw err as Error;
  }
}

/** 按投影置信度降序排序；调用方负责传入同一启用状态的集合。 */
export function sortRowsByConfidence(rows: SourceRow[]): SourceRow[] {
  const copy: SourceRow[] = rows.slice();
  copy.sort((a: SourceRow, b: SourceRow): number => b.confidence - a.confidence);
  return copy;
}

/** 同一 URL 只保留排序后的首行（稳定 id 仍然独立保留在库内）。 */
export function dedupeRowsByUrl(rows: SourceRow[]): SourceRow[] {
  const seen: Set<string> = new Set<string>();
  const out: SourceRow[] = [];
  for (const row of rows) {
    if (seen.has(row.url)) {
      continue;
    }
    seen.add(row.url);
    out.push(row);
  }
  return out;
}

/** URL → 投影行；同 URL 孪生源优先取启用行，供书架只按实际书籍加载完整规则。 */
export function preferredRowsByUrl(rows: SourceRow[]): Map<string, SourceRow> {
  const out: Map<string, SourceRow> = new Map<string, SourceRow>();
  for (const row of rows) {
    const current: SourceRow | undefined = out.get(row.url);
    if (current === undefined || (!current.enabled && row.enabled)) {
      out.set(row.url, row);
    }
  }
  return out;
}

/** 计数（含筛选）：`total` = 命中条数，`enabled` = 其中启用的条数。 */
export async function countRows(filter?: SourceFilter): Promise<SourceCounts> {
  const s: relationalStore.RdbStore | undefined = db();
  const zero: SourceCounts = { total: 0, enabled: 0 };
  if (s === undefined) {
    return zero;
  }
  const args: relationalStore.ValueType[] = [];
  const sql: string =
    'SELECT COUNT(*) AS total_n, COALESCE(SUM(enabled), 0) AS enabled_n FROM sources' + appendFilter(filter, args);
  const rs: relationalStore.ResultSet = await s.querySql(sql, args);
  const counts: SourceCounts = zero;
  if (rs.goToNextRow()) {
    counts.total = rs.getLong(rs.getColumnIndex('total_n'));
    counts.enabled = rs.getLong(rs.getColumnIndex('enabled_n'));
  }
  rs.close();
  return counts;
}

/** 单条完整书源（详情抽屉 / 规则调试）。 */
export async function getSource(id: number): Promise<BookSource | undefined> {
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return undefined;
  }
  const rs: relationalStore.ResultSet =
    await s.querySql('SELECT ' + FULL_COLS + ' FROM sources WHERE id = ?', [id]);
  let out: BookSource | undefined = undefined;
  if (rs.goToNextRow()) {
    out = parseSource(rs, rs.getColumnIndex('json'), rs.getColumnIndex('confidence'));
  }
  rs.close();
  return out;
}

/** 需要完整书源的读路径（送引擎 / 备份导出）。未初始化的库按空集处理。 */
async function readSources(filter?: SourceFilter): Promise<BookSource[]> {
  const out: BookSource[] = [];
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return out;
  }
  const args: relationalStore.ValueType[] = [];
  const sql: string =
    'SELECT ' + FULL_COLS + ' FROM sources' + appendFilter(filter, args) + ' ORDER BY sort_order, id';
  const rs: relationalStore.ResultSet = await s.querySql(sql, args);
  const cJson: number = rs.getColumnIndex('json');
  const cConf: number = rs.getColumnIndex('confidence');
  while (rs.goToNextRow()) {
    const src: BookSource | undefined = parseSource(rs, cJson, cConf);
    if (src !== undefined) {
      out.push(src);
    }
  }
  rs.close();
  return out;
}

/** 解析一行 `json` 并用权威的 `confidence` 列覆盖（见文件头要点 3）。坏行跳过，不拖垮整批。 */
function parseSource(rs: relationalStore.ResultSet, cJson: number, cConf: number): BookSource | undefined {
  try {
    const src: BookSource = JSON.parse(rs.getString(cJson)) as BookSource;
    if (src === undefined) {
      return undefined;
    }
    if (!rs.isColumnNull(cConf)) {
      src.confidence = rs.getLong(cConf);
    }
    return src;
  } catch (err) {
    hilog.warn(DOMAIN, TAG, 'skip unparsable source row: %{public}s', JSON.stringify(err));
    return undefined;
  }
}

/**
 * 送引擎的书源（按批调用，批大小由 `detect-job` 定）。筛选在 SQL 侧做：
 * 「仅未测 / 仅上次失败 / 按分组」不必把 3000 条 `json` 都解析出来。
 */
export function allForEngine(filter?: SourceFilter): Promise<BookSource[]> {
  return readSources(filter);
}

/** 备份导出：全部书源，保持既有备份文件格式（字段逐一对应，`confidence` 来自列）。 */
export function exportAll(): Promise<BookSource[]> {
  return readSources(undefined);
}

/**
 * 启停单条。**单行 UPDATE，不做任何全量序列化**（spec 成功判据 2）。
 */
export async function setEnabled(id: number, on: boolean): Promise<void> {
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return;
  }
  await s.execute('UPDATE sources SET enabled = ? WHERE id = ?', [on ? 1 : 0, id]);
}

/** 删除单条。**单行 DELETE**：同 URL 不同名的另一条不受影响（T-SRC-1 回归）。 */
export async function remove(id: number): Promise<void> {
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return;
  }
  await s.execute('DELETE FROM sources WHERE id = ?', [id]);
}

/**
 * 回写一次检测结果（`detect-job` 每源一次，故必须是单行 UPDATE）。
 * `at` 由调用方给（同一批共用一个时间戳，便于「上次检测时间」口径一致）。
 */
export async function patchDetect(id: number, state: string, elapsedMs: number, at: number): Promise<void> {
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return;
  }
  await s.executeSql(
    'UPDATE sources SET last_detect_state = ?, respond_time = ?, last_detect_at = ? WHERE id = ?',
    [state, elapsedMs, at, id]
  );
}

/** 回写置信度。只写列，不动 `json`（权威列，见文件头要点 3）。 */
export async function patchConfidence(id: number, value: number): Promise<void> {
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return;
  }
  await s.executeSql('UPDATE sources SET confidence = ? WHERE id = ?', [value, id]);
}

/** 批量回写置信度：单事务、只 UPDATE 列，不做 JSON 序列化。 */
export async function patchConfidences(updates: ConfidenceUpdate[]): Promise<void> {
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined || updates.length === 0) {
    return;
  }
  const tx: relationalStore.Transaction = await s.createTransaction();
  try {
    for (const update of updates) {
      await tx.execute('UPDATE sources SET confidence = ? WHERE url = ? AND name = ?',
        [update.confidence, update.url, update.name]);
    }
    await tx.commit();
  } catch (err) {
    await tx.rollback();
    throw err as Error;
  }
}

/** 自然键 → 行 id。`\u0000` 作分隔符，避免 url/name 自身的字符拼出歧义键。 */
export function sourceNaturalKey(url: string, name: string): string {
  return url + '\u0000' + name;
}

/** 用 SQLite 投影覆盖 `BookSource` 里可能过期的 confidence 副本。 */
export function applyStoredConfidence(sources: BookSource[], rows: SourceRow[]): void {
  const byKey: Map<string, number> = new Map<string, number>();
  for (const row of rows) {
    byKey.set(sourceNaturalKey(row.url, row.name), row.confidence);
  }
  for (const source of sources) {
    const confidence: number | undefined =
      byKey.get(sourceNaturalKey(source.bookSourceUrl, source.bookSourceName));
    if (confidence !== undefined) {
      source.confidence = confidence;
    }
  }
}

/** 单事务读出现有自然键，避免逐条 SELECT（3000 条 = 3000 次往返）。 */
async function loadKeyIds(s: relationalStore.Transaction): Promise<Map<string, number>> {
  const known: Map<string, number> = new Map<string, number>();
  const rs: relationalStore.ResultSet = await s.querySql('SELECT id, url, name FROM sources');
  const cId: number = rs.getColumnIndex('id');
  const cUrl: number = rs.getColumnIndex('url');
  const cName: number = rs.getColumnIndex('name');
  while (rs.goToNextRow()) {
    known.set(sourceNaturalKey(rs.getString(cUrl), rs.getString(cName)), rs.getLong(cId));
  }
  rs.close();
  return known;
}

async function nextSortOrder(s: relationalStore.Transaction): Promise<number> {
  const rs: relationalStore.ResultSet =
    await s.querySql('SELECT COALESCE(MAX(sort_order), -1) + 1 AS next_order FROM sources');
  const next: number = rs.goToNextRow() ? rs.getLong(rs.getColumnIndex('next_order')) : 0;
  rs.close();
  return next;
}

/** `json` 列的原样值 + 索引列。`json` 内的 `confidence` 副本不参与读取（列才是权威）。 */
function bucketOf(src: BookSource): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {
    'url': src.bookSourceUrl,
    'name': src.bookSourceName,
    'grp': src.bookSourceGroup === undefined ? null : src.bookSourceGroup,
    // 与 `SourceRepository.enabledSources` 同口径：缺省 = 启用，只有显式 false 才停用。
    'enabled': src.enabled === false ? 0 : 1,
    // 缺省停 NULL（= 从未调整过），让导出的备份对「没这个字段」的源保持逐字段一致。
    'confidence': src.confidence === undefined ? null : src.confidence,
    'json': JSON.stringify(src)
  };
  return bucket;
}

/**
 * 批量导入 / 更新（导入书源、迁移、备份合并）。**单事务**。
 *
 * 语义（spec §决策 1）：命中自然键 `(url, name)` 即**原地更新** `grp` / `enabled` / `json`，
 * `id`、`sort_order`（导入顺序）、`confidence` 与检测列全部保留——重复导入不能把用户
 * 已调整的置信度和稳定 `id` 冲掉。返回新增 / 更新条数。
 */
export async function upsertMany(list: BookSource[]): Promise<UpsertResult> {
  const s: relationalStore.RdbStore | undefined = db();
  const none: UpsertResult = { added: 0, updated: 0 };
  if (s === undefined || list.length === 0) {
    return none;
  }
  let added: number = 0;
  let updated: number = 0;
  const tx: relationalStore.Transaction = await s.createTransaction();
  try {
    const known: Map<string, number> = await loadKeyIds(tx);
    let nextOrder: number = await nextSortOrder(tx);
    for (const src of list) {
      const id: number | undefined = known.get(sourceNaturalKey(src.bookSourceUrl, src.bookSourceName));
      const bucket: relationalStore.ValuesBucket = bucketOf(src);
      if (id === undefined) {
        bucket['sort_order'] = nextOrder;
        nextOrder += 1;
        await tx.insert('sources', bucket);
        added += 1;
      } else {
        await tx.execute('UPDATE sources SET url = ?, name = ?, grp = ?, enabled = ?, json = ? WHERE id = ?', [
          src.bookSourceUrl,
          src.bookSourceName,
          bucket['grp'],
          bucket['enabled'],
          bucket['json'],
          id
        ]);
        updated += 1;
      }
    }
    await tx.commit();
  } catch (err) {
    await tx.rollback();
    throw err as Error;
  }
  const result: UpsertResult = { added: added, updated: updated };
  return result;
}

/**
 * 全量替换（恢复内置 / 备份恢复的「全量覆盖」）。**单事务**：删空后按入参顺序重建
 * `sort_order`，中途失败则回滚（不会留下半张表）。
 *
 * 输入内的重复自然键用 `ON_CONFLICT_REPLACE` 收敛（后一条胜），不让唯一索引把整批打断。
 * `expectedCount` 用于迁移：提交前在事务内核对实际行数，不一致即回滚。
 */
export async function replaceAll(list: BookSource[], expectedCount?: number): Promise<void> {
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return;
  }
  const tx: relationalStore.Transaction = await s.createTransaction();
  try {
    await tx.execute('DELETE FROM sources');
    let order: number = 0;

    for (const src of list) {
      const bucket: relationalStore.ValuesBucket = bucketOf(src);
      bucket['sort_order'] = order;
      order += 1;
      await tx.insert('sources', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    }
    if (expectedCount !== undefined) {
      const rs: relationalStore.ResultSet = await tx.querySql('SELECT COUNT(*) AS n FROM sources');
      const actual: number = rs.goToNextRow() ? rs.getLong(rs.getColumnIndex('n')) : -1;
      rs.close();
      if (actual !== expectedCount) {
        throw new Error('source count mismatch: expected ' + expectedCount + ', got ' + actual);
      }
    }
    await tx.commit();
  } catch (err) {
    await tx.rollback();
    throw err as Error;
  }
}
