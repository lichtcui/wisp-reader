import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo, picker } from '@kit.CoreFileKit';
import { Book, Chapter } from '../engine/types';
import { sanitizeText } from './BookContent';
import { inspectDownload, readDownloadedChapterText } from './DownloadStore';

const FILE_CHUNK_BYTES: number = 1024 * 1024;
const ENCODE_CHUNK_CHARS: number = Math.floor(FILE_CHUNK_BYTES / 4);
const MAX_FILE_NAME_CHARS: number = 120;
const INVALID_FILE_NAME_CHARS: RegExp = /[\\/:*?"<>|\u0000-\u001f]/g;

class TextFileWriter {
  private readonly fd: number;
  private readonly encoder: util.TextEncoder = util.TextEncoder.create('utf-8');
  private readonly buffer: ArrayBuffer = new ArrayBuffer(FILE_CHUNK_BYTES);
  private readonly bytes: Uint8Array = new Uint8Array(this.buffer);

  constructor(fd: number) {
    this.fd = fd;
  }

  private async writeAll(length: number): Promise<void> {
    let written: number = 0;
    while (written < length) {
      const source: ArrayBuffer = written === 0 ? this.buffer : this.buffer.slice(written, length);
      const count: number = await fileIo.write(this.fd, source, { length: length - written });
      if (count <= 0) {
        throw new Error('failed to write txt');
      }
      written += count;
    }
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
        throw new Error('failed to encode txt');
      }
      await this.writeAll(encoded.written);
      next += encoded.read;
    }
  }
}

function safePart(value: string, fallback: string): string {
  let text: string = value.replace(INVALID_FILE_NAME_CHARS, '_').trim();
  text = text.replace(/[. ]+$/g, '');
  if (text.length > MAX_FILE_NAME_CHARS) {
    text = text.substring(0, MAX_FILE_NAME_CHARS).trim();
  }
  return text.length > 0 ? text : fallback;
}

/** Match Legado's default export name: `书名 作者：作者.txt`. */
export function downloadedTxtFileName(book: Book): string {
  const name: string = safePart(book.name, '未命名');
  const author: string = safePart(book.author, '佚名');
  return name + ' 作者：' + author + '.txt';
}

export function downloadedTxtHeader(book: Book): string {
  const author: string = book.author.trim().length > 0 ? book.author.trim() : '佚名';
  const intro: string = book.intro.replace(/\r\n/g, '\n').replace(/\r/g, '\n').trim();
  let header: string = book.name.trim() + '\n作者：' + author + '\n';
  if (intro.length > 0) {
    header += '\n简介：\n' + intro + '\n';
  }
  return header;
}

export function downloadedTxtChapter(title: string, raw: string): string {
  return '\n\n' + sanitizeText(raw, title).join('\n') + '\n';
}

/**
 * Export an already-complete permanent download as one UTF-8 TXT file.
 * Returns false when the user dismisses the system save picker.
 */
export async function exportDownloadedTxt(
  ctx: common.UIAbilityContext,
  book: Book,
  chapters: Chapter[]
): Promise<boolean> {
  if (!inspectDownload(ctx, book, chapters).complete) {
    throw new Error('download incomplete');
  }

  const savePicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
  const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
  options.newFileNames = [downloadedTxtFileName(book)];
  options.fileSuffixChoices = ['TXT|.txt'];
  const uris: string[] = await savePicker.save(options);
  if (uris.length === 0) {
    return false;
  }

  const tempPath: string = ctx.cacheDir + '/book_export_' + Date.now().toString() +
    Math.floor(Math.random() * 1000000).toString() + '.txt';
  const tempFile: fileIo.File = await fileIo.open(
    tempPath,
    fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
  );
  try {
    try {
      const writer: TextFileWriter = new TextFileWriter(tempFile.fd);
      await writer.writeText(downloadedTxtHeader(book));
      for (let i = 0; i < chapters.length; i++) {
        const chapter: Chapter = chapters[i];
        if (chapter.isVolume === true) {
          continue;
        }
        const content: string | undefined =
          await readDownloadedChapterText(ctx, book.bookId, i, chapter.url);
        if (content === undefined) {
          throw new Error('download chapter missing');
        }
        await writer.writeText(downloadedTxtChapter(chapter.title, content));
      }
    } finally {
      await fileIo.close(tempFile);
    }
    const target: fileIo.File = await fileIo.open(
      uris[0],
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC
    );
    try {
      await fileIo.copyFile(tempPath, target.fd);
    } finally {
      await fileIo.close(target);
    }
  } finally {
    try {
      await fileIo.unlink(tempPath);
    } catch (err) {
      // The exported file is already complete; a failed temp cleanup is harmless.
    }
  }
  return true;
}
