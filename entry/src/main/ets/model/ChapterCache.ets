import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';

/**
 * Chapter body cache (plan §7): file cache under `filesDir/chapters`, never in
 * the RDB. An in-memory layer avoids re-reading files during a session.
 *
 * Entries are keyed by `bookId#index` and validated against the chapter URL so
 * a changed TOC ordering invalidates stale content instead of showing the wrong
 * chapter.
 */
interface CachedChapter {
  url: string;
  content: string;
  fetchedAt: number;
}

const memory: Map<string, string> = new Map();

function memoryKey(bookId: string, index: number): string {
  return bookId + '#' + index.toString();
}

function cacheDir(ctx: common.UIAbilityContext): string {
  return ctx.filesDir + '/chapters';
}

function filePath(ctx: common.UIAbilityContext, bookId: string, index: number): string {
  return cacheDir(ctx) + '/' + bookId + '_' + index.toString() + '.json';
}

/** Return cached chapter content if present and still matching `url`. */
export function getCachedChapter(
  ctx: common.UIAbilityContext,
  bookId: string,
  index: number,
  url: string
): string | undefined {
  const key: string = memoryKey(bookId, index);
  const mem: string | undefined = memory.get(key);
  if (mem !== undefined) {
    return mem;
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
    memory.set(key, entry.content);
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
  memory.set(memoryKey(bookId, index), content);
  const dir: string = cacheDir(ctx);
  try {
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir);
    }
  } catch (err) {
    return;
  }
  const entry: CachedChapter = { url: url, content: content, fetchedAt: Date.now() };
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
}

export function hasCachedChapter(bookId: string, index: number): boolean {
  return memory.has(memoryKey(bookId, index));
}