import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { maybeTrimCaches } from './CacheTrim';

/**
 * Chapter body cache (plan §7): file cache under `filesDir/chapters`, never in
 * the RDB. An in-memory layer avoids re-reading files during a session.
 *
 * Entries are keyed by `bookId#index` and validated against the chapter URL so
 * a changed TOC ordering invalidates stale content instead of showing the wrong
 * chapter.
 *
 * Quota / TTL maintenance lives in `CacheTrim`: a cache hit refreshes the file
 * `mtime` (throttled → real LRU), and a write pokes its cheap gate. The
 * on-disk entry JSON is deliberately not extended with an access timestamp —
 * that would change a persisted contract for a value `mtime` already carries.
 */
interface CachedChapter {
  url: string;
  content: string;
  fetchedAt: number;
}

const memory: Map<string, CachedChapter> = new Map();
/** Largest number of chapter bodies kept decoded in memory (LRU). */
const MEMORY_LIMIT: number = 24;
/** Don't re-touch a file's mtime more often than this (metadata writes are cheap, not free). */
const TOUCH_INTERVAL_MS: number = 10 * 60 * 1000;
/** Last mtime refresh per `bookId#index`, session-scoped (never persisted). */
const lastTouchAt: Map<string, number> = new Map();

function memoryKey(bookId: string, index: number): string {
  return bookId + '#' + index.toString();
}

/** Move `key` to the most-recent position and evict the oldest beyond the cap. */
function touchMemory(key: string, entry: CachedChapter): void {
  memory.delete(key);
  memory.set(key, entry);
  while (memory.size > MEMORY_LIMIT) {
    const oldest: string | undefined = memory.keys().next().value;
    if (oldest === undefined) {
      break;
    }
    memory.delete(oldest);
  }
}

function cacheDir(ctx: common.UIAbilityContext): string {
  return ctx.filesDir + '/chapters';
}

function filePath(ctx: common.UIAbilityContext, bookId: string, index: number): string {
  return cacheDir(ctx) + '/' + bookId + '_' + index.toString() + '.json';
}

/**
 * Refresh the cache file's `mtime` so `CacheTrim` sees a real last-used time.
 * Throttled per entry; best-effort (a missing file just skips).
 *
 * `fileIo.utimes` takes **milliseconds** while `stat.mtime` is in **seconds**.
 */
function touchFile(path: string, key: string): void {
  const now: number = Date.now();
  const prev: number | undefined = lastTouchAt.get(key);
  if (prev !== undefined && now - prev < TOUCH_INTERVAL_MS) {
    return;
  }
  lastTouchAt.set(key, now);
  // 长会话读成千章时清一次（只丢了节流信息，不影响正确性）。
  if (lastTouchAt.size > 4096) {
    lastTouchAt.clear();
    lastTouchAt.set(key, now);
  }
  try {
    fileIo.utimes(path, now);
  } catch (err) {
    return;
  }
}

/** Return cached chapter content if present and still matching `url`. */
export function getCachedChapter(
  ctx: common.UIAbilityContext,
  bookId: string,
  index: number,
  url: string
): string | undefined {
  const key: string = memoryKey(bookId, index);
  const mem: CachedChapter | undefined = memory.get(key);
  if (mem !== undefined) {
    if (mem.url === url) {
      touchMemory(key, mem);
      touchFile(filePath(ctx, bookId, index), key);
      return mem.content;
    }
    memory.delete(key);
  }
  const path: string = filePath(ctx, bookId, index);
  try {
    if (!fileIo.accessSync(path)) {
      return undefined;
    }
    const raw: string = fileIo.readTextSync(path);
    const entry: CachedChapter = JSON.parse(raw) as CachedChapter;
    if (entry.url !== url) {
      return undefined;
    }
    touchMemory(key, entry);
    touchFile(path, key);
    return entry.content;
  } catch (err) {
    return undefined;
  }
}

/** Store chapter content in memory and on disk. Failures are non-fatal. */
export function putCachedChapter(
  ctx: common.UIAbilityContext,
  bookId: string,
  index: number,
  url: string,
  content: string
): void {
  const entry: CachedChapter = { url: url, content: content, fetchedAt: Date.now() };
  touchMemory(memoryKey(bookId, index), entry);
  const dir: string = cacheDir(ctx);
  try {
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir);
    }
  } catch (err) {
    return;
  }
  const path: string = filePath(ctx, bookId, index);
  try {
    const file = fileIo.openSync(
      path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
    );
    fileIo.writeSync(file.fd, JSON.stringify(entry));
    fileIo.closeSync(file);
  } catch (err) {
    return;
  }
  // Cheap gate (one directory listing at most every N writes) → async quota trim.
  maybeTrimCaches(ctx);
}

/**
 * Drop every cached body of one book: the in-memory entries and the
 * `filesDir/chapters/{bookId}_{index}.json` files. Best-effort — a file that
 * denies deletion is skipped; the caller has already removed the DB row.
 *
 * Prefix safety: `bookId` is hex (`computeBookId`) and the file prefix ends with
 * `_`, so no other book's files can match.
 */
export function deleteBookChapters(ctx: common.UIAbilityContext, bookId: string): void {
  const memPrefix: string = bookId + '#';
  memory.forEach((_value: CachedChapter, key: string) => {
    if (key.startsWith(memPrefix)) {
      memory.delete(key);
    }
  });
  lastTouchAt.forEach((_at: number, key: string) => {
    if (key.startsWith(memPrefix)) {
      lastTouchAt.delete(key);
    }
  });
  const dir: string = cacheDir(ctx);
  const prefix: string = bookId + '_';
  let names: string[] = [];
  try {
    if (!fileIo.accessSync(dir)) {
      return;
    }
    names = fileIo.listFileSync(dir);
  } catch (err) {
    return;
  }
  for (const name of names) {
    if (!name.startsWith(prefix) || !name.endsWith('.json')) {
      continue;
    }
    try {
      fileIo.unlinkSync(dir + '/' + name);
    } catch (err) {
      continue;
    }
  }
}