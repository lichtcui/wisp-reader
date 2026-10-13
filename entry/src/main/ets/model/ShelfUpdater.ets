import { bookEngine } from '../engine/BookEngineNapi';
import { Book, BookSearchItem, BookSource } from '../engine/types';
import { SearchResult } from '../engine/IBookEngine';
import { cleanChapter } from '../common/Format';
import { isSameBook } from './SourceSwitch';
import { upsertBook } from './ShelfRepository';
import { isLocalBook } from './LocalBook';

/**
 * 书架「更新」：批量检查在架书籍有没有新章（T-SHELF-7，决策见 `docs/handoff/HANDOFF-S11.md` §1）。
 *
 * 探测深度**只有详情页**（不爬目录，已拍板）：目录交给打开书时的 6h 新鲜期逻辑
 * （`Const.TOC_REFRESH_AFTER_MS`），否则 20 本连载书要上百次请求。
 *
 * ## 为什么每本书是 2 次请求
 * 书架行（`Book`）**没有 `bookUrl`**，而 `bookInfo` 需要它；`bookId` 是
 * `computeBookId(sourceUrl, bookUrl)` 的哈希 ⇒ 不可逆，`tocUrl` 也顶不上（13 个内置源里
 * 7 个显式指向目录页，是另一个页面）。所以先用
 * `search([source], book.name)` + `isSameBook`（书名 + 作者严格匹配）拿到 `item.bookUrl`，
 * 再 `bookInfo`。加 `book_url` 持久列的方案（1 请求/书）要求 `books` 表幂等 ALTER +
 * 3 个写入点 + 存量行回填，收益只是把请求减半 —— 本轮不做，见 HANDOFF-S11 §2。
 *
 * ## 基线（不改表）
 * `books.last_chapter_title` 只在「加入书架」（`pages/BookDetail.ets`）与「换源」
 * （`model/SourceSwitch.ets`）写入，Reader 的后台重爬不写它、也没有任何 UI 读它 ⇒
 * 直接当「上次检查到的章节」用。代价（已接受）：**第一次检查会把「自加入书架以来更新过章节」
 * 的书报成有新章**，回写后即准。没有基线的行（本地导入的书、规则缺 `lastChapter` 的书）
 * 只静默建基线、不报新章 —— 没有可比对的信息时报「有新章」是纯误报。
 *
 * ## 失败语义
 * 单本失败（搜索没匹配到 / 请求超时 / 数组为空 / 写库失败）**静默**：不计入 `updated`、
 * 不动基线、不影响其余书。整体预算耗尽时未开始的书计入 `skipped`。
 */

/** 单源搜索超时（Rust 侧会 clamp 到 [3s, 20s]）。 */
const SEARCH_TIMEOUT_MS: number = 6_000;
/**
 * 单本总超时（search + bookInfo 两次请求）。
 *
 * 比 HANDOFF 草稿的「单本 6s」宽：一次 6s 的整链上限会让「搜索正好用满 6s」的书
 * 连 `bookInfo` 都发不出去 —— 而 `bookInfo` 在 Rust 侧没有独立超时参数（只有 reqwest
 * 客户端的 15s 硬上限），所以这条 ArkTS 侧竞速是它唯一的护栏，必须容得下两次请求。
 */
const BOOK_TIMEOUT_MS: number = 15_000;
/** 并发书数：串行太慢（20 本 × 3–5s），再高会跟用户正在进行的阅读/听书抢带宽。 */
const CHECK_CONCURRENCY: number = 3;
/** 整体预算：到点即停，剩余书计入 `skipped`（不许把入口挂死）。 */
const CHECK_BUDGET_MS: number = 90_000;

const PROBE_UPDATED: number = 1;
const PROBE_SAME: number = 0;
const PROBE_FAILED: number = -1;

export interface ShelfUpdateOutcome {
  /** 参与检查的网络书数（本地书已排除）。 */
  total: number;
  /** 拿到详情页章节名并完成比对的书数。 */
  checked: number;
  /** 失败 / 超时 / 未能匹配到同一本书 / 没有章节名可用的书数。 */
  failed: number;
  /** 整体预算耗尽而没开始检查的书数。 */
  skipped: number;
  /** 有新章的书（基线已前移）。 */
  updated: Book[];
}

/** 章节名的可比形态：削掉 `最新章节：` 之类页面标签与全部空白，再小写。 */
export function chapterKey(title: string): string {
  return cleanChapter(title).replace(/\s+/g, '').toLowerCase();
}

/**
 * 是否有新章：两侧都拿得到章节名、且归一化后不同。
 *
 * 任一侧为空 ⇒ `false`（宁可不报）。归一化是必需的：基线可能来自搜索结果
 * （`item.lastChapter`，例如 `最新章节：第1309章 剑来`），探测值来自详情页
 * （`info.lastChapterTitle`，`第1309章 剑来`）—— 直接比字符串会把它们当成新章。
 * 反过来，同一源的同一字段格式稳定 ⇒ 回写后再比就相等，幂等成立。
 */
export function hasNewChapter(baseline: string, latest: string): boolean {
  const a: string = chapterKey(baseline);
  const b: string = chapterKey(latest);
  if (a.length === 0 || b.length === 0) {
    return false;
  }
  return a !== b;
}

/**
 * 进行中文案（T-SHELF-7 收尾）：无失败 `检查中 1/2`，有失败 `检查中 1/2 · 1 本未检查`。
 *
 * 与结束 toast 的「N 本未检查」同口径，但**只算已结束的失败书**（`failed`）：
 * `skipped`（整体预算耗尽后没开始的书）要等所有 lane 收尾才知道，进行中报不出来。
 * 放在本文件而非 `pages/Index.ets`：主机仿真（`scripts/shelf-updater-sim.py`）
 * 按整文件切片本模块 ⇒ 三种形态在主机侧有断言，纯 UI 里写就只能靠真机截图 OCR。
 */
export function shelfProgressText(done: number, total: number, failed: number): string {
  if (total <= 0) {
    return '检查中…';
  }
  const base: string = '检查中 ' + done.toString() + '/' + total.toString();
  if (failed <= 0) {
    return base;
  }
  return base + ' · ' + failed.toString() + ' 本未检查';
}

/** 在搜索结果里挑出「同一本书」的第一条（书名 + 作者严格匹配，与换源同语义）。 */
function pickSameBook(book: Book, items: BookSearchItem[]): BookSearchItem | undefined {
  for (const item of items) {
    if (isSameBook(book, item)) {
      return item;
    }
  }
  return undefined;
}

/** 给一个 Promise 加超时（超时即 reject；被竞赛掉的请求由引擎自己收尾）。 */
function withTimeout<T>(task: Promise<T>, ms: number): Promise<T> {
  return new Promise<T>((resolve: (value: T) => void, reject: (reason: Error) => void): void => {
    let settled: boolean = false;
    const timer: number = setTimeout((): void => {
      if (!settled) {
        settled = true;
        reject(new Error('timeout'));
      }
    }, ms);
    task.then((value: T): void => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        resolve(value);
      }
    }, (err: Error): void => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        reject(err);
      }
    });
  });
}

/** 拿到最新的章节名：详情页优先，回落到搜索结果（与 `SourceSwitch` 同口径）。 */
function latestTitle(info: Book, item: BookSearchItem): string {
  if (info.lastChapterTitle.trim().length > 0) {
    return info.lastChapterTitle.trim();
  }
  return item.lastChapter.trim();
}

/**
 * 探测一本书并**就地前移基线**（成功路径写库）。
 *
 * 比对相等但原始串不同（只是标签/空白差异）时也回写一次：基线收敛到详情页的规范形态，
 * 下次比较就是纯字符串相等，不再依赖 `chapterKey` 的容错。无基线（空串）同此分支 ⇒ 静默建基线。
 */
async function probeBook(book: Book, source: BookSource): Promise<number> {
  const result: SearchResult = await bookEngine.search([source], book.name, {
    timeoutMs: SEARCH_TIMEOUT_MS,
    concurrency: 1
  });
  const hit: BookSearchItem | undefined = pickSameBook(book, result.items);
  if (hit === undefined) {
    return PROBE_FAILED;
  }
  const info: Book = await bookEngine.bookInfo(source, hit.bookUrl);
  const latest: string = latestTitle(info, hit);
  if (latest.length === 0) {
    return PROBE_FAILED;
  }
  const changed: boolean = hasNewChapter(book.lastChapterTitle, latest);
  if (!changed) {
    if (book.lastChapterTitle !== latest) {
      book.lastChapterTitle = latest;
      await upsertBook(book);
    }
    return PROBE_SAME;
  }
  book.lastChapterTitle = latest;
  await upsertBook(book);
  return PROBE_UPDATED;
}

/**
 * 检查所有在架书籍是否有新章。
 *
 * @param books 书架行（`ShelfRepository.getBooks()` 的输出）；本地书会被跳过，
 *              命中新章的书**就地**更新 `lastChapterTitle` 并回写 DB。
 * @param sources 书源列表（按 `bookSourceUrl` 取源；没有对应源或源已停用记为失败）。
 * @param onProgress 进度回调：开始前 `(0, total, 0)`，每本结束 `(done, total, failed)`。
 *                   第三个参数是**累计**失败数，供进行中文案显示「N 本未检查」（T-SHELF-7 收尾）。
 * @param budgetMs 整体预算，仅测试需要改。
 */
export async function checkShelfUpdates(
  books: Book[],
  sources: BookSource[],
  onProgress: (done: number, total: number, failed: number) => void,
  budgetMs: number = CHECK_BUDGET_MS
): Promise<ShelfUpdateOutcome> {
  const byUrl: Map<string, BookSource> = new Map<string, BookSource>();
  for (const source of sources) {
    byUrl.set(source.bookSourceUrl, source);
  }
  const targets: Book[] = books.filter((book: Book): boolean => !isLocalBook(book));
  const outcome: ShelfUpdateOutcome = {
    total: targets.length,
    checked: 0,
    failed: 0,
    skipped: 0,
    updated: []
  };
  onProgress(0, targets.length, 0);
  if (targets.length === 0) {
    return outcome;
  }

  const deadline: number = Date.now() + budgetMs;
  let next: number = 0;
  let done: number = 0;

  const lane = async (): Promise<void> => {
    while (next < targets.length) {
      if (Date.now() > deadline) {
        return;
      }
      const index: number = next;
      next = next + 1;
      const book: Book = targets[index];
      const source: BookSource | undefined = byUrl.get(book.sourceUrl);
      let result: number = PROBE_FAILED;
      if (source !== undefined && source.enabled !== false) {
        try {
          result = await withTimeout(probeBook(book, source), BOOK_TIMEOUT_MS);
        } catch (err) {
          result = PROBE_FAILED;
        }
      }
      if (result === PROBE_UPDATED) {
        outcome.updated.push(book);
        outcome.checked = outcome.checked + 1;
      } else if (result === PROBE_SAME) {
        outcome.checked = outcome.checked + 1;
      } else {
        outcome.failed = outcome.failed + 1;
      }
      done = done + 1;
      onProgress(done, targets.length, outcome.failed);
    }
  };

  const lanes: Promise<void>[] = [];
  for (let i: number = 0; i < CHECK_CONCURRENCY; i++) {
    lanes.push(lane());
  }
  await Promise.all(lanes);
  outcome.skipped = outcome.total - done;
  return outcome;
}
