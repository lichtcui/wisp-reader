import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { Chapter } from '../engine/types';
import { TOC_REFRESH_AFTER_MS } from '../common/Const';

/**
 * Table-of-contents cache (mirrors ChapterCache): file cache under
 * `filesDir/tocs`, plus an in-memory layer to avoid re-reading files during a
 * session. A fetched TOC is valid until the book's `tocUrl` changes, so a
 * re-imported/re-sourced book invalidates its stale chapter list instead of
 * showing an outdated one.
 *
 * `tocUrl` is not the only expiry: the entry also carries `fetchedAt`, and the
 * caller re-crawls a stale entry in the background (`isTocStale`) — otherwise a
 * serialized book would keep the chapter list it had on its first open, forever.
 */
export interface CachedToc {
  tocUrl: string;
  chapters: Chapter[];
  fetchedAt: number;
}

/**
 * Is this cached TOC old enough to be re-crawled?
 *
 * A missing / non-positive `fetchedAt` (file written by an older build) counts as
 * stale, so that first open refreshes it and stamps a real timestamp.
 */
export function isTocStale(entry: CachedToc): boolean {
  return !(entry.fetchedAt > 0) || Date.now() - entry.fetchedAt >= TOC_REFRESH_AFTER_MS;
}

const memory: Map<string, CachedToc> = new Map();
/** Keep only the few most-recently-opened books' TOCs decoded in memory. */
const MEMORY_LIMIT: number = 6;

function memoryKey(bookId: string): string {
  return bookId;
}

function touchMemory(key: string, entry: CachedToc): void {
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
  return ctx.filesDir + '/tocs';
}

function filePath(ctx: common.UIAbilityContext, bookId: string): string {
  return cacheDir(ctx) + '/' + bookId + '.json';
}

/**
 * Return the cached entry (chapters + `fetchedAt`) if present and still matching
 * `tocUrl`. The whole entry is returned rather than just the chapters so the
 * caller can decide whether it has gone stale.
 */
export function getCachedToc(
  ctx: common.UIAbilityContext,
  bookId: string,
  tocUrl: string
): CachedToc | undefined {
  const mem: CachedToc | undefined = memory.get(memoryKey(bookId));
  if (mem !== undefined) {
    if (mem.tocUrl === tocUrl) {
      touchMemory(memoryKey(bookId), mem);
      return mem;
    }
    memory.delete(memoryKey(bookId));
  }
  const path: string = filePath(ctx, bookId);
  try {
    if (!fileIo.accessSync(path)) {
      return undefined;
    }
    const raw: string = fileIo.readTextSync(path);
    const entry: CachedToc = JSON.parse(raw) as CachedToc;
    if (entry.tocUrl !== tocUrl) {
      return undefined;
    }
    touchMemory(memoryKey(bookId), entry);
    return entry;
  } catch (err) {
    return undefined;
  }
}

/** Store a fetched TOC in memory and on disk. Failures are non-fatal. */
export function putCachedToc(
  ctx: common.UIAbilityContext,
  bookId: string,
  tocUrl: string,
  chapters: Chapter[]
): void {
  const entry: CachedToc = { tocUrl: tocUrl, chapters: chapters, fetchedAt: Date.now() };
  touchMemory(memoryKey(bookId), entry);
  const dir: string = cacheDir(ctx);
  try {
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir);
    }
  } catch (err) {
    return;
  }
  const path: string = filePath(ctx, bookId);
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
}

/** Drop one book's cached TOC (memory + `filesDir/tocs/{bookId}.json`). */
export function deleteBookToc(ctx: common.UIAbilityContext, bookId: string): void {
  memory.delete(memoryKey(bookId));
  const path: string = filePath(ctx, bookId);
  try {
    if (fileIo.accessSync(path)) {
      fileIo.unlinkSync(path);
    }
  } catch (err) {
    return;
  }
}