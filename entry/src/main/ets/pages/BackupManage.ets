import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { Book, BookSource, ReadProgress } from '../engine/types';
import { countRows, exportAll, initSourceStore, replaceAll } from '../model/SourceStore';
import { migrateFromPrefsOnce } from '../model/SourceStoreMigration';
import { countShelfRows, getAllProgress, getBooks, initShelf, replaceShelf, ShelfCounts } from '../model/ShelfRepository';
import { GroupTitle } from '../components/ListCells';

const DOMAIN: number = 0x0000;
const TAG: string = 'SourceReaderBackup';
const BACKUP_SCHEMA_VERSION: number = 1;
const FILE_CHUNK_BYTES: number = 1024 * 1024;
const ENCODE_CHUNK_CHARS: number = Math.floor(FILE_CHUNK_BYTES / 4);
const BACKUP_TEMP_SUFFIX: string = '.tmp';

interface BackupPayload {
  schemaVersion: number;
  exportedAt: number;
  sources: BookSource[];
  books: Book[];
  progress: ReadProgress[];
}

/** Reuse the encoder and byte buffer across every fragment of one export. */
class BackupWriter {
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
      const n: number = await fileIo.write(this.fd, source, { length: length - written });
      if (n <= 0) {
        throw new Error('failed to write backup');
      }
      written += n;
    }
  }

  async writeText(text: string): Promise<void> {
    if (text.length === 0) {
      return;
    }
    let next: number = 0;
    while (next < text.length) {
      let end: number = Math.min(text.length, next + ENCODE_CHUNK_CHARS);
      if (end < text.length && end > next) {
        const last: number = text.charCodeAt(end - 1);
        if (last >= 0xD800 && last <= 0xDBFF) {
          end -= 1; // Keep surrogate pairs in the same UTF-8 chunk.
        }
      }
      const encoded: util.EncodeIntoUint8ArrayInfo =
        this.encoder.encodeIntoUint8Array(text.substring(next, end), this.bytes);
      if (encoded.read <= 0 || encoded.written <= 0) {
        throw new Error('failed to encode backup');
      }
      await this.writeAll(encoded.written);
      next += encoded.read;
    }
  }
}

@ComponentV2
export struct BackupManagePage {
  @Local sourceCount: number = 0;
  @Local bookCount: number = 0;
  @Local progressCount: number = 0;

  aboutToAppear(): void {
    this.reload();
  }

  private ctx(): common.UIAbilityContext | undefined {
    return this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private async prepareSourceStore(ctx: common.UIAbilityContext): Promise<void> {
    await initSourceStore(ctx);
    await migrateFromPrefsOnce(ctx);
  }

  private async reload(): Promise<void> {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return;
    }
    await this.prepareSourceStore(ctx);
    this.sourceCount = (await countRows()).total;
    const counts: ShelfCounts = await countShelfRows();
    this.bookCount = counts.books;
    this.progressCount = counts.progress;
  }

  private pad2(n: number): string {
    return n < 10 ? '0' + n.toString() : n.toString();
  }

  private dateStr(): string {
    const d: Date = new Date();
    return d.getFullYear().toString() + '-' + this.pad2(d.getMonth() + 1) + '-' + this.pad2(d.getDate());
  }

  private async readText(uri: string): Promise<string> {
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
        parts.push(decoder.decodeToString(bytes.subarray(0, read), { stream: total + read < stat.size }));
        total += read;
      }
      return parts.join('');
    } finally {
      await fileIo.close(file);
    }
  }

  private async writeJsonArray<T>(
    writer: BackupWriter, name: string, values: T[], hasNext: boolean
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

  /** Write each row while it is hot; the full backup never exists as one string. */
  private async writeBackup(writer: BackupWriter, ctx: common.UIAbilityContext): Promise<void> {
    await this.prepareSourceStore(ctx);
    await writer.writeText(
      '{\n  "schemaVersion": ' + BACKUP_SCHEMA_VERSION.toString() +
        ',\n  "exportedAt": ' + Date.now().toString() + ',\n'
    );
    const sources: BookSource[] = await exportAll();
    await this.writeJsonArray(writer, 'sources', sources, true);
    const books: Book[] = await getBooks();
    await this.writeJsonArray(writer, 'books', books, true);
    const progressMap: Map<string, ReadProgress> = await getAllProgress();
    const progress: ReadProgress[] = [];
    progressMap.forEach((p: ReadProgress) => {
      progress.push(p);
    });
    await this.writeJsonArray(writer, 'progress', progress, false);
    await writer.writeText('}\n');
  }

  private async doExport(): Promise<void> {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return;
    }
    let tempPath: string = '';
    let tempCreated: boolean = false;
    try {
      const savePicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = ['sourcereader_backup_' + this.dateStr() + '.json'];
      options.fileSuffixChoices = ['JSON|.json'];
      const uris: string[] = await savePicker.save(options);
      if (uris.length === 0) {
        return;
      }
      tempPath = ctx.cacheDir + '/sourcereader_backup_' + Date.now().toString() + '_' +
        Math.floor(Math.random() * 1000000).toString() + BACKUP_TEMP_SUFFIX;
      const tempFile: fileIo.File = await fileIo.open(
        tempPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
      );
      tempCreated = true;
      try {
        await this.writeBackup(new BackupWriter(tempFile.fd), ctx);
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
      this.toast('备份已导出');
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'export failed code=%{public}d msg=%{public}s', e.code, e.message);
      this.toast('导出失败');
    } finally {
      if (tempCreated) {
        try {
          await fileIo.unlink(tempPath);
        } catch (err) {
          const e: BusinessError = err as BusinessError;
          hilog.warn(DOMAIN, TAG, 'temp backup cleanup failed code=%{public}d msg=%{public}s',
            e.code, e.message);
        }
      }
    }
  }

  private async doImport(): Promise<void> {
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return;
    }
    try {
      const viewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.json'];
      const uris: string[] = await viewPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      const text: string = await this.readText(uris[0]);
      const payload: BackupPayload = JSON.parse(text) as BackupPayload;
      if (payload === null || payload.schemaVersion !== BACKUP_SCHEMA_VERSION) {
        this.toast('备份文件版本不受支持');
        return;
      }
      const sources: BookSource[] = payload.sources;
      const books: Book[] = payload.books;
      const progress: ReadProgress[] = payload.progress;
      if (!Array.isArray(sources) || !Array.isArray(books) || !Array.isArray(progress)) {
        this.toast('备份内容不完整');
        return;
      }
      await this.prepareSourceStore(ctx);
      await initShelf(ctx);
      // 备份恢复是全量覆盖，不能走 upsert，否则会保留备份中不存在的书源。
      await replaceAll(sources);
      await replaceShelf(books, progress);
      await this.reload();
      this.toast('已恢复：书源 ' + this.sourceCount + ' / 书架 ' + this.bookCount + ' / 进度 ' + this.progressCount);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'import failed code=%{public}d msg=%{public}s', e.code, e.message);
      this.toast('导入失败：文件无效或格式错误');
    }
  }

  private confirmImport(): void {
    this.getUIContext().showAlertDialog({
      title: '确认恢复备份',
      message: '将用备份文件全量覆盖当前书源、书架与阅读进度：现有数据会被清除，' +
        '备份中不存在的书源、书籍与进度不会被保留。是否继续？',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        fontColor: $r('app.color.text_2'),
        action: () => {
        }
      },
      secondaryButton: {
        value: '恢复',
        fontColor: $r('app.color.brand'),
        action: () => {
          this.doImport();
        }
      }
    });
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          GroupTitle({ text: '当前数据' })
          Column() {
            Row() {
              Text('书源')
                .fontSize(16)
                .fontColor($r('app.color.text_1'))
              Blank()
              Text(this.sourceCount.toString() + ' 个')
                .fontSize(14)
                .fontColor($r('app.color.text_4'))
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })

            Row() {
              Text('书架书籍')
                .fontSize(16)
                .fontColor($r('app.color.text_1'))
              Blank()
              Text(this.bookCount.toString() + ' 本')
                .fontSize(14)
                .fontColor($r('app.color.text_4'))
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })

            Row() {
              Text('阅读进度')
                .fontSize(16)
                .fontColor($r('app.color.text_1'))
              Blank()
              Text(this.progressCount.toString() + ' 条')
                .fontSize(14)
                .fontColor($r('app.color.text_4'))
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          }
          .width('100%')
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(12)
          .margin({ left: 16, right: 16, top: 6 })

          GroupTitle({ text: '操作' })
          Row({ space: 12 }) {
            Button('导出备份')
              .layoutWeight(1)
              .height(48)
              .fontSize(16)
              .fontColor($r('app.color.brand'))
              .backgroundColor($r('app.color.bg_pill'))
              .borderRadius(24)
              .onClick(() => {
                this.doExport();
              })
            Button('导入并恢复')
              .layoutWeight(1)
              .height(48)
              .fontSize(16)
              .fontColor($r('app.color.on_brand'))
              .backgroundColor($r('app.color.brand'))
              .borderRadius(24)
              .onClick(() => {
                this.confirmImport();
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 6 })

          Text('备份为单一 JSON 文件，包含书源、书架书籍与阅读进度；导入会全量覆盖现有数据（备份中不存在的书源、书籍与进度将被删除）。')
            .fontSize(12)
            .fontColor($r('app.color.text_4'))
            .lineHeight(18)
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 40 })
        }
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
