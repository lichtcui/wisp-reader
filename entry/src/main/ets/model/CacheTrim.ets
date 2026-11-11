import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  CACHE_AVG_CHAPTER_BYTES,
  CACHE_CHAPTER_QUOTA,
  CACHE_COVER_QUOTA,
  CACHE_FRESH_WINDOW_MS,
  CACHE_MAX_AGE_DAYS,
  CACHE_TARGET_RATIO,
  CACHE_TOC_QUOTA,
  CACHE_TRIM_MIN_INTERVAL_MS
} from '../common/Const';
import { chapterDir, tocDir } from './CacheRepository';
import { getChapterPositions } from './ShelfRepository';

/**
 * 缓存上限策略（plan §7 / T-DATA-4）。
 *
 * 口径（`Const.ets` 的 `CACHE_*` 常量）：**已读=软保护** —— 未读章节先删；仍超配额才按
 * 「最久未访问」删已读章节；另有未读章节的 TTL 清扫。理由是章节缓存按「读一章写一章 +
 * 预取邻居」增长，若已读绝对保留，200MB 上限几乎永不触发（一本 1441 章的书全读完约 14MB），
 * 磁盘会无界增长。
 *
 * 三条安全约束：
 * 1. **新鲜窗口**：`mtime` 在 `CACHE_FRESH_WINDOW_MS` 内的文件永不删 —— 正在读/刚预取的章不会被抽掉。
 * 2. **会话保护集**：`protectBook` 登记的书（Reader 打开的书、TtsController 在播的书）其章节永不删。
 * 3. **只碰缓存**：章节正文 / 目录 / 封面三类；`filesDir/local`（用户导入的书）、DB、备份文件一律不动。
 *
 * 时间信号只用文件 `mtime`（秒），不引入持久化索引：省掉 `obfuscation-rules.txt` 的 keep 面
 * 与写放大。`ChapterCache` 命中时会节流刷新 `mtime`（`utimes` 参数是**毫秒**！）以获得真 LRU。
 *
 * 执行方式：热路径只做「列一次文件名」的廉价闸门；真正的全扫在主线程**分片**进行（每
 * `STAT_CHUNK` 个文件让出一次事件循环），因此不用 taskpool（`UIAbilityContext` 不可跨线程传递）。
 */

const DOMAIN: number = 0x0000;
const TAG: string = 'WispReaderCache';

const JSON_SUFFIX: string = '.json';
const COVER_PREFIX: string = 'cover_';
const COVER_SUFFIX: string = '.img';
const MS_PER_SECOND: number = 1000;
const MS_PER_DAY: number = 24 * 60 * 60 * 1000;
/** 热路径（章节写入）每 N 次才检查一次闸门，避免每次写盘都去列目录。 */
const PUTS_PER_CHECK: number = 20;
/** 一次全扫中每 N 个文件让出一次事件循环，避免长帧。 */
const STAT_CHUNK: number = 200;
/** 会话级保护条目的有效期与上限。 */
const PROTECT_TTL_MS: number = 30 * 60 * 1000;
const PROTECT_LIMIT: number = 8;
/** 启动后延迟多久做首次整理（等首帧渲染完，别抢启动主线程）。 */
const STARTUP_DELAY_MS: number = 3000;

export interface TrimReport {
  scanned: number;
  freedFiles: number;
  freedBytes: number;
  keptRead: number;
  skipped: boolean;
}

interface FileMeta {
  size: number;
  mtimeMs: number;
}

interface ChapterKey {
  bookId: string;
  index: number;
}

/** 参与整理的单个缓存文件（章节/目录/封面共用）。 */
interface CacheFile {
  path: string;
  bookId: string;
  size: number;
  mtimeMs: number;
  /** 已读（`index <= progress.chapterIndex`）→ 软保护，只有在配额压力下才删。 */
  read: boolean;
  /** 绝不删：新鲜窗口内，或属于会话保护集里的书。 */
  guarded: boolean;
  deleted: boolean;
}

let lastTrimAt: number = 0;
let putsSinceCheck: number = 0;
let running: boolean = false;
const protectedBooks: Map<string, number> = new Map<string, number>();

/**
 * 会话级保护：把「正在阅读 / 正在听」的书登记进来，整理时绝不删它的章节文件。
 * Reader 打开书、TtsController 开始播放时各调一次；条目 30 分钟未更新自动失效，最多 8 本。
 */
export function protectBook(bookId: string): void {
  if (bookId.length === 0) {
    return;
  }
  protectedBooks.delete(bookId);
  protectedBooks.set(bookId, Date.now());
  while (protectedBooks.size > PROTECT_LIMIT) {
    const oldest: string | undefined = protectedBooks.keys().next().value;
    if (oldest === undefined) {
      break;
    }
    protectedBooks.delete(oldest);
  }
}

function isProtectedBook(bookId: string, now: number): boolean {
  const at: number | undefined = protectedBooks.get(bookId);
  if (at === undefined) {
    return false;
  }
  if (now - at > PROTECT_TTL_MS) {
    protectedBooks.delete(bookId);
    return false;
  }
  return true;
}

// ── 文件系统小工具（全部 best-effort，失败即当作「不存在」）──────────────

function listNames(dir: string): string[] {
  try {
    if (!fileIo.accessSync(dir)) {
      return [];
    }
    return fileIo.listFileSync(dir);
  } catch (err) {
    return [];
  }
}

function fileMeta(path: string): FileMeta | undefined {
  try {
    const stat: fileIo.Stat = fileIo.statSync(path);
    if (!stat.isFile()) {
      return undefined;
    }
    // `stat.mtime` 是**秒**，`utimes` 收**毫秒** —— 内部统一用毫秒比较。
    return { size: stat.size, mtimeMs: stat.mtime * MS_PER_SECOND };
  } catch (err) {
    return undefined;
  }
}

function removeFile(path: string, report: TrimReport): boolean {
  const meta: FileMeta | undefined = fileMeta(path);
  if (meta === undefined) {
    return false;
  }
  try {
    fileIo.unlinkSync(path);
  } catch (err) {
    return false;
  }
  report.freedFiles += 1;
  report.freedBytes += meta.size;
  return true;
}

/** `"<bookId>_<index>.json"` → `{bookId, index}`；不匹配（外来文件）→ undefined。 */
function parseChapterName(name: string): ChapterKey | undefined {
  if (!name.endsWith(JSON_SUFFIX)) {
    return undefined;
  }
  const body: string = name.substring(0, name.length - JSON_SUFFIX.length);
  const sep: number = body.lastIndexOf('_');
  if (sep <= 0 || sep >= body.length - 1) {
    return undefined;
  }
  const digits: string = body.substring(sep + 1);
  let index: number = 0;
  for (let i = 0; i < digits.length; i++) {
    const code: number = digits.charCodeAt(i);
    if (code < 48 || code > 57) {
      return undefined;
    }
    index = index * 10 + (code - 48);
  }
  return { bookId: body.substring(0, sep), index: index };
}

/** 让出一次事件循环（分片扫描用）。 */
async function yieldToUi(): Promise<void> {
  await new Promise<void>((resolve: (value: void) => void): void => {
    setTimeout((): void => {
      resolve();
    }, 0);
  });
}

function sortOldestFirst(files: CacheFile[]): void {
  files.sort((a: CacheFile, b: CacheFile): number => a.mtimeMs - b.mtimeMs);
}

/** 按「最旧先删」驱逐，直到剩余字节数降到 `target` 以下。分批让出事件循环。 */
async function evict(
  files: CacheFile[],
  live: number,
  target: number,
  report: TrimReport
): Promise<number> {
  let remaining: number = live;
  let sinceYield: number = 0;
  for (const f of files) {
    if (remaining <= target) {
      break;
    }
    if (f.deleted || f.guarded) {
      continue;
    }
    if (removeFile(f.path, report)) {
      f.deleted = true;
      remaining -= f.size;
      sinceYield += 1;
      if (sinceYield % STAT_CHUNK === 0) {
        await yieldToUi();
      }
    }
  }
  return remaining;
}

/** 启动后延迟整理的入口：等首帧渲染完再做，避免抢启动时的主线程。 */
export function scheduleStartupTrim(ctx: common.UIAbilityContext): void {
  setTimeout((): void => {
    trimCaches(ctx, true).catch((err: Error): void => {
      hilog.warn(DOMAIN, TAG, 'startup trim failed: %{public}s', err.message);
    });
  }, STARTUP_DELAY_MS);
}

/**
 * 热路径入口（`ChapterCache.putCachedChapter` 调用）：廉价闸门 + 会话节流后才异步整理。
 * 永不阻塞调用者；闸门只列一次文件名（1 次系统调用），不做 stat。
 */
export function maybeTrimCaches(ctx: common.UIAbilityContext): void {
  putsSinceCheck += 1;
  if (putsSinceCheck < PUTS_PER_CHECK) {
    return;
  }
  putsSinceCheck = 0;
  if (Date.now() - lastTrimAt < CACHE_TRIM_MIN_INTERVAL_MS) {
    return;
  }
  const gate: number = Math.floor(CACHE_CHAPTER_QUOTA / CACHE_AVG_CHAPTER_BYTES);
  if (listNames(chapterDir(ctx)).length <= gate) {
    return;
  }
  trimCaches(ctx, true).catch((err: Error): void => {
    hilog.warn(DOMAIN, TAG, 'trim failed: %{public}s', err.message);
  });
}

/**
 * 整理三类缓存：章节正文（配额 + TTL）、目录（配额 + 连带删）、封面（配额）。
 *
 * @param force 忽略会话节流（启动后的首次整理与热路径闸门命中时用 true）。
 */
export async function trimCaches(
  ctx: common.UIAbilityContext,
  force: boolean = false
): Promise<TrimReport> {
  const none: TrimReport = { scanned: 0, freedFiles: 0, freedBytes: 0, keptRead: 0, skipped: true };
  if (running) {
    return none;
  }
  const now: number = Date.now();
  if (!force && now - lastTrimAt < CACHE_TRIM_MIN_INTERVAL_MS) {
    return none;
  }
  running = true;
  lastTrimAt = now;
  try {
    // 进度表即「已读」的判定依据（听书进度写同一张表，天然覆盖）。
    const progress: Map<string, number> = await getChapterPositions();
    return await runTrim(ctx, progress, now);
  } catch (err) {
    // 这里刻意不用 `JSON.stringify`：本文件的 interface 从不参与 JSON 往返，保持
    // 「无 JSON.parse/stringify」状态可让 `make check` 的 keep 扫描跳过它（见脚本判定范围）。
    const e = err as BusinessError;
    hilog.warn(DOMAIN, TAG, 'trim failed: %{public}s', e.message ?? '');
    return none;
  } finally {
    running = false;
  }
}

async function runTrim(
  ctx: common.UIAbilityContext,
  progress: Map<string, number>,
  now: number
): Promise<TrimReport> {
  const report: TrimReport = { scanned: 0, freedFiles: 0, freedBytes: 0, keptRead: 0, skipped: false };

  // ── 1. 扫章节正文，分成「未读」（先删）与「已读」（压力下才删）─────────
  const dir: string = chapterDir(ctx);
  const names: string[] = listNames(dir);
  const readFiles: CacheFile[] = [];
  const unreadFiles: CacheFile[] = [];
  let live: number = 0;
  for (let i = 0; i < names.length; i++) {
    if (i > 0 && i % STAT_CHUNK === 0) {
      await yieldToUi();
    }
    const key: ChapterKey | undefined = parseChapterName(names[i]);
    if (key === undefined) {
      continue;
    }
    const path: string = dir + '/' + names[i];
    const meta: FileMeta | undefined = fileMeta(path);
    if (meta === undefined) {
      continue;
    }
    const chapterIndex: number | undefined = progress.get(key.bookId);
    const read: boolean = chapterIndex !== undefined && key.index <= chapterIndex;
    const guarded: boolean =
      isProtectedBook(key.bookId, now) || now - meta.mtimeMs < CACHE_FRESH_WINDOW_MS;
    const file: CacheFile = {
      path: path,
      bookId: key.bookId,
      size: meta.size,
      mtimeMs: meta.mtimeMs,
      read: read,
      guarded: guarded,
      deleted: false
    };
    report.scanned += 1;
    live += meta.size;
    if (read) {
      report.keptRead += 1;
    }
    if (!guarded) {
      if (read) {
        readFiles.push(file);
      } else {
        unreadFiles.push(file);
      }
    }
  }

  const target: number = CACHE_CHAPTER_QUOTA * CACHE_TARGET_RATIO;
  if (live > CACHE_CHAPTER_QUOTA) {
    sortOldestFirst(unreadFiles);
    live = await evict(unreadFiles, live, target, report);
    if (live > target) {
      // 已读是软保护：配额压力下按「最久未访问」继续删。
      sortOldestFirst(readFiles);
      live = await evict(readFiles, live, target, report);
    }
  }

  // ── 2. TTL：未读章节超期即清（与配额无关；已读不吃 TTL，只吃 LRU）──────
  const maxAgeMs: number = CACHE_MAX_AGE_DAYS * MS_PER_DAY;
  const all: CacheFile[] = unreadFiles.concat(readFiles);
  let ttlSinceYield: number = 0;
  for (const f of all) {
    if (f.deleted || f.guarded || f.read) {
      continue;
    }
    if (now - f.mtimeMs > maxAgeMs) {
      if (removeFile(f.path, report)) {
        f.deleted = true;
        ttlSinceYield += 1;
        if (ttlSinceYield % STAT_CHUNK === 0) {
          await yieldToUi();
        }
      }
    }
  }

  // ── 3. 目录缓存：被删空的书连带删 toc；再按独立预算兜底驱逐 ──────────
  const alive: Map<string, number> = new Map<string, number>();
  const touched: Map<string, number> = new Map<string, number>();
  for (const f of all) {
    if (f.deleted) {
      const n: number | undefined = touched.get(f.bookId);
      touched.set(f.bookId, n === undefined ? 1 : n + 1);
    } else {
      const n: number | undefined = alive.get(f.bookId);
      alive.set(f.bookId, n === undefined ? 1 : n + 1);
    }
  }
  const tocFiles: CacheFile[] = [];
  let tocLive: number = 0;
  for (const name of listNames(tocDir(ctx))) {
    if (!name.endsWith(JSON_SUFFIX)) {
      continue;
    }
    const bookId: string = name.substring(0, name.length - JSON_SUFFIX.length);
    const path: string = tocDir(ctx) + '/' + name;
    const meta: FileMeta | undefined = fileMeta(path);
    if (meta === undefined) {
      continue;
    }
    const deletedCount: number | undefined = touched.get(bookId);
    const stillAlive: number = alive.get(bookId) ?? 0;
    if (deletedCount !== undefined && stillAlive === 0 && !isProtectedBook(bookId, now)) {
      removeFile(path, report);
      continue;
    }
    tocLive += meta.size;
    if (isProtectedBook(bookId, now) || now - meta.mtimeMs < CACHE_FRESH_WINDOW_MS) {
      continue;
    }
    tocFiles.push({
      path: path,
      bookId: bookId,
      size: meta.size,
      mtimeMs: meta.mtimeMs,
      read: false,
      guarded: false,
      deleted: false
    });
  }
  if (tocLive > CACHE_TOC_QUOTA) {
    sortOldestFirst(tocFiles);
    await evict(tocFiles, tocLive, CACHE_TOC_QUOTA * CACHE_TARGET_RATIO, report);
  }

  // ── 4. 封面：单独预算。文件名是 Rust 侧对 coverUrl 的哈希，ArkTS 无法识别归属，
  //        因此只按最旧 mtime 驱逐（重下即可恢复，无数据损失）。
  const covers: CacheFile[] = [];
  let coverLive: number = 0;
  for (const name of listNames(ctx.cacheDir)) {
    if (!name.startsWith(COVER_PREFIX) || !name.endsWith(COVER_SUFFIX)) {
      continue;
    }
    const path: string = ctx.cacheDir + '/' + name;
    const meta: FileMeta | undefined = fileMeta(path);
    if (meta === undefined) {
      continue;
    }
    coverLive += meta.size;
    if (now - meta.mtimeMs < CACHE_FRESH_WINDOW_MS) {
      continue;
    }
    covers.push({
      path: path,
      bookId: '',
      size: meta.size,
      mtimeMs: meta.mtimeMs,
      read: false,
      guarded: false,
      deleted: false
    });
  }
  if (coverLive > CACHE_COVER_QUOTA) {
    sortOldestFirst(covers);
    await evict(covers, coverLive, CACHE_COVER_QUOTA * CACHE_TARGET_RATIO, report);
  }

  hilog.info(
    DOMAIN,
    TAG,
    'trim scanned=%{public}d freed=%{public}d files %{public}d B keptRead=%{public}d',
    report.scanned,
    report.freedFiles,
    report.freedBytes,
    report.keptRead
  );
  return report;
}
