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
  /**
   * 该章预生成音频的服务端缓存键（`POST /job` / `POST /cache/probe` 返回；客户端**不自己拼**）。
   * 键跟着正文缓存一起失效：正文变了（`url` 变）或条目被清掉，键自然作废。
   */
  pregKey?: string;
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

/**
 * Read one entry (memory first, then disk), validating it against the chapter `url`.
 * The returned object is the **same reference** held in `memory`, so callers may mutate it.
 */
function readEntry(
  ctx: common.UIAbilityContext,
  bookId: string,
  index: number,
  url: string
): CachedChapter | undefined {
  const key: string = memoryKey(bookId, index);
  const mem: CachedChapter | undefined = memory.get(key);
  if (mem !== undefined) {
    if (mem.url === url) {
      touchMemory(key, mem);
      touchFile(filePath(ctx, bookId, index), key);
      return mem;
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
    return entry;
  } catch (err) {
    return undefined;
  }
}

/** Write one entry to `filesDir/chapters`. Failures are non-fatal. */
function writeEntry(ctx: common.UIAbilityContext, bookId: string, index: number, entry: CachedChapter): void {
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
}

/** Return cached chapter content if present and still matching `url`. */
export function getCachedChapter(
  ctx: common.UIAbilityContext,
  bookId: string,
  index: number,
  url: string
): string | undefined {
  const entry: CachedChapter | undefined = readEntry(ctx, bookId, index, url);
  return entry !== undefined ? entry.content : undefined;
}

/**
 * 预生成音频键的**旁路**存储（T-TTS-7）。
 *
 * 正文进了章节缓存（`filesDir/chapters`）的书，键跟着条目走（`CachedChapter.pregKey`），
 * 正文重抽即作废。**本地导入的书正文不进章节缓存**（`LocalBook` 直读导入的文件）⇒ 键没有落点，
 * 落到这里：`filesDir/pregkeys/<bookId>_<index>.json`，只有 `url` + `pregKey` 两个字段
 * （两个名字本来就在 `obfuscation-rules.txt` 里，release 一样安全）。
 *
 * 权威顺序：**正文条目在 ⇒ 只信条目里的键**（不吃旁路，避免正文换了、键还活着）；
 * 没有条目（本地书）⇒ 才读旁路。`url` 一变（换源 / 目录重排）两边都自动失效。
 */
interface PregKeyEntry {
  url: string;
  pregKey: string;
}

const PREGKEY_DIR_NAME: string = 'pregkeys';

function pregKeyDir(ctx: common.UIAbilityContext): string {
  return ctx.filesDir + '/' + PREGKEY_DIR_NAME;
}

function pregKeyPath(ctx: common.UIAbilityContext, bookId: string, index: number): string {
  return pregKeyDir(ctx) + '/' + bookId + '_' + index.toString() + '.json';
}

/** `url` 对得上才返回键；文件不在 / 读不了 / url 变了都当没有。 */
function readPregKeyFile(ctx: common.UIAbilityContext, bookId: string, index: number, url: string): string {
  const path: string = pregKeyPath(ctx, bookId, index);
  try {
    if (!fileIo.accessSync(path)) {
      return '';
    }
    const entry: PregKeyEntry = JSON.parse(fileIo.readTextSync(path)) as PregKeyEntry;
    return entry.url === url ? entry.pregKey : '';
  } catch (err) {
    return '';
  }
}

function writePregKeyFile(
  ctx: common.UIAbilityContext,
  bookId: string,
  index: number,
  url: string,
  pregKey: string
): boolean {
  const dir: string = pregKeyDir(ctx);
  try {
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir);
    }
  } catch (err) {
    return false;
  }
  try {
    const file = fileIo.openSync(
      pregKeyPath(ctx, bookId, index),
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
    );
    const entry: PregKeyEntry = { url: url, pregKey: pregKey };
    fileIo.writeSync(file.fd, JSON.stringify(entry));
    fileIo.closeSync(file);
    return true;
  } catch (err) {
    return false;
  }
}

function deletePregKeyFile(ctx: common.UIAbilityContext, bookId: string, index: number): void {
  const path: string = pregKeyPath(ctx, bookId, index);
  try {
    if (fileIo.accessSync(path)) {
      fileIo.unlinkSync(path);
    }
  } catch (err) {
    return;
  }
}

/** The pre-generated cache key stored with this chapter, or '' when there is none. */
export function getChapterPregKey(
  ctx: common.UIAbilityContext,
  bookId: string,
  index: number,
  url: string
): string {
  const entry: CachedChapter | undefined = readEntry(ctx, bookId, index, url);
  if (entry !== undefined) {
    return entry.pregKey === undefined ? '' : entry.pregKey;
  }
  // 正文不在缓存（本地书）：只有旁路文件可能知道键。
  return readPregKeyFile(ctx, bookId, index, url);
}

/**
 * Remember the cache key the server returned for this chapter ('预生成' job).
 * 正文已经在章节缓存里 ⇒ 键跟着条目走（正文重抽即作废）；正文不在缓存（本地书）
 * ⇒ 落到旁路文件。返回键是否真的落盘（调用方用它统计，别再数「尝试」）。
 */
export function setChapterPregKey(
  ctx: common.UIAbilityContext,
  bookId: string,
  index: number,
  url: string,
  pregKey: string
): boolean {
  if (pregKey.length === 0) {
    return false;
  }
  const entry: CachedChapter | undefined = readEntry(ctx, bookId, index, url);
  if (entry === undefined) {
    return writePregKeyFile(ctx, bookId, index, url, pregKey);
  }
  // 正文条目是权威：顺手清掉可能残留的旁路文件，避免正文换了之后两边打架。
  deletePregKeyFile(ctx, bookId, index);
  if (entry.pregKey === pregKey) {
    return true;
  }
  entry.pregKey = pregKey;
  writeEntry(ctx, bookId, index, entry);
  return true;
}

/**
 * Forget the pre-generated key (the server-side audio is gone: played once / evicted).
 * The body stays cached, so the next play of this chapter goes realtime instead of
 * asking for a file that no longer exists.
 */
export function clearChapterPregKey(
  ctx: common.UIAbilityContext,
  bookId: string,
  index: number,
  url: string
): void {
  const entry: CachedChapter | undefined = readEntry(ctx, bookId, index, url);
  if (entry !== undefined && entry.pregKey !== undefined) {
    entry.pregKey = undefined;
    writeEntry(ctx, bookId, index, entry);
  }
  deletePregKeyFile(ctx, bookId, index);
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
  // 正文重新落盘（章节内容更新 / 缓存被清后重抓）时，旧的预生成键一并作废。
  writeEntry(ctx, bookId, index, entry);
  // Cheap gate (one directory listing at most every N writes) → async quota trim.
  maybeTrimCaches(ctx);
}

/**
 * Drop every cached body of one book: the in-memory entries, the `filesDir/chapters/{bookId}_{index}.json`
 * files **and** its `pregkeys` sidecar files (if any). Best-effort — a file that denies deletion is
 * skipped; the caller has already removed the DB row.
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
  sweepBookFiles(cacheDir(ctx), bookId + '_');
  sweepBookFiles(pregKeyDir(ctx), bookId + '_');
}

/** Delete every `<prefix><anything>.json` in `dir` (missing dir → nothing to do). Best-effort. */
function sweepBookFiles(dir: string, prefix: string): void {
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