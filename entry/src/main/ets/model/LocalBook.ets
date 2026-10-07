import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Book, BookSource, Chapter } from '../engine/types';
import { computeBookId } from '../common/Format';
import { upsertBook } from './ShelfRepository';

/**
 * Local TXT books live outside the book-source engine: the file is copied into
 * the sandbox, split into chapters by a heading regex and read back from disk.
 * They reuse the shelf/reader models by carrying a sentinel source URL.
 */
export const LOCAL_SOURCE_URL: string = 'local://';

const LOCAL_DIR: string = '/local';

interface LocalChapterMeta {
  title: string;
  start: number;
  end: number;
}

interface LocalToc {
  name: string;
  author: string;
  chapters: LocalChapterMeta[];
}

const tocCache: Map<string, LocalToc> = new Map();
const textCache: Map<string, string> = new Map();

/** Sentinel source used to route local books around the native engine. */
export function localSource(): BookSource {
  return {
    bookSourceName: '本地书籍',
    bookSourceUrl: LOCAL_SOURCE_URL,
    bookSourceGroup: '本地',
    bookSourceType: 0,
    enabled: true
  };
}

export function isLocalBook(book: Book): boolean {
  return book.sourceUrl === LOCAL_SOURCE_URL;
}

// ── Paths ───────────────────────────────────────────────────────

function bookDir(ctx: common.UIAbilityContext, bookId: string): string {
  return ctx.filesDir + LOCAL_DIR + '/' + bookId;
}

function textPath(ctx: common.UIAbilityContext, bookId: string): string {
  return bookDir(ctx, bookId) + '/book.txt';
}

function tocPath(ctx: common.UIAbilityContext, bookId: string): string {
  return bookDir(ctx, bookId) + '/toc.json';
}

function cacheSmall<T>(cache: Map<string, T>, key: string, value: T, max: number): void {
  if (cache.size >= max) {
    const first: string | undefined = cache.keys().next().value;
    if (first !== undefined) {
      cache.delete(first);
    }
  }
  cache.set(key, value);
}

// ── Import ──────────────────────────────────────────────────────

/** Pick a `.txt` file, parse it and add it to the shelf. */
export async function importLocalTxt(ctx: common.UIAbilityContext): Promise<Book | undefined> {
  const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
  const options: picker.DocumentSelectOptions = {
    maxSelectNumber: 1,
    fileSuffixFilters: ['.txt']
  };
  const uris: string[] = await documentPicker.select(options);
  if (uris.length === 0) {
    return undefined;
  }
  const uri: string = uris[0];
  const raw: ArrayBuffer = readBytes(uri);
  const text: string = normalize(decode(raw));
  if (text.trim().length === 0) {
    throw new Error('empty');
  }
  const name: string = stripExt(fileNameFromUri(uri));
  const author: string = extractAuthor(text);
  const chapters: LocalChapterMeta[] = splitChapters(text);
  const bookId: string = computeBookId(LOCAL_SOURCE_URL, name + '|' + text.length.toString());

  const dir: string = bookDir(ctx, bookId);
  if (!fileIo.accessSync(dir)) {
    fileIo.mkdirSync(dir, true);
  }
  writeText(textPath(ctx, bookId), text);
  const toc: LocalToc = { name: name, author: author, chapters: chapters };
  writeText(tocPath(ctx, bookId), JSON.stringify(toc));
  tocCache.set(bookId, toc);

  const last: LocalChapterMeta = chapters[chapters.length - 1];
  const book: Book = {
    bookId: bookId,
    sourceUrl: LOCAL_SOURCE_URL,
    name: name,
    author: author,
    coverUrl: '',
    intro: makeIntro(text, chapters),
    kind: '本地 TXT',
    wordCount: text.length.toString(),
    status: '完结',
    lastChapterTitle: last !== undefined ? last.title : '',
    tocUrl: LOCAL_SOURCE_URL + bookId,
    inShelf: true,
    addedAt: Date.now()
  };
  await upsertBook(book);
  return book;
}

/**
 * Delete one local book's sandbox files (`filesDir/local/{bookId}`) and drop its
 * decoded TOC/text from memory. Re-importing the same TXT recreates everything
 * (`importLocalTxt` always rewrites `book.txt` / `toc.json`).
 *
 * `fileIo.rmdirSync` is recursive (SDK: "Removes a directory and all its
 * subdirectories and files synchronously"), so one call clears the book dir.
 */
export function deleteLocalBookData(ctx: common.UIAbilityContext, bookId: string): void {
  tocCache.delete(bookId);
  textCache.delete(bookId);
  const dir: string = bookDir(ctx, bookId);
  try {
    if (fileIo.accessSync(dir)) {
      fileIo.rmdirSync(dir);
    }
  } catch (err) {
    return;
  }
}

// ── Loading ─────────────────────────────────────────────────────

export function loadLocalChapters(ctx: common.UIAbilityContext, book: Book): Chapter[] {
  const toc: LocalToc = readToc(ctx, book.bookId);
  const out: Chapter[] = [];
  for (let i = 0; i < toc.chapters.length; i++) {
    out.push({
      bookId: book.bookId,
      index: i,
      title: toc.chapters[i].title,
      url: LOCAL_SOURCE_URL + book.bookId + '/' + i.toString(),
      isVip: false
    });
  }
  return out;
}

export function loadLocalContent(ctx: common.UIAbilityContext, book: Book, index: number): string {
  const toc: LocalToc = readToc(ctx, book.bookId);
  const meta: LocalChapterMeta | undefined = toc.chapters[index];
  if (meta === undefined) {
    return '';
  }
  let text: string | undefined = textCache.get(book.bookId);
  if (text === undefined) {
    text = fileIo.readTextSync(textPath(ctx, book.bookId));
    cacheSmall(textCache, book.bookId, text, 2);
  }
  return text.substring(meta.start, meta.end).trim();
}

function readToc(ctx: common.UIAbilityContext, bookId: string): LocalToc {
  const cached: LocalToc | undefined = tocCache.get(bookId);
  if (cached !== undefined) {
    return cached;
  }
  const toc: LocalToc = JSON.parse(fileIo.readTextSync(tocPath(ctx, bookId))) as LocalToc;
  cacheSmall(tocCache, bookId, toc, 4);
  return toc;
}

// ── Parsing helpers ─────────────────────────────────────────────

function readBytes(uri: string): ArrayBuffer {
  const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
  try {
    const size: number = fileIo.statSync(file.fd).size;
    if (size <= 0) {
      return new ArrayBuffer(0);
    }
    const buffer: ArrayBuffer = new ArrayBuffer(size);
    const read: number = fileIo.readSync(file.fd, buffer);
    return read === size ? buffer : buffer.slice(0, read);
  } finally {
    fileIo.closeSync(file);
  }
}

function normalize(text: string): string {
  return text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
}

function decode(buffer: ArrayBuffer): string {
  const bytes: Uint8Array = new Uint8Array(buffer);
  if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    return util.TextDecoder.create('utf-8').decodeToString(bytes.subarray(3));
  }
  if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) {
    return util.TextDecoder.create('utf-16le').decodeToString(bytes.subarray(2));
  }
  if (bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff) {
    return util.TextDecoder.create('utf-16be').decodeToString(bytes.subarray(2));
  }
  const utf8: string = util.TextDecoder.create('utf-8').decodeToString(bytes);
  if (replacementRatio(utf8) > 0.005) {
    try {
      return util.TextDecoder.create('gbk').decodeToString(bytes);
    } catch (err) {
      return utf8;
    }
  }
  return utf8;
}

function replacementRatio(text: string): number {
  if (text.length === 0) {
    return 0;
  }
  let bad: number = 0;
  for (let i = 0; i < text.length; i++) {
    if (text.charCodeAt(i) === 0xfffd) {
      bad += 1;
    }
  }
  return bad / text.length;
}

function splitChapters(text: string): LocalChapterMeta[] {
  const pattern: RegExp = /^[ \t\u3000]*(第[0-9零一二三四五六七八九十百千万两]+[章回节卷集部篇])[^\n]{0,40}$/gm;
  const starts: number[] = [];
  const ends: number[] = [];
  const titles: string[] = [];
  let match: RegExpExecArray | null = pattern.exec(text);
  while (match !== null) {
    starts.push(match.index);
    ends.push(match.index + match[0].length);
    titles.push(match[0].trim());
    if (match.index === pattern.lastIndex) {
      pattern.lastIndex += 1;
    }
    match = pattern.exec(text);
  }
  const metas: LocalChapterMeta[] = [];
  if (starts.length === 0) {
    metas.push({ title: '全文', start: 0, end: text.length });
    return metas;
  }
  if (starts[0] > 40) {
    metas.push({ title: '前言', start: 0, end: starts[0] });
  }
  for (let i = 0; i < starts.length; i++) {
    const bodyStart: number = skipNewlines(text, ends[i]);
    const bodyEnd: number = i + 1 < starts.length ? starts[i + 1] : text.length;
    metas.push({ title: titles[i], start: bodyStart, end: bodyEnd });
  }
  return metas;
}

function skipNewlines(text: string, from: number): number {
  let i: number = from;
  while (i < text.length && (text[i] === '\n' || text[i] === ' ' || text[i] === '\t' || text[i] === '\u3000')) {
    i += 1;
  }
  return i;
}

function extractAuthor(text: string): string {
  const head: string = text.substring(0, 3000);
  const match: RegExpMatchArray | null = head.match(/作者[：:]\s*([^\n]{1,40})/);
  return match !== null ? match[1].trim() : '';
}

function makeIntro(text: string, chapters: LocalChapterMeta[]): string {
  const first: LocalChapterMeta | undefined = chapters[0];
  const body: string = first !== undefined ? text.substring(first.start, first.end) : text;
  const cleaned: string = body.replace(/\n+/g, ' ').trim();
  return cleaned.length > 120 ? cleaned.substring(0, 120) + '…' : cleaned;
}

function fileNameFromUri(uri: string): string {
  let value: string = uri;
  try {
    value = decodeURIComponent(uri);
  } catch (err) {
  }
  const slash: number = value.lastIndexOf('/');
  return slash >= 0 ? value.substring(slash + 1) : value;
}

function stripExt(name: string): string {
  const dot: number = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

function writeText(path: string, content: string): void {
  const file: fileIo.File = fileIo.openSync(
    path,
    fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
  );
  try {
    fileIo.writeSync(file.fd, content);
  } finally {
    fileIo.closeSync(file);
  }
}