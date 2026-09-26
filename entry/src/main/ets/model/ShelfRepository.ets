import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Book, ReadProgress } from '../engine/types';

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

let store: relationalStore.RdbStore | undefined = undefined;

export async function initShelf(ctx: common.UIAbilityContext): Promise<void> {
  if (store !== undefined) {
    return;
  }
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

function rowToBook(rs: relationalStore.ResultSet): Book {
  const book: Book = {
    bookId: rs.getString(rs.getColumnIndex('book_id')),
    sourceUrl: rs.getString(rs.getColumnIndex('source_url')),
    name: rs.getString(rs.getColumnIndex('name')),
    author: rs.getString(rs.getColumnIndex('author')),
    coverUrl: rs.getString(rs.getColumnIndex('cover_url')),
    intro: rs.getString(rs.getColumnIndex('intro')),
    kind: rs.getString(rs.getColumnIndex('kind')),
    wordCount: rs.getString(rs.getColumnIndex('word_count')),
    status: rs.getString(rs.getColumnIndex('status')),
    lastChapterTitle: rs.getString(rs.getColumnIndex('last_chapter_title')),
    tocUrl: rs.getString(rs.getColumnIndex('toc_url')),
    inShelf: true,
    addedAt: rs.getLong(rs.getColumnIndex('added_at'))
  };
  return book;
}

/** Insert or update a book. */
export async function upsertBook(book: Book): Promise<void> {
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return;
  }
  const values: relationalStore.ValuesBucket = {
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
  await s.insert('books', values, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
}

export async function removeBook(bookId: string): Promise<void> {
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return;
  }
  await s.executeSql('DELETE FROM books WHERE book_id = ?', [bookId]);
  await s.executeSql('DELETE FROM progress WHERE book_id = ?', [bookId]);
}

export async function getBooks(): Promise<Book[]> {
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return [];
  }
  const rs: relationalStore.ResultSet = await s.querySql('SELECT * FROM books ORDER BY added_at DESC');
  const out: Book[] = [];
  while (rs.goToNextRow()) {
    out.push(rowToBook(rs));
  }
  rs.close();
  return out;
}

export async function getBook(bookId: string): Promise<Book | undefined> {
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return undefined;
  }
  const rs: relationalStore.ResultSet = await s.querySql('SELECT * FROM books WHERE book_id = ?', [bookId]);
  let book: Book | undefined = undefined;
  if (rs.goToNextRow()) {
    book = rowToBook(rs);
  }
  rs.close();
  return book;
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

export async function saveProgress(p: ReadProgress): Promise<void> {
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return;
  }
  const values: relationalStore.ValuesBucket = {
    'book_id': p.bookId,
    'chapter_index': p.chapterIndex,
    'chapter_title': p.chapterTitle,
    'paragraph_index': p.paragraphIndex,
    'char_offset': p.charOffset,
    'percent': p.percent,
    'updated_at': p.updatedAt > 0 ? p.updatedAt : Date.now()
  };
  await s.insert('progress', values, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
}

/** Batch-read every progress row, keyed by bookId (avoids the per-book fanout). */
export async function getAllProgress(): Promise<Map<string, ReadProgress>> {
  const out: Map<string, ReadProgress> = new Map<string, ReadProgress>();
  const s: relationalStore.RdbStore | undefined = db();
  if (s === undefined) {
    return out;
  }
  const rs: relationalStore.ResultSet = await s.querySql('SELECT * FROM progress');
  while (rs.goToNextRow()) {
    const p: ReadProgress = {
      bookId: rs.getString(rs.getColumnIndex('book_id')),
      chapterIndex: rs.getLong(rs.getColumnIndex('chapter_index')),
      chapterTitle: rs.getString(rs.getColumnIndex('chapter_title')),
      paragraphIndex: rs.getLong(rs.getColumnIndex('paragraph_index')),
      charOffset: rs.getLong(rs.getColumnIndex('char_offset')),
      percent: rs.getDouble(rs.getColumnIndex('percent')),
      updatedAt: rs.getLong(rs.getColumnIndex('updated_at'))
    };
    out.set(p.bookId, p);
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
    p = {
      bookId: rs.getString(rs.getColumnIndex('book_id')),
      chapterIndex: rs.getLong(rs.getColumnIndex('chapter_index')),
      chapterTitle: rs.getString(rs.getColumnIndex('chapter_title')),
      paragraphIndex: rs.getLong(rs.getColumnIndex('paragraph_index')),
      charOffset: rs.getLong(rs.getColumnIndex('char_offset')),
      percent: rs.getDouble(rs.getColumnIndex('percent')),
      updatedAt: rs.getLong(rs.getColumnIndex('updated_at'))
    };
  }
  rs.close();
  return p;
}