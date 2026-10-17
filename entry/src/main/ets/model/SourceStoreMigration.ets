/**
 * One-way migration from the legacy `book_sources_v1` preferences blob to `sources.db`.
 *
 * The legacy key is intentionally kept as the one-version rollback path. A byte-for-byte
 * backup is written before parsing, and `replaceAll` verifies the row count inside its
 * transaction before commit.
 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { getBoolean, getString, putBooleanStrict } from '../common/Prefs';
import { BookSource } from '../engine/types';
import { KEY_SOURCES, loadBundled } from './SourceRepository';
import { countRows, initSourceStore, listRows, replaceAll, SourceRow } from './SourceStore';

export const SOURCE_MIGRATION_MARKER: string = 'source_store_migrated_v1';
const BACKUP_NAME: string = 'book-sources-v1.pre-migration.json';

export interface MigrateResult {
  status: string;
  count: number;
  backupPath: string;
}

let migrating: Promise<MigrateResult> | undefined = undefined;
let ensuring: Promise<MigrateResult> | undefined = undefined;

/**
 * Store entry used by pages: initialize, migrate the legacy blob once, and seed the bundled
 * set exactly once on a fresh install. The marker distinguishes "never initialized" from
 * "user deliberately deleted every source", so an empty table is not reseeded forever.
 */
export function ensureSourceStore(ctx: common.UIAbilityContext): Promise<MigrateResult> {
  if (ensuring === undefined) {
    ensuring = ensureRun(ctx).catch((err: Error): Promise<MigrateResult> => {
      ensuring = undefined;
      throw err;
    });
  }
  return ensuring;
}

async function ensureRun(ctx: common.UIAbilityContext): Promise<MigrateResult> {
  // The marker means "do not parse the legacy blob again", not "the SQLite store is
  // already open in this process". Always open first so every page shares one store.
  await initSourceStore(ctx);
  const migrated: MigrateResult = await migrateFromPrefsOnce(ctx);
  if (migrated.status !== 'no-source-preferences' || getBoolean(ctx, SOURCE_MIGRATION_MARKER, false)) {
    return migrated;
  }
  if ((await countRows()).total > 0) {
    return migrated;
  }
  const bundled: BookSource[] = loadBundled(ctx);
  if (bundled.length === 0) {
    return migrated;
  }
  await replaceAll(bundled, bundled.length);
  putBooleanStrict(ctx, SOURCE_MIGRATION_MARKER, true);
  return result('bundled-seeded', bundled.length, ctx.filesDir + '/' + BACKUP_NAME);
}

/** Shared by startup and page reads so two callers cannot migrate the same blob concurrently. */
export async function migrateFromPrefsOnce(ctx: common.UIAbilityContext): Promise<MigrateResult> {
  if (migrating === undefined) {
    migrating = runMigration(ctx).then((migrated: MigrateResult): MigrateResult => {
      // The UI may seed bundled sources just after startup; allow a later retry when this
      // first pass found no legacy blob.
      if (migrated.status === 'no-source-preferences') {
        migrating = undefined;
      }
      return migrated;
    }).catch((err: Error): Promise<MigrateResult> => {
      migrating = undefined;
      throw err;
    });
  }
  return migrating;
}

async function runMigration(ctx: common.UIAbilityContext): Promise<MigrateResult> {
  const backupPath: string = ctx.filesDir + '/' + BACKUP_NAME;
  if (getBoolean(ctx, SOURCE_MIGRATION_MARKER, false)) {
    return result('already-migrated', 0, backupPath);
  }

  const raw: string = getString(ctx, KEY_SOURCES, '');
  if (raw.length === 0) {
    return result('no-source-preferences', 0, backupPath);
  }

  writeBackup(backupPath, raw);
  const sources: BookSource[] = parseAndValidate(raw);
  const keys: Set<string> = naturalKeys(sources);

  await initSourceStore(ctx);
  const before: number = (await countRows()).total;
  if (before > 0) {
    if (sameStoredKeys(await listRows(), keys)) {
      // A previous run committed the data but crashed before flushing the marker.
      putBooleanStrict(ctx, SOURCE_MIGRATION_MARKER, true);
      return result('recovered-after-marker-failure', sources.length, backupPath);
    }
    throw new Error('cannot migrate into non-empty sources table (rows=' + before + ')');
  }

  await replaceAll(sources, sources.length);
  const after: number = (await countRows()).total;
  if (after !== sources.length) {
    throw new Error('post-migration source count mismatch: expected ' + sources.length + ', got ' + after);
  }
  putBooleanStrict(ctx, SOURCE_MIGRATION_MARKER, true);
  return result('migrated', sources.length, backupPath);
}

function result(status: string, count: number, backupPath: string): MigrateResult {
  return { status: status, count: count, backupPath: backupPath };
}

function writeBackup(path: string, raw: string): void {
  const file: fileIo.File = fileIo.openSync(
    path,
    fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
  );
  try {
    fileIo.writeSync(file.fd, raw);
  } finally {
    fileIo.closeSync(file);
  }
  const written: string = fileIo.readTextSync(path);
  if (written !== raw) {
    throw new Error('migration backup verification failed: ' + path);
  }
}

function parseAndValidate(raw: string): BookSource[] {
  const list: BookSource[] = JSON.parse(raw) as BookSource[];
  if (!Array.isArray(list)) {
    throw new Error('book_sources_v1 is not a JSON array');
  }
  const seen: Set<string> = new Set<string>();
  for (const src of list) {
    if (src === undefined || src === null || typeof src !== 'object') {
      throw new Error('book_sources_v1 contains a non-object entry');
    }
    if (typeof src.bookSourceUrl !== 'string' || src.bookSourceUrl.length === 0) {
      throw new Error('book_sources_v1 contains an entry without bookSourceUrl');
    }
    if (typeof src.bookSourceName !== 'string') {
      throw new Error('book_sources_v1 contains an entry without bookSourceName');
    }
    const key: string = naturalKey(src.bookSourceUrl, src.bookSourceName);
    if (seen.has(key)) {
      throw new Error('book_sources_v1 contains duplicate natural keys');
    }
    seen.add(key);
  }
  return list;
}

function naturalKeys(sources: BookSource[]): Set<string> {
  const keys: Set<string> = new Set<string>();
  for (const src of sources) {
    keys.add(naturalKey(src.bookSourceUrl, src.bookSourceName));
  }
  return keys;
}

function naturalKey(url: string, name: string): string {
  return url + '\u0000' + name;
}

function sameStoredKeys(rows: SourceRow[], expected: Set<string>): boolean {
  if (rows.length !== expected.size) {
    return false;
  }
  for (const row of rows) {
    if (!expected.has(naturalKey(row.url, row.name))) {
      return false;
    }
  }
  return true;
}
