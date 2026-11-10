import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { Book, Chapter } from '../engine/types';

/**
 * Permanent per-book downloads live outside the disposable chapter cache:
 * `filesDir/downloads/<bookId>/`.
 *
 * `manifest.json` exists only after every readable chapter was fetched. The
 * downloader removes the previous manifest before an incremental update, so a
 * process kill leaves a visibly incomplete download that must be restarted from
 * scratch instead of silently resuming.
 */
const DOWNLOAD_DIR: string = 'downloads';
const MANIFEST_FILE: string = 'manifest.json';
const TEMP_SUFFIX: string = '.tmp';

export interface DownloadManifest {
  tocUrl: string;
  tocFingerprint: string;
  chapterCount: number;
  completedAt: number;
}

interface StoredChapter {
  url: string;
  content: string;
  fetchedAt: number;
}

export class BookDownloadState {
  hasDirectory: boolean;
  downloadedCount: number;
  readableCount: number;
  complete: boolean;
  needsUpdate: boolean;
  /**
   * A valid completion manifest is the only proof that an interrupted run may
   * reuse chapter files. A directory without one is a cancelled or killed run
   * and must be downloaded again from scratch.
   */
  canUpdate: boolean;

  constructor(
    hasDirectory: boolean,
    downloadedCount: number,
    readableCount: number,
    complete: boolean,
    needsUpdate: boolean,
    canUpdate: boolean
  ) {
    this.hasDirectory = hasDirectory;
    this.downloadedCount = downloadedCount;
    this.readableCount = readableCount;
    this.complete = complete;
    this.needsUpdate = needsUpdate;
    this.canUpdate = canUpdate;
  }
}

function rootDir(ctx: common.UIAbilityContext): string {
  return ctx.filesDir + '/' + DOWNLOAD_DIR;
}

function bookDir(ctx: common.UIAbilityContext, bookId: string): string {
  return rootDir(ctx) + '/' + bookId;
}

function chapterPath(ctx: common.UIAbilityContext, bookId: string, index: number): string {
  return bookDir(ctx, bookId) + '/' + index.toString() + '.json';
}

function manifestPath(ctx: common.UIAbilityContext, bookId: string): string {
  return bookDir(ctx, bookId) + '/' + MANIFEST_FILE;
}

function ensureDir(dir: string): void {
  if (!fileIo.accessSync(dir)) {
    fileIo.mkdirSync(dir, true);
  }
}

function writeTextAtomic(path: string, text: string, fsync: boolean): void {
  const temp: string = path + TEMP_SUFFIX;
  const file: fileIo.File = fileIo.openSync(
    temp,
    fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
  );
  try {
    fileIo.writeSync(file.fd, text);
    if (fsync) {
      fileIo.fsyncSync(file.fd);
    }
  } finally {
    fileIo.closeSync(file);
  }
  // Mode 0 replaces an existing chapter or manifest at the destination.
  fileIo.moveFileSync(temp, path, 0);
}

function readableCount(chapters: Chapter[]): number {
  let count: number = 0;
  for (let i = 0; i < chapters.length; i++) {
    if (chapters[i].isVolume !== true) {
      count += 1;
    }
  }
  return count;
}

/**
 * Stable fingerprint of the readable TOC. Titles are included because a title
 * change can signal that the source replaced a chapter even when the URL stayed.
 */
export function tocFingerprint(chapters: Chapter[]): string {
  let hash: number = 0x811c9dc5;
  for (let i = 0; i < chapters.length; i++) {
    const chapter: Chapter = chapters[i];
    if (chapter.isVolume === true) {
      continue;
    }
    const fields: string[] = [chapter.title, chapter.url];
    for (let j = 0; j < fields.length; j++) {
      const text: string = fields[j];
      for (let k = 0; k < text.length; k++) {
        hash = hash ^ text.charCodeAt(k);
        hash = Math.imul(hash, 0x01000193);
      }
      hash = hash ^ 0x1f;
      hash = Math.imul(hash, 0x01000193);
    }
  }
  return (hash >>> 0).toString(16);
}

function readManifest(ctx: common.UIAbilityContext, bookId: string): DownloadManifest | undefined {
  const path: string = manifestPath(ctx, bookId);
  try {
    if (!fileIo.accessSync(path)) {
      return undefined;
    }
    const value: DownloadManifest = JSON.parse(fileIo.readTextSync(path)) as DownloadManifest;
    if (typeof value.tocUrl !== 'string' ||
      typeof value.tocFingerprint !== 'string' ||
      typeof value.chapterCount !== 'number' ||
      typeof value.completedAt !== 'number') {
      return undefined;
    }
    return value;
  } catch (err) {
    return undefined;
  }
}

function countChapterFiles(dir: string): number {
  let names: string[] = [];
  try {
    if (!fileIo.accessSync(dir)) {
      return 0;
    }
    names = fileIo.listFileSync(dir);
  } catch (err) {
    return 0;
  }
  let count: number = 0;
  for (let i = 0; i < names.length; i++) {
    const name: string = names[i];
    if (name.endsWith('.json') && name !== MANIFEST_FILE) {
      count += 1;
    }
  }
  return count;
}

/** Snapshot used by the reader menu and downloader. */
export function inspectDownload(
  ctx: common.UIAbilityContext,
  book: Book,
  chapters: Chapter[]
): BookDownloadState {
  const dir: string = bookDir(ctx, book.bookId);
  let hasDirectory: boolean = false;
  try {
    hasDirectory = fileIo.accessSync(dir);
  } catch (err) {
    hasDirectory = false;
  }
  const readable: number = readableCount(chapters);
  const downloaded: number = countChapterFiles(dir);
  const manifest: DownloadManifest | undefined = readManifest(ctx, book.bookId);
  const fingerprint: string = tocFingerprint(chapters);
  const complete: boolean = manifest !== undefined &&
    readable > 0 &&
    manifest.chapterCount === readable &&
    downloaded >= readable &&
    manifest.tocUrl === book.tocUrl &&
    manifest.tocFingerprint === fingerprint;
  const canUpdate: boolean = manifest !== undefined && readable > 0;
  const needsUpdate: boolean = canUpdate && !complete;
  return new BookDownloadState(hasDirectory, downloaded, readable, complete, needsUpdate, canUpdate);
}

/** Return permanent content only when the chapter URL still matches. */
export function getDownloadedChapter(
  ctx: common.UIAbilityContext,
  bookId: string,
  index: number,
  url: string
): string | undefined {
  const path: string = chapterPath(ctx, bookId, index);
  try {
    if (!fileIo.accessSync(path)) {
      return undefined;
    }
    const entry: StoredChapter = JSON.parse(fileIo.readTextSync(path)) as StoredChapter;
    if (entry.url !== url || typeof entry.content !== 'string') {
      return undefined;
    }
    return entry.content;
  } catch (err) {
    return undefined;
  }
}

/** Async variant for exporting a whole book without blocking on every chapter read. */
export async function readDownloadedChapterText(
  ctx: common.UIAbilityContext,
  bookId: string,
  index: number,
  url: string
): Promise<string | undefined> {
  const path: string = chapterPath(ctx, bookId, index);
  try {
    if (!fileIo.accessSync(path)) {
      return undefined;
    }
    const entry: StoredChapter = JSON.parse(await fileIo.readText(path)) as StoredChapter;
    if (entry.url !== url || typeof entry.content !== 'string') {
      return undefined;
    }
    return entry.content;
  } catch (err) {
    return undefined;
  }
}

/** Persist one chapter. Unlike the disposable chapter cache, write failures throw. */
export function writeDownloadedChapter(
  ctx: common.UIAbilityContext,
  bookId: string,
  index: number,
  url: string,
  content: string
): void {
  const dir: string = bookDir(ctx, bookId);
  ensureDir(dir);
  const entry: StoredChapter = { url: url, content: content, fetchedAt: Date.now() };
  writeTextAtomic(chapterPath(ctx, bookId, index), JSON.stringify(entry), false);
}

export function writeDownloadManifest(
  ctx: common.UIAbilityContext,
  book: Book,
  chapters: Chapter[]
): void {
  const dir: string = bookDir(ctx, book.bookId);
  ensureDir(dir);
  const manifest: DownloadManifest = {
    tocUrl: book.tocUrl,
    tocFingerprint: tocFingerprint(chapters),
    chapterCount: readableCount(chapters),
    completedAt: Date.now()
  };
  writeTextAtomic(manifestPath(ctx, book.bookId), JSON.stringify(manifest), true);
}

/**
 * Remove only the completion proof; chapter files remain for a manual TOC
 * update. This deliberately throws if removal fails: keeping the old manifest
 * would make an interrupted update look resumable on the next launch.
 */
export function clearDownloadManifest(ctx: common.UIAbilityContext, bookId: string): void {
  const path: string = manifestPath(ctx, bookId);
  if (!fileIo.accessSync(path)) {
    return;
  }
  fileIo.unlinkSync(path);
}

export function ensureBookDownloadDir(ctx: common.UIAbilityContext, bookId: string): void {
  ensureDir(bookDir(ctx, bookId));
}

/** Recursively remove one book's permanent download. */
export function deleteBookDownload(ctx: common.UIAbilityContext, bookId: string): void {
  const dir: string = bookDir(ctx, bookId);
  try {
    if (fileIo.accessSync(dir)) {
      fileIo.rmdirSync(dir);
    }
  } catch (err) {
    return;
  }
}

/** Full backup restore replaces the shelf, so downloads absent from it are orphans. */
export function sweepOrphanDownloads(ctx: common.UIAbilityContext, keepBookIds: string[]): void {
  const keep: Set<string> = new Set<string>();
  for (let i = 0; i < keepBookIds.length; i++) {
    keep.add(keepBookIds[i]);
  }
  const root: string = rootDir(ctx);
  let names: string[] = [];
  try {
    if (!fileIo.accessSync(root)) {
      return;
    }
    names = fileIo.listFileSync(root);
  } catch (err) {
    return;
  }
  for (let i = 0; i < names.length; i++) {
    const name: string = names[i];
    if (keep.has(name)) {
      continue;
    }
    try {
      fileIo.rmdirSync(root + '/' + name);
    } catch (err) {
      continue;
    }
  }
}
