/**
 * T1.6 debug-only storage benchmark.
 *
 * `seedT16Sources` validates the temporary JSON, backs up the current sources, clears the
 * table, and measures one `upsertMany`, one setEnabled with repeated samples, and one remove.
 * The marker survives an app restart. On the next first rendered source-page frame,
 * `measureT16Ready` measures a cold `initSourceStore + listRows`; the caller then restores
 * the backup.
 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  T16_BENCH_BACKUP_FILE,
  T16_BENCH_DATA_FILE,
  T16_BENCH_MARKER_FILE,
  T16_BENCH_ROW_COUNT,
  T16_READY_LIMIT_MS,
  T16_SINGLE_WRITE_LIMIT_MS,
  T16_UPSERT_LIMIT_MS
} from '../common/Const';
import { BookSource } from '../engine/types';
import {
  countRows,
  exportAll,
  getSource,
  initSourceStore,
  listRows,
  remove,
  replaceAll,
  setEnabled,
  sourceNaturalKey,
  SourceRow,
  upsertMany,
  UpsertResult
} from './SourceStore';
import { T16DatasetStats, T16ReadyResult, T16RestoreResult, T16SeedResult } from './SourceStoreBenchTypes';

const DOMAIN: number = 0x0000;
const TAG: string = 'SourceStoreT16';
const MARKER_SEEDING: string = 'seeding';
const MARKER_SEEDED: string = 'seeded';

class ParsedDataset {
  sources: BookSource[];
  stats: T16DatasetStats;

  constructor(sources: BookSource[], stats: T16DatasetStats) {
    this.sources = sources;
    this.stats = stats;
  }
}

function dataPath(ctx: common.UIAbilityContext): string {
  return ctx.filesDir + '/' + T16_BENCH_DATA_FILE;
}

function backupPath(ctx: common.UIAbilityContext): string {
  return ctx.filesDir + '/' + T16_BENCH_BACKUP_FILE;
}

function markerPath(ctx: common.UIAbilityContext): string {
  return ctx.filesDir + '/' + T16_BENCH_MARKER_FILE;
}

function exists(path: string): boolean {
  try {
    return fileIo.accessSync(path);
  } catch (err) {
    return false;
  }
}

function readText(path: string): string {
  if (!exists(path)) {
    throw new Error('missing file: ' + path);
  }
  return fileIo.readTextSync(path);
}

function writeTextVerified(path: string, text: string): void {
  const file: fileIo.File = fileIo.openSync(
    path,
    fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
  );
  try {
    fileIo.writeSync(file.fd, text);
  } finally {
    fileIo.closeSync(file);
  }
  if (readText(path) !== text) {
    throw new Error('write verification failed: ' + path);
  }
}

function deleteIfPresent(path: string): void {
  if (exists(path)) {
    fileIo.unlinkSync(path);
  }
}

function errorText(err: Error): string {
  return err.message.length > 0 ? err.message : 'unknown error';
}

function median(values: number[]): number {
  const sorted: number[] = values.slice().sort((a: number, b: number): number => a - b);
  return sorted[Math.floor(sorted.length / 2)];
}

function maxOf(values: number[]): number {
  let value: number = 0;
  for (const sample of values) {
    value = Math.max(value, sample);
  }
  return value;
}

/** Marker phase: '' / 'seeding' / 'seeded'. */
export function t16MarkerPhase(ctx: common.UIAbilityContext): string {
  try {
    const path: string = markerPath(ctx);
    return exists(path) ? readText(path).trim() : '';
  } catch (err) {
    hilog.warn(DOMAIN, TAG, 'T1.6 marker read failed: %{public}s', errorText(err as Error));
    return '';
  }
}

function parseDataset(raw: string): ParsedDataset {
  const parsed: object = JSON.parse(raw) as object;
  if (parsed === null || !Array.isArray(parsed)) {
    throw new Error('T1.6 dataset is not a JSON array');
  }
  const sources: BookSource[] = parsed as BookSource[];
  if (sources.length !== T16_BENCH_ROW_COUNT) {
    throw new Error('T1.6 dataset rows: expected ' + T16_BENCH_ROW_COUNT + ', got ' + sources.length);
  }

  const keys: Set<string> = new Set<string>();
  const firstNames: Map<string, string> = new Map<string, string>();
  const twinUrls: Set<string> = new Set<string>();
  const groups: Set<string> = new Set<string>();
  let enabled: number = 0;
  let disabled: number = 0;
  for (const source of sources) {
    if (source === null || source === undefined || typeof source !== 'object') {
      throw new Error('T1.6 dataset contains a non-object entry');
    }
    if (typeof source.bookSourceUrl !== 'string' || source.bookSourceUrl.length === 0) {
      throw new Error('T1.6 dataset contains an entry without bookSourceUrl');
    }
    if (typeof source.bookSourceName !== 'string' || source.bookSourceName.length === 0) {
      throw new Error('T1.6 dataset contains an entry without bookSourceName');
    }
    if (typeof source.bookSourceGroup === 'string' && source.bookSourceGroup.length > 0) {
      groups.add(source.bookSourceGroup);
    }
    const key: string = sourceNaturalKey(source.bookSourceUrl, source.bookSourceName);
    if (keys.has(key)) {
      throw new Error('T1.6 dataset contains duplicate natural keys');
    }
    keys.add(key);
    const firstName: string | undefined = firstNames.get(source.bookSourceUrl);
    if (firstName === undefined) {
      firstNames.set(source.bookSourceUrl, source.bookSourceName);
    } else if (firstName !== source.bookSourceName) {
      twinUrls.add(source.bookSourceUrl);
    }
    if (source.enabled === false) {
      disabled += 1;
    } else {
      enabled += 1;
    }
  }
  if (groups.size < 2) {
    throw new Error('T1.6 dataset needs multiple groups');
  }
  if (enabled === 0 || disabled === 0) {
    throw new Error('T1.6 dataset needs mixed enabled states');
  }
  if (twinUrls.size === 0) {
    throw new Error('T1.6 dataset needs same-URL/different-name entries');
  }
  const stats: T16DatasetStats = {
    rows: sources.length,
    groups: groups.size,
    duplicateUrls: twinUrls.size,
    enabled: enabled,
    disabled: disabled
  };
  return new ParsedDataset(sources, stats);
}

/**
 * Back up, seed, and run the single-row/upsert measurements. If anything after the marker
 * write fails, the original sources are restored before the error is rethrown.
 */
export async function seedT16Sources(ctx: common.UIAbilityContext): Promise<T16SeedResult> {
  const existingPhase: string = t16MarkerPhase(ctx);
  if (existingPhase.length > 0) {
    throw new Error('T1.6 benchmark already pending: phase=' + existingPhase);
  }

  const backup: string = backupPath(ctx);
  let markerWritten: boolean = false;
  try {
    const parsed: ParsedDataset = parseDataset(readText(dataPath(ctx)));
    const before: BookSource[] = await exportAll();
    if (before.length === 0) {
      throw new Error('T1.6 refuses to replace an empty source store (backup would be empty)');
    }
    const backupRaw: string = JSON.stringify(before);
    writeTextVerified(backup, backupRaw);

    writeTextVerified(markerPath(ctx), MARKER_SEEDING);
    markerWritten = true;
    await replaceAll([], 0);

    const upsertStart: number = Date.now();
    const upserted: UpsertResult = await upsertMany(parsed.sources);
    const upsertMs: number = Date.now() - upsertStart;
    if (upserted.added !== T16_BENCH_ROW_COUNT || upserted.updated !== 0) {
      throw new Error('T1.6 upsert result mismatch: added=' + upserted.added + ' updated=' + upserted.updated);
    }
    const afterUpsert: number = (await countRows()).total;
    if (afterUpsert !== T16_BENCH_ROW_COUNT) {
      throw new Error('T1.6 rows after upsert: expected ' + T16_BENCH_ROW_COUNT + ', got ' + afterUpsert);
    }
    hilog.info(
      DOMAIN,
      TAG,
      'T1.6 upsert rows=%{public}d added=%{public}d updated=%{public}d ms=%{public}d ' +
        'limit_ms=%{public}d ok=%{public}d',
      T16_BENCH_ROW_COUNT,
      upserted.added,
      upserted.updated,
      upsertMs,
      T16_UPSERT_LIMIT_MS,
      upsertMs <= T16_UPSERT_LIMIT_MS ? 1 : 0
    );

    const rows: SourceRow[] = await listRows();
    if (rows.length < 2 || rows[0].url !== rows[1].url || rows[0].name === rows[1].name) {
      throw new Error('T1.6 dataset order does not start with a same-URL twin pair');
    }
    const first: SourceRow = rows[0];
    const second: SourceRow = rows[1];
    const secondSource: BookSource | undefined = await getSource(second.id);
    if (secondSource === undefined) {
      throw new Error('T1.6 could not load the twin source before remove');
    }

    const toggleStart: number = Date.now();
    await setEnabled(first.id, !first.enabled);
    const setEnabledMs: number = Date.now() - toggleStart;
    const toggledRows: SourceRow[] = await listRows();
    let toggled: SourceRow | undefined = undefined;
    for (const row of toggledRows) {
      if (row.id === first.id) {
        toggled = row;
        break;
      }
    }
    if (toggled === undefined || toggled.enabled === first.enabled) {
      throw new Error('T1.6 setEnabled did not update only the requested row');
    }

    await setEnabled(first.id, first.enabled);
    const toggleSamples: number[] = [setEnabledMs];
    for (let i: number = 0; i < 9; i++) {
      const sampleStart: number = Date.now();
      await setEnabled(first.id, (i % 2) === 0 ? !first.enabled : first.enabled);
      toggleSamples.push(Date.now() - sampleStart);
    }
    await setEnabled(first.id, first.enabled);

    const removeStart: number = Date.now();
    await remove(second.id);
    const removeMs: number = Date.now() - removeStart;
    const afterRemoveRows: SourceRow[] = await listRows();
    if (afterRemoveRows.length !== T16_BENCH_ROW_COUNT - 1) {
      throw new Error('T1.6 remove row count mismatch: ' + afterRemoveRows.length);
    }
    let twinRemained: boolean = false;
    for (const row of afterRemoveRows) {
      if (row.id !== second.id && row.url === second.url && row.name !== second.name) {
        twinRemained = true;
        break;
      }
    }
    if (!twinRemained) {
      throw new Error('T1.6 remove deleted the same-URL twin');
    }
    hilog.info(
      DOMAIN,
      TAG,
      'T1.6 single setEnabled_ms=%{public}d setEnabled_median_ms=%{public}d setEnabled_max_ms=%{public}d ' +
        'remove_ms=%{public}d rows_after_remove=%{public}d twin_remained=%{public}d jsonSerialize=0 ' +
        'limit_ms=%{public}d first_ok=%{public}d median_ok=%{public}d',
      setEnabledMs,
      median(toggleSamples),
      maxOf(toggleSamples),
      removeMs,
      afterRemoveRows.length,
      twinRemained ? 1 : 0,
      T16_SINGLE_WRITE_LIMIT_MS,
      setEnabledMs <= T16_SINGLE_WRITE_LIMIT_MS && removeMs <= T16_SINGLE_WRITE_LIMIT_MS ? 1 : 0,
      median(toggleSamples) <= T16_SINGLE_WRITE_LIMIT_MS && removeMs <= T16_SINGLE_WRITE_LIMIT_MS ? 1 : 0
    );

    await upsertMany([secondSource]);
    const restoredCount: number = (await countRows()).total;
    if (restoredCount !== T16_BENCH_ROW_COUNT) {
      throw new Error('T1.6 failed to restore the removed benchmark row: ' + restoredCount);
    }

    writeTextVerified(markerPath(ctx), MARKER_SEEDED);
    hilog.info(
      DOMAIN,
      TAG,
      'T1.6 seed rows=%{public}d groups=%{public}d twin_urls=%{public}d enabled=%{public}d ' +
        'disabled=%{public}d backup_rows=%{public}d data=%{public}s backup=%{public}s',
      parsed.stats.rows,
      parsed.stats.groups,
      parsed.stats.duplicateUrls,
      parsed.stats.enabled,
      parsed.stats.disabled,
      before.length,
      dataPath(ctx),
      backup
    );
    const result: T16SeedResult = {
      backupRows: before.length,
      upsertMs: upsertMs,
      added: upserted.added,
      updated: upserted.updated,
      setEnabledMs: setEnabledMs,
      removeMs: removeMs,
      rowsAfterRemove: afterRemoveRows.length,
      twinRemained: twinRemained,
      stats: parsed.stats,
      dataPath: dataPath(ctx),
      backupPath: backup
    };
    return result;
  } catch (err) {
    const failure: Error = err as Error;
    hilog.error(
      DOMAIN,
      TAG,
      'T1.6 seed failed: %{public}s data=%{public}s',
      errorText(failure),
      dataPath(ctx)
    );
    if (markerWritten) {
      try {
        const restored: T16RestoreResult = await restoreT16Backup(ctx);
        hilog.info(
          DOMAIN,
          TAG,
          'T1.6 failure restore rows=%{public}d exact=%{public}d',
          restored.rows,
          restored.exact ? 1 : 0
        );
      } catch (restoreErr) {
        hilog.error(
          DOMAIN,
          TAG,
          'T1.6 failure restore error=%{public}s backup=%{public}s',
          errorText(restoreErr as Error),
          backup
        );
      }
    }
    throw failure;
  }
}

/** Measure the page's data path. Call this only after the first frame has rendered. */
export async function measureT16Ready(ctx: common.UIAbilityContext): Promise<T16ReadyResult> {
  const totalStart: number = Date.now();
  const initStart: number = Date.now();
  await initSourceStore(ctx);
  const initMs: number = Date.now() - initStart;
  const listStart: number = Date.now();
  const rows: SourceRow[] = await listRows();
  const listMs: number = Date.now() - listStart;
  const totalMs: number = Date.now() - totalStart;
  if (rows.length !== T16_BENCH_ROW_COUNT) {
    throw new Error('T1.6 readiness rows: expected ' + T16_BENCH_ROW_COUNT + ', got ' + rows.length);
  }
  const result: T16ReadyResult = {
    rows: rows,
    initMs: initMs,
    listMs: listMs,
    totalMs: totalMs
  };
  return result;
}

/** Emit the readiness line after both the first frame and projection are available. */
export function logT16Ready(result: T16ReadyResult, firstFrameMs: number, pageToReadyMs: number): void {
  hilog.info(
    DOMAIN,
    TAG,
    'T1.6 ready init_ms=%{public}d list_ms=%{public}d total_ms=%{public}d rows=%{public}d ' +
      'first_frame_ms=%{public}d page_to_ready_ms=%{public}d limit_ms=%{public}d ok=%{public}d',
    result.initMs,
    result.listMs,
    result.totalMs,
    result.rows.length,
    firstFrameMs,
    pageToReadyMs,
    T16_READY_LIMIT_MS,
    result.totalMs <= T16_READY_LIMIT_MS ? 1 : 0
  );
}

function sameNaturalKeys(a: BookSource[], b: BookSource[]): boolean {
  if (a.length !== b.length) {
    return false;
  }
  const keys: Set<string> = new Set<string>();
  for (const source of a) {
    keys.add(sourceNaturalKey(source.bookSourceUrl, source.bookSourceName));
  }
  if (keys.size !== b.length) {
    return false;
  }
  for (const source of b) {
    if (!keys.has(sourceNaturalKey(source.bookSourceUrl, source.bookSourceName))) {
      return false;
    }
  }
  return true;
}

/** Restore the pre-benchmark sources and retain the backup file as recovery evidence. */
export async function restoreT16Backup(ctx: common.UIAbilityContext): Promise<T16RestoreResult> {
  const backup: string = backupPath(ctx);
  const raw: string = readText(backup);
  const parsed: object = JSON.parse(raw) as object;
  if (parsed === null || !Array.isArray(parsed)) {
    throw new Error('T1.6 backup is not a JSON array');
  }
  const expected: BookSource[] = parsed as BookSource[];
  await replaceAll(expected, expected.length);
  const actual: BookSource[] = await exportAll();
  if (!sameNaturalKeys(expected, actual)) {
    throw new Error('T1.6 restore natural-key verification failed');
  }
  const count: number = (await countRows()).total;
  if (count !== expected.length) {
    throw new Error('T1.6 restore row count: expected ' + expected.length + ', got ' + count);
  }
  const exact: boolean = JSON.stringify(actual) === raw;
  deleteIfPresent(markerPath(ctx));
  hilog.info(
    DOMAIN,
    TAG,
    'T1.6 restore rows=%{public}d exact=%{public}d backup=%{public}s',
    count,
    exact ? 1 : 0,
    backup
  );
  const result: T16RestoreResult = { rows: count, exact: exact };
  return result;
}
