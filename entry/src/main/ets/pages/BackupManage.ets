import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { Book, BookSource, ReadProgress } from '../engine/types';
import { countRows, exportAll, initSourceStore } from '../model/SourceStore';
import { migrateFromPrefsOnce } from '../model/SourceStoreMigration';
import { countShelfRows, getAllProgress, getBooks, initShelf, ShelfCounts } from '../model/ShelfRepository';
import {
  applyRestorePayload,
  BACKUP_SCHEMA_VERSION,
  BackupPayload,
  BackupValidationError,
  createRestoreJournal,
  hasPendingRestore,
  parseBackupPayload,
  readUtf8Text,
  recoverPendingRestore,
  RestoreRecoveryResult
} from '../model/BackupRecovery';
import { GroupTitle } from '../components/ListCells';

const DOMAIN: number = 0x0000;
const TAG: string = 'WispReaderBackup';
const FILE_CHUNK_BYTES: number = 1024 * 1024;
const ENCODE_CHUNK_CHARS: number = Math.floor(FILE_CHUNK_BYTES / 4);
const BACKUP_TEMP_SUFFIX: string = '.tmp';

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
  @Local busy: boolean = false;
  @Local importDialogOpen: boolean = false;

  aboutToAppear(): void {
    this.startup();
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

  private async recoverThenReload(ctx: common.UIAbilityContext): Promise<void> {
    await recoverPendingRestore(ctx);
    await this.reloadData(ctx);
  }

  private async startup(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      this.busy = false;
      return;
    }
    try {
      await this.recoverThenReload(ctx);
    } catch (err) {
      const e: Error = err as Error;
      hilog.error(DOMAIN, TAG, 'startup recovery failed msg=%{public}s', e.message);
      this.toast('上次恢复未完成，旧数据恢复失败，请重启应用重试');
    } finally {
      this.busy = false;
    }
  }

  private async reloadData(ctx: common.UIAbilityContext): Promise<void> {
    await this.prepareSourceStore(ctx);
    await initShelf(ctx);
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
    await initShelf(ctx);
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
    if (this.busy) {
      return;
    }
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return;
    }
    this.busy = true;
    let tempPath: string = '';
    let tempCreated: boolean = false;
    try {
      await recoverPendingRestore(ctx);
      const savePicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = ['wispreader_backup_' + this.dateStr() + '.json'];
      options.fileSuffixChoices = ['JSON|.json'];
      const uris: string[] = await savePicker.save(options);
      if (uris.length === 0) {
        return;
      }
      tempPath = ctx.cacheDir + '/wispreader_backup_' + Date.now().toString() + '_' +
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
      if (hasPendingRestore(ctx)) {
        this.toast('导出失败：上次恢复未完成，请重启应用重试');
      } else {
        this.toast('导出失败');
      }
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
      this.busy = false;
    }
  }

  private validationToast(err: Error): boolean {
    const e: BackupValidationError = err as BackupValidationError;
    if (e.name !== 'BackupValidationError') {
      return false;
    }
    if (e.kind === 'version') {
      this.toast('备份文件版本不受支持');
    } else if (e.kind === 'incomplete') {
      this.toast('备份内容不完整');
    } else {
      this.toast('导入失败：文件无效或格式错误');
    }
    return true;
  }

  private async doImport(): Promise<void> {
    if (this.busy) {
      return;
    }
    const ctx: common.UIAbilityContext | undefined = this.ctx();
    if (ctx === undefined) {
      return;
    }
    this.busy = true;
    let stage: string = 'picker';
    let journalCreated: boolean = false;
    try {
      const viewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.json'];
      const uris: string[] = await viewPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      stage = 'read';
      const text: string = await readUtf8Text(uris[0]);
      stage = 'validate';
      // Complete validation happens before any RDB is opened or changed.
      const payload: BackupPayload = parseBackupPayload(text);
      stage = 'recover-existing';
      await recoverPendingRestore(ctx);
      stage = 'prepare';
      await this.prepareSourceStore(ctx);
      await initShelf(ctx);
      stage = 'journal';
      await createRestoreJournal(ctx);
      journalCreated = true;
      stage = 'apply';
      const restored: RestoreRecoveryResult = await applyRestorePayload(ctx, payload);
      try {
        await this.reloadData(ctx);
      } catch (err) {
        const e: Error = err as Error;
        hilog.warn(DOMAIN, TAG, 'post-import reload failed msg=%{public}s', e.message);
        this.sourceCount = restored.sources;
        this.bookCount = restored.books;
        this.progressCount = restored.progress;
      }
      this.toast('已恢复：书源 ' + restored.sources + ' / 书架 ' + restored.books +
        ' / 进度 ' + restored.progress);
    } catch (err) {
      const e: Error = err as Error;
      hilog.error(DOMAIN, TAG, 'import %{public}s failed msg=%{public}s', stage, e.message);
      if (this.validationToast(e)) {
        return;
      }
      if (journalCreated || hasPendingRestore(ctx)) {
        try {
          const recovered: RestoreRecoveryResult = await recoverPendingRestore(ctx);
          if (recovered.status !== 'restored') {
            throw new Error('restore journal is missing after import failure');
          }
          this.toast('导入失败，当前数据已恢复');
        } catch (recoveryErr) {
          const re: Error = recoveryErr as Error;
          hilog.error(DOMAIN, TAG, 'import rollback failed msg=%{public}s', re.message);
          this.toast('导入失败：旧数据恢复失败，请重启应用重试');
        }
        return;
      }
      if (hasPendingRestore(ctx)) {
        this.toast('导入失败：上次恢复未完成，请重启应用重试');
        return;
      }
      this.toast('导入失败：文件无效或格式错误');
    } finally {
      this.busy = false;
    }
  }

  private confirmImport(): void {
    if (this.busy || this.importDialogOpen) {
      return;
    }
    this.importDialogOpen = true;
    this.getUIContext().showAlertDialog({
      title: '确认恢复备份',
      message: '将用备份文件全量覆盖当前书源、书架与阅读进度：现有数据会被清除，' +
        '备份中不存在的书源、书籍与进度不会被保留。是否继续？',
      autoCancel: true,
      onWillDismiss: (action: DismissDialogAction) => {
        this.importDialogOpen = false;
        action.dismiss();
      },
      primaryButton: {
        value: '取消',
        fontColor: $r('app.color.text_2'),
        action: () => {
          this.importDialogOpen = false;
        }
      },
      secondaryButton: {
        value: '恢复',
        fontColor: $r('app.color.brand'),
        action: () => {
          this.importDialogOpen = false;
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
              .enabled(!this.busy)
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
              .enabled(!this.busy)
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
