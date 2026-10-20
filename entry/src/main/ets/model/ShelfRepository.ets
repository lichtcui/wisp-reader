import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Book, ReadProgress } from '../engine/types';
import { canWriteProgress, forgetProgressOwner, ProgressWriter } from './ProgressOwner';

const DB_NAME: string = 'shelf.db';

const CREATE_BOOKS: string =
  'CREATE TABLE IF NOT EXISTS books (' +
  'book_id TEXT PRIMARY KEY, source_url TEXT NOT NULL, name TEXT, author TEXT, ' +
  'cover_url TEXT, intro TEXT, kind TEXT, word_count TEXT, status TEXT, ' +
  'last_chapter_title TEXT, toc_url TEXT, added_at INTEGER)';

const CREATE_PROGRESS: string =
  'CREATE TABLE IF NOT EXISTS progress (' +
  'book_id TEXT PRIMARY KEY, chapter_index INTEGER, chapter_title TEXT, ' +
  'paragraph_index INTEGER, char_offset INTEGER, percent REAL, updated_at INTEGER)';

/** Keep SQLite bind-variable counts below the portable 999 limit. */
const ID_CHUNK_SIZE: number = 400;

/** Lightweight counts for status surfaces; no row payloads are read. */
export interface ShelfCounts {
  books: number;
  progress: number;
}

/** One shelf row plus its optional progress, read from a single LEFT JOIN. */
export interface ShelfBookRecord {
  book: Book;
  progress: ReadProgress | undefined;
}

interface BookColumns {
  bookId: number;
  sourceUrl: number;
  name: number;
  author: number;
  coverUrl: number;
  intro: number;
  kind: number;
  wordCount: number;
  status: number;
  lastChapter: number;
  tocUrl: number;
  addedAt: number;
}

interface ProgressColumns {
  bookId: number;
  chapterIndex: number;
  chapterTitle: number;
  paragraphIndex: number;
  charOffset: number;
  percent: number;
  updatedAt: number;
}

let store: relationalStore.RdbStore | undefined = undefined;
/** 并发初始化护栏：Ability 与页面同帧调用时共用一个 open，失败后允许重试。 */
let opening: Promise<void> | undefined = undefined;
/** Last progress write timestamp per book, to reject an older late write. */
const lastWriteAt: Map<string, number> = new Map<string, number>();

export function initShelf(ctx: common.UIAbilityContext): Promise<void> {
  if (store !== undefined) {
    return Promise.resolve();
  }
  if (opening === undefined) {
    opening = openShelf(ctx).catch((err: Error): Promise<void> => {
      opening = undefined;
      throw err;
    });
  }
  return opening;
}

async function openShelf(ctx: common.UIAbilityContext): Promise<void> {
  const config: relationalStore.StoreConfig = {
    name: DB_NAME,
    securityLevel: relationalStore.SecurityLevel.S1
  };
  const s: relationalStore.RdbStore = await relationalStore.getRdbStore(ctx, config);
  await s.executeSql(CREATE_BOOKS);
  await s.executeSql(CREATE_PROGRESS);
  store = s;
}

function db(): relationalStore.RdbStore | undefined {
  return store;
}

function bookColumns(rs: relationalStore.ResultSet): BookColumns {
  return {
    bookId: rs.getColumnIndex('book_id'),
    sourceUrl: rs.getColumnIndex('source_url'),
    name: rs.getColumnIndex('name'),
    author: rs.getColumnIndex('author'),
    coverUrl: rs.getColumnIndex('cover_url'),
    intro: rs.getColumnIndex('intro'),
    kind: rs.getColumnIndex('kind'),
    wordCount: rs.getColumnIndex('word_count'),
    status: rs.getColumnIndex('status'),
    lastChapter: rs.getColumnIndex('last_chapter_title'),
    tocUrl: rs.getColumnIndex('toc_url'),
    addedAt: rs.getColumnIndex('added_at')
  };
}

function readBook(rs: relationalStore.ResultSet, c: BookColumns): Book {
  return {
    bookId: rs.getString(c.bookId),
    sourceUrl: rs.getString(c.sourceUrl),
    name: rs.getString(c.name),
    author: rs.getString(c.author),
    coverUrl: rs.getString(c.coverUrl),
    intro: rs.getString(c.intro),
    kind: rs.getString(c.kind),
    wordCount: rs.getString(c.wordCount),
    status: rs.getString(c.status),
    lastChapterTitle: rs.getString(c.lastChapter),
    tocUrl: rs.getString(c.tocUrl),
    inShelf: true,
    addedAt: rs.getLong(c.addedAt)
  };
}

function progressColumns(rs: relationalStore.ResultSet, prefix: string): ProgressColumns {
  return {
    bookId: rs.getColumnIndex(prefix + 'book_id'),
    chapterIndex: rs.getColumnIndex(prefix + 'chapter_index'),
    chapterTitle: rs.getColumnIndex(prefix + 'chapter_title'),
    paragraphIndex: rs.getColumnIndex(prefix + 'paragraph_index'),
    charOffset: rs.getColumnIndex(prefix + 'char_offset'),
    percent: rs.getColumnIndex(prefix + 'percent'),
    updatedAt: rs.getColumnIndex(prefix + 'updated_at')
  };
}

function readProgress(rs: relationalStore.ResultSet, c: ProgressColumns): ReadProgress {
  return {
    bookId: rs.getString(c.bookId),
    chapterIndex: rs.getLong(c.chapterIndex),
    chapterTitle: rs.getString(c.chapterTitle),
    paragraphIndex: rs.getLong(c.paragraphIndex),
    charOffset: rs.getLong(c.charOffset),
    percent: rs.getDouble(c.percent),
    updatedAt: rs.getLong(c.updatedAt)
  };
}

function bookValues(book: Book): relationalStore.ValuesBucket {
  return {
    'book_id': book.bookId,
    'source_url': book.sourceUrl,
    'name': book.name,
    'author': book.author,
    'cover_url': book.coverUrl,
    'intro': book.intro,
    'kind': book.kind,
    'word_count': book.wordCount,
    'status': book.status,
    'last_chapter_title': book.lastChapterTitle,
    'toc_url': book.tocUrl,
    'added_at': book.addedAt > 0 ? book.addedAt : Date.now()
  };
}

function progressValues(progress: ReadProgress, updatedAt: number): relationalStore.ValuesBucket {
  return {
    'book_id': progress.bookId,
    'chapter_index': progress.chapterIndex,
    'chapter_title': progress.chapterTitle,
    'paragraph_index': progress.paragraphIndex,
    'char_offset': progress.charOffset,
    'percent': progress.percent,
    'updated_at': updatedAt
  };
}

/** Insert or update a book. */
export async function upsertBook(book: Book): Promise<void> {
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return;
  }
  await s.insert('books', bookValues(book), relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
}

/**
 * Remove books from the shelf: their `books` row (source of truth, so the shelf
 * stops showing them even if cache cleanup fails) and their `progress` row.
 * Callers that own a context should use `BookRemoval.deleteBooks`, which also
 * purges the chapter/toc/local caches.
 *
 * `lastWriteAt.delete()` is required, not cosmetic: `saveProgress()` rejects a
 * write when the stored timestamp is newer (`last > incoming`), so a stale entry
 * (clock skew / future timestamp) would swallow the progress of a book that is
 * re-added later.
 */
export async function removeBooks(bookIds: string[]): Promise<void> {
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined || bookIds.length === 0) {
    return;
  }
  const unique: string[] = [];
  const seen: Set<string> = new Set<string>();
  for (const bookId of bookIds) {
    if (bookId.length > 0 && !seen.has(bookId)) {
      seen.add(bookId);
      unique.push(bookId);
    }
  }
  if (unique.length === 0) {
    return;
  }
  const tx: relationalStore.Transaction = await s.createTransaction();
  try {
    for (let start: number = 0; start < unique.length; start += ID_CHUNK_SIZE) {
      const chunk: string[] = unique.slice(start, start + ID_CHUNK_SIZE);
      const holes: string[] = [];
      const args: relationalStore.ValueType[] = [];
      for (const bookId of chunk) {
        holes.push('?');
        args.push(bookId);
      }
      const where: string = ' WHERE book_id IN (' + holes.join(', ') + ')';
      await tx.execute('DELETE FROM books' + where, args);
      await tx.execute('DELETE FROM progress' + where, args);
    }
    await tx.commit();
  } catch (err) {
    await tx.rollback();
    throw err as Error;
  }
  for (const bookId of unique) {
    lastWriteAt.delete(bookId);
    forgetProgressOwner(bookId);
  }
}

/**
 * Replace the whole shelf (every `books` and `progress` row) with the given rows.
 *
 * Used by 备份恢复, whose UI promises 「全量覆盖」: `upsertBook` / `saveProgress`
 * alone only add/update, so rows absent from the backup (orphan progress left
 * behind by older deletes) would survive and the data would not match the file.
 *
 * `lastWriteAt.clear()` is required, not cosmetic: the monotonic guard in
 * `saveProgress()` rejects a write older than the last one *this session*, and
 * the map still holds pre-import timestamps — without the clear, an imported
 * progress row with an older `updatedAt` is silently dropped.
 *
 * The `ProgressOwner` claim is deliberately **not** cleared: a restore must not
 * hijack a live listening session. The transaction writes progress rows directly
 * instead of going through `saveProgress()`, so the restore bypasses arbitration;
 * if the restored book happens to be playing, the audio clock overwrites the
 * restored (stale) row on its next tick, which is the intended outcome.
 *
 * Callers still validate the whole payload before calling this so a malformed
 * backup never reaches the DB. The transaction itself is all-or-nothing.
 */
export async function replaceShelf(books: Book[], progress: ReadProgress[]): Promise<void> {
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return;
  }
  const restoredAt: Map<string, number> = new Map<string, number>();
  const tx: relationalStore.Transaction = await s.createTransaction();
  try {
    await tx.execute('DELETE FROM books');
    await tx.execute('DELETE FROM progress');
    for (const book of books) {
      await tx.insert('books', bookValues(book), relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    }
    for (const row of progress) {
      const updatedAt: number = row.updatedAt > 0 ? row.updatedAt : Date.now();
      await tx.insert('progress', progressValues(row, updatedAt),
        relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
      restoredAt.set(row.bookId, updatedAt);
    }
    await tx.commit();
  } catch (err) {
    await tx.rollback();
    throw err as Error;
  }
  lastWriteAt.clear();
  restoredAt.forEach((updatedAt: number, bookId: string): void => {
    lastWriteAt.set(bookId, updatedAt);
  });
}

/** Row counts for status screens; avoids deserializing every book/progress row just to take a length. */
export async function countShelfRows(): Promise<ShelfCounts> {
  const empty: ShelfCounts = { books: 0, progress: 0 };
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return empty;
  }
  const rs: relationalStore.ResultSet = await s.querySql(
    'SELECT (SELECT COUNT(*) FROM books) AS books_n, ' +
    '(SELECT COUNT(*) FROM progress) AS progress_n'
  );
  const counts: ShelfCounts = empty;
  if (rs.goToNextRow()) {
    counts.books = rs.getLong(rs.getColumnIndex('books_n'));
    counts.progress = rs.getLong(rs.getColumnIndex('progress_n'));
  }
  rs.close();
  return counts;
}

export async function getBooks(): Promise<Book[]> {
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return [];
  }
  const rs: relationalStore.ResultSet = await s.querySql('SELECT * FROM books ORDER BY added_at DESC');
  const c: BookColumns = bookColumns(rs);
  const out: Book[] = [];
  while (rs.goToNextRow()) {
    out.push(readBook(rs, c));
  }
  rs.close();
  return out;
}

/** Shelf snapshot in display order; one query fetches books and their progress. */
export async function getShelfBooks(): Promise<ShelfBookRecord[]> {
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return [];
  }
  const rs: relationalStore.ResultSet = await s.querySql(
    'SELECT b.*, p.book_id AS p_book_id, p.chapter_index AS p_chapter_index, ' +
      'p.chapter_title AS p_chapter_title, p.paragraph_index AS p_paragraph_index, ' +
      'p.char_offset AS p_char_offset, p.percent AS p_percent, p.updated_at AS p_updated_at ' +
      'FROM books b LEFT JOIN progress p ON p.book_id = b.book_id ORDER BY b.added_at DESC'
  );
  const cBook: BookColumns = bookColumns(rs);
  const cProgress: ProgressColumns = progressColumns(rs, 'p_');
  const out: ShelfBookRecord[] = [];
  while (rs.goToNextRow()) {
    const progress: ReadProgress | undefined = rs.isColumnNull(cProgress.bookId)
      ? undefined
      : readProgress(rs, cProgress);
    out.push({ book: readBook(rs, cBook), progress: progress });
  }
  rs.close();
  return out;
}

/** Dedupe by name + author (no cross-source identity mapping in v1). */
export async function isInShelf(name: string, author: string): Promise<boolean> {
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return false;
  }
  const rs: relationalStore.ResultSet =
    await s.querySql('SELECT book_id FROM books WHERE name = ? AND author = ? LIMIT 1', [name, author]);
  const hit: boolean = rs.goToNextRow();
  rs.close();
  return hit;
}

/**
 * Write one book's reading position.
 *
 * `writer` is part of the contract, not decoration: while the TTS is playing a
 * book it owns that book's position and every other writer is dropped here — see
 * `model/ProgressOwner.ets` for why (the audio clock is authoritative, the Reader
 * would stamp the first paragraph of its visible page, which may be a chapter it
 * loaded *before* the audio moved on). The check runs **before** the timestamp
 * guard so a rejected write cannot poison `lastWriteAt` with a future timestamp.
 */
export async function saveProgress(p: ReadProgress, writer: ProgressWriter): Promise<void> {
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return;
  }
  if (!canWriteProgress(p.bookId, writer)) {
    return;
  }
  const incoming: number = p.updatedAt > 0 ? p.updatedAt : Date.now();
  const last: number | undefined = lastWriteAt.get(p.bookId);
  if (last !== undefined && last > incoming) {
    return;
  }
  lastWriteAt.set(p.bookId, incoming);
  await s.insert('progress', progressValues(p, incoming), relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
}

/** Batch-read every progress row, keyed by bookId (avoids the per-book fanout). */
export async function getAllProgress(): Promise<Map<string, ReadProgress>> {
  const out: Map<string, ReadProgress> = new Map<string, ReadProgress>();
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return out;
  }
  const rs: relationalStore.ResultSet = await s.querySql('SELECT * FROM progress');
  const c: ProgressColumns = progressColumns(rs, '');
  while (rs.goToNextRow()) {
    const p: ReadProgress = readProgress(rs, c);
    out.set(p.bookId, p);
  }
  rs.close();
  return out;
}

/** Cache trimming only compares chapter indices; avoid loading titles/offsets for every row. */
export async function getChapterPositions(): Promise<Map<string, number>> {
  const out: Map<string, number> = new Map<string, number>();
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return out;
  }
  const rs: relationalStore.ResultSet = await s.querySql('SELECT book_id, chapter_index FROM progress');
  const cBookId: number = rs.getColumnIndex('book_id');
  const cChapterIndex: number = rs.getColumnIndex('chapter_index');
  while (rs.goToNextRow()) {
    out.set(rs.getString(cBookId), rs.getLong(cChapterIndex));
  }
  rs.close();
  return out;
}

export async function getProgress(bookId: string): Promise<ReadProgress | undefined> {
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return undefined;
  }
  const rs: relationalStore.ResultSet =
    await s.querySql('SELECT * FROM progress WHERE book_id = ?', [bookId]);
  let p: ReadProgress | undefined = undefined;
  if (rs.goToNextRow()) {
    p = readProgress(rs, progressColumns(rs, ''));
  }
  rs.close();
  return p;
}
