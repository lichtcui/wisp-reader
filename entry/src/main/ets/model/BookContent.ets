import { common } from '@kit.AbilityKit';
import { bookEngine } from '../engine/BookEngineNapi';
import { Book, BookSource, Chapter } from '../engine/types';
import { getCachedChapter, putCachedChapter } from './ChapterCache';
import { getDownloadedChapter } from './DownloadStore';
import { isLocalBook, loadLocalContent } from './LocalBook';
import { ENGINE_CONTENT_TIMEOUT_MS } from '../common/Const';

/**
 * 页码尾巴：`（第1/3页）` / `(2/3)` / `第 3/3 页`（空格在比较前已删）。
 * 裸的 `1/3` 刻意不算 —— 那只要求「章名后面跟一个分数」，误伤正文的代价不值得。
 */
const PAGE_MARK_RE: RegExp = /^(?:[（(\[【](?:第)?\d+\/\d+页?[)）\]】]|第\d+\/\d+页?|\d+\/\d+页)$/;

/**
 * Some sources render the chapter body inside a container that also carries the
 * site breadcrumb ("当前位置：/作者/书名/章节名") and repeats the title on every
 * paginated sub-page. Keep exactly one title heading, drop the rest.
 *
 * **分页子页的章名重复**（T-READ-9）：书源用 `nextContentUrl` 把一章拼成多页时，
 * **每个子页的正文首行都再印一次章名**，只多带一个页码后缀。真机实测
 * 《我都成超人了，灵气才复苏？》第五章（bbiquge8，`/book/176923/tc_5.html`）拼出来的正文里
 * 夹着 `第五章 寻找 (第1/3页)` / `(第2/3页)` / `(第3/3页)` 三行 —— 旧判定只认「整行 == 章名」，
 * 于是阅读页出现「第五章 寻找」（本函数补的标题段落）+「第五章 寻找 (第1/3页)」两行同名。
 * 这里把「章名 + 纯页码尾巴」与「孤立的页码行」一并去掉，判据见 `PAGE_MARK_RE`。
 *
 * **正文清洗的唯一实现**（T-READ-1）：阅读页分页（`pages/Reader.ets`）与听书分段
 * （`TtsController` → `loadChapterParagraphs`）都走这里。任一侧单独改清洗规则会让
 * 两边段落/标题不一致，进而使 TTS 高亮与阅读页定位错位。
 */
export function sanitizeText(raw: string, title: string): string[] {
  const text: string = raw.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const target: string = title.trim().replace(/\s/g, '');
  const out: string[] = [];
  for (const rawLine of text.split('\n')) {
    const line: string = rawLine.trim();
    if (line.length === 0) {
      continue;
    }
    if (line.indexOf('当前位置') >= 0) {
      continue;
    }
    const compact: string = line.replace(/\s/g, '');
    if (compact === '/' || line.endsWith('/')) {
      continue;
    }
    if (target.length > 0 && compact === target) {
      continue;
    }
    // 章名后面只剩一个页码标记 ⇒ 分页子页重复的标题行（`第五章 寻找 (第1/3页)`）。
    if (target.length > 0 && compact.startsWith(target) &&
      PAGE_MARK_RE.test(compact.substring(target.length))) {
      continue;
    }
    // 站点把页码标记单独成行（没有章名）时同样清掉。
    if (PAGE_MARK_RE.test(compact)) {
      continue;
    }
    out.push(line);
  }
  if (title.trim().length > 0) {
    out.unshift(title.trim());
  }
  return out;
}

/**
 * Load one chapter's sanitized paragraphs: local TXT books read from the
 * sandbox, engine books prefer their permanent download, then the disposable
 * file cache (both validated by chapter URL), and finally the Rust `content`
 * NAPI on a miss.
 */
export async function loadChapterParagraphs(
  ctx: common.UIAbilityContext | undefined,
  src: BookSource | undefined,
  book: Book | undefined,
  chapter: Chapter,
  index: number
): Promise<string[]> {
  if (book === undefined || src === undefined) {
    return [];
  }
  if (isLocalBook(book)) {
    return ctx !== undefined ? sanitizeText(loadLocalContent(ctx, book, index), chapter.title) : [];
  }
  if (ctx !== undefined) {
    const downloaded: string | undefined = getDownloadedChapter(ctx, book.bookId, index, chapter.url);
    if (downloaded !== undefined) {
      return sanitizeText(downloaded, chapter.title);
    }
    const cached: string | undefined = getCachedChapter(ctx, book.bookId, index, chapter.url);
    if (cached !== undefined) {
      return sanitizeText(cached, chapter.title);
    }
  }
  const result = await bookEngine.content(src, chapter.url, ENGINE_CONTENT_TIMEOUT_MS);
  if (ctx !== undefined) {
    putCachedChapter(ctx, book.bookId, index, chapter.url, result.content);
  }
  return sanitizeText(result.content, chapter.title);
}
