import { common } from '@kit.AbilityKit';
import { bookEngine } from '../engine/BookEngineNapi';
import { Book, BookSource, Chapter } from '../engine/types';
import { getCachedChapter, putCachedChapter } from './ChapterCache';
import { isLocalBook, loadLocalContent } from './LocalBook';

/**
 * Some sources render the chapter body inside a container that also carries the
 * site breadcrumb ("当前位置：/作者/书名/章节名") and repeats the title on every
 * paginated sub-page. Keep exactly one title heading, drop the rest.
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
    out.push(line);
  }
  if (title.trim().length > 0) {
    out.unshift(title.trim());
  }
  return out;
}

/**
 * Load one chapter's sanitized paragraphs: local TXT books read from the
 * sandbox, engine books go through the file cache (validated by chapter URL)
 * and the Rust `content` NAPI on a miss.
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
    const cached: string | undefined = getCachedChapter(ctx, book.bookId, index, chapter.url);
    if (cached !== undefined) {
      return sanitizeText(cached, chapter.title);
    }
  }
  const result = await bookEngine.content(src, chapter.url);
  if (ctx !== undefined) {
    putCachedChapter(ctx, book.bookId, index, chapter.url, result.content);
  }
  return sanitizeText(result.content, chapter.title);
}