import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Book, BookSource, Chapter } from '../engine/types';
import { computeBookId, splitTitleAuthor, TitleAuthorParts } from '../common/Format';
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

interface ParsedLocalTxt {
  name: string;
  author: string;
  text: string;
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

/**
 * Older imports kept the trailing `作者：…` in the title. Repair those rows in
 * place so the stable id, source and progress stay attached to the same book.
 */
export async function repairLocalBookMetadata(
  ctx: common.UIAbilityContext,
  book: Book
): Promise<Book> {
  if (!isLocalBook(book)) {
    return book;
  }
  const parts: TitleAuthorParts = splitTitleAuthor(book.name);
  if (parts.author.length === 0) {
    return book;
  }
  if (parts.title === book.name && parts.author === book.author) {
    return book;
  }
  const repaired: Book = {
    bookId: book.bookId,
    sourceUrl: book.sourceUrl,
    name: parts.title,
    author: parts.author,
    coverUrl: book.coverUrl,
    intro: book.intro,
    kind: book.kind,
    wordCount: book.wordCount,
    status: book.status,
    lastChapterTitle: book.lastChapterTitle,
    tocUrl: book.tocUrl,
    inShelf: book.inShelf,
    addedAt: book.addedAt
  };
  try {
    await upsertBook(repaired);
  } catch (err) {
    return book;
  }
  updateLocalTocMetadata(ctx, book.bookId, parts.title, parts.author);
  return repaired;
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
  const parsed: ParsedLocalTxt | undefined = await pickLocalTxt(ctx);
  if (parsed === undefined) {
    return undefined;
  }
  const bookId: string = computeBookId(LOCAL_SOURCE_URL, parsed.name + '|' + parsed.text.length.toString());
  persistLocalTxt(ctx, bookId, parsed);

  const last: LocalChapterMeta = parsed.chapters[parsed.chapters.length - 1];
  const book: Book = {
    bookId: bookId,
    sourceUrl: LOCAL_SOURCE_URL,
    name: parsed.name,
    author: parsed.author,
    coverUrl: '',
    intro: makeIntro(parsed.text, parsed.chapters),
    kind: '本地 TXT',
    wordCount: parsed.text.length.toString(),
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
 * Reattach a TXT to an existing local shelf row. The old bookId/sourceUrl/tocUrl
 * stay unchanged so reading progress still belongs to the same book.
 */
export async function relinkLocalTxt(
  ctx: common.UIAbilityContext,
  book: Book
): Promise<Book | undefined> {
  const parsed: ParsedLocalTxt | undefined = await pickLocalTxt(ctx);
  if (parsed === undefined) {
    return undefined;
  }
  validateRelink(book, parsed);
  persistLocalTxt(ctx, book.bookId, parsed);

  const last: LocalChapterMeta = parsed.chapters[parsed.chapters.length - 1];
  const relinked: Book = {
    bookId: book.bookId,
    sourceUrl: book.sourceUrl,
    name: parsed.name,
    author: parsed.author,
    coverUrl: book.coverUrl,
    intro: makeIntro(parsed.text, parsed.chapters),
    kind: book.kind,
    wordCount: parsed.text.length.toString(),
    status: book.status,
    lastChapterTitle: last !== undefined ? last.title : '',
    tocUrl: book.tocUrl,
    inShelf: book.inShelf,
    addedAt: book.addedAt
  };
  await upsertBook(relinked);
  return relinked;
}

async function pickLocalTxt(ctx: common.UIAbilityContext): Promise<ParsedLocalTxt | undefined> {
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
  const parts: TitleAuthorParts = splitTitleAuthor(stripExt(fileNameFromUri(uri)));
  const author: string = parts.author.length > 0 ? parts.author : extractAuthor(text);
  const chapters: LocalChapterMeta[] = splitChapters(text);
  return { name: parts.title, author: author, text: text, chapters: chapters };
}

function persistLocalTxt(ctx: common.UIAbilityContext, bookId: string, parsed: ParsedLocalTxt): void {
  const dir: string = bookDir(ctx, bookId);
  if (!fileIo.accessSync(dir)) {
    fileIo.mkdirSync(dir, true);
  }
  writeText(textPath(ctx, bookId), parsed.text);
  const toc: LocalToc = { name: parsed.name, author: parsed.author, chapters: parsed.chapters };
  writeText(tocPath(ctx, bookId), JSON.stringify(toc));
  tocCache.set(bookId, toc);
  textCache.delete(bookId);
}

/** A relink must not silently attach an unrelated file to the current progress. */
function validateRelink(book: Book, parsed: ParsedLocalTxt): void {
  const expected: string = normalizeTitle(book.name);
  const actual: string = normalizeTitle(parsed.name);
  if (expected.length === 0 || actual.length === 0) {
    return;
  }
  if (expected === actual || expected.indexOf(actual) >= 0 || actual.indexOf(expected) >= 0) {
    return;
  }
  throw new Error('mismatch');
}

function normalizeTitle(value: string): string {
  return value.replace(/\s+/g, '').trim();
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

/** Check the imported text directly; caches must not hide missing sandbox data. */
export function hasLocalBookText(ctx: common.UIAbilityContext, book: Book): boolean {
  try {
    return fileIo.accessSync(textPath(ctx, book.bookId));
  } catch (err) {
    return false;
  }
}

export function hasLocalBookToc(ctx: common.UIAbilityContext, book: Book): boolean {
  try {
    return fileIo.accessSync(tocPath(ctx, book.bookId));
  } catch (err) {
    return false;
  }
}

/** Rebuild only the chapter index; keeps the existing text and shelf row untouched. */
export function rebuildLocalToc(ctx: common.UIAbilityContext, book: Book): void {
  const text: string = normalize(fileIo.readTextSync(textPath(ctx, book.bookId)));
  const chapters: LocalChapterMeta[] = splitChapters(text);
  const toc: LocalToc = { name: book.name, author: book.author, chapters: chapters };
  writeText(tocPath(ctx, book.bookId), JSON.stringify(toc));
  tocCache.set(book.bookId, toc);
}

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

function updateLocalTocMetadata(
  ctx: common.UIAbilityContext,
  bookId: string,
  name: string,
  author: string
): void {
  try {
    if (!fileIo.accessSync(tocPath(ctx, bookId))) {
      return;
    }
    const toc: LocalToc = readToc(ctx, bookId);
    toc.name = name;
    toc.author = author;
    writeText(tocPath(ctx, bookId), JSON.stringify(toc));
    tocCache.set(bookId, toc);
  } catch (err) {
    // Metadata repair must not make an otherwise readable local book unavailable.
  }
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
