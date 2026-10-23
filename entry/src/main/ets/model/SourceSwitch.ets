import { common } from '@kit.AbilityKit';
import { bookEngine } from '../engine/BookEngineNapi';
import { Book, BookSearchItem, BookSource, Chapter, ReadProgress } from '../engine/types';
import { computeBookId, cleanAuthor } from '../common/Format';
import { removeBooks, saveProgress, upsertBook } from './ShelfRepository';
import { ProgressWriter } from './ProgressOwner';
import { deleteBookChapters } from './ChapterCache';
import { deleteBookToc, putCachedToc } from './TocCache';
import { takePrefetchedInfo, takePrefetchedToc } from './SourcePrefetch';
import { isLocalBook } from './LocalBook';
import { TtsController } from './TtsController';
import { BookDownloader } from './BookDownloader';
import { deleteBookDownload } from './DownloadStore';
import { ENGINE_INFO_TIMEOUT_MS, ENGINE_TOC_TIMEOUT_MS } from '../common/Const';

/**
 * 换源（v1.1 新增，决策见 `docs/decisions.md` D16；原 D11 把换源列为 v1 不做）。
 *
 * 一条链路：**书名 + 作者严格匹配**挑出候选（`isSameBook`，与书架的
 * `isInShelf` 去重同语义）→ 对新源 `bookInfo` + `toc` → **按章节序号迁移进度**
 * （先按章节名对齐，落空再按 `percent` 折算）→ 替换书架行（`bookId` 变了，旧行删除）
 * 并清掉旧源缓存。
 *
 * 为什么必须换 `bookId`：`bookId = computeBookId(sourceUrl, bookUrl)`，书架
 * `books` / `progress` / 章节缓存 / 目录缓存全部以它为键。换源 = 换这本书的来源，
 * 所以是「删旧行 + 插新行」而不是「改旧行的 source_url」—— 后者会让一条进度行
 * 与它的缓存、`TocCache` 的 `tocUrl` 校验全部对不上（缓存条目按 `bookId` 落盘，
 * 只在 `tocUrl` 一致时被采用）。
 *
 * 失败语义：写库之前任何一步失败（`bookInfo` / 空目录）都直接抛出，**不动任何数据**；
 * 写库之后清缓存失败只记日志（与 `model/BookRemoval` 一致，残留可由「清理缓存」扫掉）。
 */

/** 归一化书名/作者：去掉全部空白（含全角空格）并转小写。 */
export function normalizeKey(text: string): string {
  return text.replace(/\s+/g, '').replace(/[\u3000]/g, '').toLowerCase();
}

/**
 * 是否同一本书：书名归一化后**完全相等**，且作者一致（任一方为空则视为一致，
 * 因为搜索结果经常缺作者，严格相等会把整本书滤掉）。
 *
 * 比作者前要先削掉页面标签：搜索结果里 `item.author` 常是 `作者：烽火戏诸侯`，
 * 而书架里的 `book.author` 是干净的 `烽火戏诸侯` —— 不削就直接不相等。
 * 真机上 13 源搜《剑来》，8 条同名结果里 6 条带前缀，**全被当成另一本书滤掉，只剩 1 个候选**；
 * 削掉后同一批结果是 8 个候选（`normalizeKey` 不管 `作者：`，它只删空白）。
 *
 * 刻意不做模糊匹配：同名不同书（如《斗破苍穹》的不同作者版本）会被误判，
 * 而这个动作是破坏性的（删旧行 + 清缓存）。
 */
export function isSameBook(book: Book, item: BookSearchItem): boolean {
  const a: string = normalizeKey(book.name);
  const b: string = normalizeKey(item.name);
  if (a.length === 0 || a !== b) {
    return false;
  }
  const aa: string = normalizeKey(cleanAuthor(book.author));
  const ba: string = normalizeKey(cleanAuthor(item.author));
  if (aa.length === 0 || ba.length === 0) {
    return true;
  }
  return aa === ba;
}

function isReadable(chapters: Chapter[], index: number): boolean {
  return index >= 0 && index < chapters.length && chapters[index].isVolume !== true;
}

function firstReadable(chapters: Chapter[]): number {
  for (let i = 0; i < chapters.length; i++) {
    if (isReadable(chapters, i)) {
      return i;
    }
  }
  return -1;
}

/** 从 `from` 起先向后、再向前找最近的可读章（卷标题不是正文，不能停）。 */
function nearestReadable(chapters: Chapter[], from: number): number {
  if (chapters.length === 0) {
    return -1;
  }
  const start: number = Math.min(Math.max(from, 0), chapters.length - 1);
  for (let i = start; i < chapters.length; i++) {
    if (isReadable(chapters, i)) {
      return i;
    }
  }
  for (let i = start - 1; i >= 0; i--) {
    if (isReadable(chapters, i)) {
      return i;
    }
  }
  return -1;
}

/**
 * 进度迁移：先在新目录里找与旧章节**同名**的可读章；找不到再按 `percent`
 * 折算章号（`round(percent × 章数) − 1`，即旧书里那个「已读章数」比例对应的位置）。
 *
 * `matchedBy` 会回报给用户（「按章节对齐」/「按进度对齐」），因为两者体验差别很大：
 * 前者位置精确，后者在新旧目录差异大时会有偏差，用户需要知道。
 */
export function locateChapter(
  chapters: Chapter[],
  progress: ReadProgress | undefined
): SwitchMatch {
  const fallback: number = firstReadable(chapters);
  if (progress === undefined) {
    return new SwitchMatch(fallback, 'start');
  }
  const want: string = normalizeKey(progress.chapterTitle);
  if (want.length > 0) {
    for (let i = 0; i < chapters.length; i++) {
      if (isReadable(chapters, i) && normalizeKey(chapters[i].title) === want) {
        return new SwitchMatch(i, 'title');
      }
    }
  }
  let percent: number = progress.percent;
  if (!(percent > 0)) {
    percent = 0;
  }
  if (percent > 1) {
    percent = 1;
  }
  const guess: number = Math.round(percent * chapters.length) - 1;
  const index: number = nearestReadable(chapters, guess);
  return new SwitchMatch(index < 0 ? fallback : index, 'percent');
}

/** 进度迁移结果：目标章号 + 用什么方式对齐（用于提示文案）。 */
export class SwitchMatch {
  index: number;
  /** 'title' 章节名命中 / 'percent' 按比例折算 / 'start' 原书没有进度。 */
  by: string;

  constructor(index: number, by: string) {
    this.index = index;
    this.by = by;
  }
}

/** 换源结果：新书的完整状态，调用方据此重建阅读页。 */
export class SwitchOutcome {
  book: Book;
  chapters: Chapter[];
  chapterIndex: number;
  /** 进度对齐方式，见 `SwitchMatch.by`。 */
  matchedBy: string;

  constructor(book: Book, chapters: Chapter[], chapterIndex: number, matchedBy: string) {
    this.book = book;
    this.chapters = chapters;
    this.chapterIndex = chapterIndex;
    this.matchedBy = matchedBy;
  }
}

/**
 * Switch the current book to `target`, migrating the reading position.
 *
 * @param oldProgress the position to migrate; `undefined` starts the new source at
 *        its first readable chapter.
 * @throws when the new source cannot serve `bookInfo` / a non-empty TOC — nothing
 *         is written in that case.
 */
export async function switchSource(
  ctx: common.UIAbilityContext | undefined,
  oldBook: Book,
  oldSource: BookSource,
  oldProgress: ReadProgress | undefined,
  target: BookSource,
  item: BookSearchItem
): Promise<SwitchOutcome> {
  if (isLocalBook(oldBook)) {
    throw new Error('本地书籍不支持换源');
  }
  if (target.bookSourceUrl === oldSource.bookSourceUrl) {
    throw new Error('已经是当前书源');
  }
  // 抽屉里的预热（`SourcePrefetch`）命中就直接用：详情 1.1s / 目录 5.9s 已在用户点「切换」前跑完。
  const warmedInfo: Book | undefined = takePrefetchedInfo(target.bookSourceUrl, item.bookUrl);
  const info: Book = warmedInfo !== undefined
    ? warmedInfo
    : await bookEngine.bookInfo(target, item.bookUrl, ENGINE_INFO_TIMEOUT_MS);
  const tocUrl: string = info.tocUrl.length > 0 ? info.tocUrl : item.bookUrl;
  const warmedChapters: Chapter[] | undefined =
    takePrefetchedToc(target.bookSourceUrl, item.bookUrl, tocUrl);
  const chapters: Chapter[] = warmedChapters !== undefined && warmedChapters.length > 0
    ? warmedChapters
    : await bookEngine.toc(target, tocUrl, ENGINE_TOC_TIMEOUT_MS);
  if (chapters.length === 0) {
    throw new Error('该源目录为空');
  }
  const match: SwitchMatch = locateChapter(chapters, oldProgress);
  if (match.index < 0) {
    throw new Error('该源目录没有可读章节');
  }
  const bookId: string = computeBookId(target.bookSourceUrl, item.bookUrl);
  const newBook: Book = {
    bookId: bookId,
    sourceUrl: target.bookSourceUrl,
    name: info.name.length > 0 ? info.name : oldBook.name,
    author: info.author.length > 0 ? info.author : oldBook.author,
    coverUrl: info.coverUrl.length > 0 ? info.coverUrl : item.coverUrl,
    intro: info.intro.length > 0 ? info.intro : oldBook.intro,
    kind: info.kind.length > 0 ? info.kind : oldBook.kind,
    wordCount: info.wordCount,
    status: info.status,
    lastChapterTitle: info.lastChapterTitle.length > 0 ? info.lastChapterTitle : item.lastChapter,
    tocUrl: tocUrl,
    inShelf: true,
    // 保留原加入时间：换源是同一本书改来源，书架排序不该被这次操作顶到最前。
    addedAt: oldBook.addedAt > 0 ? oldBook.addedAt : Date.now()
  };

  // 听书不能跨源继续：`TtsController` 持有旧的 `chapters` 引用与旧 bookId 的进度所有权，
  // 换源后它播的是已从书架删除的书的正文。先停播（同时释放 `ProgressOwner` 的占用），
  // 再写新行 —— 否则下面这次 saveProgress 会被仲裁丢弃。
  const tts: TtsController = TtsController.instance();
  if (tts.isActiveFor(oldBook.bookId)) {
    tts.stop();
  }
  BookDownloader.instance().cancelForBook(oldBook.bookId);

  await removeBooks([oldBook.bookId]);
  await upsertBook(newBook);
  await saveProgress({
    bookId: bookId,
    chapterIndex: match.index,
    chapterTitle: chapters[match.index].title,
    paragraphIndex: 0,
    charOffset: 0,
    percent: (match.index + 1) / chapters.length,
    updatedAt: Date.now()
  }, ProgressWriter.READER);

  if (ctx !== undefined) {
    // 新目录直接落盘：切过去的那一次 `loadToc` 就不必再爬一遍。
    putCachedToc(ctx, bookId, tocUrl, chapters);
    try {
      deleteBookChapters(ctx, oldBook.bookId);
      deleteBookToc(ctx, oldBook.bookId);
      deleteBookDownload(ctx, oldBook.bookId);
    } catch (err) {
      // 残留文件由「清理缓存」兜底，不能因为清不掉就回滚已经生效的换源。
    }
  }
  return new SwitchOutcome(newBook, chapters, match.index, match.by);
}
