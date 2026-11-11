/**
 * Backup payload validation and restore journal.
 *
 * `sources.db` and `shelf.db` are separate RDB stores, so an import cannot be one
 * cross-store transaction. Before either table is replaced, the current data is
 * written to a journal in `filesDir`. A failed import rolls back immediately; if
 * the process dies mid-import, the next startup restores the journal before normal
 * use. This provides crash recovery, not a claim of cross-database atomicity.
 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { Book, BookSource, ReadProgress } from '../engine/types';
import { countRows, exportAll, initSourceStore, replaceAll } from './SourceStore';
import { countShelfRows, getAllProgress, getBooks, initShelf, replaceShelf, ShelfCounts } from './ShelfRepository';
import { sweepOrphanDownloads } from './DownloadStore';
import { BookDownloader } from './BookDownloader';

const DOMAIN: number = 0x0000;
const TAG: string = 'WispReaderBackup';
const FILE_CHUNK_BYTES: number = 1024 * 1024;
const ENCODE_CHUNK_CHARS: number = Math.floor(FILE_CHUNK_BYTES / 4);
const RESTORE_JOURNAL_NAME: string = 'backup-restore.pending.json';
const RESTORE_JOURNAL_TEMP_SUFFIX: string = '.tmp';

export const BACKUP_SCHEMA_VERSION: number = 1;

export interface BackupPayload {
  schemaVersion: number;
  exportedAt: number;
  sources: BookSource[];
  books: Book[];
  progress: ReadProgress[];
}

export interface RestoreRecoveryResult {
  status: string;
  sources: number;
  books: number;
  progress: number;
}

export class BackupValidationError extends Error {
  readonly kind: string;

  constructor(kind: string, message: string) {
    super(message);
    this.name = 'BackupValidationError';
    this.kind = kind;
  }
}

class TextFdWriter {
  private readonly fd: number;
  private readonly encoder: util.TextEncoder = util.TextEncoder.create('utf-8');
  private readonly buffer: ArrayBuffer = new ArrayBuffer(FILE_CHUNK_BYTES);
  private readonly bytes: Uint8Array = new Uint8Array(this.buffer);
  totalBytes: number = 0;

  constructor(fd: number) {
    this.fd = fd;
  }

  private async writeAll(length: number): Promise<void> {
    let written: number = 0;
    while (written < length) {
      const source: ArrayBuffer = written === 0 ? this.buffer : this.buffer.slice(written, length);
      const n: number = await fileIo.write(this.fd, source, { length: length - written });
      if (n <= 0) {
        throw new Error('failed to write restore journal');
      }
      written += n;
    }
    this.totalBytes += length;
  }

  async writeText(text: string): Promise<void> {
    let next: number = 0;
    while (next < text.length) {
      let end: number = Math.min(text.length, next + ENCODE_CHUNK_CHARS);
      if (end < text.length && end > next) {
        const last: number = text.charCodeAt(end - 1);
        if (last >= 0xD800 && last <= 0xDBFF) {
          end -= 1;
        }
      }
      const encoded: util.EncodeIntoUint8ArrayInfo =
        this.encoder.encodeIntoUint8Array(text.substring(next, end), this.bytes);
      if (encoded.read <= 0 || encoded.written <= 0) {
        throw new Error('failed to encode restore journal');
      }
      await this.writeAll(encoded.written);
      next += encoded.read;
    }
  }
}

function validationError(kind: string, message: string): BackupValidationError {
  return new BackupValidationError(kind, message);
}

function isFiniteNumber(value: number | undefined): boolean {
  return value !== undefined && typeof value === 'number' && Number.isFinite(value);
}

function isNonNegativeInteger(value: number | undefined): boolean {
  return value !== undefined && typeof value === 'number' &&
    Number.isInteger(value) && value >= 0;
}

function isOptionalString(value: string | undefined): boolean {
  return value === undefined || value === null || typeof value === 'string';
}

function isOptionalBoolean(value: boolean | undefined): boolean {
  return value === undefined || value === null || typeof value === 'boolean';
}

function isOptionalNumber(value: number | undefined): boolean {
  return value === undefined || value === null || isFiniteNumber(value);
}

function isOptionalObject(value: object | undefined): boolean {
  return value === undefined || value === null || (typeof value === 'object' && !Array.isArray(value));
}

function validateSource(source: BookSource, index: number): void {
  if (source === null || typeof source !== 'object' || Array.isArray(source)) {
    throw validationError('field', 'sources[' + index + '] is not an object');
  }
  if (typeof source.bookSourceName !== 'string') {
    throw validationError('field', 'sources[' + index + '].bookSourceName is not a string');
  }
  if (typeof source.bookSourceUrl !== 'string' || source.bookSourceUrl.length === 0) {
    throw validationError('field', 'sources[' + index + '].bookSourceUrl is empty or invalid');
  }
  if (!Number.isInteger(source.bookSourceType) || source.bookSourceType < 0) {
    throw validationError('field', 'sources[' + index + '].bookSourceType is invalid');
  }
  if (!isOptionalString(source.bookSourceGroup) ||
      !isOptionalString(source.bookSourceComment) ||
      !isOptionalBoolean(source.enabled) ||
      !isOptionalBoolean(source.enabledExplore) ||
      !isOptionalString(source.searchUrl) ||
      !isOptionalString(source.exploreUrl) ||
      !isOptionalString(source.header) ||
      !isOptionalString(source.loginUrl) ||
      !isOptionalString(source.loginUi) ||
      !isOptionalString(source.loginCheckJs) ||
      !isOptionalString(source.bookUrlPattern)) {
    throw validationError('field', 'sources[' + index + '] has an invalid string or boolean field');
  }
  if (!isOptionalNumber(source.weight) ||
      !isOptionalNumber(source.lastUpdateTime) ||
      !isOptionalNumber(source.respondTime)) {
    throw validationError('field', 'sources[' + index + '] has an invalid numeric field');
  }
  if (source.confidence !== undefined && source.confidence !== null &&
      (!isFiniteNumber(source.confidence) || source.confidence < 0 || source.confidence > 100)) {
    throw validationError('field', 'sources[' + index + '].confidence is out of range');
  }
  if (source.concurrentRate !== undefined && source.concurrentRate !== null &&
      typeof source.concurrentRate !== 'string' &&
      (typeof source.concurrentRate !== 'object' || Array.isArray(source.concurrentRate))) {
    throw validationError('field', 'sources[' + index + '].concurrentRate is invalid');
  }
  if (!isOptionalObject(source.ruleSearch) ||
      !isOptionalObject(source.ruleBookInfo) ||
      !isOptionalObject(source.ruleToc) ||
      !isOptionalObject(source.ruleContent)) {
    throw validationError('field', 'sources[' + index + '] has an invalid rule object');
  }
}

function validateBook(book: Book, index: number): void {
  if (book === null || typeof book !== 'object' || Array.isArray(book)) {
    throw validationError('field', 'books[' + index + '] is not an object');
  }
  if (typeof book.bookId !== 'string' || book.bookId.length === 0 ||
      typeof book.sourceUrl !== 'string' || book.sourceUrl.length === 0 ||
      typeof book.name !== 'string' ||
      typeof book.author !== 'string' ||
      typeof book.coverUrl !== 'string' ||
      typeof book.intro !== 'string' ||
      typeof book.kind !== 'string' ||
      typeof book.wordCount !== 'string' ||
      typeof book.status !== 'string' ||
      typeof book.lastChapterTitle !== 'string' ||
      typeof book.tocUrl !== 'string') {
    throw validationError('field', 'books[' + index + '] has an invalid required field');
  }
  if (typeof book.inShelf !== 'boolean') {
    throw validationError('field', 'books[' + index + '].inShelf is not a boolean');
  }
  if (!isNonNegativeInteger(book.addedAt)) {
    throw validationError('field', 'books[' + index + '].addedAt is out of range');
  }
}

function validateProgress(progress: ReadProgress, index: number): void {
  if (progress === null || typeof progress !== 'object' || Array.isArray(progress)) {
    throw validationError('field', 'progress[' + index + '] is not an object');
  }
  if (typeof progress.bookId !== 'string' || progress.bookId.length === 0 ||
      typeof progress.chapterTitle !== 'string') {
    throw validationError('field', 'progress[' + index + '] has an invalid required field');
  }
  if (!Number.isInteger(progress.chapterIndex) || progress.chapterIndex < 0 ||
      !Number.isInteger(progress.paragraphIndex) || progress.paragraphIndex < 0 ||
      !Number.isInteger(progress.charOffset) || progress.charOffset < 0 ||
      !isFiniteNumber(progress.percent) || progress.percent < 0 || progress.percent > 1 ||
      !isNonNegativeInteger(progress.updatedAt)) {
    throw validationError('field', 'progress[' + index + '] has an invalid numeric field');
  }
}

/** Validate the full payload before any RDB is opened, journaled, or changed. */
export function parseBackupPayload(text: string): BackupPayload {
  let payload: BackupPayload;
  try {
    payload = JSON.parse(text) as BackupPayload;
  } catch (err) {
    throw validationError('json', 'backup is not valid JSON');
  }
  if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) {
    throw validationError('field', 'backup root is not an object');
  }
  if (payload.schemaVersion !== BACKUP_SCHEMA_VERSION) {
    throw validationError('version', 'unsupported backup schemaVersion');
  }
  if (!isNonNegativeInteger(payload.exportedAt)) {
    throw validationError('field', 'exportedAt is invalid');
  }
  if (!Array.isArray(payload.sources) || !Array.isArray(payload.books) || !Array.isArray(payload.progress)) {
    throw validationError('incomplete', 'backup arrays are missing');
  }
  const sourceKeys: Map<string, boolean> = new Map<string, boolean>();
  for (let i: number = 0; i < payload.sources.length; i++) {
    validateSource(payload.sources[i], i);
    const key: string =
      payload.sources[i].bookSourceUrl + '\u0000' + payload.sources[i].bookSourceName;
    if (sourceKeys.has(key)) {
      throw validationError('field', 'sources[' + i + '] duplicates a source natural key');
    }
    sourceKeys.set(key, true);
  }
  const bookIds: Map<string, boolean> = new Map<string, boolean>();
  for (let i: number = 0; i < payload.books.length; i++) {
    validateBook(payload.books[i], i);
    if (bookIds.has(payload.books[i].bookId)) {
      throw validationError('field', 'books[' + i + '].bookId is duplicated');
    }
    bookIds.set(payload.books[i].bookId, true);
  }
  const progressBookIds: Map<string, boolean> = new Map<string, boolean>();
  for (let i: number = 0; i < payload.progress.length; i++) {
    validateProgress(payload.progress[i], i);
    if (progressBookIds.has(payload.progress[i].bookId)) {
      throw validationError('field', 'progress[' + i + '].bookId is duplicated');
    }
    progressBookIds.set(payload.progress[i].bookId, true);
  }
  return payload;
}

function journalPath(ctx: common.UIAbilityContext): string {
  return ctx.filesDir + '/' + RESTORE_JOURNAL_NAME;
}

function journalTempPath(ctx: common.UIAbilityContext): string {
  return journalPath(ctx) + RESTORE_JOURNAL_TEMP_SUFFIX;
}

/** Read a picker URI or journal in bounded chunks so a large backup is not duplicated as raw bytes. */
export async function readUtf8Text(uri: string): Promise<string> {
  const file: fileIo.File = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
  try {
    const stat: fileIo.Stat = await fileIo.stat(file.fd);
    if (stat.size <= 0) {
      return '';
    }
    const buffer: ArrayBuffer = new ArrayBuffer(FILE_CHUNK_BYTES);
    const bytes: Uint8Array = new Uint8Array(buffer);
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    const parts: string[] = [];
    let total: number = 0;
    while (total < stat.size) {
      const length: number = Math.min(FILE_CHUNK_BYTES, stat.size - total);
      const read: number = await fileIo.read(file.fd, buffer, { length: length });
      if (read <= 0) {
        throw new Error('unexpected EOF while reading backup');
      }
      parts.push(decoder.decodeToString(
        bytes.subarray(0, read),
        { stream: total + read < stat.size }
      ));
      total += read;
    }
    return parts.join('');
  } finally {
    await fileIo.close(file);
  }
}

async function writeJsonArray<T>(
  writer: TextFdWriter, name: string, values: T[], hasNext: boolean
): Promise<void> {
  if (values.length === 0) {
    await writer.writeText('  "' + name + '": []' + (hasNext ? ',\n' : '\n'));
    return;
  }
  await writer.writeText('  "' + name + '": [\n');
  for (let i: number = 0; i < values.length; i++) {
    const json: string = JSON.stringify(values[i], null, 2);
    const indented: string = '    ' + json.replace(/\n/g, '\n    ');
    await writer.writeText(indented + (i + 1 < values.length ? ',\n' : '\n'));
  }
  await writer.writeText('  ]' + (hasNext ? ',\n' : '\n'));
}

async function writeJournal(ctx: common.UIAbilityContext, payload: BackupPayload): Promise<void> {
  const tempPath: string = journalTempPath(ctx);
  let file: fileIo.File | undefined = undefined;
  let moved: boolean = false;
  try {
    file = await fileIo.open(
      tempPath,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
    );
    const writer: TextFdWriter = new TextFdWriter(file.fd);
    await writer.writeText(
      '{\n  "schemaVersion": ' + BACKUP_SCHEMA_VERSION.toString() +
        ',\n  "exportedAt": ' + payload.exportedAt.toString() + ',\n'
    );
    await writeJsonArray(writer, 'sources', payload.sources, true);
    await writeJsonArray(writer, 'books', payload.books, true);
    await writeJsonArray(writer, 'progress', payload.progress, false);
    await writer.writeText('}\n');
    fileIo.fsyncSync(file.fd);
    await fileIo.close(file);
    file = undefined;
    const size: number = fileIo.statSync(tempPath).size;
    if (size !== writer.totalBytes) {
      throw new Error('restore journal size mismatch: expected ' + writer.totalBytes + ', got ' + size);
    }
    fileIo.moveFileSync(tempPath, journalPath(ctx), 0);
    moved = true;
  } finally {
    if (file !== undefined) {
      try {
        await fileIo.close(file);
      } catch (err) {
      }
    }
    try {
      if (!moved && fileIo.accessSync(tempPath)) {
        await fileIo.unlink(tempPath);
      }
    } catch (err) {
    }
  }
}

export function hasPendingRestore(ctx: common.UIAbilityContext): boolean {
  try {
    return fileIo.accessSync(journalPath(ctx));
  } catch (err) {
    return false;
  }
}

/**
 * Persist the pre-import rows before either database is replaced.
 *
 * The journal is written to a sibling temp file, fsynced, size-checked and atomically
 * renamed into place. If the process is killed after either replace succeeds, startup
 * can still restore this snapshot.
 */
export async function createRestoreJournal(ctx: common.UIAbilityContext): Promise<void> {
  if (hasPendingRestore(ctx)) {
    throw new Error('pending restore journal already exists');
  }
  await initSourceStore(ctx);
  await initShelf(ctx);
  const progressMap: Map<string, ReadProgress> = await getAllProgress();
  const progress: ReadProgress[] = [];
  progressMap.forEach((row: ReadProgress): void => {
    progress.push(row);
  });
  const payload: BackupPayload = {
    schemaVersion: BACKUP_SCHEMA_VERSION,
    exportedAt: Date.now(),
    sources: await exportAll(),
    books: await getBooks(),
    progress: progress
  };
  await writeJournal(ctx, payload);
  hilog.info(DOMAIN, TAG, 'restore journal created sources=%{public}d books=%{public}d progress=%{public}d',
    payload.sources.length, payload.books.length, payload.progress.length);
}

export async function clearRestoreJournal(ctx: common.UIAbilityContext): Promise<void> {
  if (hasPendingRestore(ctx)) {
    await fileIo.unlink(journalPath(ctx));
    hilog.info(DOMAIN, TAG, 'restore journal cleared');
  }
}

/**
 * Replace both stores and verify their committed counts.
 *
 * This is explicitly not a cross-store transaction: both replaces can commit
 * independently. The caller only treats success as complete after both counts
 * match and the recovery journal has been removed.
 */
export async function applyRestorePayload(
  ctx: common.UIAbilityContext, payload: BackupPayload
): Promise<RestoreRecoveryResult> {
  // Restore replaces shelf ownership; an in-process job must not recreate an orphan download.
  BookDownloader.instance().cancel();
  await initSourceStore(ctx);
  await initShelf(ctx);
  await replaceAll(payload.sources, payload.sources.length);
  await replaceShelf(payload.books, payload.progress);

  const sourceCount: number = (await countRows()).total;
  const shelf: ShelfCounts = await countShelfRows();
  if (sourceCount !== payload.sources.length ||
      shelf.books !== payload.books.length ||
      shelf.progress !== payload.progress.length) {
    throw new Error(
      'restore count mismatch: expected ' +
        payload.sources.length + '/' + payload.books.length + '/' + payload.progress.length +
        ', got ' + sourceCount + '/' + shelf.books + '/' + shelf.progress
    );
  }
  await clearRestoreJournal(ctx);
  // Orphan state follows the committed restored shelf, so sweep only after commit.
  sweepOrphanDownloads(ctx, payload.books.map((book: Book): string => book.bookId));
  hilog.info(DOMAIN, TAG, 'restore committed sources=%{public}d books=%{public}d progress=%{public}d',
    sourceCount, shelf.books, shelf.progress);
  return { status: 'restored', sources: sourceCount, books: shelf.books, progress: shelf.progress };
}

async function recoverPendingRestoreOnce(ctx: common.UIAbilityContext): Promise<RestoreRecoveryResult> {
  if (!hasPendingRestore(ctx)) {
    return { status: 'none', sources: 0, books: 0, progress: 0 };
  }
  try {
    hilog.info(DOMAIN, TAG, 'restore recovery begin');
    const text: string = await readUtf8Text(journalPath(ctx));
    const payload: BackupPayload = parseBackupPayload(text);
    const result: RestoreRecoveryResult = await applyRestorePayload(ctx, payload);
    hilog.info(DOMAIN, TAG, 'restore recovery complete sources=%{public}d books=%{public}d progress=%{public}d',
      result.sources, result.books, result.progress);
    return result;
  } catch (err) {
    const e: Error = err as Error;
    hilog.error(DOMAIN, TAG, 'restore recovery failed msg=%{public}s', e.message);
    throw e;
  }
}

let recovering: Promise<RestoreRecoveryResult> | undefined = undefined;

/** Startup and the backup page can race; both await the same recovery pass. */
export async function recoverPendingRestore(
  ctx: common.UIAbilityContext
): Promise<RestoreRecoveryResult> {
  if (recovering !== undefined) {
    return recovering;
  }
  const run: Promise<RestoreRecoveryResult> = recoverPendingRestoreOnce(ctx);
  recovering = run;
  try {
    return await run;
  } finally {
    if (recovering === run) {
      recovering = undefined;
    }
  }
}
